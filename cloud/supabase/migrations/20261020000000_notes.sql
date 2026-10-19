-- Notes: Markdown notes owned by one identity, synced across devices.
-- See cloud/docs/notes.md.
--
-- A note's text is a CRDT document of the collaboration service (cloud/collab,
-- kind 'note'): the append-only log in collab_updates is the note's revision
-- history, the sync server orders and role-checks every update, and two
-- offline edits merge character by character when they meet. This file adds
-- what a notes app needs on top of that:
--
--   notes             one row per note, keyed by the collab document's id,
--                     which the client chooses (so a note created offline has
--                     its final id in its front matter from the first second)
--   note_carries      the carry log: a copy taken from one of your identities
--                     into another, one row on each side, append-only
--   note_attachments  files a note embeds, content-addressed in Storage
--
-- Crossing identities happens in exactly two ways, each an explicit row:
-- a share (a collab_grants row, read or edit, made by the owning identity)
-- and a carry (an independent copy plus a log row on both sides). There is no
-- third way; in particular nothing resolves a [[link]] across identities.
--
-- Server-visible metadata (title, notebook, tags, pinned, trashed) is a
-- mirror the owner's devices write after they sync, for listing on a new
-- device and for the grantee's "shared with me" list. The source of truth is
-- the CRDT's registers. An end-to-end encrypted identity would leave these
-- columns empty (cloud/docs/notes.md, "End-to-end encryption").

-- The collaboration service gains a document kind. Its office types stay as
-- they were; a note is one text sequence ("body") plus registers ("note").
alter table public.collab_documents drop constraint collab_documents_kind_check;
alter table public.collab_documents add constraint collab_documents_kind_check
	check (kind in ('doc', 'sheet', 'deck', 'note'));

-- So a note row can name its document *and* insist on the same identity with
-- a foreign key rather than a check in code.
create unique index collab_documents_id_identity on public.collab_documents (id, identity_id);

create table public.notes (
	id          uuid primary key,
	identity_id uuid not null references public.identities (id) on delete cascade,
	title       text not null default '' check (length(title) <= 300),
	-- A folder path inside the identity's notebook root: "", "Projects",
	-- "Projects/Halcyon". Never absolute, never climbing out.
	notebook    text not null default ''
	            check (length(notebook) <= 300 and notebook !~ '^/' and notebook !~ '(^|/)\.\.?(/|$)'),
	tags        text[] not null default '{}' check (cardinality(tags) <= 64),
	pinned      boolean not null default false,
	trashed_at  timestamptz,
	created_at  timestamptz not null default now(),
	updated_at  timestamptz not null default now(),
	foreign key (id, identity_id) references public.collab_documents (id, identity_id) on delete cascade
);

create index notes_identity on public.notes (identity_id);

-- The carry log. One carry is two rows with the same carry_id: 'out' in the
-- identity it left, 'in' in the identity that received the copy. Rows are
-- never updated or deleted by anyone but a deleted identity's cascade, so the
-- log answers "how did this get here?" for as long as either side exists.
-- note_id has no foreign key on purpose: the log outlives the notes.
create table public.note_carries (
	id            uuid primary key default gen_random_uuid(),
	carry_id      uuid not null,
	identity_id   uuid not null references public.identities (id) on delete cascade,
	direction     text not null check (direction in ('out', 'in')),
	note_id       uuid not null,
	peer_identity uuid not null references public.identities (id) on delete cascade,
	peer_handle   text not null,
	peer_name     text not null,
	peer_note     uuid not null,
	title         text not null default '' check (length(title) <= 300),
	content_hash  text not null check (content_hash ~ '^[0-9a-f]{64}$'),
	bytes         integer not null default 0 check (bytes >= 0),
	device        text not null default '' check (length(device) <= 120),
	carried_at    timestamptz not null default now(),
	unique (carry_id, direction)
);

create index note_carries_identity on public.note_carries (identity_id, carried_at desc);

