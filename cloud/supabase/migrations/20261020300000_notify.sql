-- Notifications, delivered once across a person's devices
-- (cloud/docs/notifications.md, "Once, across devices").
--
-- The notifications themselves never come here. Each device's palm-notifyd
-- receives them locally -- from mail, calendar and chat syncing on that
-- device -- and what the devices have to agree on is small: for one key in
-- one identity, has it been shown somewhere, and has it been read or
-- withdrawn. That is one row per (identity, key), and a row per device for
-- "this device was used in the last minute", which is how the one being
-- looked at is chosen.
--
-- Both tables go through can_access_identity like every other table
-- (cloud/CONTRACT.md): a device holds a session scoped to each identity it
-- carries, and the Northwind session can neither see nor touch Personal's
-- notifications -- the test the whole design is held to
-- (tests/notify_once.sql).

create table public.notify_state (
	identity_id uuid not null references public.identities (id) on delete cascade,
	key         text not null check (char_length(key) between 1 and 512),
	-- shown < read < withdrawn: a state only ever moves right
	state       text not null check (state in ('shown', 'read', 'withdrawn')),
	device_id   uuid references public.devices (id) on delete set null,
	updated_at  timestamptz not null default now(),
	primary key (identity_id, key)
);

create index notify_state_recent on public.notify_state (identity_id, updated_at desc);

alter table public.notify_state enable row level security;

create policy notify_state_select on public.notify_state
	for select using (public.can_access_identity(identity_id));
create policy notify_state_insert on public.notify_state
	for insert with check (public.can_access_identity(identity_id));
create policy notify_state_update on public.notify_state
	for update using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));
create policy notify_state_delete on public.notify_state
	for delete using (public.can_access_identity(identity_id));

grant select, insert, update, delete on public.notify_state to authenticated;

create table public.notify_presence (
	identity_id uuid not null references public.identities (id) on delete cascade,
	device_id   uuid not null references public.devices (id) on delete cascade,
	active_at   timestamptz not null default now(),
	primary key (identity_id, device_id)
);

alter table public.notify_presence enable row level security;

create policy notify_presence_select on public.notify_presence
	for select using (public.can_access_identity(identity_id));
create policy notify_presence_insert on public.notify_presence
	for insert with check (public.can_access_identity(identity_id));
create policy notify_presence_update on public.notify_presence
	for update using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));
create policy notify_presence_delete on public.notify_presence
	for delete using (public.can_access_identity(identity_id));

grant select, insert, update, delete on public.notify_presence to authenticated;

-- notify_rank orders the states so an update can only move forward: a
-- device that comes back online with a stale "shown" never un-reads what
-- another device read.
create function public.notify_rank(s text) returns int
language sql immutable
set search_path = ''
as $$ select case s when 'shown' then 1 when 'read' then 2 when 'withdrawn' then 3 else 0 end $$;

-- notify_device_check: the device must be one of the identity's own, live.
-- Runs as the caller, so RLS on devices already hides another identity's.
create function public.notify_device_check(p_identity uuid, p_device uuid) returns void
language plpgsql stable
set search_path = ''
as $$
begin
	if not public.can_access_identity(p_identity) then
		raise exception 'not this session''s identity' using errcode = '42501';
	end if;
	if not exists (
		select 1 from public.devices d
		where d.id = p_device and d.identity_id = p_identity and d.revoked_at is null
	) then
		raise exception 'not a device of this identity' using errcode = '42501';
	end if;
end
$$;

-- notify_here: "this device was used just now" (the wm's input, at most
-- every few seconds). The most recently used device within a minute is the
-- one being looked at.
create function public.notify_here(p_identity uuid, p_device uuid) returns void
language plpgsql
set search_path = ''
as $$
begin
	perform public.notify_device_check(p_identity, p_device);
	-- clock_timestamp, not now(): two devices reporting inside one
	-- transaction's instant must still come out in the order they did.
	insert into public.notify_presence as p (identity_id, device_id, active_at)
	values (p_identity, p_device, clock_timestamp())
	on conflict (identity_id, device_id) do update set active_at = clock_timestamp();
end
$$;

-- notify_claim asks, for a notification that has just arrived on a device,
-- whether this device should put it on screen:
--
--   'yours'      it is new everywhere and this device is the one in use (or
--                no device is in use): show it, and it is now marked shown
--   'elsewhere'  another device is being looked at, or already showed it:
--                keep it in this device's center, do not interrupt
--   'read', 'withdrawn'   it was dealt with on another device: do not show
--
-- The primary key makes the first claim win: two devices claiming the same
-- key at the same instant get one 'yours' between them.
create function public.notify_claim(p_identity uuid, p_key text, p_device uuid) returns text
language plpgsql
set search_path = ''
as $$
declare
	cur      text;
	other_at timestamptz;
	mine_at  timestamptz;
begin
	perform public.notify_device_check(p_identity, p_device);

	select s.state into cur from public.notify_state s
	where s.identity_id = p_identity and s.key = p_key;
	if cur in ('read', 'withdrawn') then
		return cur;
	end if;
	if cur = 'shown' then
		return 'elsewhere';
	end if;

	select max(p.active_at) into other_at from public.notify_presence p
	where p.identity_id = p_identity and p.device_id <> p_device and p.active_at > now() - interval '60 seconds';
	select p.active_at into mine_at from public.notify_presence p
	where p.identity_id = p_identity and p.device_id = p_device;
	if other_at is not null and (mine_at is null or other_at > mine_at) then
		return 'elsewhere';
	end if;

	insert into public.notify_state (identity_id, key, state, device_id)
	values (p_identity, p_key, 'shown', p_device)
	on conflict (identity_id, key) do nothing;
	if found then
		return 'yours';
	end if;
	return 'elsewhere';
end
$$;

-- notify_mark records that a notification was read or withdrawn on this
-- device, so the others take it down. It never moves a state backwards.
create function public.notify_mark(p_identity uuid, p_key text, p_device uuid, p_state text) returns text
language plpgsql
set search_path = ''
as $$
declare
	out_state text;
begin
	perform public.notify_device_check(p_identity, p_device);
	if p_state not in ('shown', 'read', 'withdrawn') then
		raise exception 'state is shown, read or withdrawn' using errcode = '22023';
	end if;
	insert into public.notify_state as s (identity_id, key, state, device_id)
	values (p_identity, p_key, p_state, p_device)
	on conflict (identity_id, key) do update
		set state = excluded.state, device_id = excluded.device_id, updated_at = now()
		where public.notify_rank(excluded.state) > public.notify_rank(s.state);
	select s.state into out_state from public.notify_state s
	where s.identity_id = p_identity and s.key = p_key;
	return out_state;
end
$$;

grant execute on function public.notify_here(uuid, uuid) to authenticated;
grant execute on function public.notify_claim(uuid, text, uuid) to authenticated;
grant execute on function public.notify_mark(uuid, text, uuid, text) to authenticated;
