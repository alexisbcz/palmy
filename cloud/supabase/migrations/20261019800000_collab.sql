-- Collaborative documents: the office suite's sync service (cloud/collab).
-- See cloud/docs/office.md.
--
-- A document belongs to one identity (its owner). Its content is a CRDT
-- (cloud/collab/crdt): an append-only log of updates, numbered per document,
-- plus snapshots taken every so often so that opening a document never
-- replays its whole history. The log is written only by the sync server,
-- through collab_append(), after it has checked the author's role on every
-- operation; people read what their role allows through RLS.
--
-- Crossing identities is an explicit grant row (view, comment, suggest, edit)
-- created by the owning identity, which the grantee's side reads — the
-- contract's sharing rule. A link share is a separate row holding only the
-- hash of its token.

create table public.collab_documents (
	id            uuid primary key default gen_random_uuid(),
	identity_id   uuid not null references public.identities (id) on delete cascade,
	kind          text not null check (kind in ('doc', 'sheet', 'deck')),
	title         text not null default '' check (length(title) <= 300),
	-- The drive item this document is stored as, when the drive area files it
	-- (a seam: drive owns drive_items; nothing here depends on it existing).
	drive_item_id uuid,
	head_seq      bigint not null default 0,
	snapshot_seq  bigint not null default 0,
	created_at    timestamptz not null default now(),
	updated_at    timestamptz not null default now()
);

create index collab_documents_identity on public.collab_documents (identity_id);

-- The update log. `identity_id` is the owning identity (the contract column);
-- `author_identity` is who wrote it, which may be a grantee.
create table public.collab_updates (
	doc_id          uuid not null references public.collab_documents (id) on delete cascade,
	seq             bigint not null,
	identity_id     uuid not null references public.identities (id) on delete cascade,
	author_identity uuid not null references public.identities (id) on delete cascade,
	agent           text not null check (agent ~ '^[0-9a-f]{1,16}$'),
	data            bytea not null,
	created_at      timestamptz not null default now(),
	primary key (doc_id, seq)
);

-- Full states. A snapshot at `seq` reproduces the document exactly after
-- update `seq`; history is reconstructed from the nearest one before a point.
create table public.collab_snapshots (
	doc_id      uuid not null references public.collab_documents (id) on delete cascade,
	seq         bigint not null,
	identity_id uuid not null references public.identities (id) on delete cascade,
	data        bytea not null,
	created_at  timestamptz not null default now(),
	primary key (doc_id, seq)
);

