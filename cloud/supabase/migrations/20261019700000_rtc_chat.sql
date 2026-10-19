-- Chat and calls (area `rtc`). See cloud/docs/chat-calls.md.
--
-- A *space* is owned by one identity. Identities join it, and its private
-- channels, only through an explicit invite row that the invitee accepts. A
-- public channel is read by every non-guest member of its space; a private
-- channel or a DM by its channel members only.
--
-- Every policy goes through public.can_access_identity(), directly or through
-- one of the rtc_* helpers below, each of which asks it about a member row.
-- There is no ambient access: being the same *person* as a member does not
-- make your other identities members, and a session scoped to one identity
-- reaches only what that identity was invited to.
--
-- Ordering. Every change in a channel takes the next value of that channel's
-- `last_seq`, under the channel row's lock, inside the writing transaction. So
-- per channel the sequence is gapless and equals commit order, and a client
-- that remembers the highest `rev` it has seen can ask for exactly what it
-- missed (rtc_changes). Message ids are drawn *after* that lock too, so within
-- a channel id order is commit order as well.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.rtc_spaces (
	id          uuid primary key default gen_random_uuid(),
	identity_id uuid not null references public.identities (id),   -- the owner
	name        text not null check (length(name) between 1 and 80),
	created_at  timestamptz not null default now()
);

create table public.rtc_members (
	space_id     uuid not null references public.rtc_spaces (id) on delete cascade,
	identity_id  uuid not null references public.identities (id),
	role         text not null default 'member'
	             check (role in ('owner', 'admin', 'member', 'guest')),
	-- A snapshot of the identity as other members see it. public.identities is
	-- private to its owner, so the name another member draws has to live here.
	handle       text not null,
	display_name text not null,
	color        text not null,
	invite_id    uuid,                                   -- the row that let it in
	joined_at    timestamptz not null default now(),
	primary key (space_id, identity_id)
);
create index rtc_members_identity on public.rtc_members (identity_id);

create table public.rtc_channels (
	id          uuid primary key default gen_random_uuid(),
	space_id    uuid not null references public.rtc_spaces (id) on delete cascade,
	identity_id uuid not null references public.identities (id),   -- the creator
	kind        text not null default 'public' check (kind in ('public', 'private', 'dm')),
	name        text not null check (length(name) between 1 and 80),
	topic       text not null default '',
	last_seq    bigint not null default 0,
	archived_at timestamptz,
	created_at  timestamptz not null default now()
);
create unique index rtc_channels_name on public.rtc_channels (space_id, lower(name)) where kind <> 'dm';
create index rtc_channels_space on public.rtc_channels (space_id);

create table public.rtc_channel_members (
	channel_id  uuid not null references public.rtc_channels (id) on delete cascade,
	space_id    uuid not null references public.rtc_spaces (id) on delete cascade,
	identity_id uuid not null references public.identities (id),
	invite_id   uuid,
	joined_at   timestamptz not null default now(),
	primary key (channel_id, identity_id)
);
create index rtc_channel_members_identity on public.rtc_channel_members (identity_id);

create table public.rtc_invites (
	id             uuid primary key default gen_random_uuid(),
	space_id       uuid not null references public.rtc_spaces (id) on delete cascade,
	channel_id     uuid references public.rtc_channels (id) on delete cascade,
	identity_id    uuid not null references public.identities (id),   -- the inviter
	invitee_handle text not null,
	invitee_id     uuid references public.identities (id),            -- resolved on insert
	role           text not null default 'member' check (role in ('admin', 'member', 'guest')),
	note           text not null default '',
	created_at     timestamptz not null default now(),
	expires_at     timestamptz not null default now() + interval '14 days',
	accepted_at    timestamptz,
	declined_at    timestamptz,
	revoked_at     timestamptz
);
create index rtc_invites_invitee on public.rtc_invites (invitee_id);

create sequence public.rtc_message_id;

