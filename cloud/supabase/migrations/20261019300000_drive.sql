-- Drive: a file tree per identity, content-addressed blobs in Storage, and
-- sharing that is an explicit row. See cloud/docs/drive.md for the model.
--
-- Every policy below goes through public.can_access_identity(), directly or
-- through a share row whose grantee it checks with can_access_identity().
-- Nothing checks auth.uid() itself.
--
-- Storage layout, bucket `drive` (private):
--
--     <identity id>/chunks/<sha256 hex>      one immutable chunk, at most 4 MiB
--
-- A file's content is an ordered list of chunk hashes held in drive_versions.
-- Chunks are deduplicated *within* an identity and never across identities:
-- cross-identity dedupe would let one identity learn that another holds a
-- given file, which is exactly the leak the separation exists to prevent.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- The change feed. Every insert and update of an item takes the next value,
-- so a sync client asks "everything with seq > my cursor" and gets moves,
-- renames, edits and trashings in the order they happened.
create extension if not exists pg_trgm with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create sequence public.drive_seq;

create table public.drive_items (
	id           uuid primary key default gen_random_uuid(),
	identity_id  uuid not null references public.identities (id) on delete cascade,
	parent_id    uuid,
	name         text not null
	             check (name <> '' and name !~ '[/\x00]' and name not in ('.', '..')
	                    and octet_length(name) <= 255),
	kind         text not null check (kind in ('folder', 'file')),
	version_id   uuid,                     -- the current version, files only
	size         bigint not null default 0 check (size >= 0),
	content_hash text check (content_hash ~ '^[0-9a-f]{64}$'),
	mime         text,
	starred      boolean not null default false,
	trashed_at   timestamptz,
	trashed_root uuid,                     -- the item whose trashing took this one
	created_at   timestamptz not null default now(),
	modified_at  timestamptz not null default now(), -- content time, as the client saw it
	updated_at   timestamptz not null default now(), -- any change, server time
	accessed_at  timestamptz,              -- last opened, for Recent
	seq          bigint not null default nextval('public.drive_seq'),
	device       text,                     -- which device made the last change

	unique (id, identity_id),
	-- A parent is in the same identity's drive. The composite key is what
	-- stops a folder in one drive from holding a file of another.
	foreign key (parent_id, identity_id) references public.drive_items (id, identity_id)
		on delete cascade,
	check (kind = 'file' or (version_id is null and content_hash is null))
);

-- One live name per folder. Trashed items step out of the way, so a file can
-- be trashed and a new one made under the same name; restore then renames.
create unique index drive_items_live_name on public.drive_items
	(identity_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), name)
	where trashed_at is null;
create index drive_items_parent on public.drive_items (parent_id);
create index drive_items_feed on public.drive_items (identity_id, seq);
create index drive_items_recent on public.drive_items (identity_id, accessed_at desc nulls last);
create index drive_items_name_trgm on public.drive_items using gin (name extensions.gin_trgm_ops);

create table public.drive_versions (
	id           uuid primary key default gen_random_uuid(),
	identity_id  uuid not null references public.identities (id) on delete cascade,
	item_id      uuid not null,
	size         bigint not null check (size >= 0),
	content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
	chunk_size   integer not null check (chunk_size > 0),
	chunks       text[] not null,
	mime         text,
	device       text,
	created_at   timestamptz not null default now(),
	foreign key (item_id, identity_id) references public.drive_items (id, identity_id)
		on delete cascade
);

create index drive_versions_item on public.drive_versions (item_id, created_at desc);
create index drive_versions_chunks on public.drive_versions using gin (chunks);

alter table public.drive_items
	add constraint drive_items_version_fk foreign key (version_id)
	references public.drive_versions (id) deferrable initially deferred;

-- Identity to identity. Made by the source identity; read on the target side
-- by the policies below. Revoking sets revoked_at; the row stays as the
-- record that the share existed.
create table public.drive_shares (
	id               uuid primary key default gen_random_uuid(),
	identity_id      uuid not null references public.identities (id) on delete cascade,
	item_id          uuid not null,
	grantee_identity uuid not null references public.identities (id) on delete cascade,
	role             text not null default 'viewer' check (role in ('viewer', 'editor')),
	created_at       timestamptz not null default now(),
	expires_at       timestamptz,
	revoked_at       timestamptz,
	foreign key (item_id, identity_id) references public.drive_items (id, identity_id)
		on delete cascade,
	check (grantee_identity <> identity_id)
);