-- Named versions ("Sent to legal"), on top of the automatic history.
create table public.collab_versions (
	id          uuid primary key default gen_random_uuid(),
	doc_id      uuid not null references public.collab_documents (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	seq         bigint not null,
	name        text not null check (length(name) between 1 and 200),
	created_by  uuid not null references public.identities (id) on delete cascade,
	created_at  timestamptz not null default now()
);

create index collab_versions_doc on public.collab_versions (doc_id, seq);

-- Which identity each CRDT agent wrote as, so history can say who did what
-- and the server can refuse an agent claimed by two identities.
create table public.collab_agents (
	doc_id          uuid not null references public.collab_documents (id) on delete cascade,
	agent           text not null check (agent ~ '^[0-9a-f]{1,16}$'),
	identity_id     uuid not null references public.identities (id) on delete cascade,
	author_identity uuid not null references public.identities (id) on delete cascade,
	created_at      timestamptz not null default now(),
	primary key (doc_id, agent)
);

-- Explicit grants to another identity: the owner's, someone else's, any.
create table public.collab_grants (
	id               uuid primary key default gen_random_uuid(),
	doc_id           uuid not null references public.collab_documents (id) on delete cascade,
	identity_id      uuid not null references public.identities (id) on delete cascade,
	grantee_identity uuid not null references public.identities (id) on delete cascade,
	role             text not null check (role in ('view', 'comment', 'suggest', 'edit')),
	created_at       timestamptz not null default now(),
	revoked_at       timestamptz,
	check (grantee_identity <> identity_id)
);

create unique index collab_grants_live on public.collab_grants (doc_id, grantee_identity) where revoked_at is null;
create index collab_grants_grantee on public.collab_grants (grantee_identity) where revoked_at is null;

-- Link shares. Only a hash of the token is stored; the token itself is shown
-- once, to the owner who made it. Links expire and are listed.
create table public.collab_links (
	id          uuid primary key default gen_random_uuid(),
	doc_id      uuid not null references public.collab_documents (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	token_hash  text not null unique,
	role        text not null check (role in ('view', 'comment', 'suggest')),
	expires_at  timestamptz not null default now() + interval '30 days',
	revoked_at  timestamptz,
	created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------

create function public.collab_rank(r text) returns int
language sql immutable
set search_path = ''
as $$
	select case r when 'view' then 1 when 'comment' then 2 when 'suggest' then 3
	              when 'edit' then 4 when 'owner' then 5 else 0 end
$$;

-- The role one identity holds on a document: 'owner' for the owning
-- identity, else its live grant, else null. A person may only ask about an
-- identity their session can act as; the sync server (service_role) may ask
-- about any.
create function public.collab_role_of(p_doc uuid, p_identity uuid) returns text
language sql stable security definer
set search_path = ''
as $$
	select case
		when d.identity_id = p_identity then 'owner'
		else (select g.role from public.collab_grants g
		      where g.doc_id = d.id and g.grantee_identity = p_identity and g.revoked_at is null)
	end
	from public.collab_documents d
	where d.id = p_doc
	  and (coalesce(auth.role(), '') = 'service_role' or public.can_access_identity(p_identity))
$$;

-- The best role the calling session can act with on a document, through any
-- identity it can access (one, for a scoped session). Every RLS policy below
-- goes through this, and it goes through can_access_identity().
create function public.collab_session_role(p_doc uuid) returns text
language sql stable security definer
set search_path = ''
as $$
	select r from (
		select 'owner' as r, 5 as k
		from public.collab_documents d
		where d.id = p_doc and public.can_access_identity(d.identity_id)
		union all
		select g.role, public.collab_rank(g.role)
		from public.collab_grants g
		where g.doc_id = p_doc and g.revoked_at is null
		  and public.can_access_identity(g.grantee_identity)
	) x
	order by k desc
	limit 1
$$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.collab_documents enable row level security;
alter table public.collab_updates   enable row level security;
alter table public.collab_snapshots enable row level security;
alter table public.collab_versions  enable row level security;
alter table public.collab_agents    enable row level security;
alter table public.collab_grants    enable row level security;
alter table public.collab_links     enable row level security;

-- The owner test is on the row itself as well as through the role function:
-- an INSERT ... RETURNING checks this policy against a row the function's
-- snapshot cannot see yet.
create policy collab_documents_select on public.collab_documents for select
	using (public.can_access_identity(identity_id) or public.collab_session_role(id) is not null);
create policy collab_documents_insert on public.collab_documents for insert
	with check (public.can_access_identity(identity_id) and head_seq = 0 and snapshot_seq = 0);
-- Editors may rename; only the owner may do anything else, which the column
-- grants below and the trigger enforce.
create policy collab_documents_update on public.collab_documents for update
	using (public.collab_rank(public.collab_session_role(id)) >= 4)
	with check (public.collab_rank(public.collab_session_role(id)) >= 4);
create policy collab_documents_delete on public.collab_documents for delete
	using (public.can_access_identity(identity_id));

create policy collab_updates_select on public.collab_updates for select
	using (public.collab_session_role(doc_id) is not null);
create policy collab_snapshots_select on public.collab_snapshots for select
	using (public.collab_session_role(doc_id) is not null);
create policy collab_agents_select on public.collab_agents for select
	using (public.collab_session_role(doc_id) is not null);

create policy collab_versions_select on public.collab_versions for select
	using (public.collab_session_role(doc_id) is not null);
create policy collab_versions_insert on public.collab_versions for insert
	with check (public.collab_rank(public.collab_session_role(doc_id)) >= 4
	            and public.can_access_identity(created_by)
	            and public.collab_rank(public.collab_role_of(doc_id, created_by)) >= 4
	            and identity_id = (select d.identity_id from public.collab_documents d where d.id = doc_id));

-- The source sees the grants it made; the grantee sees what it was given.
create policy collab_grants_select on public.collab_grants for select
	using (public.can_access_identity(identity_id) or public.can_access_identity(grantee_identity));
create policy collab_grants_insert on public.collab_grants for insert
	with check (public.can_access_identity(identity_id)
	            and identity_id = (select d.identity_id from public.collab_documents d where d.id = doc_id)
	            and revoked_at is null);
-- Revoking is the owner's; a grantee may also leave.
create policy collab_grants_update on public.collab_grants for update
	using (public.can_access_identity(identity_id) or public.can_access_identity(grantee_identity))
	with check (revoked_at is not null);

create policy collab_links_select on public.collab_links for select
	using (public.can_access_identity(identity_id));
create policy collab_links_update on public.collab_links for update
	using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));

-- Owners write title; nothing else about a document is client-writable.
revoke all on public.collab_documents, public.collab_updates, public.collab_snapshots,
	public.collab_versions, public.collab_agents, public.collab_grants, public.collab_links
	from anon, authenticated;
grant select, delete on public.collab_documents to authenticated;
grant insert (identity_id, kind, title, drive_item_id) on public.collab_documents to authenticated;
grant update (title, drive_item_id) on public.collab_documents to authenticated;
grant select on public.collab_updates, public.collab_snapshots, public.collab_agents to authenticated;
grant select, insert on public.collab_versions to authenticated;
grant select, insert on public.collab_grants to authenticated;
grant update (revoked_at) on public.collab_grants to authenticated;
grant select on public.collab_links to authenticated;
grant update (revoked_at) on public.collab_links to authenticated;
grant all on public.collab_documents, public.collab_updates, public.collab_snapshots,
	public.collab_versions, public.collab_agents, public.collab_grants, public.collab_links
	to service_role;

create function public.collab_documents_touch() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.identity_id is distinct from old.identity_id then
		raise exception 'a document cannot move between identities; carry a copy instead'
			using errcode = '42501';
	end if;
	new.updated_at := now();
	return new;
end
$$;

create trigger collab_documents_touch before update on public.collab_documents
	for each row execute function public.collab_documents_touch();

-- A grant may not be re-pointed or have its role raised in place: revoke and
-- grant again, so the history of who could do what stays readable.
create function public.collab_grants_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.doc_id is distinct from old.doc_id or new.grantee_identity is distinct from old.grantee_identity
	   or new.role is distinct from old.role or new.identity_id is distinct from old.identity_id then
		raise exception 'grants are revoked and re-made, not edited' using errcode = '42501';
	end if;
	if old.revoked_at is not null then
		raise exception 'already revoked' using errcode = '42501';
	end if;
	return new;
end
$$;

create trigger collab_grants_guard before update on public.collab_grants
	for each row execute function public.collab_grants_guard();

-- ---------------------------------------------------------------------------
-- Functions people call
-- ---------------------------------------------------------------------------

-- collab_share grants `role` on a document to the identity with `handle`.
-- Handles are addresses, so looking one up by exact name reveals nothing a
-- mail address would not. Re-sharing replaces a live grant.
create function public.collab_share(p_doc uuid, p_handle text, p_role text) returns public.collab_grants
language plpgsql security definer
set search_path = ''
as $$
declare
	d public.collab_documents;
	target uuid;
	g public.collab_grants;
begin
	select * into d from public.collab_documents where id = p_doc;
	if d.id is null or not public.can_access_identity(d.identity_id) then
		raise exception 'only the owning identity can share this document' using errcode = '42501';
	end if;
	if p_role not in ('view', 'comment', 'suggest', 'edit') then
		raise exception 'unknown role %', p_role using errcode = '22023';
	end if;
	select i.id into target from public.identities i where i.handle = lower(p_handle) and i.archived_at is null;
	if target is null then
		raise exception 'no identity is called %', p_handle using errcode = 'P0002';
	end if;
	if target = d.identity_id then
		raise exception 'that identity already owns the document' using errcode = '22023';
	end if;
	update public.collab_grants set revoked_at = now()
		where doc_id = p_doc and grantee_identity = target and revoked_at is null;
	insert into public.collab_grants (doc_id, identity_id, grantee_identity, role)
		values (p_doc, d.identity_id, target, p_role)
		returning * into g;
	return g;
end
$$;

-- collab_unshare revokes the live grant to the identity with `handle`.
create function public.collab_unshare(p_doc uuid, p_handle text) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
	d public.collab_documents;
	n int;
begin
	select * into d from public.collab_documents where id = p_doc;
	if d.id is null or not public.can_access_identity(d.identity_id) then
		raise exception 'only the owning identity can change sharing' using errcode = '42501';
	end if;
	update public.collab_grants g set revoked_at = now()
		from public.identities i
		where g.doc_id = p_doc and g.revoked_at is null and i.id = g.grantee_identity and i.handle = lower(p_handle);
	get diagnostics n = row_count;
	return n > 0;
end
$$;

-- collab_people lists who a document is shared with, by name, for the
-- share dialog: the owner sees every grant; a grantee sees the owner and
-- itself.
create function public.collab_people(p_doc uuid) returns table (
	identity_id uuid, handle text, display_name text, color text, role text)
language sql stable security definer
set search_path = ''
as $$
	select i.id, i.handle, i.display_name, i.color, 'owner'
	from public.collab_documents d join public.identities i on i.id = d.identity_id
	where d.id = p_doc and public.collab_session_role(p_doc) is not null
	union all
	select i.id, i.handle, i.display_name, i.color, g.role
	from public.collab_grants g
	join public.collab_documents d on d.id = g.doc_id
	join public.identities i on i.id = g.grantee_identity
	where g.doc_id = p_doc and g.revoked_at is null
	  and (public.can_access_identity(d.identity_id) or public.can_access_identity(g.grantee_identity))
$$;

-- collab_make_link creates a link share and returns its token, once.
create function public.collab_make_link(p_doc uuid, p_role text, p_days int default 30) returns text
language plpgsql security definer
set search_path = ''
as $$
declare
	d public.collab_documents;
	tok text;
begin
	select * into d from public.collab_documents where id = p_doc;
	if d.id is null or not public.can_access_identity(d.identity_id) then
		raise exception 'only the owning identity can make a link' using errcode = '42501';
	end if;
	if p_role not in ('view', 'comment', 'suggest') then
		raise exception 'a link can grant view, comment or suggest, not %', p_role using errcode = '22023';
	end if;
	tok := encode(extensions.gen_random_bytes(24), 'hex');
	insert into public.collab_links (doc_id, identity_id, token_hash, role, expires_at)
		values (p_doc, d.identity_id, encode(extensions.digest(tok, 'sha256'), 'hex'), p_role,
		        now() + make_interval(days => greatest(1, least(p_days, 365))));
	return tok;
end
$$;

-- collab_join is what the sync server calls *with the person's own token*
-- when a window opens a document: it proves the session may act as
-- `p_as` and returns the role that identity holds (optionally raised by a
-- link token), who it is, and where the log stands. Null role: refused.
create function public.collab_join(p_doc uuid, p_as uuid, p_link text default null) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
	d public.collab_documents;
	i public.identities;
	r text;
	lr text;
begin
	if not public.can_access_identity(p_as) then
		return jsonb_build_object('role', null, 'reason', 'identity');
	end if;
	select * into d from public.collab_documents where id = p_doc;
	if d.id is null then
		return jsonb_build_object('role', null, 'reason', 'document');
	end if;
	r := public.collab_role_of(p_doc, p_as);
	if p_link is not null and p_link <> '' then
		select l.role into lr from public.collab_links l
			where l.doc_id = p_doc and l.revoked_at is null and l.expires_at > now()
			  and l.token_hash = encode(extensions.digest(p_link, 'sha256'), 'hex');
		if public.collab_rank(lr) > public.collab_rank(r) then
			r := lr;
		end if;
	end if;
	if r is null then
		return jsonb_build_object('role', null, 'reason', 'role');
	end if;
	select * into i from public.identities where id = p_as;
	return jsonb_build_object(
		'role', r,
		'user', auth.uid(),
		'identity', jsonb_build_object('id', i.id, 'handle', i.handle, 'display_name', i.display_name,
		                               'color', i.color, 'kind', i.kind),
		'doc', jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'owner', d.identity_id,
		                          'head_seq', d.head_seq, 'snapshot_seq', d.snapshot_seq));