create table public.note_attachments (
	note_id     uuid not null references public.notes (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	sha256      text not null check (sha256 ~ '^[0-9a-f]{64}$'),
	name        text not null check (length(name) between 1 and 255 and name !~ '/'),
	size        bigint not null check (size >= 0),
	mime        text not null default 'application/octet-stream',
	created_at  timestamptz not null default now(),
	primary key (note_id, sha256)
);

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.notes            enable row level security;
alter table public.note_carries     enable row level security;
alter table public.note_attachments enable row level security;

-- The owner sees its notes; a grantee sees exactly the notes shared with it
-- (collab_session_role goes through can_access_identity for both sides).
create policy notes_select on public.notes for select
	using (public.can_access_identity(identity_id) or public.collab_session_role(id) is not null);
-- Metadata is the owner's: a grantee with edit access edits the text, not
-- where the owner files it, whether the owner pinned it, or the trash.
create policy notes_update on public.notes for update
	using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));

create policy note_carries_select on public.note_carries for select
	using (public.can_access_identity(identity_id));

create policy note_attachments_select on public.note_attachments for select
	using (public.can_access_identity(identity_id) or public.collab_session_role(note_id) is not null);
create policy note_attachments_insert on public.note_attachments for insert
	with check (identity_id = (select n.identity_id from public.notes n where n.id = note_id)
	            and public.collab_rank(public.collab_session_role(note_id)) >= 4);
create policy note_attachments_delete on public.note_attachments for delete
	using (public.can_access_identity(identity_id));

revoke all on public.notes, public.note_carries, public.note_attachments from anon, authenticated;
grant select on public.notes, public.note_carries, public.note_attachments to authenticated;
grant update (title, notebook, tags, pinned, trashed_at) on public.notes to authenticated;
grant insert (note_id, identity_id, sha256, name, size, mime), delete on public.note_attachments to authenticated;
grant all on public.notes, public.note_carries, public.note_attachments to service_role;

create function public.notes_touch() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.identity_id is distinct from old.identity_id or new.id is distinct from old.id then
		raise exception 'a note cannot move between identities; carry a copy instead'
			using errcode = '42501';
	end if;
	new.updated_at := now();
	return new;
end
$$;

create trigger notes_touch before update on public.notes
	for each row execute function public.notes_touch();

-- ---------------------------------------------------------------------------
-- Storage: bucket "notes", objects "<identity id>/<sha256>"
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('notes', 'notes', false, 25 * 1024 * 1024)
on conflict (id) do nothing;

create function public.notes_path_identity(p_name text) returns uuid
language sql immutable
set search_path = ''
as $$
	select case when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{64}$'
	            then substr(p_name, 1, 36)::uuid end
$$;

-- Readable through a share: an attachment row with that hash, on a note of
-- that identity, which the session can read.
create function public.notes_can_read_blob(p_identity uuid, p_hash text) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select exists (
		select 1 from public.note_attachments a
		where a.identity_id = p_identity and a.sha256 = p_hash
		  and public.collab_session_role(a.note_id) is not null
	)
$$;

