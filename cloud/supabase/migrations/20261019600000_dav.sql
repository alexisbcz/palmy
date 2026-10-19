-- Calendars and contacts: the storage behind cloud/dav (CalDAV and CardDAV).
-- See cloud/docs/calendar-contacts.md for the design and cloud/CONTRACT.md for
-- the rule every table here follows: identity_id on every row, and every
-- policy through public.can_access_identity().
--
-- What lives here
--
--   dav_collections    a calendar or an address book, owned by one identity
--   dav_objects        one calendar object resource (an iCalendar text with
--                      one UID) or one vCard, plus the columns a query needs
--   dav_changes        the change log behind sync-collection (RFC 6578),
--                      tombstones included
--   dav_grants         a collection shared with another identity, read or
--                      read-write: the explicit cross-identity row
--   dav_itip           scheduling messages (RFC 6638 / iTIP RFC 5546) sent
--                      by an identity, to a local identity or queued for the
--                      outside world
--   dav_app_passwords  per-identity passwords for stock DAV clients
--
-- The canonical copy of an event or a contact is the text the client wrote.
-- The indexed columns are derived from it by the server (which owns the
-- iCalendar and time zone logic) and exist only so the database can answer
-- "which objects might overlap this range" without parsing anything.

--------------------------------------------------------------------------------
-- Collections
--------------------------------------------------------------------------------