end
$$;

-- collab_documents_mine lists what a session can open: owned and shared, each
-- with the role and the owning identity's name.
create function public.collab_documents_mine() returns table (
	id uuid, kind text, title text, role text, owner uuid, owner_handle text,
	owner_name text, owner_color text, updated_at timestamptz)
language sql stable security definer
set search_path = ''
as $$
	select d.id, d.kind, d.title, public.collab_session_role(d.id), d.identity_id, i.handle,
	       i.display_name, i.color, d.updated_at
	from public.collab_documents d
	join public.identities i on i.id = d.identity_id
	where public.collab_session_role(d.id) is not null
	order by d.updated_at desc
$$;

-- collab_history groups the log into editing sessions the way a version list
-- wants them: a new session starts after `p_gap` seconds without an edit
-- (five minutes by default), and each session lists everyone who edited in
-- it. Named versions come alongside.
create function public.collab_history(p_doc uuid, p_gap int default 300) returns jsonb
language sql stable security definer
set search_path = ''
as $$
	with u as (
		select seq, author_identity, created_at,
		       case when created_at - lag(created_at) over w > make_interval(secs => greatest(p_gap, 1))
		            then 1 else 0 end as brk
		from public.collab_updates
		where doc_id = p_doc and public.collab_session_role(p_doc) is not null
		window w as (order by seq)
	), g as (
		select *, sum(brk) over (order by seq) as grp from u
	), s as (
		select grp, min(seq) as seq_from, max(seq) as seq_to,
		       min(created_at) as first_at, max(created_at) as last_at, count(*) as n
		from g group by grp
	)
	select jsonb_build_object(
		'sessions', coalesce((select jsonb_agg(jsonb_build_object(
			'from', s.seq_from, 'to', s.seq_to, 'n', s.n, 'first_at', s.first_at, 'last_at', s.last_at,
			'authors', (select jsonb_agg(distinct jsonb_build_object('name', i.display_name, 'handle', i.handle, 'color', i.color))
			            from g join public.identities i on i.id = g.author_identity where g.grp = s.grp))
			order by s.seq_to desc)
			from s), '[]'::jsonb),
		'versions', coalesce((select jsonb_agg(jsonb_build_object('seq', v.seq, 'name', v.name,
			'at', v.created_at, 'by', i.display_name, 'color', i.color) order by v.seq desc)
			from public.collab_versions v join public.identities i on i.id = v.created_by
			where v.doc_id = p_doc and public.collab_session_role(p_doc) is not null), '[]'::jsonb))