create unique index drive_shares_live on public.drive_shares (item_id, grantee_identity)
	where revoked_at is null;
create index drive_shares_grantee on public.drive_shares (grantee_identity) where revoked_at is null;

-- Read-only links. The token is shown once, when minted; only its SHA-256 is
-- stored, so a database dump does not hand out working links.
create table public.drive_links (
	id            uuid primary key default gen_random_uuid(),
	identity_id   uuid not null references public.identities (id) on delete cascade,
	item_id       uuid not null,
	token_hash    text not null unique,
	label         text,
	created_at    timestamptz not null default now(),
	expires_at    timestamptz,
	revoked_at    timestamptz,
	opened        integer not null default 0,
	last_opened   timestamptz,
	foreign key (item_id, identity_id) references public.drive_items (id, identity_id)
		on delete cascade
);

-- Set by billing (the service role); readable by the identity.
create table public.drive_quotas (
	identity_id uuid primary key references public.identities (id) on delete cascade,
	bytes_limit bigint not null check (bytes_limit >= 0),
	updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

create function public.drive_items_touch() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if tg_op = 'UPDATE' then
		if new.identity_id <> old.identity_id then
			raise exception 'an item cannot move between identities; share it or copy it'
				using errcode = '42501';
		end if;
		if new.kind <> old.kind then
			raise exception 'an item cannot change kind' using errcode = '22023';
		end if;
		-- Only bump the feed on a change the sync cares about. Opening a file
		-- (accessed_at) is not a change to its content or place.
		if (new.parent_id, new.name, new.version_id, new.trashed_at, new.starred)
		   is distinct from (old.parent_id, old.name, old.version_id, old.trashed_at, old.starred) then
			new.seq := nextval('public.drive_seq');
			new.updated_at := now();
		end if;
	end if;
	-- An editor may move things only between folders the share covers: a
	-- direct share on a file lets it be renamed, not carried off elsewhere.
	if tg_op = 'UPDATE' and new.parent_id is distinct from old.parent_id
	   and not public.can_access_identity(new.identity_id)
	   and (new.parent_id is null or public.drive_shared_role(null, new.parent_id) is distinct from 'editor') then
		raise exception 'an editor can only move within the shared folder' using errcode = '42501';
	end if;
	-- A folder cannot be put inside itself.
	if new.parent_id is not null and new.kind = 'folder' and tg_op = 'UPDATE'
	   and new.parent_id is distinct from old.parent_id then
		if exists (
			with recursive up(id, parent_id) as (
				select i.id, i.parent_id from public.drive_items i where i.id = new.parent_id
				union all
				select i.id, i.parent_id from public.drive_items i join up on i.id = up.parent_id
			)
			select 1 from up where up.id = new.id
		) then
			raise exception 'a folder cannot be moved inside itself' using errcode = '22023';
		end if;
	end if;
	return new;
end
$$;

create trigger drive_items_touch before insert or update on public.drive_items
	for each row execute function public.drive_items_touch();

-- ---------------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------------

-- The share role the caller holds on an item, through a share on the item
-- itself or on any folder above it. `p_parent` is where to start walking up,
-- passed separately so an update's WITH CHECK can ask about the *new* parent.
-- Null when no active share reaches the caller. Owners are not "shared"; their
-- access is can_access_identity() and is checked separately.
create function public.drive_shared_role(p_item uuid, p_parent uuid) returns text
language sql stable security definer
set search_path = ''
as $$
	with recursive up(id, parent_id, depth) as (
		select i.id, i.parent_id, 0 from public.drive_items i where i.id = p_parent
		union all
		select i.id, i.parent_id, up.depth + 1
		from public.drive_items i join up on i.id = up.parent_id
		where up.depth < 64
	),
	chain as (
		select p_item as id where p_item is not null
		union
		select id from up
	)
	select case when bool_or(s.role = 'editor') then 'editor'
	            when count(*) > 0 then 'viewer' end
	from public.drive_shares s
	join chain on chain.id = s.item_id
	where s.revoked_at is null
	  and (s.expires_at is null or s.expires_at > now())
	  and public.can_access_identity(s.grantee_identity)
$$;

-- Whether the caller holds an editor share on anything in this identity's
-- drive, which is what lets them upload chunks into its prefix.
create function public.drive_has_editor_share(p_identity uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select exists (
		select 1 from public.drive_shares s
		where s.identity_id = p_identity and s.role = 'editor'
		  and s.revoked_at is null
		  and (s.expires_at is null or s.expires_at > now())
		  and public.can_access_identity(s.grantee_identity)
	)
$$;

-- The identity a storage path belongs to, or null when the path is not one
-- of ours. Never throws, so a malformed path fails a policy instead of the
-- whole request.
create function public.drive_path_identity(p_name text) returns uuid
language sql immutable
set search_path = ''
as $$
	select case when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
	            then substr(p_name, 1, 36)::uuid end
$$;

-- Whether a chunk is readable through a share: some current version of an
-- item shared with the caller lists it.
create function public.drive_can_read_shared_chunk(p_identity uuid, p_hash text) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select exists (
		select 1
		from public.drive_versions v
		join public.drive_items i on i.version_id = v.id
		where v.identity_id = p_identity
		  and v.chunks @> array[p_hash]
		  and i.trashed_at is null
		  and public.drive_shared_role(i.id, i.parent_id) is not null
	)
$$;

-- Bytes held in Storage for an identity: every chunk once, whatever number
-- of versions, files or trashed items point at it.
create function public.drive_stored_bytes(p_identity uuid) returns bigint
language sql stable security definer
set search_path = ''
as $$
	select coalesce(sum((o.metadata ->> 'size')::bigint), 0)::bigint
	from storage.objects o
	where o.bucket_id = 'drive' and o.name like p_identity::text || '/%'
$$;

create function public.drive_quota_bytes(p_identity uuid) returns bigint
language sql stable security definer
set search_path = ''
as $$
	select coalesce((select q.bytes_limit from public.drive_quotas q where q.identity_id = p_identity),
	                15::bigint * 1024 * 1024 * 1024)
$$;

-- Lock the helpers down: they are building blocks for policies, and the
-- security definer ones must not become a way to probe other identities.
revoke execute on function public.drive_stored_bytes(uuid) from public, anon;
revoke execute on function public.drive_can_read_shared_chunk(uuid, text) from public, anon;
revoke execute on function public.drive_has_editor_share(uuid) from public, anon;
revoke execute on function public.drive_shared_role(uuid, uuid) from public, anon;
revoke execute on function public.drive_quota_bytes(uuid) from public, anon;
grant execute on function public.drive_stored_bytes(uuid) to authenticated, service_role;
grant execute on function public.drive_can_read_shared_chunk(uuid, text) to authenticated, service_role;
grant execute on function public.drive_has_editor_share(uuid) to authenticated, service_role;
grant execute on function public.drive_shared_role(uuid, uuid) to authenticated, service_role;
grant execute on function public.drive_quota_bytes(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.drive_items enable row level security;
alter table public.drive_versions enable row level security;
alter table public.drive_shares enable row level security;
alter table public.drive_links enable row level security;
alter table public.drive_quotas enable row level security;

create policy drive_items_select on public.drive_items for select
	using (public.can_access_identity(identity_id)
	       or public.drive_shared_role(id, parent_id) is not null);

create policy drive_items_insert on public.drive_items for insert
	with check (public.can_access_identity(identity_id)
	            or (parent_id is not null and public.drive_shared_role(null, parent_id) = 'editor'));

create policy drive_items_update on public.drive_items for update
	using (public.can_access_identity(identity_id)
	       or public.drive_shared_role(id, parent_id) = 'editor')
	with check (public.can_access_identity(identity_id)
	            or public.drive_shared_role(id, parent_id) = 'editor');

-- Deleting for good is the owner's alone; an editor trashes.
create policy drive_items_delete on public.drive_items for delete
	using (public.can_access_identity(identity_id));

create policy drive_versions_select on public.drive_versions for select
	using (public.can_access_identity(identity_id)
	       or exists (select 1 from public.drive_items i
	                  where i.id = item_id and i.version_id = drive_versions.id
	                    and public.drive_shared_role(i.id, i.parent_id) is not null));

create policy drive_versions_insert on public.drive_versions for insert
	with check (public.can_access_identity(identity_id)
	            or exists (select 1 from public.drive_items i
	                       where i.id = item_id
	                         and public.drive_shared_role(i.id, i.parent_id) = 'editor'));

create policy drive_versions_delete on public.drive_versions for delete
	using (public.can_access_identity(identity_id));

-- The source sees its shares; the target sees what was shared with it.
create policy drive_shares_select on public.drive_shares for select
	using (public.can_access_identity(identity_id)
	       or public.can_access_identity(grantee_identity));

create policy drive_shares_insert on public.drive_shares for insert
	with check (public.can_access_identity(identity_id));

create policy drive_shares_update on public.drive_shares for update
	using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));

create policy drive_shares_delete on public.drive_shares for delete
	using (public.can_access_identity(identity_id));

create policy drive_links_select on public.drive_links for select
	using (public.can_access_identity(identity_id));
create policy drive_links_insert on public.drive_links for insert
	with check (public.can_access_identity(identity_id));
create policy drive_links_update on public.drive_links for update
	using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));