create table public.dav_collections (
	id              uuid primary key default gen_random_uuid(),
	identity_id     uuid not null references public.identities (id) on delete cascade,
	kind            text not null check (kind in ('calendar', 'addressbook')),
	-- The URL segment: /dav/calendars/<handle>/<slug>/
	slug            text not null check (slug ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' and slug not in ('inbox', 'outbox')),
	display_name    text not null default '',
	description     text not null default '',
	-- #RRGGBB or #RRGGBBAA, which is what Apple's calendar-color carries.
	color           text not null default '#2563eb' check (color ~ '^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$'),
	sort_order      integer not null default 0,
	-- Calendars only: which components it accepts (supported-calendar-component-set).
	components      text[] not null default '{VEVENT,VTODO}',
	-- Calendars only: the IANA zone floating times and all-day events are read in.
	timezone        text not null default 'UTC',
	-- Opt-in: anyone may ask this calendar's busy times through dav_freebusy().
	public_freebusy boolean not null default false,
	-- Sync state. sync_seq is the collection's current sync token; changes
	-- older than min_seq have been compacted away.
	sync_seq        bigint not null default 0,
	min_seq         bigint not null default 0,
	created_at      timestamptz not null default now(),
	updated_at      timestamptz not null default now(),
	unique (identity_id, kind, slug)
);

create index dav_collections_identity on public.dav_collections (identity_id);

--------------------------------------------------------------------------------
-- Grants: sharing a collection with another identity
--------------------------------------------------------------------------------

-- Created by the owning identity (identity_id), read by both sides. The
-- grantee identity may belong to the same person (work calendar shown in the
-- personal view) or to someone else. Deleting the row is revocation; the
-- grantee may delete it too, which is declining the share.
create table public.dav_grants (
	id               uuid primary key default gen_random_uuid(),
	identity_id      uuid not null references public.identities (id) on delete cascade,
	collection_id    uuid not null references public.dav_collections (id) on delete cascade,
	grantee_identity uuid not null references public.identities (id) on delete cascade,
	access           text not null check (access in ('read', 'read-write')),
	created_at       timestamptz not null default now(),
	unique (collection_id, grantee_identity),
	check (grantee_identity <> identity_id)
);

create index dav_grants_grantee on public.dav_grants (grantee_identity);
create index dav_grants_identity on public.dav_grants (identity_id);

-- A grant is only as good as its owner's claim to the collection.
create function public.dav_grants_check() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
	if not exists (select 1 from public.dav_collections c
	               where c.id = new.collection_id and c.identity_id = new.identity_id) then
		raise exception 'a grant must be made by the identity that owns the collection'
			using errcode = '42501';
	end if;
	return new;
end
$$;

create trigger dav_grants_check before insert or update on public.dav_grants
	for each row execute function public.dav_grants_check();

-- True when the calling session reaches the collection through a grant of
-- at least the asked access. Goes through can_access_identity() on the
-- grantee side, so a session scoped to another identity is not admitted.
create function public.dav_has_grant(collection uuid, want text) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select exists (
		select 1 from public.dav_grants g
		where g.collection_id = collection
		  and (want = 'read' or g.access = 'read-write')
		  and public.can_access_identity(g.grantee_identity)
	)
$$;

--------------------------------------------------------------------------------
-- Objects
--------------------------------------------------------------------------------

create table public.dav_objects (
	id            uuid primary key default gen_random_uuid(),
	-- Always the collection's owner, even when a grantee wrote the row.
	identity_id   uuid not null references public.identities (id) on delete cascade,
	collection_id uuid not null references public.dav_collections (id) on delete cascade,
	name          text not null check (name ~ '^[^/]{1,255}$'),
	uid           text not null,
	component     text not null check (component in ('VEVENT', 'VTODO', 'VJOURNAL', 'VFREEBUSY', 'VCARD')),
	body          text not null,
	etag          text not null,
	size          integer not null default 0,

	-- Calendar index (UTC). first_start/last_end bound every instance of a
	-- recurring object; last_end is null when the recurrence is unbounded.
	dtstart       timestamptz,
	dtend         timestamptz,
	first_start   timestamptz,
	last_end      timestamptz,
	all_day       boolean not null default false,
	rrule         text,
	overrides     integer not null default 0, -- RECURRENCE-ID components
	summary       text,
	location      text,
	status        text,
	organizer     text,
	attendees     text[] not null default '{}',

	-- Contact index.
	fn            text,
	given_name    text,
	family_name   text,
	org           text,
	emails        text[] not null default '{}',
	phones        text[] not null default '{}',
	card_kind     text, -- individual | group | org | location
	members       text[] not null default '{}', -- group members, as urn:uuid or UIDs

	created_at    timestamptz not null default now(),
	updated_at    timestamptz not null default now(),
	unique (collection_id, name),
	unique (collection_id, uid)
);

create index dav_objects_identity on public.dav_objects (identity_id);
create index dav_objects_range on public.dav_objects (collection_id, first_start, last_end);
create index dav_objects_emails on public.dav_objects using gin (emails);
create index dav_objects_attendees on public.dav_objects using gin (attendees);

-- identity_id is the collection's owner, whatever the writer says.
create function public.dav_objects_owner() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
	select c.identity_id into new.identity_id
	  from public.dav_collections c where c.id = new.collection_id;
	if new.identity_id is null then
		raise exception 'no such collection' using errcode = '23503';
	end if;
	if tg_op = 'UPDATE' and new.collection_id <> old.collection_id then
		raise exception 'an object does not move between collections; delete and put'
			using errcode = '42501';
	end if;
	new.size := octet_length(new.body);
	new.updated_at := now();
	return new;
end
$$;

create trigger dav_objects_owner before insert or update on public.dav_objects
	for each row execute function public.dav_objects_owner();

--------------------------------------------------------------------------------
-- The change log (sync-collection), tombstones included
--------------------------------------------------------------------------------

create table public.dav_changes (
	id            bigserial primary key,
	identity_id   uuid not null references public.identities (id) on delete cascade,
	collection_id uuid not null references public.dav_collections (id) on delete cascade,
	seq           bigint not null,
	name          text not null,
	deleted       boolean not null default false,
	at            timestamptz not null default now(),
	unique (collection_id, seq)
);

create index dav_changes_since on public.dav_changes (collection_id, seq);

-- Every write to an object bumps its collection's sync_seq and records the
-- name. Runs as definer because a grantee with read-write access may write
-- objects but has no business updating the collection row itself.
create function public.dav_objects_log() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
	coll uuid := coalesce(new.collection_id, old.collection_id);
	n    bigint;
	ident uuid;
begin
	update public.dav_collections set sync_seq = sync_seq + 1, updated_at = now()
	 where id = coll returning sync_seq, identity_id into n, ident;
	if n is null then
		-- The collection is being deleted (cascade): nothing to log.
		return null;
	end if;
	if tg_op = 'DELETE' then
		insert into public.dav_changes (identity_id, collection_id, seq, name, deleted)
		values (ident, coll, n, old.name, true);
	else
		insert into public.dav_changes (identity_id, collection_id, seq, name, deleted)
		values (ident, coll, n, new.name, false);
	end if;
	return null;
end
$$;

create trigger dav_objects_log after insert or update or delete on public.dav_objects
	for each row execute function public.dav_objects_log();

-- A change to the collection's own properties is a sync event too, for
-- clients that watch getctag.
create function public.dav_collections_touch() returns trigger
language plpgsql
as $$
begin
	if (new.display_name, new.description, new.color, new.sort_order, new.components, new.timezone, new.public_freebusy)
	   is distinct from
	   (old.display_name, old.description, old.color, old.sort_order, old.components, old.timezone, old.public_freebusy) then
		new.sync_seq := old.sync_seq + 1;
		new.updated_at := now();
	end if;
	return new;
end
$$;

create trigger dav_collections_touch before update on public.dav_collections
	for each row execute function public.dav_collections_touch();

-- Tombstones are kept for a while, then compacted. A client holding a token
-- older than min_seq is told its token is no longer valid and resyncs fully
-- (RFC 6578 section 3.2, DAV:valid-sync-token).
create function public.dav_compact(keep interval default interval '90 days') returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
	gone bigint;
begin
	with old as (
		delete from public.dav_changes where at < now() - keep returning collection_id, seq
	), top as (
		select collection_id, max(seq) as s from old group by collection_id
	)
	update public.dav_collections c set min_seq = greatest(c.min_seq, top.s)
	  from top where c.id = top.collection_id;
	get diagnostics gone = row_count;
	return gone;
end
$$;

revoke execute on function public.dav_compact(interval) from public, anon, authenticated;

--------------------------------------------------------------------------------
-- Scheduling: iTIP messages between identities
--------------------------------------------------------------------------------

-- A row is a message *sent by* identity_id. That makes it the explicit
-- cross-identity row the contract asks for: the sender creates it, and the
-- recipient's policy reads it. Nothing writes into another identity's
-- calendar: the recipient's own session applies the message (cloud/dav does
-- this when the recipient next connects, or the client does it on accept).
--
-- recipient_identity is null for an address outside the platform; those rows
-- are the outbound queue, and they stay 'not sent: outbound not enabled'
-- until a transport (Resend, see cloud/docs/calendar-contacts.md) exists.
create table public.dav_itip (
	id                 uuid primary key default gen_random_uuid(),
	identity_id        uuid not null references public.identities (id) on delete cascade,
	recipient_identity uuid references public.identities (id) on delete cascade,
	sender_address     text not null,
	recipient_address  text not null,
	method             text not null check (method in ('REQUEST', 'REPLY', 'CANCEL', 'ADD', 'REFRESH', 'COUNTER', 'DECLINECOUNTER', 'PUBLISH')),
	uid                text not null,
	body               text not null,
	status             text not null default 'delivered'
	                   check (status in ('delivered', 'not sent: outbound not enabled')),
	created_at         timestamptz not null default now(),
	-- Set by the recipient: applied to their calendar, and removed from
	-- their inbox collection.
	processed_at       timestamptz,
	dismissed_at       timestamptz
);