$$;

-- collab_state_at returns what a client needs to rebuild the document as it
-- was after update `p_seq`: the nearest snapshot at or before it (base64)
-- and the updates after that snapshot up to `p_seq`.
create function public.collab_state_at(p_doc uuid, p_seq bigint) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
	snap public.collab_snapshots;
begin
	if public.collab_session_role(p_doc) is null then
		raise exception 'no access' using errcode = '42501';
	end if;
	select * into snap from public.collab_snapshots
		where doc_id = p_doc and seq <= p_seq order by seq desc limit 1;
	return jsonb_build_object(
		'snapshot_seq', coalesce(snap.seq, 0),
		'snapshot', case when snap.data is null then null else translate(encode(snap.data, 'base64'), E'\n', '') end,
		'updates', coalesce((select jsonb_agg(translate(encode(u.data, 'base64'), E'\n', '') order by u.seq)
			from public.collab_updates u
			where u.doc_id = p_doc and u.seq > coalesce(snap.seq, 0) and u.seq <= p_seq), '[]'::jsonb));
end
$$;

-- ---------------------------------------------------------------------------
-- Functions only the sync server calls (service_role)
-- ---------------------------------------------------------------------------

-- collab_server_role re-checks, without trusting the server's own memory,
-- that `p_user` owns identity `p_as` (not archived) and what role it holds.
create function public.collab_server_role(p_doc uuid, p_as uuid, p_user uuid) returns text
language sql stable security definer
set search_path = ''
as $$
	select public.collab_role_of(p_doc, p_as)
	from public.identities i
	where i.id = p_as and i.owner = p_user and i.archived_at is null