create policy drive_quotas_select on public.drive_quotas for select
	using (public.can_access_identity(identity_id));

grant select, insert, update, delete on public.drive_items, public.drive_versions,
	public.drive_shares, public.drive_links to authenticated;
grant select on public.drive_quotas to authenticated;
grant usage on sequence public.drive_seq to authenticated;
revoke all on public.drive_items, public.drive_versions, public.drive_shares,
	public.drive_links, public.drive_quotas from anon;

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('drive', 'drive', false, 4 * 1024 * 1024 + 4096)
on conflict (id) do nothing;

-- Read: your own identity's chunks, or a chunk a share lets you see.
create policy drive_objects_select on storage.objects for select to authenticated
	using (bucket_id = 'drive'
	       and (public.can_access_identity(public.drive_path_identity(name))
	            or public.drive_can_read_shared_chunk(public.drive_path_identity(name),
	                                                  storage.filename(name))));

-- Write: a chunk, under a prefix you may write, while under quota. Chunks are
-- immutable, so there is no update policy: re-uploading one that exists is a
-- 409 the client treats as success.
create policy drive_objects_insert on storage.objects for insert to authenticated
	with check (bucket_id = 'drive'
	            and name ~ '^[0-9a-f-]{36}/chunks/[0-9a-f]{64}$'
	            and (public.can_access_identity(public.drive_path_identity(name))
	                 or public.drive_has_editor_share(public.drive_path_identity(name)))
	            and public.drive_stored_bytes(public.drive_path_identity(name))
	                < public.drive_quota_bytes(public.drive_path_identity(name)));