create index dav_itip_recipient on public.dav_itip (recipient_identity, created_at);
create index dav_itip_sender on public.dav_itip (identity_id, created_at);

-- The domain local addresses live in. The mail area owns the real setting;
-- until there is one, 'palm.test' as in cloud/CONTRACT.md.
create function public.dav_mail_domain() returns text
language sql stable
as $$
	select coalesce(nullif(current_setting('app.mail_domain', true), ''), 'palm.test')
$$;

-- The identity behind a calendar user address (mailto:handle@domain), or
-- null when the address is not a local identity. Security definer because
-- the sender cannot see other people's identities; it reveals only whether
-- a handle exists, which the mail address already does.
create function public.dav_resolve_address(address text) returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
	a      text := lower(trim(address));
	local  text;
	domain text;
	found  uuid;
begin
	if a like 'mailto:%' then
		a := substr(a, 8);
	end if;
	local := split_part(a, '@', 1);
	domain := split_part(a, '@', 2);
	if domain <> public.dav_mail_domain() then
		return null;
	end if;
	select i.id into found from public.identities i
	 where i.handle = local and i.archived_at is null;
	return found;
end
$$;

-- The handle of an identity the caller may know about: its own, or one that
-- shares a collection with it, or one that sent it a scheduling message.
-- Used to build URLs for shared calendars and to name senders.
create function public.dav_identity_handle(target uuid) returns text
language sql stable security definer
set search_path = ''
as $$
	select i.handle from public.identities i
	where i.id = target
	  and (public.can_access_identity(target)
	       or exists (select 1 from public.dav_grants g
	                  where (g.identity_id = target and public.can_access_identity(g.grantee_identity))
	                     or (g.grantee_identity = target and public.can_access_identity(g.identity_id)))
	       or exists (select 1 from public.dav_itip m
	                  where m.identity_id = target and public.can_access_identity(m.recipient_identity)))
