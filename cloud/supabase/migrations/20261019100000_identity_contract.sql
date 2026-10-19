-- The identity contract. Every Palmy cloud table is scoped to an identity,
-- and every policy goes through can_access_identity(). See cloud/CONTRACT.md.
-- Later migrations may add columns and functions; they must not change what
-- can_access_identity() means.

create table public.identities (
	id           uuid primary key default gen_random_uuid(),
	owner        uuid not null references auth.users (id) on delete cascade,
	handle       text not null unique check (handle ~ '^[a-z0-9][a-z0-9._-]{1,62}$'),
	display_name text not null,
	kind         text not null default 'personal'
	             check (kind in ('personal', 'work', 'public', 'project')),
	color        text not null default 'indigo',
	archived_at  timestamptz,
	created_at   timestamptz not null default now()
);

create index identities_owner on public.identities (owner);

-- The identity a session is scoped to, or null for an unscoped session.
-- A scoped session (an assistant, a device acting for one identity) carries
-- the claim `palm_identity` in its JWT. Unscoped sessions belong to the
-- person and see all of their own identities.
create function public.session_identity() returns uuid
language sql stable
as $$
	select nullif(coalesce(auth.jwt() ->> 'palm_identity', ''), '')::uuid
$$;

-- The one access rule. True when the caller owns the identity, it is not
-- archived, and the session is either unscoped or scoped to exactly it.
create function public.can_access_identity(target uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select exists (
		select 1 from public.identities i
		where i.id = target
		  and i.owner = auth.uid()
		  and i.archived_at is null
		  and (public.session_identity() is null or public.session_identity() = target)
	)
$$;

alter table public.identities enable row level security;

create policy identities_select on public.identities
	for select using (owner = auth.uid()
	                  and (public.session_identity() is null or public.session_identity() = id));

create policy identities_insert on public.identities
	for insert with check (owner = auth.uid() and public.session_identity() is null);

create policy identities_update on public.identities
	for update using (owner = auth.uid() and public.session_identity() is null)
	with check (owner = auth.uid());

-- No delete policy: identities are archived, not deleted.