-- Delete: garbage collection, the owner only.
create policy drive_objects_delete on storage.objects for delete to authenticated
	using (bucket_id = 'drive'
	       and public.can_access_identity(public.drive_path_identity(name)));

-- ---------------------------------------------------------------------------
-- Operations
--
-- Security invoker unless marked otherwise: they run as the caller, so the
-- policies above are what decides, and an RPC is never a way around them.
-- Errors use PostgREST's PTxxx codes so the HTTP status means something:
-- PT409 the item changed under you, PT412 a chunk is missing, PT404 not found.
-- ---------------------------------------------------------------------------

-- A slash-separated path from the drive root, for display and for the sync.
create function public.drive_path(p_item uuid) returns text
language sql stable
set search_path = ''
as $$
	with recursive up(id, parent_id, name, depth) as (
		select i.id, i.parent_id, i.name, 0 from public.drive_items i where i.id = p_item
		union all
		select i.id, i.parent_id, i.name, up.depth + 1
		from public.drive_items i join up on i.id = up.parent_id
		where up.depth < 64
	)
	select string_agg(name, '/' order by depth desc) from up
$$;

-- Commit a file's content. Chunks must already be in Storage; this records
-- the version and makes it current. `p_item` null creates the file.
-- `p_base_seq` is the seq the client last saw; if the item moved on since,
-- the commit is refused with PT409 and the client has a conflict to resolve.
create function public.drive_commit(
	p_identity   uuid,
	p_parent     uuid,
	p_name       text,
	p_item       uuid,
	p_base_seq   bigint,
	p_size       bigint,
	p_hash       text,
	p_mime       text,
	p_chunks     text[],
	p_chunk_size integer,
	p_modified   timestamptz default now(),
	p_device     text default null
) returns public.drive_items
language plpgsql
set search_path = ''
as $$
declare
	it      public.drive_items;
	missing integer;
	ver     uuid := gen_random_uuid();