$$;

-- Fill in recipient_identity and status from the address, so a client cannot
-- claim delivery to an identity the address does not name.
create function public.dav_itip_route() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
	new.recipient_identity := public.dav_resolve_address(new.recipient_address);
	new.status := case when new.recipient_identity is null
	                   then 'not sent: outbound not enabled' else 'delivered' end;
	new.processed_at := null;
	new.dismissed_at := null;
	new.created_at := now();
	return new;
end
$$;

create trigger dav_itip_route before insert on public.dav_itip
	for each row execute function public.dav_itip_route();

--------------------------------------------------------------------------------
-- App passwords: one identity, revocable, for stock clients over Basic auth
--------------------------------------------------------------------------------

-- The secret is 32 random characters, so it is stored as a SHA-256 hash
-- rather than a slow password hash: it has the entropy of a key, and
-- checking it on every request has to be cheap. Revocation is immediate
-- because every request is checked.
create table public.dav_app_passwords (
	id           uuid primary key default gen_random_uuid(),
	identity_id  uuid not null references public.identities (id) on delete cascade,
	label        text not null default '' check (length(label) <= 100),
	token_hash   bytea not null unique,
	prefix       text not null,
	created_at   timestamptz not null default now(),
	last_used_at timestamptz,
	revoked_at   timestamptz
);

create index dav_app_passwords_identity on public.dav_app_passwords (identity_id);

-- Create one. Returns the secret, which is never retrievable again. Needs an
-- unscoped session: a device acting for one identity does not mint more
-- credentials for it.
create function public.dav_app_password_create(target uuid, label text default '')
returns table (id uuid, secret text, prefix text)
language plpgsql
security invoker
set search_path = ''
as $$
declare
	alphabet constant text := 'abcdefghijkmnpqrstuvwxyz23456789';
	raw   bytea := extensions.gen_random_bytes(32);
	s     text := '';
	i     int;
	row_id uuid;
begin
	if public.session_identity() is not null then
		raise exception 'app passwords are created from an unscoped session'
			using errcode = '42501', hint = 'palm_identity';
	end if;
	if not public.can_access_identity(target) then
		raise exception 'no such identity' using errcode = '42501';
	end if;
	for i in 0..31 loop
		s := s || substr(alphabet, (get_byte(raw, i) % 32) + 1, 1);
	end loop;
	insert into public.dav_app_passwords (identity_id, label, token_hash, prefix)
	values (target, coalesce(label, ''), extensions.digest(s, 'sha256'), substr(s, 1, 4))
	returning dav_app_passwords.id into row_id;
	return query select row_id, s, substr(s, 1, 4);
end
$$;

-- Revoke one. Rows are kept so the list shows when it was revoked.
create function public.dav_app_password_revoke(target uuid) returns boolean
language sql
security invoker
set search_path = ''
as $$
	update public.dav_app_passwords set revoked_at = now()
	 where id = target and revoked_at is null
	returning true
$$;

