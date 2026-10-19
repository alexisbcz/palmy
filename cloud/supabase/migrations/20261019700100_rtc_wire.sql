-- The chat wire format, shaped in SQL.
--
-- The rtc gateway (cloud/rtc) answers a client by running one of these as
-- that client's identity-scoped session, and splices the JSON it gets back
-- into a frame. So the rows in an answer are exactly the rows RLS lets that
-- identity read: the gateway has no way to put anything else into a reply.
-- The object shapes are the ones apps/chat/PROTOCOL.md documents.
--
-- All of these are security invoker (the default), stable, and read-only,
-- except rtc_seed_reads.

-- One message, as the wire carries it. Absent fields are omitted rather than
-- null, exactly as the v1 server did.
create function public.rtc_msg_json(m public.rtc_messages) returns json
language sql stable set search_path = ''
as $$
	select json_strip_nulls(json_build_object(
		'id', m.id,
		'ch', m.channel_id,
		'nick', m.author_handle,
		'text', m.body,
		'ts', extract(epoch from m.created_at)::bigint,
		'edited', extract(epoch from m.edited_at)::bigint,
		'deleted', case when m.deleted_at is not null then true end,
		'reply_to', m.reply_to,
		'thread', m.thread_root,
		'replies', nullif(m.replies, 0),
		'last_reply', case when m.replies > 0 then extract(epoch from m.last_reply_at)::bigint end,
		'file', case when m.attachment is not null then json_build_object(
			'id', m.id, 'name', m.attachment ->> 'name', 'mime', m.attachment ->> 'mime',
			'size', (m.attachment ->> 'size')::bigint) end,
		'reacts', (select json_agg(json_build_object('key', x.key, 'nicks', x.nicks) order by x.first)
		           from (select r.key, json_agg(r.handle order by r.created_at) as nicks, min(r.created_at) as first
		                 from public.rtc_reactions r where r.message_id = m.id group by r.key) x),
		'seq', m.seq,
		'rev', m.rev,
		'ident', json_build_object('id', m.identity_id, 'handle', m.author_handle,
		                           'name', m.author_name, 'color', m.author_color)
	))
$$;

-- A page of a channel's timeline, oldest first. Thread replies are not in the
-- timeline (PROTOCOL.md, "Threads").
create function public.rtc_history_json(channel uuid, before bigint, lim integer) returns json
language sql stable set search_path = ''
as $$
	with page as (
		select m.* from public.rtc_messages m
		where m.channel_id = channel and m.thread_root is null
		  and (before is null or before = 0 or m.id < before)
		order by m.id desc
		limit least(greatest(lim, 1), 200) + 1
	)
	select json_build_object(
		'msgs', coalesce((select json_agg(public.rtc_msg_json(p) order by p.id)
		                  from (select * from page order by id desc limit least(greatest(lim, 1), 200)) p), '[]'),
		'more', (select count(*) from page) > least(greatest(lim, 1), 200))
$$;

-- A thread: its root and the newest `lim` replies, oldest first. `id` may be
-- the root or any reply in it.
create function public.rtc_thread_json(msg bigint, lim integer) returns json
language sql stable set search_path = ''
as $$
	with root as (
		select r.* from public.rtc_messages r
		where r.id = (select coalesce(m.thread_root, m.id) from public.rtc_messages m where m.id = msg)
	), replies as (
		select m.* from public.rtc_messages m, root where m.thread_root = root.id
	), page as (
		select * from replies order by id desc limit least(greatest(lim, 1), 120)
	)
	select case when not exists (select 1 from root) then null else json_build_object(
		'id', (select id from root),
		'ch', (select channel_id from root),
		'root', (select public.rtc_msg_json(root) from root),
		'msgs', coalesce((select json_agg(public.rtc_msg_json(p) order by p.id) from page p), '[]'),
		'replies', (select count(*) from replies),
		'more', (select count(*) from replies) > least(greatest(lim, 1), 120)) end
$$;

