-- Browser bookmarks, synced per identity. See cloud/docs/browser.md.
--
-- The browser keeps its bookmarks locally in a shape built to merge
-- (apps/browser/bookmarks.odin): client-generated UUIDs, three hybrid logical
-- clocks per record -- content (title, url), place (parent, position) and life
-- (deleted) -- and tombstones instead of deletes. This table stores the same
-- records, and the merge happens here, in one statement, so two devices
-- pushing at once cannot lose each other's edits: for each field group the
-- larger clock wins, exactly as on the client. Merging is commutative and
-- idempotent, so a push can be retried blindly.
--
-- Access follows the contract and nothing else: every row has identity_id,
-- and every policy is can_access_identity(identity_id). A device's session is
-- scoped to one identity, so a work browser's push can neither read nor write
-- a personal bookmark.

create table public.browser_bookmarks (
	identity_id   uuid not null references public.identities (id) on delete cascade,
	id            uuid not null,
	kind          text not null default 'bookmark'
	              check (kind in ('bookmark', 'folder', 'separator')),
	parent_id     uuid,
	position      text not null default '' check (position ~ '^[0-9A-Za-z]*$'),
	title         text not null default '',
	url           text not null default '' check (length(url) <= 8192),
	created_at    timestamptz not null default now(),
	deleted       boolean not null default false,
	content_clock text not null check (content_clock ~ '^[0-9]{13}-[0-9a-f]{4}-[0-9A-Za-z._-]{1,64}$'),
	place_clock   text not null check (place_clock ~ '^[0-9]{13}-[0-9a-f]{4}-[0-9A-Za-z._-]{1,64}$'),
	life_clock    text not null check (life_clock ~ '^[0-9]{13}-[0-9a-f]{4}-[0-9A-Za-z._-]{1,64}$'),
	-- a server-side change counter: a device pulls "everything after the last
	-- seq I saw", which needs no trust in anybody's wall clock
	seq           bigint not null,
	updated_at    timestamptz not null default now(),
	primary key (identity_id, id)
);

create sequence public.browser_bookmarks_seq;
alter table public.browser_bookmarks alter column seq set default nextval('public.browser_bookmarks_seq');

create index browser_bookmarks_pull on public.browser_bookmarks (identity_id, seq);

-- Every write takes a new seq, so pulls see it.
create function public.browser_bookmarks_touch() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	new.seq := nextval('public.browser_bookmarks_seq');
	new.updated_at := now();
	return new;
end
$$;

create trigger browser_bookmarks_touch
	before insert or update on public.browser_bookmarks
	for each row execute function public.browser_bookmarks_touch();

alter table public.browser_bookmarks enable row level security;

create policy browser_bookmarks_select on public.browser_bookmarks
	for select using (public.can_access_identity(identity_id));
create policy browser_bookmarks_insert on public.browser_bookmarks
	for insert with check (public.can_access_identity(identity_id));
create policy browser_bookmarks_update on public.browser_bookmarks
	for update using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));
-- Deleting a row would lose a tombstone and let another device resurrect the
-- bookmark. Clients mark deleted; a row goes away only with its identity.

-- Supabase's default privileges grant everything to anon and authenticated;
-- take back what this table must never allow, so it is refused outright
-- rather than filtered to nothing.
revoke all on public.browser_bookmarks from anon;
revoke delete, truncate on public.browser_bookmarks from authenticated;
grant select, insert, update on public.browser_bookmarks to authenticated;
grant usage on sequence public.browser_bookmarks_seq to authenticated;

-- browser_merge_bookmarks folds a batch of client records into the table,
-- field group by field group, and returns the merged rows. It runs as the
-- caller (security invoker), so the policies above decide what it may touch:
-- a record for an identity the session cannot access fails the whole batch.
create function public.browser_merge_bookmarks(target uuid, items jsonb)
returns setof public.browser_bookmarks
language plpgsql
security invoker
set search_path = ''
as $$
begin
	if not public.can_access_identity(target) then
		raise exception 'out of scope' using errcode = '42501';
	end if;
	return query
	insert into public.browser_bookmarks as b
		(identity_id, id, kind, parent_id, position, title, url, created_at, deleted,
		 content_clock, place_clock, life_clock)
	select target,
	       (r ->> 'id')::uuid,
	       coalesce(nullif(r ->> 'kind', ''), 'bookmark'),
	       nullif(r ->> 'parent', '')::uuid,
	       coalesce(r ->> 'position', ''),
	       coalesce(r ->> 'title', ''),
	       coalesce(r ->> 'url', ''),
	       case when coalesce((r ->> 'created')::bigint, 0) > 0
	            then to_timestamp((r ->> 'created')::bigint / 1000.0) else now() end,
	       coalesce((r ->> 'deleted')::boolean, false),
	       r ->> 'content_clock', r ->> 'place_clock', r ->> 'life_clock'
	from jsonb_array_elements(items) r
	on conflict (identity_id, id) do update set
		kind          = case when excluded.content_clock > b.content_clock then excluded.kind else b.kind end,
		title         = case when excluded.content_clock > b.content_clock then excluded.title else b.title end,
		url           = case when excluded.content_clock > b.content_clock then excluded.url else b.url end,
		content_clock = greatest(b.content_clock, excluded.content_clock),
		parent_id     = case when excluded.place_clock > b.place_clock then excluded.parent_id else b.parent_id end,
		position      = case when excluded.place_clock > b.place_clock then excluded.position else b.position end,
		place_clock   = greatest(b.place_clock, excluded.place_clock),
		deleted       = case when excluded.life_clock > b.life_clock then excluded.deleted else b.deleted end,
		life_clock    = greatest(b.life_clock, excluded.life_clock),
		created_at    = least(b.created_at, excluded.created_at)
	-- a record that brings nothing newer is not a change: no new seq, so the
	-- devices do not pull back what they already have
	where excluded.content_clock > b.content_clock
	   or excluded.place_clock > b.place_clock
	   or excluded.life_clock > b.life_clock
	returning b.*;
end
$$;

revoke execute on function public.browser_merge_bookmarks(uuid, jsonb) from public, anon;
grant execute on function public.browser_merge_bookmarks(uuid, jsonb) to authenticated;