create table public.rtc_messages (
	id            bigint primary key,
	channel_id    uuid not null references public.rtc_channels (id) on delete cascade,
	space_id      uuid not null references public.rtc_spaces (id) on delete cascade,
	identity_id   uuid not null references public.identities (id),   -- the author
	-- The author as the channel saw them when they wrote it, so a message
	-- keeps its name after its author leaves the space.
	author_handle text not null default '',
	author_name   text not null default '',
	author_color  text not null default '',
	seq           bigint not null,
	rev           bigint not null,
	thread_root   bigint references public.rtc_messages (id),
	reply_to      bigint references public.rtc_messages (id),
	body          text not null default '' check (length(body) <= 4000),
	attachment    jsonb,
	created_at    timestamptz not null default now(),
	edited_at     timestamptz,
	deleted_at    timestamptz,
	replies       integer not null default 0,
	last_reply_at timestamptz,
	fts           tsvector generated always as (to_tsvector('simple', body)) stored
);
create unique index rtc_messages_seq on public.rtc_messages (channel_id, seq);
create index rtc_messages_rev on public.rtc_messages (channel_id, rev);
create index rtc_messages_thread on public.rtc_messages (thread_root) where thread_root is not null;
create index rtc_messages_fts on public.rtc_messages using gin (fts);

create table public.rtc_reactions (
	message_id  bigint not null references public.rtc_messages (id) on delete cascade,
	channel_id  uuid not null references public.rtc_channels (id) on delete cascade,
	identity_id uuid not null references public.identities (id),
	handle      text not null default '',
	key         text not null check (key in ('thumbsup', 'heart', 'party', 'rocket', 'fire', 'grin', 'eyes', 'check')),
	created_at  timestamptz not null default now(),
	primary key (message_id, identity_id, key)
);

-- Read receipts. A cursor is the newest message an identity has read in a
-- channel. It is visible to the channel's members, which is what lets a DM say
-- "Seen".
create table public.rtc_reads (
	channel_id  uuid not null references public.rtc_channels (id) on delete cascade,
	identity_id uuid not null references public.identities (id),
	message_id  bigint not null default 0,
	updated_at  timestamptz not null default now(),
	primary key (channel_id, identity_id)
);

create table public.rtc_presence (
	identity_id uuid primary key references public.identities (id),
	state       text not null default 'offline' check (state in ('online', 'away', 'offline')),
	updated_at  timestamptz not null default now()
);

create table public.rtc_calls (
	id          uuid primary key default gen_random_uuid(),
	channel_id  uuid not null references public.rtc_channels (id) on delete cascade,
	space_id    uuid not null references public.rtc_spaces (id) on delete cascade,
	identity_id uuid not null references public.identities (id),   -- who started it
	e2ee        boolean not null default true,
	sfu         text not null default '',
	started_at  timestamptz not null default now(),
	ended_at    timestamptz
);
create index rtc_calls_channel on public.rtc_calls (channel_id) where ended_at is null;

create table public.rtc_call_participants (
	id          uuid primary key default gen_random_uuid(),
	call_id     uuid not null references public.rtc_calls (id) on delete cascade,
	channel_id  uuid not null references public.rtc_channels (id) on delete cascade,
	identity_id uuid not null references public.identities (id),
	joined_at   timestamptz not null default now(),
	left_at     timestamptz
);
create index rtc_call_participants_call on public.rtc_call_participants (call_id);

-- Recording metadata only. Recording itself is planned, not built; the row is
-- what a recorder would write, and its storage path is in the `rtc` bucket.
create table public.rtc_recordings (
	id           uuid primary key default gen_random_uuid(),
	call_id      uuid not null references public.rtc_calls (id) on delete cascade,
	channel_id   uuid not null references public.rtc_channels (id) on delete cascade,
	identity_id  uuid not null references public.identities (id),   -- who recorded
	storage_path text not null,
	bytes        bigint not null default 0,
	started_at   timestamptz not null default now(),
	ended_at     timestamptz
);

-- ---------------------------------------------------------------------------
-- Helpers. All security definer, so that policies on rtc_members and
-- rtc_channel_members can consult those tables without recursing into their
-- own policies. Each one still answers only through can_access_identity().
-- ---------------------------------------------------------------------------

-- The highest role any identity the caller can act as holds in a space.
create function public.rtc_space_role(space uuid) returns text
language sql stable security definer set search_path = ''
as $$
	select m.role from public.rtc_members m
	where m.space_id = space and public.can_access_identity(m.identity_id)
	order by case m.role when 'owner' then 0 when 'admin' then 1 when 'member' then 2 else 3 end
	limit 1
$$;

-- The role of one specific identity, provided the caller can act as it.
create function public.rtc_identity_role(space uuid, ident uuid) returns text
language sql stable security definer set search_path = ''
as $$
	select m.role from public.rtc_members m
	where m.space_id = space and m.identity_id = ident and public.can_access_identity(ident)