-- Check a Basic credential. Only the DAV server calls this (service role):
-- it returns the identity and its owner, and the server mints a short-lived
-- token scoped to that identity. The username is the identity's handle or
-- its full address.
create function public.dav_app_password_check(username text, secret text)
returns table (identity_id uuid, owner uuid, handle text, password_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
	u text := lower(trim(username));
begin
	if position('@' in u) > 0 then
		if split_part(u, '@', 2) <> public.dav_mail_domain() then
			return;
		end if;
		u := split_part(u, '@', 1);
	end if;
	return query
	update public.dav_app_passwords p set last_used_at = now()
	  from public.identities i
	 where p.identity_id = i.id
	   and i.handle = u
	   and i.archived_at is null
	   and p.revoked_at is null
	   and p.token_hash = extensions.digest(secret, 'sha256')
	returning i.id, i.owner, i.handle, p.id;
end
$$;

revoke execute on function public.dav_app_password_check(text, text) from public, anon, authenticated;
grant execute on function public.dav_app_password_check(text, text) to service_role;

--------------------------------------------------------------------------------
-- Row-level security
--------------------------------------------------------------------------------

alter table public.dav_collections enable row level security;
alter table public.dav_objects enable row level security;
alter table public.dav_changes enable row level security;
alter table public.dav_grants enable row level security;
alter table public.dav_itip enable row level security;
alter table public.dav_app_passwords enable row level security;

-- Collections: the owner does everything; a grantee sees the row.
create policy dav_collections_select on public.dav_collections for select
	using (public.can_access_identity(identity_id) or public.dav_has_grant(id, 'read'));
create policy dav_collections_insert on public.dav_collections for insert
	with check (public.can_access_identity(identity_id));
create policy dav_collections_update on public.dav_collections for update
	using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));
create policy dav_collections_delete on public.dav_collections for delete
	using (public.can_access_identity(identity_id));

-- Objects: owner, or a grantee at the access the grant says.
create policy dav_objects_select on public.dav_objects for select
	using (public.can_access_identity(identity_id) or public.dav_has_grant(collection_id, 'read'));
create policy dav_objects_insert on public.dav_objects for insert
	with check (public.can_access_identity(identity_id) or public.dav_has_grant(collection_id, 'read-write'));
create policy dav_objects_update on public.dav_objects for update
	using (public.can_access_identity(identity_id) or public.dav_has_grant(collection_id, 'read-write'))
	with check (public.can_access_identity(identity_id) or public.dav_has_grant(collection_id, 'read-write'));
create policy dav_objects_delete on public.dav_objects for delete
	using (public.can_access_identity(identity_id) or public.dav_has_grant(collection_id, 'read-write'));

-- The change log is read-only to clients; the trigger writes it.
create policy dav_changes_select on public.dav_changes for select
	using (public.can_access_identity(identity_id) or public.dav_has_grant(collection_id, 'read'));

-- Grants: the owner makes and revokes; the grantee sees and may decline.
create policy dav_grants_select on public.dav_grants for select
	using (public.can_access_identity(identity_id) or public.can_access_identity(grantee_identity));
create policy dav_grants_insert on public.dav_grants for insert
	with check (public.can_access_identity(identity_id));
create policy dav_grants_update on public.dav_grants for update
	using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));
create policy dav_grants_delete on public.dav_grants for delete
	using (public.can_access_identity(identity_id) or public.can_access_identity(grantee_identity));

-- Scheduling messages: sent by identity_id, read by both ends; only the
-- recipient marks one processed or dismissed.
create policy dav_itip_select on public.dav_itip for select
	using (public.can_access_identity(identity_id) or public.can_access_identity(recipient_identity));
create policy dav_itip_insert on public.dav_itip for insert
	with check (public.can_access_identity(identity_id));
create policy dav_itip_update on public.dav_itip for update
	using (public.can_access_identity(recipient_identity))
	with check (public.can_access_identity(recipient_identity));

-- App passwords: listed and revoked by their identity; created through the
-- function above, which is security invoker and so held to the insert policy.
create policy dav_app_passwords_select on public.dav_app_passwords for select
	using (public.can_access_identity(identity_id));
create policy dav_app_passwords_insert on public.dav_app_passwords for insert
	with check (public.can_access_identity(identity_id) and public.session_identity() is null);
create policy dav_app_passwords_update on public.dav_app_passwords for update
	using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));

grant select, insert, update, delete on public.dav_collections to authenticated;
grant select, insert, update, delete on public.dav_objects to authenticated;
grant select on public.dav_changes to authenticated;
grant select, insert, update, delete on public.dav_grants to authenticated;
grant select, insert on public.dav_itip to authenticated;
grant update (processed_at, dismissed_at) on public.dav_itip to authenticated;
grant select, insert on public.dav_app_passwords to authenticated;
grant update (revoked_at, label) on public.dav_app_passwords to authenticated;
revoke all on public.dav_collections, public.dav_objects, public.dav_changes,
	public.dav_grants, public.dav_itip, public.dav_app_passwords from anon;

