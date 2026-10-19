-- Accounts: identity lifecycle, per-identity profiles and avatars, devices,
-- and sessions scoped to one identity. See cloud/CONTRACT.md and
-- cloud/docs/accounts.md.
--
-- Nothing here changes what can_access_identity() means. Every table holding
-- a person's data has identity_id and goes through it. The account-level
-- operations (listing and ending GoTrue sessions, minting a scoped session)
-- are security definer functions that refuse scoped callers outright, the
-- same rule the contract's identities_insert policy uses.

--------------------------------------------------------------------------------
-- Identities: lifecycle rules the contract left to accounts
--------------------------------------------------------------------------------

-- The colours an identity may carry: Tailwind's chromatic palette, which is
-- what palmy resolves class names against, so `bg-<color>-500` always works.
alter table public.identities add constraint identities_color_known check (color in (
	'slate', 'gray', 'zinc', 'neutral', 'stone', 'red', 'orange', 'amber',
	'yellow', 'lime', 'green', 'emerald', 'teal', 'cyan', 'sky', 'blue',
	'indigo', 'violet', 'purple', 'fuchsia', 'pink', 'rose'));

alter table public.identities add constraint identities_display_name_length
	check (char_length(btrim(display_name)) between 1 and 80);

-- Local parts a person may not claim, because mail software and people
-- expect them to reach the operator (RFC 2142, plus the obvious ones).
create function public.handle_reserved(h text) returns boolean
language sql immutable
set search_path = ''
as $$
	select h in (
		'abuse', 'admin', 'administrator', 'hostmaster', 'info', 'mailer-daemon',
		'noc', 'no-reply', 'noreply', 'postmaster', 'root', 'security', 'support',
		'webmaster', 'www', 'palm', 'palmframe', 'system', 'help', 'billing')
$$;

-- How many identities one account may hold. A person has a handful; this is
-- a guard against a script, not a product tier.
create function public.identity_limit() returns integer
language sql immutable
set search_path = ''
as $$ select 16 $$;

create function public.identities_before_insert() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
	if public.handle_reserved(new.handle) then
		raise exception 'handle "%" is reserved', new.handle using errcode = '23514';
	end if;
	if (select count(*) from public.identities where owner = new.owner) >= public.identity_limit() then
		raise exception 'an account holds at most % identities', public.identity_limit()
			using errcode = '54000';
	end if;
	new.display_name := btrim(new.display_name);
	return new;
end
$$;

create trigger identities_before_insert before insert on public.identities
	for each row execute function public.identities_before_insert();

-- The handle is the mail address and the name other people know an identity
-- by, so it is permanent: renaming changes display_name. The owner and id
-- never change.
create function public.identities_before_update() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.id <> old.id or new.owner <> old.owner or new.created_at <> old.created_at then
		raise exception 'id, owner and created_at are permanent' using errcode = '42501';
	end if;
	if new.handle <> old.handle then
		raise exception 'a handle is permanent; change display_name instead' using errcode = '42501';
	end if;
	new.display_name := btrim(new.display_name);
	return new;
end
$$;

create trigger identities_before_update before update on public.identities
	for each row execute function public.identities_before_update();

--------------------------------------------------------------------------------
-- Profiles: what an identity says about itself
--------------------------------------------------------------------------------

create table public.profiles (
	identity_id uuid primary key references public.identities (id) on delete cascade,
	bio         text not null default '' check (char_length(bio) <= 500),
	pronouns    text not null default '' check (char_length(pronouns) <= 40),
	locale      text not null default 'en' check (locale ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'),
	-- Object name in the `avatars` bucket; always under the identity's folder.
	avatar_path text check (avatar_path is null or avatar_path like identity_id::text || '/%'),
	updated_at  timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy profiles_select on public.profiles
	for select using (public.can_access_identity(identity_id));
create policy profiles_insert on public.profiles
	for insert with check (public.can_access_identity(identity_id));
create policy profiles_update on public.profiles
	for update using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));

grant select, insert, update on public.profiles to authenticated;

create function public.profiles_touch() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	new.updated_at := now();
	return new;
end
$$;

create trigger profiles_touch before update on public.profiles
	for each row execute function public.profiles_touch();

-- Every identity has a profile from birth, so clients never special-case
-- its absence.
create function public.identities_after_insert() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
	insert into public.profiles (identity_id) values (new.id) on conflict do nothing;
	return new;
end
$$;

create trigger identities_after_insert after insert on public.identities
	for each row execute function public.identities_after_insert();

--------------------------------------------------------------------------------
-- Devices: sessions scoped to one identity
--------------------------------------------------------------------------------