-- What changed in a channel after `since`, in rev order: what a reconnecting
-- client asks for. `rev` is the high-water mark to remember next time.
create function public.rtc_changes_json(channel uuid, since bigint, lim integer) returns json
language sql stable set search_path = ''
as $$
	with page as (
		select * from public.rtc_changes(channel, since, least(greatest(lim, 1), 500) + 1)
	), kept as (
		select * from page order by rev limit least(greatest(lim, 1), 500)
	)
	select json_build_object(
		'ch', channel,
		'msgs', coalesce((select json_agg(public.rtc_msg_json(k) order by k.rev) from kept k), '[]'),
		'rev', coalesce((select max(rev) from kept), since),
		'more', (select count(*) from page) > least(greatest(lim, 1), 500))
$$;

create function public.rtc_search_json(q text, lim integer) returns json
language sql stable set search_path = ''
as $$
	select coalesce(json_agg(public.rtc_msg_json(m)), '[]') from public.rtc_search(q, lim) m
$$;

-- The channels this session can read. `name` is the channel's id, which is
-- the key every other frame uses; `label` is what to draw. A DM's label is
-- the other person's name.
create function public.rtc_channels_json() returns json
language sql stable set search_path = ''
as $$
	select coalesce(json_agg(json_strip_nulls(json_build_object(
		'name', c.id,
		'kind', case when c.kind = 'dm' then 'dm' else 'channel' end,
		'private', case when c.kind = 'private' then true end,
		'label', case when c.kind = 'dm' then coalesce((
			select m.display_name from public.rtc_channel_members cm
			join public.rtc_members m on m.space_id = cm.space_id and m.identity_id = cm.identity_id
			where cm.channel_id = c.id and not public.can_access_identity(cm.identity_id)
			limit 1), c.name) else c.name end,
		'peer', case when c.kind = 'dm' then (
			select m.handle from public.rtc_channel_members cm
			join public.rtc_members m on m.space_id = cm.space_id and m.identity_id = cm.identity_id
			where cm.channel_id = c.id and not public.can_access_identity(cm.identity_id)
			limit 1) end,
		'topic', c.topic,
		'space', c.space_id,
		'call', (select k.id from public.rtc_calls k where k.channel_id = c.id and k.ended_at is null
		         order by k.started_at desc limit 1),
		'rev', c.last_seq
	)) order by s.created_at, c.kind = 'dm', lower(c.name)), '[]')
	from public.rtc_channels c join public.rtc_spaces s on s.id = c.space_id
	where c.archived_at is null
$$;

create function public.rtc_spaces_json() returns json
language sql stable set search_path = ''
as $$
	select coalesce(json_agg(json_build_object(
		'id', s.id, 'name', s.name, 'role', public.rtc_space_role(s.id),
		'owner', (select m.handle from public.rtc_members m where m.space_id = s.id and m.role = 'owner' limit 1),
		'members', (select count(*) from public.rtc_members m where m.space_id = s.id)
	) order by s.created_at), '[]')
	from public.rtc_spaces s
$$;

-- Everyone who shares a space with this session's identity, with presence.
create function public.rtc_users_json() returns json
language sql stable set search_path = ''
as $$
	select coalesce(json_agg(json_build_object(
		'nick', u.handle, 'id', u.identity_id, 'name', u.display_name, 'color', u.color,
		'state', coalesce((select p.state from public.rtc_presence p where p.identity_id = u.identity_id), 'offline')
	) order by lower(u.display_name)), '[]')
	from (select distinct on (m.identity_id) m.identity_id, m.handle, m.display_name, m.color
	      from public.rtc_members m order by m.identity_id, m.joined_at desc) u
$$;

-- Members of one space, for the member panel.
create function public.rtc_members_json(space uuid) returns json
language sql stable set search_path = ''
as $$
	select coalesce(json_agg(json_build_object(
		'nick', m.handle, 'id', m.identity_id, 'name', m.display_name, 'color', m.color, 'role', m.role,
		'state', coalesce((select p.state from public.rtc_presence p where p.identity_id = m.identity_id), 'offline')
	) order by m.role <> 'owner', lower(m.display_name)), '[]')
	from public.rtc_members m where m.space_id = space