--------------------------------------------------------------------------------
-- The functions cloud/dav calls
--
-- All security invoker (so every row they touch is held to the policies
-- above) except where noted. They exist to make one DAV request one round
-- trip, and to put preconditions (If-Match, If-None-Match) inside the same
-- statement as the write.
--------------------------------------------------------------------------------

-- The collections an identity's home shows: its own, and the ones shared
-- with it, each with the owner's handle and the access the caller has.
create function public.dav_list_collections(target uuid, want_kind text default null)
returns table (
	id uuid, identity_id uuid, owner_handle text, kind text, slug text,
	display_name text, description text, color text, sort_order integer,
	components text[], timezone text, public_freebusy boolean,
	sync_seq bigint, min_seq bigint, access text, updated_at timestamptz
)
language sql stable
security invoker
set search_path = ''
as $$
	select c.id, c.identity_id, public.dav_identity_handle(c.identity_id), c.kind, c.slug,
	       c.display_name, c.description, c.color, c.sort_order, c.components,
	       c.timezone, c.public_freebusy, c.sync_seq, c.min_seq,
	       case when c.identity_id = target then 'owner' else g.access end,
	       c.updated_at
	  from public.dav_collections c
	  left join public.dav_grants g on g.collection_id = c.id and g.grantee_identity = target
	 where public.can_access_identity(target)
	   and (c.identity_id = target or g.id is not null)
	   and (want_kind is null or c.kind = want_kind)
	 order by c.identity_id = target desc, c.sort_order, c.display_name
$$;

-- First contact: an identity with no calendar and no address book gets one
-- of each, so a client that connects sees somewhere to put things.
create function public.dav_ensure_defaults(target uuid) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
	name text;
	col  text;
begin
	if not public.can_access_identity(target) then
		return;
	end if;
	select i.display_name, i.color into name, col from public.identities i where i.id = target;
	if not exists (select 1 from public.dav_collections where identity_id = target and kind = 'calendar') then
		insert into public.dav_collections (identity_id, kind, slug, display_name, color)
		values (target, 'calendar', 'default', 'Calendar', public.dav_color_hex(col));
	end if;
	if not exists (select 1 from public.dav_collections where identity_id = target and kind = 'addressbook') then
		insert into public.dav_collections (identity_id, kind, slug, display_name, color)
		values (target, 'addressbook', 'default', 'Contacts', public.dav_color_hex(col));
	end if;
end
$$;

-- The identity's Tailwind colour name as the 500 shade, for a default.
create function public.dav_color_hex(name text) returns text
language sql immutable
as $$
	select case coalesce(name, '')
		when 'slate' then '#64748b' when 'gray' then '#6b7280' when 'zinc' then '#71717a'
		when 'red' then '#ef4444' when 'orange' then '#f97316' when 'amber' then '#f59e0b'
		when 'yellow' then '#eab308' when 'lime' then '#84cc16' when 'green' then '#22c55e'
		when 'emerald' then '#10b981' when 'teal' then '#14b8a6' when 'cyan' then '#06b6d4'
		when 'sky' then '#0ea5e9' when 'blue' then '#3b82f6' when 'indigo' then '#6366f1'
		when 'violet' then '#8b5cf6' when 'purple' then '#a855f7' when 'fuchsia' then '#d946ef'
		when 'pink' then '#ec4899' when 'rose' then '#f43f5e'
		else '#6366f1' end
$$;

-- PUT, with the HTTP preconditions evaluated inside the write.
--   if_match       the ETag the client last saw, or null
--   if_none_match  true for "If-None-Match: *" (create only)
-- Returns the new ETag and whether the resource was created. Raises
-- 'P0412' (precondition failed) or 'P0409' (UID already used under another
-- name: CalDAV no-uid-conflict) for the server to map to HTTP.
create function public.dav_put_object(
	collection uuid, obj_name text, if_match text, if_none_match boolean,
	idx jsonb, obj_body text
) returns table (etag text, created boolean)
language plpgsql
security invoker
set search_path = ''
as $$
declare
	cur   public.dav_objects%rowtype;
	other text;
	tag   text := '"' || md5(obj_body) || '"';
	uid_v text := idx ->> 'uid';