-- A device row is a delegation: a GoTrue session, minted by the person's own
-- unscoped session, that may act for one identity only. Its access tokens
-- carry palm_identity because custom_access_token_hook below finds this row.
--
-- The invariant that makes the scope hold: a scoped session never exists
-- without its device row. mint_scoped_session creates both in one
-- transaction, before any token for the session can be issued, and deleting
-- a device row deletes its session (devices_after_delete). When GoTrue ends
-- the session (sign-out, revocation, expiry cleanup), session_id goes null
-- and the row stays as history.
create table public.devices (
	id           uuid primary key default gen_random_uuid(),
	identity_id  uuid not null references public.identities (id) on delete cascade,
	session_id   uuid unique references auth.sessions (id) on delete set null,
	name         text not null check (char_length(btrim(name)) between 1 and 80),
	kind         text not null default 'device' check (kind in ('device', 'assistant')),
	created_at   timestamptz not null default now(),
	expires_at   timestamptz,
	last_seen_at timestamptz,
	revoked_at   timestamptz
);

create index devices_identity on public.devices (identity_id);

alter table public.devices enable row level security;

-- Read through the one rule. There is deliberately no insert, update or
-- delete policy: devices are created by mint_scoped_session and ended by
-- revoke_device, which check more than a policy can.
create policy devices_select on public.devices
	for select using (public.can_access_identity(identity_id));

grant select on public.devices to authenticated;

create function public.devices_before_update() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.identity_id <> old.identity_id then
		raise exception 'a device''s identity is permanent' using errcode = '42501';
	end if;
	if new.session_id is not null and new.session_id is distinct from old.session_id then
		raise exception 'a device''s session is permanent' using errcode = '42501';
	end if;
	return new;
end
$$;

create trigger devices_before_update before update on public.devices
	for each row execute function public.devices_before_update();

create function public.devices_after_delete() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
	if old.session_id is not null then
		delete from auth.sessions where id = old.session_id;
	end if;
	return old;
end
$$;

-- After, not before: deleting the session sets session_id null on this very
-- row through the foreign key, which a before trigger may not do.
create trigger devices_after_delete after delete on public.devices
	for each row execute function public.devices_after_delete();

-- GoTrue calls this for every access token it issues: sign-in, refresh,
-- everything. A session with a device row gets palm_identity; any other
-- session gets the claim removed, so it cannot be smuggled in some other
-- way. If this function fails, GoTrue issues no token at all.
create function public.custom_access_token_hook(event jsonb) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
	claims jsonb := coalesce(event -> 'claims', '{}'::jsonb);
	sid    uuid := nullif(claims ->> 'session_id', '')::uuid;
	scope  uuid;
begin
	if sid is not null then
		select d.identity_id into scope
		from public.devices d
		where d.session_id = sid;
	end if;
	if scope is not null then
		claims := jsonb_set(claims, '{palm_identity}', to_jsonb(scope::text));
	else
		claims := claims - 'palm_identity';
	end if;
	return jsonb_build_object('claims', claims);
end
$$;

revoke all on function public.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;

-- Raised by the functions below when a scoped session asks for something
-- only the person may do. SQLSTATE 42501 is insufficient_privilege, which
-- PostgREST answers with 403.
create function public.require_unscoped() returns uuid
language plpgsql
stable
set search_path = ''
as $$
begin
	if auth.uid() is null then
		raise exception 'not signed in' using errcode = '42501';
	end if;
	if public.session_identity() is not null then
		raise exception 'out of scope: this session acts for one identity only'
			using errcode = '42501', hint = 'palm_identity';
	end if;
	return auth.uid();
end
$$;