$$;

-- Whether some identity the caller can act as reads this channel.
create function public.rtc_can_read_channel(channel uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
	select exists (
		select 1 from public.rtc_channels c
		join public.rtc_members m on m.space_id = c.space_id
		where c.id = channel
		  and public.can_access_identity(m.identity_id)
		  and (
		       (c.kind = 'public' and m.role <> 'guest')
		    or exists (select 1 from public.rtc_channel_members cm
		               where cm.channel_id = c.id and cm.identity_id = m.identity_id)
		  )
	)
$$;

-- Whether this specific identity may post in this channel. Posting is always
-- *as* an identity, so it is not enough that some other identity of the same
-- person could read the channel.
create function public.rtc_identity_can_post(channel uuid, ident uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
	select public.can_access_identity(ident) and exists (
		select 1 from public.rtc_channels c
		join public.rtc_members m on m.space_id = c.space_id and m.identity_id = ident
		where c.id = channel and c.archived_at is null
		  and (
		       (c.kind = 'public' and m.role <> 'guest')
		    or exists (select 1 from public.rtc_channel_members cm
		               where cm.channel_id = c.id and cm.identity_id = ident)
		  )
	)
$$;

-- Whether some identity the caller can act as shares a space with `other`.
-- This is what makes another identity's presence and member row visible.
create function public.rtc_shares_space(other uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
	select exists (
		select 1 from public.rtc_members mine
		join public.rtc_members theirs on theirs.space_id = mine.space_id
		where theirs.identity_id = other and public.can_access_identity(mine.identity_id)
	)
$$;

create function public.rtc_is_space_member(space uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
	select public.rtc_space_role(space) is not null
$$;

-- A storage object's channel, from the first segment of its name, or null.
create function public.rtc_object_channel(name text) returns uuid
language sql immutable set search_path = ''
as $$
	select case when split_part(name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
	            then split_part(name, '/', 1)::uuid end
$$;

-- Whether some identity the caller can act as may post in the channel. Used
-- for uploads, whose rows carry no identity of their own.
create function public.rtc_can_post_any(channel uuid) returns boolean
language sql stable security definer set search_path = ''
as $$
	select exists (
		select 1 from public.rtc_channels c
		join public.rtc_members m on m.space_id = c.space_id
		where c.id = channel and public.rtc_identity_can_post(channel, m.identity_id)
	)
$$;

-- The next change number in a channel. Takes the channel row's lock until the
-- transaction ends, which is what makes the sequence equal commit order.
-- Internal: callable only from the security definer triggers below.
create function public.rtc_next_seq(channel uuid) returns bigint
language sql volatile security definer set search_path = ''
as $$
	update public.rtc_channels set last_seq = last_seq + 1 where id = channel returning last_seq
$$;
revoke execute on function public.rtc_next_seq(uuid) from public, anon, authenticated;

create function public.rtc_notify(kind text, channel uuid, msg bigint, rev bigint, extra jsonb default '{}')
returns void
language sql volatile set search_path = ''
as $$
	select pg_notify('rtc', (jsonb_build_object(
		'k', kind, 'ch', channel, 'id', msg, 'rev', rev,
		'origin', coalesce(current_setting('rtc.origin', true), ''),
		'tag', coalesce(current_setting('rtc.tag', true), '')
	) || extra)::text)
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- A new space: its owner is its first member, and it has a #general.
create function public.rtc_space_created() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	insert into public.rtc_members (space_id, identity_id, role, handle, display_name, color)
	select new.id, i.id, 'owner', i.handle, i.display_name, i.color
	from public.identities i where i.id = new.identity_id;
	insert into public.rtc_channels (space_id, identity_id, kind, name, topic)
	values (new.id, new.identity_id, 'public', 'general', 'Everyone in ' || new.name);
	return new;
end
$$;
create trigger rtc_space_created after insert on public.rtc_spaces
	for each row execute function public.rtc_space_created();

-- A private channel starts with its creator in it.
create function public.rtc_channel_created() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	if new.kind = 'private' then
		insert into public.rtc_channel_members (channel_id, space_id, identity_id)
		values (new.id, new.space_id, new.identity_id);
	end if;
	perform public.rtc_notify('channel', new.id, 0, 0, jsonb_build_object('space', new.space_id));
	return new;
end
$$;
create trigger rtc_channel_created after insert on public.rtc_channels
	for each row execute function public.rtc_channel_created();

-- The owner cannot be removed from their own space, and leaving a space takes
-- its private channels and DMs with it.
create function public.rtc_member_removed() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	if old.role = 'owner' and exists (select 1 from public.rtc_spaces s where s.id = old.space_id) then
		raise exception 'the owner of a space cannot leave it' using errcode = '42501';
	end if;
	delete from public.rtc_channel_members
	where space_id = old.space_id and identity_id = old.identity_id;
	perform public.rtc_notify('member', null, 0, 0,
		jsonb_build_object('space', old.space_id, 'identity', old.identity_id, 'on', false));
	return old;
end
$$;
create trigger rtc_member_removed before delete on public.rtc_members
	for each row execute function public.rtc_member_removed();

create function public.rtc_chmember_changed() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
	if tg_op = 'DELETE' then r := old; else r := new; end if;
	perform public.rtc_notify('chmember', r.channel_id, 0, 0,
		jsonb_build_object('space', r.space_id, 'identity', r.identity_id, 'on', tg_op <> 'DELETE'));
	return null;
end
$$;
create trigger rtc_chmember_changed after insert or delete on public.rtc_channel_members
	for each row execute function public.rtc_chmember_changed();

-- An invite names a handle; the identity behind it is resolved here, because
-- the inviter cannot read other people's identities. A handle is the identity's
-- mail address, so resolving one reveals nothing that is not already public.
create function public.rtc_invite_resolve() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	select i.id into new.invitee_id from public.identities i
	where i.handle = lower(new.invitee_handle) and i.archived_at is null;
	if new.invitee_id is null then
		raise exception 'no identity with handle %', new.invitee_handle using errcode = 'P0002';
	end if;
	new.invitee_handle := lower(new.invitee_handle);
	if new.channel_id is not null then
		if not exists (select 1 from public.rtc_channels c
		               where c.id = new.channel_id and c.space_id = new.space_id and c.kind <> 'dm') then
			raise exception 'that channel is not in this space' using errcode = '22023';
		end if;
	end if;
	new.accepted_at := null; new.declined_at := null; new.revoked_at := null;
	new.created_at := now();
	return new;
end
$$;
create trigger rtc_invite_resolve before insert on public.rtc_invites
	for each row execute function public.rtc_invite_resolve();

create function public.rtc_invite_notify() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	perform public.rtc_notify('invite', new.channel_id, 0, 0,
		jsonb_build_object('space', new.space_id, 'identity', new.invitee_id, 'invite', new.id));
	return null;
end
$$;
create trigger rtc_invite_notify after insert or update on public.rtc_invites
	for each row execute function public.rtc_invite_notify();

-- A message gets its place in the channel here: the channel's next sequence
-- number (taking the channel row's lock), then an id drawn under that lock.
-- A thread reply is normalised to its root, and both pointers must stay in
-- the channel, so nothing can be made to show in an audience its target is
-- not in.
create function public.rtc_message_insert() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare root bigint; ch uuid;
begin
	select c.space_id into new.space_id from public.rtc_channels c where c.id = new.channel_id;
	if new.thread_root is not null then
		select coalesce(m.thread_root, m.id), m.channel_id into root, ch
		from public.rtc_messages m where m.id = new.thread_root;
		if root is null or ch <> new.channel_id then
			raise exception 'no such thread in this channel' using errcode = '22023';
		end if;
		new.thread_root := root;
	end if;
	if new.reply_to is not null and not exists (
		select 1 from public.rtc_messages m where m.id = new.reply_to and m.channel_id = new.channel_id) then
		new.reply_to := null;
	end if;
	select m.handle, m.display_name, m.color into new.author_handle, new.author_name, new.author_color
	from public.rtc_members m where m.space_id = new.space_id and m.identity_id = new.identity_id;
	new.seq := public.rtc_next_seq(new.channel_id);
	new.rev := new.seq;
	new.id := nextval('public.rtc_message_id');
	new.created_at := now();
	new.edited_at := null; new.deleted_at := null;
	new.replies := 0; new.last_reply_at := null;
	return new;
end
$$;
create trigger rtc_message_insert before insert on public.rtc_messages
	for each row execute function public.rtc_message_insert();

create function public.rtc_message_inserted() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	-- The message is announced before its root's reply count changes, and
	-- the root's new rev is above the reply's. So whether a client is live
	-- (notifications arrive in this order) or syncing (changes come back in
	-- rev order), it never sees a count before the reply it counts.
	perform public.rtc_notify('msg', new.channel_id, new.id, new.rev);
	if new.thread_root is not null then
		update public.rtc_messages
		set replies = replies + 1, last_reply_at = new.created_at
		where id = new.thread_root;
	end if;
	return null;
end
$$;
create trigger rtc_message_inserted after insert on public.rtc_messages
	for each row execute function public.rtc_message_inserted();

-- Every update takes a new rev. A user's own update (trigger depth 1) may only
-- change the body or delete; everything else is the triggers' business.
create function public.rtc_message_update() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	if pg_trigger_depth() = 1 then
		if old.deleted_at is not null then
			raise exception 'that message was deleted' using errcode = '22023';
		end if;
		if new.channel_id <> old.channel_id or new.identity_id <> old.identity_id
		   or new.thread_root is distinct from old.thread_root or new.seq <> old.seq
		   or new.replies <> old.replies or new.attachment is distinct from old.attachment
		   or new.created_at <> old.created_at then
			raise exception 'only the body of a message can be changed' using errcode = '42501';
		end if;
		if new.deleted_at is not null then
			new.deleted_at := now();
			new.body := '';
			new.attachment := null;
		elsif new.body is distinct from old.body then
			if btrim(new.body) = '' then
				raise exception 'an edit needs some text' using errcode = '22023';
			end if;
			new.edited_at := now();
		end if;
	end if;
	new.rev := public.rtc_next_seq(new.channel_id);
	return new;
end
$$;
create trigger rtc_message_update before update on public.rtc_messages
	for each row execute function public.rtc_message_update();

create function public.rtc_message_updated() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	if new.deleted_at is not null and old.deleted_at is null then
		delete from public.rtc_reactions where message_id = new.id;
	end if;
	-- A rev-only update is a reaction, which announces itself with its delta.
	if new.deleted_at is not null and old.deleted_at is null then
		perform public.rtc_notify('del', new.channel_id, new.id, new.rev);
	elsif new.replies <> old.replies then
		perform public.rtc_notify('replies', new.channel_id, new.id, new.rev);
	elsif new.body is distinct from old.body then
		perform public.rtc_notify('edit', new.channel_id, new.id, new.rev);
	end if;
	return null;
end
$$;
create trigger rtc_message_updated after update on public.rtc_messages
	for each row execute function public.rtc_message_updated();

create function public.rtc_reaction_insert() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	select m.channel_id into new.channel_id from public.rtc_messages m
	where m.id = new.message_id and m.deleted_at is null;
	if new.channel_id is null then
		raise exception 'no such message' using errcode = 'P0002';
	end if;
	select mm.handle into new.handle from public.rtc_members mm
	join public.rtc_channels c on c.space_id = mm.space_id
	where c.id = new.channel_id and mm.identity_id = new.identity_id;
	new.created_at := now();
	return new;
end
$$;
create trigger rtc_reaction_insert before insert on public.rtc_reactions
	for each row execute function public.rtc_reaction_insert();

-- A reaction changes its message's rev, so a syncing client sees it.
create function public.rtc_reaction_changed() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
	if tg_op = 'DELETE' then r := old; else r := new; end if;
	update public.rtc_messages set rev = rev where id = r.message_id and deleted_at is null;
	if found then
		perform public.rtc_notify('react', r.channel_id, r.message_id,
			(select m.rev from public.rtc_messages m where m.id = r.message_id),
			jsonb_build_object('key', r.key, 'nick', r.handle, 'on', tg_op <> 'DELETE'));
	end if;
	return null;
end
$$;
create trigger rtc_reaction_changed after insert or delete on public.rtc_reactions
	for each row execute function public.rtc_reaction_changed();

-- Read cursors only move forward, and only to a message in the channel.
create function public.rtc_read_upsert() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare newest bigint;
begin
	select coalesce(max(m.id), 0) into newest from public.rtc_messages m where m.channel_id = new.channel_id;
	new.message_id := least(new.message_id, newest);
	if tg_op = 'UPDATE' then
		new.message_id := greatest(new.message_id, old.message_id);
	end if;
	new.updated_at := now();
	return new;
end
$$;
create trigger rtc_read_upsert before insert or update on public.rtc_reads
	for each row execute function public.rtc_read_upsert();

create function public.rtc_call_insert() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	select c.space_id into new.space_id from public.rtc_channels c where c.id = new.channel_id;
	new.started_at := now(); new.ended_at := null;
	return new;
end
$$;
create trigger rtc_call_insert before insert on public.rtc_calls
	for each row execute function public.rtc_call_insert();

create function public.rtc_participant_insert() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	select c.channel_id into new.channel_id from public.rtc_calls c
	where c.id = new.call_id and c.ended_at is null;
	if new.channel_id is null then
		raise exception 'that call has ended' using errcode = '22023';
	end if;
	new.joined_at := now(); new.left_at := null;
	return new;
end
$$;
create trigger rtc_participant_insert before insert on public.rtc_call_participants
	for each row execute function public.rtc_participant_insert();

-- ---------------------------------------------------------------------------
-- Actions that cross a boundary, and so cannot be plain inserts
-- ---------------------------------------------------------------------------

-- Accepting an invite is the only way an identity becomes a member. It grants
-- exactly what the invite names: the space at the invite's role, and, when the
-- invite names a channel, that channel.
create function public.rtc_accept_invite(invite uuid) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare inv public.rtc_invites; i public.identities;
begin
	select * into inv from public.rtc_invites v where v.id = invite for update;
	if inv.id is null or not public.can_access_identity(inv.invitee_id) then
		raise exception 'no such invite' using errcode = 'P0002';
	end if;
	if inv.revoked_at is not null or inv.declined_at is not null or inv.expires_at < now() then
		raise exception 'that invite is no longer valid' using errcode = '22023';
	end if;
	if inv.accepted_at is not null then
		return inv.space_id;
	end if;
	select * into i from public.identities where id = inv.invitee_id;
	insert into public.rtc_members (space_id, identity_id, role, handle, display_name, color, invite_id)
	values (inv.space_id, i.id, inv.role, i.handle, i.display_name, i.color, inv.id)
	on conflict (space_id, identity_id) do nothing;
	if inv.channel_id is not null then
		insert into public.rtc_channel_members (channel_id, space_id, identity_id, invite_id)
		values (inv.channel_id, inv.space_id, i.id, inv.id)
		on conflict do nothing;
	end if;
	update public.rtc_invites set accepted_at = now() where id = inv.id;
	perform public.rtc_notify('member', inv.channel_id, 0, 0,
		jsonb_build_object('space', inv.space_id, 'identity', i.id, 'on', true));
	return inv.space_id;
end
$$;

create function public.rtc_decline_invite(invite uuid) returns void
language plpgsql security definer set search_path = ''
as $$
begin
	update public.rtc_invites v set declined_at = now()
	where v.id = invite and public.can_access_identity(v.invitee_id)
	  and v.accepted_at is null and v.declined_at is null;
	if not found then
		raise exception 'no such invite' using errcode = 'P0002';
	end if;
end
$$;

-- A DM between two members of a space. Both already joined the space through
-- an invite, so this does not let anyone in who was not; a guest can only DM
-- people who share one of its channels.
create function public.rtc_open_dm(space uuid, me uuid, other uuid) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare ch uuid; mine text; theirs text; name text;
begin
	mine := public.rtc_identity_role(space, me);
	select m.role into theirs from public.rtc_members m where m.space_id = space and m.identity_id = other;
	if mine is null or theirs is null or me = other then
		raise exception 'both people must be members of the space' using errcode = '42501';
	end if;
	if (mine = 'guest' or theirs = 'guest') and not exists (
		select 1 from public.rtc_channel_members a join public.rtc_channel_members b using (channel_id)
		where a.identity_id = me and b.identity_id = other) then
		raise exception 'a guest can only message people it shares a channel with' using errcode = '42501';
	end if;
	select c.id into ch from public.rtc_channels c
	where c.space_id = space and c.kind = 'dm'
	  and exists (select 1 from public.rtc_channel_members x where x.channel_id = c.id and x.identity_id = me)
	  and exists (select 1 from public.rtc_channel_members x where x.channel_id = c.id and x.identity_id = other);
	if ch is not null then
		return ch;
	end if;
	select string_agg(h, '+' order by h) into name
	from (select m.handle as h from public.rtc_members m where m.space_id = space and m.identity_id in (me, other)) t;
	insert into public.rtc_channels (space_id, identity_id, kind, name)
	values (space, me, 'dm', name) returning id into ch;
	insert into public.rtc_channel_members (channel_id, space_id, identity_id)
	values (ch, space, me), (ch, space, other);
	return ch;
end
$$;

-- Messages changed after `since` in one channel, oldest change first. This is
-- what a reconnecting client asks for: every message created, edited,
-- deleted, reacted to or replied under since it last looked, once each.
create function public.rtc_changes(channel uuid, since bigint, lim integer default 500)
returns setof public.rtc_messages
language sql stable set search_path = ''
as $$
	select * from public.rtc_messages m
	where m.channel_id = channel and m.rev > since
	order by m.rev
	limit least(greatest(lim, 1), 1000)
$$;

-- Full-text search over what the caller can read. Each word is a prefix
-- match, in the language-neutral `simple` configuration: "deploy" finds
-- "deploying", and nothing is stemmed in a language the text is not in.
create function public.rtc_search(q text, lim integer default 40)
returns setof public.rtc_messages
language sql stable set search_path = ''
as $$
	with words as (
		select string_agg(quote_literal(w) || ':*', ' & ') as tsq
		from regexp_split_to_table(lower(q), '[^[:alnum:]]+') w where w <> ''
	)
	select m.* from public.rtc_messages m, words
	where words.tsq is not null and m.deleted_at is null
	  and m.fts @@ to_tsquery('simple', words.tsq)
	order by ts_rank(m.fts, to_tsquery('simple', words.tsq)) desc, m.id desc
	limit least(greatest(lim, 1), 200)
$$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.rtc_spaces enable row level security;
alter table public.rtc_members enable row level security;
alter table public.rtc_channels enable row level security;
alter table public.rtc_channel_members enable row level security;
alter table public.rtc_invites enable row level security;
alter table public.rtc_messages enable row level security;
alter table public.rtc_reactions enable row level security;
alter table public.rtc_reads enable row level security;
alter table public.rtc_presence enable row level security;
alter table public.rtc_calls enable row level security;
alter table public.rtc_call_participants enable row level security;
alter table public.rtc_recordings enable row level security;

create policy rtc_spaces_select on public.rtc_spaces for select
	using (public.can_access_identity(identity_id) or public.rtc_is_space_member(id));
create policy rtc_spaces_insert on public.rtc_spaces for insert
	with check (public.can_access_identity(identity_id));
create policy rtc_spaces_update on public.rtc_spaces for update
	using (public.can_access_identity(identity_id)) with check (public.can_access_identity(identity_id));
create policy rtc_spaces_delete on public.rtc_spaces for delete
	using (public.can_access_identity(identity_id));

-- Members: no insert policy. An identity joins only through rtc_accept_invite.
create policy rtc_members_select on public.rtc_members for select
	using (public.can_access_identity(identity_id) or public.rtc_is_space_member(space_id));
create policy rtc_members_delete on public.rtc_members for delete
	using (public.can_access_identity(identity_id)                    -- leaving
	       or public.rtc_space_role(space_id) in ('owner', 'admin'));  -- removing

create policy rtc_channels_select on public.rtc_channels for select
	using (public.rtc_can_read_channel(id));
create policy rtc_channels_insert on public.rtc_channels for insert
	with check (public.can_access_identity(identity_id) and kind in ('public', 'private')
	            and public.rtc_identity_role(space_id, identity_id) in ('owner', 'admin', 'member'));
create policy rtc_channels_update on public.rtc_channels for update
	using (public.can_access_identity(identity_id) or public.rtc_space_role(space_id) in ('owner', 'admin'));

-- Channel members: no insert policy, for the same reason as rtc_members.
create policy rtc_channel_members_select on public.rtc_channel_members for select
	using (public.can_access_identity(identity_id) or public.rtc_can_read_channel(channel_id));
create policy rtc_channel_members_delete on public.rtc_channel_members for delete
	using (public.can_access_identity(identity_id) or public.rtc_space_role(space_id) in ('owner', 'admin'));

create policy rtc_invites_select on public.rtc_invites for select
	using (public.can_access_identity(identity_id) or public.can_access_identity(invitee_id));
create policy rtc_invites_insert on public.rtc_invites for insert
	with check (public.can_access_identity(identity_id) and (
		-- a space invite needs an owner or admin; a channel invite, a member
		-- who can post in that channel
		(channel_id is null and public.rtc_identity_role(space_id, identity_id) in ('owner', 'admin'))
		or (channel_id is not null and role <> 'admin'
		    and public.rtc_identity_role(space_id, identity_id) in ('owner', 'admin', 'member')
		    and public.rtc_identity_can_post(channel_id, identity_id))));
create policy rtc_invites_update on public.rtc_invites for update
	using (public.can_access_identity(identity_id));

create policy rtc_messages_select on public.rtc_messages for select
	using (public.rtc_can_read_channel(channel_id));
create policy rtc_messages_insert on public.rtc_messages for insert
	with check (public.rtc_identity_can_post(channel_id, identity_id));
create policy rtc_messages_update on public.rtc_messages for update
	using (public.can_access_identity(identity_id) and public.rtc_can_read_channel(channel_id))
	with check (public.can_access_identity(identity_id));

create policy rtc_reactions_select on public.rtc_reactions for select
	using (public.rtc_can_read_channel(channel_id));
create policy rtc_reactions_insert on public.rtc_reactions for insert
	with check (public.rtc_identity_can_post(channel_id, identity_id));
create policy rtc_reactions_delete on public.rtc_reactions for delete
	using (public.can_access_identity(identity_id));

create policy rtc_reads_select on public.rtc_reads for select
	using (public.can_access_identity(identity_id) or public.rtc_can_read_channel(channel_id));
create policy rtc_reads_insert on public.rtc_reads for insert
	with check (public.can_access_identity(identity_id) and public.rtc_can_read_channel(channel_id));
create policy rtc_reads_update on public.rtc_reads for update
	using (public.can_access_identity(identity_id)) with check (public.can_access_identity(identity_id));

create policy rtc_presence_select on public.rtc_presence for select
	using (public.can_access_identity(identity_id) or public.rtc_shares_space(identity_id));
create policy rtc_presence_insert on public.rtc_presence for insert
	with check (public.can_access_identity(identity_id));
create policy rtc_presence_update on public.rtc_presence for update
	using (public.can_access_identity(identity_id)) with check (public.can_access_identity(identity_id));

create policy rtc_calls_select on public.rtc_calls for select
	using (public.rtc_can_read_channel(channel_id));
create policy rtc_calls_insert on public.rtc_calls for insert
	with check (public.rtc_identity_can_post(channel_id, identity_id));
create policy rtc_calls_update on public.rtc_calls for update
	using (public.rtc_can_read_channel(channel_id));

create policy rtc_call_participants_select on public.rtc_call_participants for select
	using (public.rtc_can_read_channel(channel_id));
create policy rtc_call_participants_insert on public.rtc_call_participants for insert
	with check (public.rtc_identity_can_post(channel_id, identity_id));
create policy rtc_call_participants_update on public.rtc_call_participants for update
	using (public.can_access_identity(identity_id)) with check (public.can_access_identity(identity_id));

create policy rtc_recordings_select on public.rtc_recordings for select
	using (public.can_access_identity(identity_id) or public.rtc_can_read_channel(channel_id));
create policy rtc_recordings_insert on public.rtc_recordings for insert
	with check (public.rtc_identity_can_post(channel_id, identity_id));

-- Column grants narrow what an allowed update can touch. The triggers enforce
-- the same thing for messages; these make the rest of the tables agree.
revoke update on public.rtc_invites from authenticated, anon;
grant update (revoked_at) on public.rtc_invites to authenticated;
revoke update on public.rtc_calls from authenticated, anon;
grant update (ended_at) on public.rtc_calls to authenticated;
revoke update on public.rtc_call_participants from authenticated, anon;
grant update (left_at) on public.rtc_call_participants to authenticated;
revoke update on public.rtc_channels from authenticated, anon;
grant update (name, topic, archived_at) on public.rtc_channels to authenticated;
revoke update on public.rtc_messages from authenticated, anon;
grant update (body, deleted_at) on public.rtc_messages to authenticated;
revoke insert on public.rtc_messages from anon;
grant usage on sequence public.rtc_message_id to authenticated;

-- ---------------------------------------------------------------------------
-- Attachments: a private bucket, objects named <channel id>/<uuid>/<name>.
-- Reading follows the channel; writing needs an identity that can post there.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('rtc', 'rtc', false, 26214400)
on conflict (id) do nothing;

create policy rtc_objects_select on storage.objects for select to authenticated
	using (bucket_id = 'rtc' and public.rtc_can_read_channel(public.rtc_object_channel(name)));
create policy rtc_objects_insert on storage.objects for insert to authenticated
	with check (bucket_id = 'rtc' and public.rtc_can_post_any(public.rtc_object_channel(name)));