begin
	-- Read first, then lock: a row visible through a read-only grant does not
	-- pass the update policy, so FOR UPDATE alone would make it look absent.
	select * into cur from public.dav_objects o
	 where o.collection_id = collection and o.name = obj_name;
	if found then
		perform 1 from public.dav_objects o where o.id = cur.id for update;
		if not found then
			raise exception 'read-only' using errcode = '42501';
		end if;
	end if;
	if cur.id is not null then
		if if_none_match then
			raise exception 'the resource exists' using errcode = 'P0412';
		end if;
		if if_match is not null and if_match <> '*' and if_match <> cur.etag then
			raise exception 'the resource changed' using errcode = 'P0412';
		end if;
	else
		if if_match is not null then
			raise exception 'the resource does not exist' using errcode = 'P0412';
		end if;
	end if;

	select o.name into other from public.dav_objects o
	 where o.collection_id = collection and o.uid = uid_v and o.name <> obj_name;
	if other is not null then
		raise exception '%', other using errcode = 'P0409';
	end if;

	if cur.id is not null then
		if cur.etag = tag then
			return query select tag, false;
			return;
		end if;
		update public.dav_objects o set
			uid = uid_v, component = idx ->> 'component', body = obj_body, etag = tag,
			dtstart = (idx ->> 'dtstart')::timestamptz, dtend = (idx ->> 'dtend')::timestamptz,
			first_start = (idx ->> 'first_start')::timestamptz, last_end = (idx ->> 'last_end')::timestamptz,
			all_day = coalesce((idx ->> 'all_day')::boolean, false), rrule = idx ->> 'rrule',
			overrides = coalesce((idx ->> 'overrides')::int, 0),
			summary = idx ->> 'summary', location = idx ->> 'location', status = idx ->> 'status',
			organizer = idx ->> 'organizer',
			attendees = coalesce(array(select jsonb_array_elements_text(idx -> 'attendees')), '{}'),
			fn = idx ->> 'fn', given_name = idx ->> 'given_name', family_name = idx ->> 'family_name',
			org = idx ->> 'org',
			emails = coalesce(array(select jsonb_array_elements_text(idx -> 'emails')), '{}'),
			phones = coalesce(array(select jsonb_array_elements_text(idx -> 'phones')), '{}'),
			card_kind = idx ->> 'card_kind',
			members = coalesce(array(select jsonb_array_elements_text(idx -> 'members')), '{}')
		 where o.id = cur.id;
		if not found then
			-- Visible but not writable: a read-only share.
			raise exception 'read-only' using errcode = '42501';
		end if;
		return query select tag, false;
	else
		insert into public.dav_objects (
			identity_id, collection_id, name, uid, component, body, etag,
			dtstart, dtend, first_start, last_end, all_day, rrule, overrides,
			summary, location, status, organizer, attendees,
			fn, given_name, family_name, org, emails, phones, card_kind, members)
		values (
			-- Placeholder: the owner trigger sets the real owner.
			(select c.identity_id from public.dav_collections c where c.id = collection),
			collection, obj_name, uid_v, idx ->> 'component', obj_body, tag,
			(idx ->> 'dtstart')::timestamptz, (idx ->> 'dtend')::timestamptz,
			(idx ->> 'first_start')::timestamptz, (idx ->> 'last_end')::timestamptz,
			coalesce((idx ->> 'all_day')::boolean, false), idx ->> 'rrule',
			coalesce((idx ->> 'overrides')::int, 0),
			idx ->> 'summary', idx ->> 'location', idx ->> 'status', idx ->> 'organizer',
			coalesce(array(select jsonb_array_elements_text(idx -> 'attendees')), '{}'),
			idx ->> 'fn', idx ->> 'given_name', idx ->> 'family_name', idx ->> 'org',
			coalesce(array(select jsonb_array_elements_text(idx -> 'emails')), '{}'),
			coalesce(array(select jsonb_array_elements_text(idx -> 'phones')), '{}'),
			idx ->> 'card_kind',
			coalesce(array(select jsonb_array_elements_text(idx -> 'members')), '{}'));
		return query select tag, true;
	end if;