begin
	select count(*) into missing from public.drive_missing_chunks(p_identity, p_chunks);
	if missing > 0 then
		raise exception '% chunk(s) not uploaded', missing using errcode = 'PT412';
	end if;

	if p_item is null then
		insert into public.drive_items (id, identity_id, parent_id, name, kind, modified_at, device)
		values (gen_random_uuid(), p_identity, p_parent, p_name, 'file', p_modified, p_device)
		returning * into it;
	else
		select * into it from public.drive_items where id = p_item for update;
		if not found then
			raise exception 'no such item' using errcode = 'PT404';
		end if;
		if p_base_seq is not null and it.seq <> p_base_seq then
			raise exception 'item changed (seq % now, client had %)', it.seq, p_base_seq
				using errcode = 'PT409';
		end if;
	end if;

	insert into public.drive_versions (id, identity_id, item_id, size, content_hash,
	                                   chunk_size, chunks, mime, device)
	values (ver, p_identity, it.id, p_size, p_hash, p_chunk_size, p_chunks, p_mime, p_device);

	update public.drive_items
	set version_id = ver, size = p_size, content_hash = p_hash, mime = p_mime,
	    modified_at = p_modified, device = p_device, trashed_at = null, trashed_root = null
	where id = it.id
	returning * into it;
	return it;
end
$$;

-- Move and/or rename, refused with PT409 if the item changed since base_seq.
create function public.drive_move(p_item uuid, p_parent uuid, p_name text,
                                  p_base_seq bigint default null, p_device text default null)
returns public.drive_items
language plpgsql
set search_path = ''
as $$
declare
	it public.drive_items;
begin
	select * into it from public.drive_items where id = p_item for update;
	if not found then
		raise exception 'no such item' using errcode = 'PT404';
	end if;
	if p_base_seq is not null and it.seq <> p_base_seq then
		raise exception 'item changed' using errcode = 'PT409';
	end if;
	update public.drive_items set parent_id = p_parent, name = p_name, device = p_device
	where id = p_item returning * into it;
	return it;
end
$$;

-- Trash an item and everything under it, remembering which trashing took
-- them so restore brings back exactly that set.
create function public.drive_trash(p_item uuid, p_device text default null) returns integer
language plpgsql
set search_path = ''
as $$
declare
	n integer;
begin
	with recursive down(id) as (
		select i.id from public.drive_items i where i.id = p_item and i.trashed_at is null
		union all
		select i.id from public.drive_items i join down on i.parent_id = down.id
		where i.trashed_at is null
	)
	update public.drive_items i
	set trashed_at = now(), trashed_root = p_item, device = p_device
	from down where i.id = down.id;
	get diagnostics n = row_count;
	if n = 0 then
		raise exception 'no such item, or already in the trash' using errcode = 'PT404';
	end if;
	return n;
end
$$;

-- Restore what one trashing took. If the original folder is itself in the
-- trash the item comes back at the root; if its name is taken it comes back
-- as "name (restored)".
create function public.drive_restore(p_item uuid) returns public.drive_items
language plpgsql
set search_path = ''
as $$
declare
	it      public.drive_items;
	parent  uuid;
	newname text;
	k       integer := 1;
begin
	select * into it from public.drive_items where id = p_item and trashed_root = p_item;
	if not found then
		raise exception 'not in the trash' using errcode = 'PT404';
	end if;
	parent := it.parent_id;
	if parent is not null and exists (select 1 from public.drive_items
	                                  where id = parent and trashed_at is not null) then
		parent := null;
	end if;
	newname := it.name;
	while exists (select 1 from public.drive_items
	              where identity_id = it.identity_id and trashed_at is null
	                and parent_id is not distinct from parent and name = newname) loop
		newname := case when k = 1 then
			regexp_replace(it.name, '(\.[^.]*)?$', ' (restored)\1')
		else
			regexp_replace(it.name, '(\.[^.]*)?$', format(' (restored %s)\1', k))
		end;
		k := k + 1;
	end loop;
	update public.drive_items set trashed_at = null, trashed_root = null
	where trashed_root = p_item and id <> p_item;
	update public.drive_items set trashed_at = null, trashed_root = null,
	       parent_id = parent, name = newname
	where id = p_item returning * into it;
	return it;
end
$$;

-- Empty the trash for good. Returns how many items went. Chunks are not
-- removed here: drive_unreferenced_chunks lists them for a GC pass that
-- deletes through the Storage API, which is the only way the blob goes too.
create function public.drive_empty_trash(p_identity uuid, p_older_than interval default '0'::interval)
returns integer
language plpgsql
set search_path = ''
as $$
declare
	n integer;