$$;

-- collab_append adds one update to the log and returns its sequence number.
-- The row lock on the document serialises writers, so numbers are dense.
create function public.collab_append(p_doc uuid, p_as uuid, p_user uuid, p_agent text, p_data text,
                                     p_min_role text default 'comment') returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
	d public.collab_documents;
	n bigint;
	who uuid;
begin
	if public.collab_rank(public.collab_server_role(p_doc, p_as, p_user)) < public.collab_rank(p_min_role)
	   or public.collab_rank(p_min_role) < 2 then
		raise exception 'not allowed to write this document' using errcode = '42501';
	end if;
	select * into d from public.collab_documents where id = p_doc for update;
	select a.author_identity into who from public.collab_agents a where a.doc_id = p_doc and a.agent = p_agent;
	if who is null then
		insert into public.collab_agents (doc_id, agent, identity_id, author_identity)
			values (p_doc, p_agent, d.identity_id, p_as);
	elsif who <> p_as then
		raise exception 'agent % belongs to another identity', p_agent using errcode = '42501';
	end if;
	n := d.head_seq + 1;
	insert into public.collab_updates (doc_id, seq, identity_id, author_identity, agent, data)
		values (p_doc, n, d.identity_id, p_as, p_agent, decode(p_data, 'base64'));
	update public.collab_documents set head_seq = n, updated_at = now() where id = p_doc;
	return n;