$$;

-- Invites waiting for this session's identity to answer.
create function public.rtc_invites_json() returns json
language sql stable security definer set search_path = ''
as $$
	-- Security definer because the invitee cannot yet read the space or the
	-- channel it is being invited to, and the invite has to say what it is
	-- for. It reveals the names of those two rows and the inviter, to the
	-- one identity the invite is addressed to, and nothing else.
	select coalesce(json_agg(json_strip_nulls(json_build_object(
		'id', v.id, 'space', v.space_id, 'space_name', s.name,
		'ch', v.channel_id, 'ch_name', c.name, 'role', v.role, 'note', nullif(v.note, ''),
		'from', json_build_object('handle', m.handle, 'name', m.display_name, 'color', m.color),
		'to', v.invitee_handle,
		'ts', extract(epoch from v.created_at)::bigint
	)) order by v.created_at), '[]')
	from public.rtc_invites v
	join public.rtc_spaces s on s.id = v.space_id
	left join public.rtc_channels c on c.id = v.channel_id
	left join public.rtc_members m on m.space_id = v.space_id and m.identity_id = v.identity_id
	where public.can_access_identity(v.invitee_id)
	  and v.accepted_at is null and v.declined_at is null and v.revoked_at is null
	  and v.expires_at > now()
$$;

-- Read cursors and the three numbers derived from each (PROTOCOL.md, "Read
-- cursors and unread"): new timeline messages, new thread replies, and
-- whether any unread timeline message mentions the reader.
create function public.rtc_reads_json(me uuid) returns json
language sql stable set search_path = ''
as $$
	select coalesce(json_agg(json_build_object(
		'ch', c.id,
		'id', coalesce(r.message_id, 0),
		'unread', (select count(*) from public.rtc_messages m
		           where m.channel_id = c.id and m.id > coalesce(r.message_id, 0) and m.deleted_at is null
		             and m.identity_id <> me and m.thread_root is null),
		'threads', (select count(*) from public.rtc_messages m
		            where m.channel_id = c.id and m.id > coalesce(r.message_id, 0) and m.deleted_at is null
		              and m.identity_id <> me and m.thread_root is not null),
		'mention', exists (select 1 from public.rtc_messages m
		                   where m.channel_id = c.id and m.id > coalesce(r.message_id, 0) and m.deleted_at is null
		                     and m.identity_id <> me and m.thread_root is null
		                     and position(lower((select h.handle from public.rtc_members h
		                                         where h.space_id = c.space_id and h.identity_id = me)) in lower(m.body)) > 0)
	)), '[]')
	from public.rtc_channels c
	left join public.rtc_reads r on r.channel_id = c.id and r.identity_id = me
	where c.archived_at is null
$$;

-- A channel this identity has never had a cursor in starts at its newest
-- message: arriving is not the same as having everything unread. Done once
-- per channel, so a reconnect is never mistaken for an arrival.
create function public.rtc_seed_reads(me uuid) returns integer
language sql volatile set search_path = ''
as $$
	with seeded as (
		insert into public.rtc_reads (channel_id, identity_id, message_id)
		select c.id, me, coalesce((select max(m.id) from public.rtc_messages m where m.channel_id = c.id), 0)
		from public.rtc_channels c
		where public.can_access_identity(me)
		  and not exists (select 1 from public.rtc_reads r where r.channel_id = c.id and r.identity_id = me)
		on conflict do nothing
		returning 1
	)
	select count(*)::integer from seeded
$$;

-- The read cursor moved: the new position and what is still unread behind it.
create function public.rtc_read_json(channel uuid, me uuid) returns json
language sql stable set search_path = ''
as $$
	select x from json_array_elements(public.rtc_reads_json(me)) x where x ->> 'ch' = channel::text
$$;