-- Writable by the owner, or by an identity holding edit on one of its notes.
create function public.notes_can_write_blob(p_identity uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select public.can_access_identity(p_identity) or exists (
		select 1 from public.notes n
		where n.identity_id = p_identity
		  and public.collab_rank(public.collab_session_role(n.id)) >= 4
	)
$$;

create policy notes_objects_select on storage.objects for select to authenticated
	using (bucket_id = 'notes'
	       and (public.can_access_identity(public.notes_path_identity(name))
	            or public.notes_can_read_blob(public.notes_path_identity(name), storage.filename(name))));
create policy notes_objects_insert on storage.objects for insert to authenticated
	with check (bucket_id = 'notes'
	            and public.notes_path_identity(name) is not null
	            and public.notes_can_write_blob(public.notes_path_identity(name)));
create policy notes_objects_delete on storage.objects for delete to authenticated
	using (bucket_id = 'notes' and public.can_access_identity(public.notes_path_identity(name)));

-- ---------------------------------------------------------------------------
-- Functions people call
-- ---------------------------------------------------------------------------

-- notes_create makes a note with the id the device already gave it. It is
-- idempotent for the same identity, so a device that created the note
-- offline and lost the reply simply calls it again.
create function public.notes_create(p_id uuid, p_identity uuid, p_title text default '',
                                    p_notebook text default '') returns public.notes
language plpgsql security definer
set search_path = ''
as $$
declare
	d public.collab_documents;
	n public.notes;
begin
	if not public.can_access_identity(p_identity) then
		raise exception 'this session cannot create notes in that identity' using errcode = '42501';
	end if;
	select * into d from public.collab_documents where id = p_id;
	if d.id is not null then
		if d.identity_id <> p_identity or d.kind <> 'note' then
			raise exception 'that id is already taken' using errcode = '23505';
		end if;
		select * into n from public.notes where id = p_id;
		if n.id is not null then
			return n;
		end if;
	else
		insert into public.collab_documents (id, identity_id, kind, title)
			values (p_id, p_identity, 'note', left(coalesce(p_title, ''), 300));
	end if;
	insert into public.notes (id, identity_id, title, notebook)
		values (p_id, p_identity, left(coalesce(p_title, ''), 300), coalesce(p_notebook, ''))
		returning * into n;
	return n;
end
$$;

-- notes_share gives another identity read or edit access to one note: a
-- collab grant (view or edit), which is what the sync server and every RLS
-- policy here read. Only the owning identity can share.
create function public.notes_share(p_note uuid, p_handle text, p_access text) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
	n public.notes;
	g public.collab_grants;
	i public.identities;
begin
	select * into n from public.notes where id = p_note;
	if n.id is null or not public.can_access_identity(n.identity_id) then
		raise exception 'only the owning identity can share this note' using errcode = '42501';
	end if;
	if p_access not in ('read', 'edit') then
		raise exception 'a note is shared to read or to edit, not %', p_access using errcode = '22023';
	end if;
	g := public.collab_share(p_note, p_handle, case p_access when 'read' then 'view' else 'edit' end);
	select * into i from public.identities where id = g.grantee_identity;
	return jsonb_build_object('note', p_note, 'access', p_access,
		'identity', jsonb_build_object('id', i.id, 'handle', i.handle, 'display_name', i.display_name,
		                               'color', i.color));
end
$$;

create function public.notes_unshare(p_note uuid, p_handle text) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
	n public.notes;
begin
	select * into n from public.notes where id = p_note;
	if n.id is null or not public.can_access_identity(n.identity_id) then
		raise exception 'only the owning identity can change sharing' using errcode = '42501';
	end if;
	return public.collab_unshare(p_note, p_handle);
end
$$;

-- notes_people: who a note is shared with, in the notes vocabulary.
create function public.notes_people(p_note uuid) returns table (
	identity_id uuid, handle text, display_name text, color text, access text)
language sql stable security definer
set search_path = ''
as $$
	select p.identity_id, p.handle, p.display_name, p.color,
	       case p.role when 'owner' then 'owner' when 'view' then 'read' else 'edit' end
	from public.collab_people(p_note) p
	join public.notes n on n.id = p_note
$$;

-- notes_carry copies a note from one of your identities into another: a new
-- note with its own id in the target, independent from then on, and a row in
-- each identity's carry log naming the other side and the content's hash.
--
-- It needs to act in both identities, so a session scoped to one of them
-- (an assistant, a device enrolled for one identity) cannot carry: that is
-- the point of the scope, not a limitation of it. The copy's text is written
-- by the carrying device through the sync server as the target identity, and
-- the hash here is what that text must hash to.
create function public.notes_carry(p_note uuid, p_to text, p_new uuid, p_hash text,
                                   p_title text default null, p_bytes int default 0,
                                   p_device text default '') returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
	n public.notes;
	src public.identities;
	dst public.identities;
	cid uuid := gen_random_uuid();
	title text;
begin
	select * into n from public.notes where id = p_note;
	if n.id is null or not public.can_access_identity(n.identity_id) then
		raise exception 'only the owning identity can carry this note' using errcode = '42501';
	end if;
	select * into src from public.identities where id = n.identity_id;
	select * into dst from public.identities
		where handle = lower(p_to) and owner = auth.uid() and archived_at is null;
	if dst.id is null or not public.can_access_identity(dst.id) then
		raise exception 'carry crosses between your own identities, and this session cannot act as %', p_to
			using errcode = '42501';
	end if;
	if dst.id = src.id then
		raise exception 'the note is already in %', p_to using errcode = '22023';
	end if;
	if p_hash !~ '^[0-9a-f]{64}$' then
		raise exception 'the content hash must be a sha256 in hex' using errcode = '22023';
	end if;
	if exists (select 1 from public.collab_documents where id = p_new) then
		raise exception 'that id is already taken' using errcode = '23505';
	end if;
	title := left(coalesce(p_title, n.title), 300);

	insert into public.collab_documents (id, identity_id, kind, title) values (p_new, dst.id, 'note', title);
	insert into public.notes (id, identity_id, title, notebook) values (p_new, dst.id, title, '');

	insert into public.note_carries (carry_id, identity_id, direction, note_id, peer_identity, peer_handle,
	                                 peer_name, peer_note, title, content_hash, bytes, device)
	values
		(cid, src.id, 'out', n.id, dst.id, dst.handle, dst.display_name, p_new, title, p_hash,
		 greatest(coalesce(p_bytes, 0), 0), left(coalesce(p_device, ''), 120)),
		(cid, dst.id, 'in', p_new, src.id, src.handle, src.display_name, n.id, title, p_hash,
		 greatest(coalesce(p_bytes, 0), 0), left(coalesce(p_device, ''), 120));

	return jsonb_build_object('carry_id', cid, 'note', p_new, 'from_note', n.id,
		'from', jsonb_build_object('id', src.id, 'handle', src.handle, 'display_name', src.display_name, 'color', src.color),
		'to', jsonb_build_object('id', dst.id, 'handle', dst.handle, 'display_name', dst.display_name, 'color', dst.color));
end
$$;

-- notes_sync_state is what a device asks first when it syncs one identity:
-- every note it owns and every note shared with it, with the head of each
-- one's log, so only the notes that moved get a connection to the server.
create function public.notes_sync_state(p_identity uuid) returns table (
	id uuid, title text, notebook text, tags text[], pinned boolean, trashed_at timestamptz,
	head_seq bigint, access text, owner_identity uuid, owner_handle text, owner_name text,
	owner_color text, updated_at timestamptz)
language sql stable security definer
set search_path = ''
as $$
	select n.id, n.title, n.notebook, n.tags, n.pinned, n.trashed_at, d.head_seq, 'owner',
	       i.id, i.handle, i.display_name, i.color, d.updated_at
	from public.notes n
	join public.collab_documents d on d.id = n.id
	join public.identities i on i.id = n.identity_id
	where n.identity_id = p_identity and public.can_access_identity(p_identity)
	union all
	select n.id, n.title, '', '{}'::text[], false, n.trashed_at, d.head_seq,
	       case g.role when 'view' then 'read' else 'edit' end,
	       i.id, i.handle, i.display_name, i.color, d.updated_at
	from public.collab_grants g
	join public.notes n on n.id = g.doc_id
	join public.collab_documents d on d.id = n.id
	join public.identities i on i.id = n.identity_id
	where g.grantee_identity = p_identity and g.revoked_at is null
	  and g.role in ('view', 'edit')
	  and n.trashed_at is null
	  and public.can_access_identity(p_identity)
$$;

-- notes_purge deletes a note for good, on every device: the document, its
-- log, its grants and its attachment rows go with it. The carry log stays.
create function public.notes_purge(p_note uuid) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
	n public.notes;
begin
	select * into n from public.notes where id = p_note;
	if n.id is null or not public.can_access_identity(n.identity_id) then
		raise exception 'only the owning identity can delete this note' using errcode = '42501';
	end if;
	delete from public.collab_documents where id = p_note and kind = 'note';
	return true;
end
$$;

revoke execute on function public.notes_create(uuid, uuid, text, text), public.notes_share(uuid, text, text),
	public.notes_unshare(uuid, text), public.notes_people(uuid),
	public.notes_carry(uuid, text, uuid, text, text, int, text), public.notes_sync_state(uuid),
	public.notes_purge(uuid), public.notes_can_read_blob(uuid, text), public.notes_can_write_blob(uuid)
	from public, anon;
grant execute on function public.notes_create(uuid, uuid, text, text), public.notes_share(uuid, text, text),
	public.notes_unshare(uuid, text), public.notes_people(uuid),
	public.notes_carry(uuid, text, uuid, text, text, int, text), public.notes_sync_state(uuid),
	public.notes_purge(uuid), public.notes_can_read_blob(uuid, text), public.notes_can_write_blob(uuid)
	to authenticated, service_role;