begin
	-- Clear the current-version pointer first: the version rows go with the
	-- item by cascade, and the deferred FK must not see a dangling pointer.
	delete from public.drive_items
	where identity_id = p_identity and trashed_at is not null
	  and trashed_at <= now() - p_older_than;
	get diagnostics n = row_count;
	return n;
end
$$;

create function public.drive_unreferenced_chunks(p_identity uuid) returns setof text
language sql stable
set search_path = ''
as $$
	select o.name from storage.objects o
	where o.bucket_id = 'drive' and o.name like p_identity::text || '/chunks/%'
	  and public.can_access_identity(p_identity)
	  and not exists (select 1 from public.drive_versions v
	                  where v.identity_id = p_identity
	                    and v.chunks @> array[storage.filename(o.name)])
$$;

-- Which of these chunks the identity does not have yet: the dedupe question
-- a client asks before uploading anything. Security definer because an
-- editor of a shared folder writes chunks it cannot read back; it answers
-- only to the owner or an editor, and to anyone else claims every chunk is
-- missing, which reveals nothing.
create function public.drive_missing_chunks(p_identity uuid, p_hashes text[]) returns setof text
language sql stable security definer
set search_path = ''
as $$
	select h from unnest(p_hashes) h
	where not (public.can_access_identity(p_identity) or public.drive_has_editor_share(p_identity)
	           or coalesce(auth.jwt() ->> 'role', '') = 'service_role')
	   or not exists (select 1 from storage.objects o
	                  where o.bucket_id = 'drive'
	                    and o.name = p_identity::text || '/chunks/' || h)
$$;

-- Mark an item opened, for Recent. Not a change: it does not bump seq.
create function public.drive_touch(p_item uuid) returns void
language sql
set search_path = ''
as $$
	update public.drive_items set accessed_at = now() where id = p_item
$$;

-- Storage use for the quota bar.
create function public.drive_usage(p_identity uuid)
returns table (stored_bytes bigint, file_bytes bigint, trash_bytes bigint,
               version_bytes bigint, quota_bytes bigint, files bigint, folders bigint)
language sql stable
set search_path = ''
as $$
	select
		case when public.can_access_identity(p_identity) then public.drive_stored_bytes(p_identity) end,
		coalesce(sum(size) filter (where kind = 'file' and trashed_at is null), 0)::bigint,
		coalesce(sum(size) filter (where kind = 'file' and trashed_at is not null), 0)::bigint,
		(select coalesce(sum(v.size), 0)::bigint from public.drive_versions v
		 join public.drive_items i on i.id = v.item_id
		 where v.identity_id = p_identity and v.id <> i.version_id),
		case when public.can_access_identity(p_identity) then public.drive_quota_bytes(p_identity) end,
		count(*) filter (where kind = 'file' and trashed_at is null),
		count(*) filter (where kind = 'folder' and trashed_at is null)
	from public.drive_items
	where identity_id = p_identity and public.can_access_identity(p_identity)
$$;

-- Share with another identity by handle. Handles are mail addresses and so
-- already public; looking one up reveals nothing a mail would not.
create function public.drive_share(p_item uuid, p_handle text, p_role text default 'viewer',
                                   p_expires timestamptz default null)
returns public.drive_shares
language plpgsql
set search_path = ''
as $$
declare
	it      public.drive_items;
	grantee uuid;
	s       public.drive_shares;
begin
	select * into it from public.drive_items where id = p_item;
	if not found or not public.can_access_identity(it.identity_id) then
		raise exception 'no such item' using errcode = 'PT404';
	end if;
	select public.drive_identity_by_handle(p_handle) into grantee;
	if grantee is null then
		raise exception 'no identity %', p_handle using errcode = 'PT404';
	end if;
	update public.drive_shares set revoked_at = now()
	where item_id = p_item and grantee_identity = grantee and revoked_at is null;
	insert into public.drive_shares (identity_id, item_id, grantee_identity, role, expires_at)
	values (it.identity_id, p_item, grantee, p_role, p_expires)
	returning * into s;
	return s;
end
$$;

create function public.drive_identity_by_handle(p_handle text) returns uuid
language sql stable security definer
set search_path = ''
as $$
	select id from public.identities where handle = lower(p_handle) and archived_at is null
$$;
revoke execute on function public.drive_identity_by_handle(text) from public, anon;
grant execute on function public.drive_identity_by_handle(text) to authenticated, service_role;