-- A refresh token in GoTrue's own legacy format: 12 characters of
-- [a-z0-9]. GoTrue v2.197 rejects any other length as "not valid" unless
-- its newer HMAC-signed refresh tokens are switched on, which they are not
-- by default. Each byte maps onto 36 symbols by rejection sampling, so the
-- token is uniform (about 62 bits, the same as GoTrue's own); it is single
-- use, because rotation replaces it on the first exchange.
create function public.new_refresh_token() returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
	alphabet constant text := 'abcdefghijklmnopqrstuvwxyz0123456789';
	out  text := '';
	b    bytea;
	v    integer;
begin
	while char_length(out) < 12 loop
		b := extensions.gen_random_bytes(16);
		for i in 0 .. 15 loop
			v := get_byte(b, i);
			if v < 252 and char_length(out) < 12 then
				out := out || substr(alphabet, (v % 36) + 1, 1);
			end if;
		end loop;
	end loop;
	return out;
end
$$;

revoke all on function public.new_refresh_token() from public, anon, authenticated;

-- Mint a session scoped to one identity, for a device or an assistant. Only
-- the person's own unscoped session may do this, and only for a live
-- identity it owns. Returns a refresh token; exchanging it at
-- /auth/v1/token?grant_type=refresh_token yields access tokens carrying
-- palm_identity. The refresh token is shown once and is not stored in the
-- clear anywhere but GoTrue's own table.
create function public.mint_scoped_session(
	target uuid,
	device_name text,
	device_kind text default 'device',
	expires_in_seconds integer default null
) returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
	uid     uuid := public.require_unscoped();
	sid     uuid := gen_random_uuid();
	token   text := public.new_refresh_token();
	expires timestamptz;
	dev     public.devices;
begin
	if not public.can_access_identity(target) then
		raise exception 'no such identity' using errcode = '42501';
	end if;
	if expires_in_seconds is not null then
		if expires_in_seconds < 60 then
			raise exception 'a scoped session lasts at least 60 seconds' using errcode = '22023';
		end if;
		expires := now() + make_interval(secs => expires_in_seconds);
	end if;

	insert into auth.sessions (id, user_id, created_at, updated_at, aal, not_after, user_agent)
	values (sid, uid, now(), now(), 'aal1', expires, left(btrim(device_name), 80));

	insert into auth.refresh_tokens (instance_id, token, user_id, revoked, created_at, updated_at, session_id)
	values ('00000000-0000-0000-0000-000000000000', token, uid::text, false, now(), now(), sid);

	insert into public.devices (identity_id, session_id, name, kind, expires_at)
	values (target, sid, btrim(device_name), device_kind, expires)
	returning * into dev;

	return jsonb_build_object(
		'device_id', dev.id,
		'identity_id', dev.identity_id,
		'session_id', sid,
		'refresh_token', token,
		'expires_at', expires);
end
$$;

revoke all on function public.mint_scoped_session(uuid, text, text, integer) from public, anon;
grant execute on function public.mint_scoped_session(uuid, text, text, integer) to authenticated;

-- End a scoped session. The person's unscoped session may revoke any device
-- of theirs; a scoped session may end only itself (that is signing out).
create function public.revoke_device(device uuid) returns public.devices
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
	d public.devices;
begin
	select * into d from public.devices where id = device;
	if not found or not exists (
		select 1 from public.identities i where i.id = d.identity_id and i.owner = auth.uid()
	) then
		raise exception 'no such device' using errcode = '42501';
	end if;
	if public.session_identity() is not null
	   and d.session_id is distinct from nullif(auth.jwt() ->> 'session_id', '')::uuid then
		raise exception 'out of scope: a scoped session may only end itself'
			using errcode = '42501', hint = 'palm_identity';
	end if;
	if d.session_id is not null then
		delete from auth.sessions where id = d.session_id;
	end if;
	update public.devices set revoked_at = coalesce(revoked_at, now()), session_id = null
	where id = device
	returning * into d;
	return d;
end
$$;

revoke all on function public.revoke_device(uuid) from public, anon;
grant execute on function public.revoke_device(uuid) to authenticated;

-- Archiving an identity ends every session scoped to it. can_access_identity
-- already refuses an archived identity; this makes the refusal visible as
-- signed-out devices rather than empty results.
create function public.identities_after_archive() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
	if old.archived_at is null and new.archived_at is not null then
		delete from auth.sessions s
		using public.devices d
		where d.identity_id = new.id and d.session_id = s.id;
		update public.devices set revoked_at = coalesce(revoked_at, now())
		where identity_id = new.id;
	end if;
	return new;
end
$$;

create trigger identities_after_archive after update of archived_at on public.identities
	for each row execute function public.identities_after_archive();

--------------------------------------------------------------------------------
-- Account sessions
--------------------------------------------------------------------------------

-- Every GoTrue session of the caller's account, scoped or not, with the
-- device it belongs to. An unscoped session sees them all; a scoped one sees
-- only itself, because which other machines the person uses is account
-- information, not identity information.
create function public.list_sessions()
returns table (
	session_id   uuid,
	created_at   timestamptz,
	refreshed_at timestamptz,
	not_after    timestamptz,
	user_agent   text,
	ip           text,
	identity_id  uuid,
	device_id    uuid,
	device_name  text,
	device_kind  text,
	current      boolean
)
language sql
stable
security definer
set search_path = ''
as $$
	select s.id, s.created_at, coalesce(s.refreshed_at at time zone 'utc', s.updated_at),
	       s.not_after, s.user_agent, host(s.ip), d.identity_id, d.id, d.name, d.kind,
	       s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid
	from auth.sessions s
	left join public.devices d on d.session_id = s.id
	where s.user_id = auth.uid()
	  and (public.session_identity() is null
	       or s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid)
	order by s.created_at desc
$$;

revoke all on function public.list_sessions() from public, anon;
grant execute on function public.list_sessions() to authenticated;

-- End one of the account's sessions, scoped or not. Unscoped callers only.
create function public.end_session(target uuid) returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
	uid uuid := public.require_unscoped();
begin
	update public.devices set revoked_at = coalesce(revoked_at, now())
	where session_id = target
	  and identity_id in (select id from public.identities where owner = uid);
	delete from auth.sessions where id = target and user_id = uid;
	return found;
end
$$;

revoke all on function public.end_session(uuid) from public, anon;
grant execute on function public.end_session(uuid) to authenticated;

-- Who is asking: the account, the session, and the identity it is scoped to.
-- What a client shows as "this session acts for ...".
create function public.whoami() returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
	select jsonb_build_object(
		'user_id', auth.uid(),
		'session_id', nullif(auth.jwt() ->> 'session_id', ''),
		'scoped', public.session_identity() is not null,
		'identity', (
			select jsonb_build_object('id', i.id, 'handle', i.handle,
			                          'display_name', i.display_name, 'kind', i.kind,
			                          'color', i.color, 'archived', i.archived_at is not null)
			from public.identities i
			where i.id = public.session_identity() and i.owner = auth.uid()),
		'device', (
			select jsonb_build_object('id', d.id, 'name', d.name, 'kind', d.kind,
			                          'expires_at', d.expires_at)
			from public.devices d
			where d.session_id = nullif(auth.jwt() ->> 'session_id', '')::uuid
			  and public.session_identity() is not null))
$$;

revoke all on function public.whoami() from public, anon;
grant execute on function public.whoami() to authenticated;

--------------------------------------------------------------------------------
-- Identity lifecycle RPCs. Plain PostgREST writes to identities work too;
-- these exist so every client says the same thing the same way. They are
-- security invoker: the contract's policies decide.
--------------------------------------------------------------------------------

create function public.create_identity(
	handle text,
	display_name text,
	kind text default 'personal',
	color text default 'indigo'
) returns public.identities
language sql
volatile
set search_path = ''
as $$
	insert into public.identities (owner, handle, display_name, kind, color)
	values (auth.uid(), lower(btrim(handle)), display_name, kind, color)
	returning *
$$;

create function public.rename_identity(target uuid, display_name text) returns public.identities
language sql
volatile
set search_path = ''
as $$
	update public.identities set display_name = rename_identity.display_name
	where id = target
	returning *
$$;

create function public.set_identity_color(target uuid, color text) returns public.identities
language sql
volatile
set search_path = ''
as $$
	update public.identities set color = set_identity_color.color
	where id = target
	returning *
$$;

create function public.archive_identity(target uuid) returns public.identities
language sql
volatile
set search_path = ''
as $$
	update public.identities set archived_at = coalesce(archived_at, now())
	where id = target
	returning *
$$;

create function public.restore_identity(target uuid) returns public.identities
language sql
volatile
set search_path = ''
as $$
	update public.identities set archived_at = null
	where id = target
	returning *
$$;

grant select, insert, update on public.identities to authenticated;

--------------------------------------------------------------------------------
-- Revocation takes effect at once
--------------------------------------------------------------------------------

-- An access token is a signed, stateless JWT, valid until it expires. Without
-- this, revoking a device would leave its current token working for up to an
-- hour. PostgREST runs this before every request; a token whose session no
-- longer exists is refused with 401. Tokens without a session (the anon and
-- service keys) are not affected.
create function public.palm_pre_request() returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
	sid uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
begin
	if sid is not null and not exists (select 1 from auth.sessions where id = sid) then
		raise exception 'this session has ended'
			using errcode = 'PT401', hint = 'session_ended';
	end if;
end
$$;

grant execute on function public.palm_pre_request() to anon, authenticated, service_role;

alter role authenticator set pgrst.db_pre_request = 'public.palm_pre_request';

--------------------------------------------------------------------------------
-- Avatars, in Storage
--------------------------------------------------------------------------------

-- The identity an object belongs to: its first path segment, if that is a
-- uuid. Anything else belongs to no identity, so no policy admits it.
create function public.storage_identity(object_name text) returns uuid
language plpgsql
immutable
set search_path = ''
as $$
declare
	head text := split_part(object_name, '/', 1);
begin
	if head ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
		return head::uuid;
	end if;
	return null;
end
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

create policy avatars_select on storage.objects
	for select to authenticated
	using (bucket_id = 'avatars' and public.can_access_identity(public.storage_identity(name)));
create policy avatars_insert on storage.objects
	for insert to authenticated
	with check (bucket_id = 'avatars' and public.can_access_identity(public.storage_identity(name)));
create policy avatars_update on storage.objects
	for update to authenticated
	using (bucket_id = 'avatars' and public.can_access_identity(public.storage_identity(name)))
	with check (bucket_id = 'avatars' and public.can_access_identity(public.storage_identity(name)));
create policy avatars_delete on storage.objects
	for delete to authenticated
	using (bucket_id = 'avatars' and public.can_access_identity(public.storage_identity(name)));