end
$$;

create function public.collab_put_snapshot(p_doc uuid, p_seq bigint, p_data text) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
	insert into public.collab_snapshots (doc_id, seq, identity_id, data)
		select p_doc, p_seq, d.identity_id, decode(p_data, 'base64')
		from public.collab_documents d where d.id = p_doc
		on conflict (doc_id, seq) do nothing;
	update public.collab_documents set snapshot_seq = greatest(snapshot_seq, p_seq) where id = p_doc;
end
$$;

-- collab_load gives the server a document's latest snapshot and the updates
-- after it, in one round trip.
create function public.collab_load(p_doc uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
	with s as (
		select seq, data from public.collab_snapshots where doc_id = p_doc order by seq desc limit 1
	)
	select jsonb_build_object(
		'head_seq', (select head_seq from public.collab_documents where id = p_doc),
		'snapshot_seq', coalesce((select seq from s), 0),
		'snapshot', (select translate(encode(data, 'base64'), E'\n', '') from s),
		'updates', coalesce((select jsonb_agg(jsonb_build_object('seq', u.seq, 'data', translate(encode(u.data, 'base64'), E'\n', ''))
			order by u.seq) from public.collab_updates u
			where u.doc_id = p_doc and u.seq > coalesce((select seq from s), 0)), '[]'::jsonb))
$$;

revoke execute on function public.collab_role_of(uuid, uuid), public.collab_session_role(uuid),
	public.collab_share(uuid, text, text), public.collab_unshare(uuid, text), public.collab_people(uuid), public.collab_make_link(uuid, text, int),
	public.collab_join(uuid, uuid, text), public.collab_documents_mine(), public.collab_history(uuid, int),
	public.collab_state_at(uuid, bigint), public.collab_server_role(uuid, uuid, uuid),
	public.collab_append(uuid, uuid, uuid, text, text, text), public.collab_put_snapshot(uuid, bigint, text),
	public.collab_load(uuid)
	from public, anon, authenticated;
grant execute on function public.collab_role_of(uuid, uuid), public.collab_session_role(uuid),
	public.collab_share(uuid, text, text), public.collab_unshare(uuid, text), public.collab_people(uuid), public.collab_make_link(uuid, text, int),
	public.collab_join(uuid, uuid, text), public.collab_documents_mine(), public.collab_history(uuid, int),
	public.collab_state_at(uuid, bigint)
	to authenticated, service_role;
grant execute on function public.collab_server_role(uuid, uuid, uuid),
	public.collab_append(uuid, uuid, uuid, text, text, text), public.collab_put_snapshot(uuid, bigint, text),
	public.collab_load(uuid)
	to service_role;