-- Mint a read-only link. Returns the token, once; only its hash is kept.
create function public.drive_link_mint(p_item uuid, p_expires_in interval default '7 days',
                                       p_label text default null)
returns table (link_id uuid, token text, expires_at timestamptz)
language plpgsql
set search_path = ''
as $$
declare
	it  public.drive_items;
	tok text := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_');
	l   public.drive_links;
begin
	select * into it from public.drive_items where id = p_item and trashed_at is null;
	if not found or not public.can_access_identity(it.identity_id) then
		raise exception 'no such item' using errcode = 'PT404';
	end if;
	insert into public.drive_links (identity_id, item_id, token_hash, label, expires_at)
	values (it.identity_id, p_item, encode(extensions.digest(tok, 'sha256'), 'hex'), p_label,
	        case when p_expires_in is null then null else now() + p_expires_in end)
	returning * into l;
	return query select l.id, tok, l.expires_at;
end
$$;

-- Resolve a link: anyone holding the token may call this, signed in or not.
-- It answers only for a live link to an item not in the trash, and only with
-- what a read-only download needs: names, sizes, and the chunk lists. The
-- chunks themselves are fetched by the link gateway with the service role
-- (see cloud/docs/drive.md); this function is what decides whether it may.
create function public.drive_link_resolve(p_token text)
returns table (identity_id uuid, item_id uuid, path text, kind text, size bigint,
               mime text, content_hash text, chunk_size integer, chunks text[])
language plpgsql security definer
set search_path = ''
as $$
declare
	l public.drive_links;
begin
	select * into l from public.drive_links
	where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
	  and revoked_at is null and (expires_at is null or expires_at > now());
	if not found then
		raise exception 'no such link' using errcode = 'PT404';
	end if;
	update public.drive_links set opened = opened + 1, last_opened = now() where id = l.id;
	return query
	with recursive down(id, rel) as (
		select i.id, i.name from public.drive_items i
		where i.id = l.item_id and i.trashed_at is null
		union all
		select i.id, down.rel || '/' || i.name
		from public.drive_items i join down on i.parent_id = down.id
		where i.trashed_at is null
	)
	select i.identity_id, i.id, down.rel, i.kind, i.size, i.mime, i.content_hash,
	       v.chunk_size, v.chunks
	from down join public.drive_items i on i.id = down.id
	left join public.drive_versions v on v.id = i.version_id
	order by down.rel;
end
$$;
grant execute on function public.drive_link_resolve(text) to anon, authenticated, service_role;

-- The RPCs that act on a person's drive are for signed-in callers only.
revoke execute on function public.drive_commit(uuid, uuid, text, uuid, bigint, bigint, text, text, text[], integer, timestamptz, text) from public, anon;
revoke execute on function public.drive_move(uuid, uuid, text, bigint, text) from public, anon;
revoke execute on function public.drive_trash(uuid, text) from public, anon;
revoke execute on function public.drive_restore(uuid) from public, anon;
revoke execute on function public.drive_empty_trash(uuid, interval) from public, anon;
revoke execute on function public.drive_unreferenced_chunks(uuid) from public, anon;
revoke execute on function public.drive_missing_chunks(uuid, text[]) from public, anon;
revoke execute on function public.drive_touch(uuid) from public, anon;
revoke execute on function public.drive_usage(uuid) from public, anon;
revoke execute on function public.drive_share(uuid, text, text, timestamptz) from public, anon;
revoke execute on function public.drive_link_mint(uuid, interval, text) from public, anon;
grant execute on function public.drive_commit(uuid, uuid, text, uuid, bigint, bigint, text, text, text[], integer, timestamptz, text) to authenticated;
grant execute on function public.drive_move(uuid, uuid, text, bigint, text) to authenticated;
grant execute on function public.drive_trash(uuid, text) to authenticated;
grant execute on function public.drive_restore(uuid) to authenticated;
grant execute on function public.drive_empty_trash(uuid, interval) to authenticated;
grant execute on function public.drive_unreferenced_chunks(uuid) to authenticated;
grant execute on function public.drive_missing_chunks(uuid, text[]) to authenticated;
grant execute on function public.drive_touch(uuid) to authenticated;
grant execute on function public.drive_usage(uuid) to authenticated;
grant execute on function public.drive_share(uuid, text, text, timestamptz) to authenticated;
grant execute on function public.drive_link_mint(uuid, interval, text) to authenticated;