end
$$;

create function public.dav_delete_object(collection uuid, obj_name text, if_match text)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
	cur public.dav_objects%rowtype;
begin
	select * into cur from public.dav_objects o
	 where o.collection_id = collection and o.name = obj_name;
	if not found then
		return false;
	end if;
	perform 1 from public.dav_objects o where o.id = cur.id for update;
	if not found then
		raise exception 'read-only' using errcode = '42501';
	end if;
	if if_match is not null and if_match <> '*' and if_match <> cur.etag then
		raise exception 'the resource changed' using errcode = 'P0412';
	end if;
	delete from public.dav_objects o where o.id = cur.id;
	if not found then
		-- Visible but not deletable: a read-only share.
		raise exception 'read-only' using errcode = '42501';
	end if;
	return true;
end
$$;

-- What changed since a sync token. Returns one row per name with its latest
-- state; 'invalid' is true when the token is older than the retained log.
create function public.dav_sync(collection uuid, since bigint)
returns table (name text, deleted boolean, seq bigint, etag text, invalid boolean, current bigint)
language plpgsql stable
security invoker
set search_path = ''
as $$
declare
	c public.dav_collections%rowtype;
begin
	select * into c from public.dav_collections x where x.id = collection;
	if not found then
		return;
	end if;
	if since < c.min_seq or since > c.sync_seq then
		return query select null::text, false, 0::bigint, null::text, true, c.sync_seq;
		return;
	end if;
	return query
	select distinct on (ch.name) ch.name, ch.deleted, ch.seq, o.etag, false, c.sync_seq
	  from public.dav_changes ch
	  left join public.dav_objects o on o.collection_id = collection and o.name = ch.name
	 where ch.collection_id = collection and ch.seq > since
	 order by ch.name, ch.seq desc;
end
$$;

-- Busy time for a calendar user address, across calendars that opted in to
-- public free/busy. Security definer by design: it is the published surface,
-- and it returns intervals, never titles. Recurring events are returned as
-- their bounds and rrule for the server to expand.
create function public.dav_freebusy(address text, range_start timestamptz, range_end timestamptz)
returns table (dtstart timestamptz, dtend timestamptz, first_start timestamptz, last_end timestamptz,
               rrule text, body text, transparent boolean)
language plpgsql stable security definer
set search_path = ''
as $$
declare
	who uuid := public.dav_resolve_address(address);
begin
	if who is null then
		return;
	end if;
	return query
	select o.dtstart, o.dtend, o.first_start, o.last_end, o.rrule,
	       -- The body is needed only to expand recurrences; it is stripped to
	       -- the timing by the server before anything leaves it.
	       case when o.rrule is not null or o.overrides > 0 then o.body end,
	       coalesce(o.status = 'CANCELLED', false)
	  from public.dav_objects o
	  join public.dav_collections c on c.id = o.collection_id
	 where c.identity_id = who
	   and (c.public_freebusy or public.can_access_identity(who))
	   and o.component = 'VEVENT'
	   and o.first_start < range_end
	   and (o.last_end is null or o.last_end > range_start);
end
$$;

revoke execute on function public.dav_freebusy(text, timestamptz, timestamptz) from public, anon;
grant execute on function public.dav_freebusy(text, timestamptz, timestamptz) to authenticated, service_role;

grant execute on function public.dav_list_collections(uuid, text) to authenticated;
grant execute on function public.dav_ensure_defaults(uuid) to authenticated;
grant execute on function public.dav_put_object(uuid, text, text, boolean, jsonb, text) to authenticated;
grant execute on function public.dav_delete_object(uuid, text, text) to authenticated;
grant execute on function public.dav_sync(uuid, bigint) to authenticated;
grant execute on function public.dav_app_password_create(uuid, text) to authenticated;
grant execute on function public.dav_app_password_revoke(uuid) to authenticated;
grant execute on function public.dav_resolve_address(text) to authenticated, service_role;
grant execute on function public.dav_identity_handle(uuid) to authenticated;
revoke execute on function public.dav_has_grant(uuid, text) from anon;
