-- The forge: git repositories owned by identities, with issues, pull requests,
-- reviews, labels, releases, LFS objects, an activity feed and (held)
-- webhooks. See cloud/docs/forge.md.
--
-- Every table here carries identity_id: the identity that OWNS the repository
-- the row belongs to. It is filled by a trigger from the repository, never
-- trusted from the client. Rows written by somebody else (an issue opened on
-- a public repository, a collaborator's comment) also carry the acting
-- identity in an *_identity_id column, and the write policies check that the
-- caller can act as it.
--
-- One access rule, and it goes through can_access_identity():
--
--   forge_repo_role(repo) =
--     'admin'  when the caller can act as the owning identity
--     the grant's role when an unrevoked forge_collaborators row names an
--              identity the caller can act as (the explicit share row the
--              contract asks for, created by the owning identity)
--     'read'   when visibility = 'shared' and the caller can act as another
--              identity of the same account
--     'read'   when visibility = 'public' (anonymous included)
--   then capped by the personal access token, if the session came from one.
--
-- A personal access token never becomes a general session. The forge server
-- exchanges it for a short JWT in the role `forge_pat`, which has grants on
-- forge tables only: such a session cannot read mail or drive rows even
-- though it is scoped to an identity that owns them. The token row is checked
-- on every statement, so revoking it takes effect at once.

--------------------------------------------------------------------------------
-- The token role
--------------------------------------------------------------------------------

do $$
begin
	if not exists (select 1 from pg_roles where rolname = 'forge_pat') then
		create role forge_pat nologin noinherit;
	end if;
end
$$;

grant forge_pat to authenticator;
grant usage on schema public to forge_pat;
grant usage on schema storage to forge_pat;
grant select on storage.buckets to forge_pat;
grant select, insert, update, delete on storage.objects to forge_pat;

--------------------------------------------------------------------------------
-- Tables
--------------------------------------------------------------------------------

create table public.forge_repos (
	id             uuid primary key default gen_random_uuid(),
	identity_id    uuid not null references public.identities (id) on delete cascade,
	name           text not null
	               check (name ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' and name !~* '\.git$'),
	description    text not null default '' check (length(description) <= 500),
	visibility     text not null default 'private'
	               check (visibility in ('private', 'shared', 'public')),
	default_branch text not null default 'main' check (default_branch ~ '^[A-Za-z0-9._/-]{1,200}$'),
	next_number    integer not null default 1,
	created_at     timestamptz not null default now(),
	updated_at     timestamptz not null default now(),
	pushed_at      timestamptz,
	archived_at    timestamptz
);

create unique index forge_repos_name on public.forge_repos (identity_id, lower(name));

-- An explicit grant from the owning identity to another identity: the share
-- row of the contract. Revoked, not deleted, so the audit trail survives.
create table public.forge_collaborators (
	id                  uuid primary key default gen_random_uuid(),
	repo_id             uuid not null references public.forge_repos (id) on delete cascade,
	identity_id         uuid not null references public.identities (id) on delete cascade,
	grantee_identity_id uuid not null references public.identities (id) on delete cascade,
	role                text not null check (role in ('read', 'write', 'admin')),
	created_at          timestamptz not null default now(),
	revoked_at          timestamptz,
	check (grantee_identity_id <> identity_id)
);

create unique index forge_collaborators_live
	on public.forge_collaborators (repo_id, grantee_identity_id) where revoked_at is null;
create index forge_collaborators_grantee on public.forge_collaborators (grantee_identity_id);

-- Personal access tokens. Only the SHA-256 of the token is stored; the
-- plaintext is returned once by forge_token_create.
create table public.forge_tokens (
	id           uuid primary key default gen_random_uuid(),
	identity_id  uuid not null references public.identities (id) on delete cascade,
	name         text not null check (length(name) between 1 and 80),
	token_hash   text not null unique,
	prefix       text not null,
	scope        text not null check (scope in ('read', 'write')),
	created_at   timestamptz not null default now(),
	expires_at   timestamptz,
	last_used_at timestamptz,
	revoked_at   timestamptz
);

create index forge_tokens_identity on public.forge_tokens (identity_id);

-- The refs as of the last recorded push, so the interface can list branches
-- without touching the disk.
create table public.forge_refs (
	repo_id     uuid not null references public.forge_repos (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	name        text not null,
	sha         text not null check (sha ~ '^[0-9a-f]{40}$'),
	updated_at  timestamptz not null default now(),
	primary key (repo_id, name)
);

create table public.forge_pushes (
	id                 uuid primary key default gen_random_uuid(),
	repo_id            uuid not null references public.forge_repos (id) on delete cascade,
	identity_id        uuid not null references public.identities (id) on delete cascade,
	pusher_identity_id uuid references public.identities (id) on delete set null,
	ref                text not null,
	old_sha            text not null,
	new_sha            text not null,
	commit_count       integer not null default 0,
	created_at         timestamptz not null default now()
);

create index forge_pushes_repo on public.forge_pushes (repo_id, created_at desc);

create table public.forge_commits (
	repo_id      uuid not null references public.forge_repos (id) on delete cascade,
	identity_id  uuid not null references public.identities (id) on delete cascade,
	sha          text not null check (sha ~ '^[0-9a-f]{40}$'),
	push_id      uuid references public.forge_pushes (id) on delete set null,
	author_name  text not null default '',
	author_email text not null default '',
	authored_at  timestamptz,
	summary      text not null default '',
	primary key (repo_id, sha)
);

-- Issues and pull requests share one numbering, as on GitHub: a pull request
-- is an issue with a forge_pulls row beside it.
create table public.forge_issues (
	id                 uuid primary key default gen_random_uuid(),
	repo_id            uuid not null references public.forge_repos (id) on delete cascade,
	identity_id        uuid not null references public.identities (id) on delete cascade,
	number             integer not null,
	author_identity_id uuid references public.identities (id) on delete set null,
	title              text not null check (length(title) between 1 and 300),
	body               text not null default '',
	state              text not null default 'open' check (state in ('open', 'closed')),
	is_pull            boolean not null default false,
	created_at         timestamptz not null default now(),
	updated_at         timestamptz not null default now(),
	closed_at          timestamptz,
	unique (repo_id, number)
);

create table public.forge_pulls (
	issue_id              uuid primary key references public.forge_issues (id) on delete cascade,
	repo_id               uuid not null references public.forge_repos (id) on delete cascade,
	identity_id           uuid not null references public.identities (id) on delete cascade,
	head_ref              text not null,
	base_ref              text not null,
	head_sha              text,
	base_sha              text,
	merge_method          text check (merge_method in ('fast-forward', 'merge-commit')),
	merged_sha            text,
	merged_at             timestamptz,
	merged_by_identity_id uuid references public.identities (id) on delete set null,
	check (head_ref <> base_ref)
);

create table public.forge_reviews (
	id                 uuid primary key default gen_random_uuid(),
	repo_id            uuid not null references public.forge_repos (id) on delete cascade,
	identity_id        uuid not null references public.identities (id) on delete cascade,
	issue_id           uuid not null references public.forge_issues (id) on delete cascade,
	author_identity_id uuid references public.identities (id) on delete set null,
	state              text not null check (state in ('commented', 'approved', 'changes_requested')),
	body               text not null default '',
	commit_sha         text,
	created_at         timestamptz not null default now()
);

-- Comments on an issue or pull request; with path and line, a review comment
-- on the diff.
create table public.forge_comments (
	id                 uuid primary key default gen_random_uuid(),
	repo_id            uuid not null references public.forge_repos (id) on delete cascade,
	identity_id        uuid not null references public.identities (id) on delete cascade,
	issue_id           uuid not null references public.forge_issues (id) on delete cascade,
	review_id          uuid references public.forge_reviews (id) on delete cascade,
	author_identity_id uuid references public.identities (id) on delete set null,
	body               text not null check (length(body) between 1 and 65536),
	path               text,
	line               integer,
	created_at         timestamptz not null default now(),
	updated_at         timestamptz not null default now(),
	check ((path is null) = (line is null))
);

create index forge_comments_issue on public.forge_comments (issue_id, created_at);

create table public.forge_labels (
	id          uuid primary key default gen_random_uuid(),
	repo_id     uuid not null references public.forge_repos (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	name        text not null check (length(name) between 1 and 50),
	color       text not null default 'slate',
	unique (repo_id, name)
);

create table public.forge_issue_labels (
	issue_id    uuid not null references public.forge_issues (id) on delete cascade,
	label_id    uuid not null references public.forge_labels (id) on delete cascade,
	repo_id     uuid not null references public.forge_repos (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	primary key (issue_id, label_id)
);

create table public.forge_events (
	id                uuid primary key default gen_random_uuid(),
	repo_id           uuid not null references public.forge_repos (id) on delete cascade,
	identity_id       uuid not null references public.identities (id) on delete cascade,
	actor_identity_id uuid references public.identities (id) on delete set null,
	kind              text not null,
	payload           jsonb not null default '{}',
	created_at        timestamptz not null default now()
);

create index forge_events_repo on public.forge_events (repo_id, created_at desc);

-- Outbound webhooks. Disabled by default and, in this build, never sent:
-- a matching event records a delivery with status 'held'. See forge.md.
create table public.forge_webhooks (
	id          uuid primary key default gen_random_uuid(),
	repo_id     uuid not null references public.forge_repos (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	url         text not null check (url ~ '^https?://'),
	events      text[] not null default '{*}',
	secret      text not null default encode(extensions.gen_random_bytes(20), 'hex'),
	active      boolean not null default false,
	created_at  timestamptz not null default now()
);

create table public.forge_webhook_deliveries (
	id          uuid primary key default gen_random_uuid(),
	webhook_id  uuid not null references public.forge_webhooks (id) on delete cascade,
	repo_id     uuid not null references public.forge_repos (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	event_id    uuid not null references public.forge_events (id) on delete cascade,
	status      text not null check (status in ('disabled', 'held')),
	created_at  timestamptz not null default now()
);

create table public.forge_releases (
	id                 uuid primary key default gen_random_uuid(),
	repo_id            uuid not null references public.forge_repos (id) on delete cascade,
	identity_id        uuid not null references public.identities (id) on delete cascade,
	tag                text not null,
	name               text not null default '',
	body               text not null default '',
	author_identity_id uuid references public.identities (id) on delete set null,
	created_at         timestamptz not null default now(),
	unique (repo_id, tag)
);

-- Release assets and LFS objects live in Supabase Storage, in the buckets
-- forge-releases and forge-lfs, under a path that starts with the repo id.
create table public.forge_release_assets (
	id           uuid primary key default gen_random_uuid(),
	release_id   uuid not null references public.forge_releases (id) on delete cascade,
	repo_id      uuid not null references public.forge_repos (id) on delete cascade,
	identity_id  uuid not null references public.identities (id) on delete cascade,
	name         text not null,
	size         bigint not null default 0,
	content_type text not null default 'application/octet-stream',
	object_path  text not null,
	created_at   timestamptz not null default now(),
	unique (release_id, name)
);

create table public.forge_lfs_objects (
	repo_id     uuid not null references public.forge_repos (id) on delete cascade,
	identity_id uuid not null references public.identities (id) on delete cascade,
	oid         text not null check (oid ~ '^[0-9a-f]{64}$'),
	size        bigint not null,
	created_at  timestamptz not null default now(),
	primary key (repo_id, oid)
);

--------------------------------------------------------------------------------
-- The access rule
--------------------------------------------------------------------------------

-- The cap a personal-access-token session carries: 'read' or 'write', or
-- 'none' when the token has been revoked or has expired. Null for any other
-- session, which is not capped.
create function public.forge_token_cap() returns text
language sql stable security definer
set search_path = ''
as $$
	select case
		when coalesce(auth.jwt() ->> 'role', '') <> 'forge_pat' then null
		else coalesce((
			select t.scope from public.forge_tokens t
			where t.id = nullif(auth.jwt() ->> 'forge_token', '')::uuid
			  and t.identity_id = public.session_identity()
			  and t.revoked_at is null
			  and (t.expires_at is null or t.expires_at > now())), 'none')
	end
$$;

-- May this session act as `who` and write? can_access_identity, plus the
-- token cap.
create function public.forge_can_act(who uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select public.can_access_identity(who)
	   and coalesce(public.forge_token_cap(), 'write') = 'write'
$$;

-- May this session see rows owned by `who`? can_access_identity, unless the
-- session comes from a revoked or expired token.
create function public.forge_owner_sees(who uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select public.can_access_identity(who)
	   and coalesce(public.forge_token_cap(), '') <> 'none'
$$;

create function public.forge_role_rank(r text) returns integer
language sql immutable
as $$ select case r when 'admin' then 3 when 'write' then 2 when 'read' then 1 else 0 end $$;

create function public.forge_repo_role(target uuid) returns text
language plpgsql stable security definer
set search_path = ''
as $$
declare
	r    public.forge_repos;
	cap  text := public.forge_token_cap();
	role text;
begin
	if cap = 'none' then
		return null;
	end if;
	select * into r from public.forge_repos where id = target;
	if not found then
		return null;
	end if;

	if public.can_access_identity(r.identity_id) then
		role := 'admin';
	else
		select c.role into role
		from public.forge_collaborators c
		where c.repo_id = target
		  and c.revoked_at is null
		  and public.can_access_identity(c.grantee_identity_id)
		order by public.forge_role_rank(c.role) desc
		limit 1;

		if role is null and r.visibility = 'shared' and exists (
			select 1 from public.identities o, public.identities me
			where o.id = r.identity_id and me.owner = o.owner and me.id <> o.id
			  and public.can_access_identity(me.id)) then
			role := 'read';
		end if;

		if role is null and r.visibility = 'public' then
			role := 'read';
		end if;
	end if;

	if role is not null and cap = 'read' then
		role := 'read';
	end if;
	if role = 'write' and r.archived_at is not null then
		role := 'read';
	end if;
	return role;
end
$$;

create function public.forge_can_read(target uuid) returns boolean
language sql stable
as $$ select public.forge_repo_role(target) is not null $$;

create function public.forge_can_write(target uuid) returns boolean
language sql stable
as $$ select coalesce(public.forge_repo_role(target), '') in ('write', 'admin') $$;

create function public.forge_can_admin(target uuid) returns boolean
language sql stable
as $$ select public.forge_repo_role(target) = 'admin' $$;

-- Which identity this session acts as on a repository: the scoped identity
-- if there is one, else the owner if the caller is the owner, else the
-- identity holding the strongest grant. Null for an anonymous reader.
create function public.forge_acting_identity(target uuid) returns uuid
language sql stable security definer
set search_path = ''
as $$
	select coalesce(
		public.session_identity(),
		(select r.identity_id from public.forge_repos r
		 where r.id = target and public.can_access_identity(r.identity_id)),
		(select c.grantee_identity_id from public.forge_collaborators c
		 where c.repo_id = target and c.revoked_at is null
		   and public.can_access_identity(c.grantee_identity_id)
		 order by public.forge_role_rank(c.role) desc limit 1))
$$;

--------------------------------------------------------------------------------
-- Triggers: identity_id from the repository, numbering, timestamps
--------------------------------------------------------------------------------

create function public.forge_fill_identity() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
	select r.identity_id into new.identity_id from public.forge_repos r where r.id = new.repo_id;
	return new;
end
$$;

do $$
declare t text;
begin
	foreach t in array array['forge_collaborators', 'forge_refs', 'forge_pushes', 'forge_commits',
		'forge_issues', 'forge_pulls', 'forge_reviews', 'forge_comments', 'forge_labels',
		'forge_issue_labels', 'forge_events', 'forge_webhooks', 'forge_webhook_deliveries',
		'forge_releases', 'forge_release_assets', 'forge_lfs_objects']
	loop
		execute format('create trigger %I before insert or update of repo_id on public.%I
			for each row execute function public.forge_fill_identity()', t || '_identity', t);
	end loop;
end
$$;

create function public.forge_issue_number() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
	update public.forge_repos set next_number = next_number + 1
	where id = new.repo_id
	returning next_number - 1 into new.number;
	return new;
end
$$;

create trigger forge_issues_number before insert on public.forge_issues
	for each row execute function public.forge_issue_number();

create function public.forge_touch() returns trigger
language plpgsql
as $$
begin
	new.updated_at := now();
	return new;
end
$$;

create trigger forge_repos_touch before update on public.forge_repos
	for each row execute function public.forge_touch();
create trigger forge_issues_touch before update on public.forge_issues
	for each row execute function public.forge_touch();
create trigger forge_comments_touch before update on public.forge_comments
	for each row execute function public.forge_touch();

-- Columns a client may not rewrite on an issue: which repository, its
-- number, its author, whether it is a pull request.
create function public.forge_issue_guard() returns trigger
language plpgsql
as $$
begin
	if new.repo_id <> old.repo_id or new.number <> old.number or new.is_pull <> old.is_pull
	   or new.author_identity_id is distinct from old.author_identity_id then
		raise exception 'that column is fixed once an issue exists' using errcode = '42501';
	end if;
	if new.state <> old.state then
		new.closed_at := case when new.state = 'closed' then now() end;
	end if;
	return new;
end
$$;

create trigger forge_issues_guard before update on public.forge_issues
	for each row execute function public.forge_issue_guard();

-- A collaborator grant names the repository's owning identity and cannot be
-- re-pointed; only its role and revocation change.
create function public.forge_collaborator_guard() returns trigger
language plpgsql
as $$
begin
	if new.grantee_identity_id <> old.grantee_identity_id or new.repo_id <> old.repo_id then
		raise exception 'a grant cannot be re-pointed; revoke it and grant again' using errcode = '42501';
	end if;
	return new;
end
$$;

create trigger forge_collaborators_guard before update on public.forge_collaborators
	for each row execute function public.forge_collaborator_guard();

--------------------------------------------------------------------------------
-- Activity and held webhooks
--------------------------------------------------------------------------------

create function public.forge_emit(repo uuid, actor uuid, kind text, payload jsonb) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
	ev uuid;
begin
	insert into public.forge_events (repo_id, actor_identity_id, kind, payload)
	values (repo, actor, kind, payload)
	returning id into ev;

	insert into public.forge_webhook_deliveries (webhook_id, repo_id, event_id, status)
	select w.id, repo, ev, case when w.active then 'held' else 'disabled' end
	from public.forge_webhooks w
	where w.repo_id = repo and (w.events @> array['*'] or w.events @> array[kind]);
	return ev;
end
$$;

revoke all on function public.forge_emit(uuid, uuid, text, jsonb) from public, anon, authenticated;

create function public.forge_on_repo() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
	perform public.forge_emit(new.id, new.identity_id, 'repo.created',
		jsonb_build_object('name', new.name, 'visibility', new.visibility));
	return null;
end
$$;

create trigger forge_repos_event after insert on public.forge_repos
	for each row execute function public.forge_on_repo();

create function public.forge_on_issue() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
	noun text := case when new.is_pull then 'pull' else 'issue' end;
begin
	if tg_op = 'INSERT' then
		perform public.forge_emit(new.repo_id, new.author_identity_id, noun || '.opened',
			jsonb_build_object('number', new.number, 'title', new.title));
	elsif new.state <> old.state
	      -- a merge closes its pull request; pull.merged already says so
	      and not exists (select 1 from public.forge_pulls p where p.issue_id = new.id and p.merged_at is not null) then
		perform public.forge_emit(new.repo_id, public.forge_acting_identity(new.repo_id),
			noun || case when new.state = 'closed' then '.closed' else '.reopened' end,
			jsonb_build_object('number', new.number, 'title', new.title));
	end if;
	return null;
end
$$;

create trigger forge_issues_event after insert or update of state on public.forge_issues
	for each row execute function public.forge_on_issue();

create function public.forge_on_comment() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
	perform public.forge_emit(new.repo_id, new.author_identity_id, 'comment.created',
		jsonb_build_object('number', (select number from public.forge_issues where id = new.issue_id),
		                   'path', new.path, 'line', new.line));
	return null;
end
$$;

create trigger forge_comments_event after insert on public.forge_comments
	for each row execute function public.forge_on_comment();

create function public.forge_on_review() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
	perform public.forge_emit(new.repo_id, new.author_identity_id, 'review.' || new.state,
		jsonb_build_object('number', (select number from public.forge_issues where id = new.issue_id)));
	return null;
end
$$;

create trigger forge_reviews_event after insert on public.forge_reviews
	for each row execute function public.forge_on_review();

create function public.forge_on_collaborator() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
	if tg_op = 'INSERT' then
		perform public.forge_emit(new.repo_id, new.identity_id, 'collaborator.added',
			jsonb_build_object('grantee', new.grantee_identity_id, 'role', new.role));
	elsif new.revoked_at is not null and old.revoked_at is null then
		perform public.forge_emit(new.repo_id, new.identity_id, 'collaborator.revoked',
			jsonb_build_object('grantee', new.grantee_identity_id));
	end if;
	return null;
end
$$;

create trigger forge_collaborators_event after insert or update on public.forge_collaborators
	for each row execute function public.forge_on_collaborator();

--------------------------------------------------------------------------------
-- Row-level security
--------------------------------------------------------------------------------

do $$
declare t text;
begin
	foreach t in array array['forge_repos', 'forge_collaborators', 'forge_tokens', 'forge_refs',
		'forge_pushes', 'forge_commits', 'forge_issues', 'forge_pulls', 'forge_reviews',
		'forge_comments', 'forge_labels', 'forge_issue_labels', 'forge_events', 'forge_webhooks',
		'forge_webhook_deliveries', 'forge_releases', 'forge_release_assets', 'forge_lfs_objects']
	loop
		execute format('alter table public.%I enable row level security', t);
	end loop;
end
$$;

-- Repositories. The owner clause reads the row's own column rather than
-- going through forge_repo_role, because a row inserted by the statement
-- being checked (INSERT ... RETURNING) is not yet visible to a subquery.
create policy forge_repos_select on public.forge_repos
	for select using (public.forge_owner_sees(identity_id) or public.forge_can_read(id));
create policy forge_repos_insert on public.forge_repos
	for insert with check (public.forge_can_act(identity_id));
create policy forge_repos_update on public.forge_repos
	for update using (public.forge_can_admin(id))
	with check (public.forge_can_act(identity_id));
create policy forge_repos_delete on public.forge_repos
	for delete using (public.forge_can_admin(id) and public.forge_can_act(identity_id));

-- Collaborators: the owner side manages; the grantee sees its own grants.
create policy forge_collaborators_select on public.forge_collaborators
	for select using (public.forge_owner_sees(identity_id)
	                  or public.forge_owner_sees(grantee_identity_id));
create policy forge_collaborators_insert on public.forge_collaborators
	for insert with check (public.forge_can_act(identity_id));
create policy forge_collaborators_update on public.forge_collaborators
	for update using (public.forge_can_act(identity_id))
	with check (public.forge_can_act(identity_id));

-- Tokens: the owning identity only, and never from a token session (forge_pat
-- has no grant on this table at all).
create policy forge_tokens_select on public.forge_tokens
	for select using (public.can_access_identity(identity_id));
create policy forge_tokens_insert on public.forge_tokens
	for insert with check (public.can_access_identity(identity_id));
create policy forge_tokens_update on public.forge_tokens
	for update using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));

-- Read-only mirrors of the disk, written by forge_record_push.
create policy forge_refs_select on public.forge_refs for select using (public.forge_can_read(repo_id));
create policy forge_pushes_select on public.forge_pushes for select using (public.forge_can_read(repo_id));
create policy forge_commits_select on public.forge_commits for select using (public.forge_can_read(repo_id));
create policy forge_events_select on public.forge_events for select using (public.forge_can_read(repo_id));

-- Issues: anyone who can read may open one, as the identity they act as.
-- The author edits their own; writers edit any.
create policy forge_issues_select on public.forge_issues
	for select using (public.forge_can_read(repo_id));
create policy forge_issues_insert on public.forge_issues
	for insert with check (public.forge_can_read(repo_id) and public.forge_can_act(author_identity_id)
	                       and (not is_pull or public.forge_can_write(repo_id)));
create policy forge_issues_update on public.forge_issues
	for update using (public.forge_can_write(repo_id)
	                  or (public.forge_can_read(repo_id) and public.forge_can_act(author_identity_id)));

-- Pull requests: opened by writers (the branch has to be in the repository);
-- the merge columns are written only by forge_record_merge.
create policy forge_pulls_select on public.forge_pulls
	for select using (public.forge_can_read(repo_id));
create policy forge_pulls_insert on public.forge_pulls
	for insert with check (public.forge_can_write(repo_id) and merged_at is null and merged_sha is null);

create policy forge_reviews_select on public.forge_reviews
	for select using (public.forge_can_read(repo_id));
create policy forge_reviews_insert on public.forge_reviews
	for insert with check (public.forge_can_read(repo_id) and public.forge_can_act(author_identity_id));

create policy forge_comments_select on public.forge_comments
	for select using (public.forge_can_read(repo_id));
create policy forge_comments_insert on public.forge_comments
	for insert with check (public.forge_can_read(repo_id) and public.forge_can_act(author_identity_id));
create policy forge_comments_update on public.forge_comments
	for update using (public.forge_can_act(author_identity_id));
create policy forge_comments_delete on public.forge_comments
	for delete using (public.forge_can_act(author_identity_id) or public.forge_can_admin(repo_id));

create policy forge_labels_select on public.forge_labels
	for select using (public.forge_can_read(repo_id));
create policy forge_labels_write on public.forge_labels
	for all using (public.forge_can_write(repo_id)) with check (public.forge_can_write(repo_id));

create policy forge_issue_labels_select on public.forge_issue_labels
	for select using (public.forge_can_read(repo_id));
create policy forge_issue_labels_write on public.forge_issue_labels
	for all using (public.forge_can_write(repo_id)) with check (public.forge_can_write(repo_id));

create policy forge_webhooks_admin on public.forge_webhooks
	for all using (public.forge_can_admin(repo_id)) with check (public.forge_can_admin(repo_id));
create policy forge_webhook_deliveries_select on public.forge_webhook_deliveries
	for select using (public.forge_can_admin(repo_id));

create policy forge_releases_select on public.forge_releases
	for select using (public.forge_can_read(repo_id));
create policy forge_releases_insert on public.forge_releases
	for insert with check (public.forge_can_write(repo_id) and public.forge_can_act(author_identity_id));
create policy forge_releases_delete on public.forge_releases
	for delete using (public.forge_can_write(repo_id));

create policy forge_release_assets_select on public.forge_release_assets
	for select using (public.forge_can_read(repo_id));
create policy forge_release_assets_write on public.forge_release_assets
	for all using (public.forge_can_write(repo_id)) with check (public.forge_can_write(repo_id));

create policy forge_lfs_objects_select on public.forge_lfs_objects
	for select using (public.forge_can_read(repo_id));
create policy forge_lfs_objects_insert on public.forge_lfs_objects
	for insert with check (public.forge_can_write(repo_id));

--------------------------------------------------------------------------------
-- Views the interface reads (owner handles resolved, access filtered)
--------------------------------------------------------------------------------

-- These run with the view owner's rights so they can show the owning
-- identity's handle, which identities' own RLS hides from other accounts.
-- Each one filters on forge_can_read, so they show exactly the rows the
-- tables would.
create view public.forge_repo_list with (security_barrier) as
select r.id, r.identity_id, i.handle as owner_handle, i.display_name as owner_name,
       i.color as owner_color, r.name, r.description, r.visibility, r.default_branch,
       r.created_at, r.updated_at, r.pushed_at, r.archived_at,
       public.forge_repo_role(r.id) as role,
       (select count(*) from public.forge_issues x where x.repo_id = r.id and x.state = 'open' and not x.is_pull)::int as open_issues,
       (select count(*) from public.forge_issues x where x.repo_id = r.id and x.state = 'open' and x.is_pull)::int as open_pulls
from public.forge_repos r
join public.identities i on i.id = r.identity_id
where public.forge_can_read(r.id);

create view public.forge_issue_list with (security_barrier) as
select x.id, x.repo_id, x.identity_id, x.number, x.title, x.body, x.state, x.is_pull,
       x.created_at, x.updated_at, x.closed_at, x.author_identity_id,
       a.handle as author_handle, a.display_name as author_name, a.color as author_color,
       p.head_ref, p.base_ref, p.head_sha, p.base_sha, p.merge_method, p.merged_sha, p.merged_at,
       (select count(*) from public.forge_comments c where c.issue_id = x.id)::int as comment_count,
       coalesce((select array_agg(l.name order by l.name) from public.forge_issue_labels il
                 join public.forge_labels l on l.id = il.label_id where il.issue_id = x.id), '{}') as labels
from public.forge_issues x
left join public.identities a on a.id = x.author_identity_id
left join public.forge_pulls p on p.issue_id = x.id
where public.forge_can_read(x.repo_id);

create view public.forge_comment_list with (security_barrier) as
select c.id, c.repo_id, c.issue_id, c.review_id, c.body, c.path, c.line, c.created_at,
       c.author_identity_id, a.handle as author_handle, a.display_name as author_name,
       a.color as author_color
from public.forge_comments c
left join public.identities a on a.id = c.author_identity_id
where public.forge_can_read(c.repo_id);

create view public.forge_event_list with (security_barrier) as
select e.id, e.repo_id, r.name as repo_name, o.handle as owner_handle, e.kind, e.payload,
       e.created_at, e.actor_identity_id, a.handle as actor_handle, a.color as actor_color
from public.forge_events e
join public.forge_repos r on r.id = e.repo_id
join public.identities o on o.id = r.identity_id
left join public.identities a on a.id = e.actor_identity_id
where public.forge_can_read(e.repo_id);

create view public.forge_collaborator_list with (security_barrier) as
select c.id, c.repo_id, c.role, c.created_at, c.revoked_at, c.grantee_identity_id,
       g.handle as grantee_handle, g.display_name as grantee_name, g.color as grantee_color
from public.forge_collaborators c
join public.identities g on g.id = c.grantee_identity_id
where public.forge_owner_sees(c.identity_id) or public.forge_owner_sees(c.grantee_identity_id);

--------------------------------------------------------------------------------
-- Functions the server and the clients call
--------------------------------------------------------------------------------

-- Resolve `<handle>/<repo>` for this session. No row when the session may not
-- read it, which the server turns into 404 (or 401 for an anonymous caller,
-- so git asks for credentials).
create function public.forge_resolve(owner_handle text, repo_name text)
returns table (repo_id uuid, identity_id uuid, handle text, name text, visibility text,
               default_branch text, role text, acting_identity uuid, archived boolean)
language sql stable security definer
set search_path = ''
as $$
	select r.id, r.identity_id, i.handle, r.name, r.visibility, r.default_branch,
	       public.forge_repo_role(r.id), public.forge_acting_identity(r.id), r.archived_at is not null
	from public.forge_repos r
	join public.identities i on i.id = r.identity_id
	where i.handle = lower(owner_handle) and lower(r.name) = lower(repo_name)
	  and i.archived_at is null
	  and public.forge_repo_role(r.id) is not null
$$;

-- An identity's public card: handle, display name and colour, and nothing
-- that would link it to the account's other identities.
create function public.forge_identity_card(who text)
returns table (id uuid, handle text, display_name text, color text)
language sql stable security definer
set search_path = ''
as $$
	select i.id, i.handle, i.display_name, i.color from public.identities i
	where (i.handle = lower(who) or i.id::text = who) and i.archived_at is null
$$;

-- The identities this session can act as (the switcher).
create function public.forge_my_identities()
returns table (id uuid, handle text, display_name text, color text, kind text)
language sql stable security definer
set search_path = ''
as $$
	select i.id, i.handle, i.display_name, i.color, i.kind from public.identities i
	where public.can_access_identity(i.id)
	order by i.created_at
$$;

-- Create a personal access token for an identity this session can act as.
-- Returns the plaintext once.
create function public.forge_token_create(target uuid, token_name text, token_scope text default 'read',
                                          expires_in_days integer default null)
returns jsonb
language plpgsql volatile
set search_path = ''
as $$
declare
	plain text := 'palmforge_' || encode(extensions.gen_random_bytes(20), 'hex');
	t     public.forge_tokens;
begin
	insert into public.forge_tokens (identity_id, name, token_hash, prefix, scope, expires_at)
	values (target, btrim(token_name), encode(extensions.digest(plain, 'sha256'), 'hex'),
	        left(plain, 16), token_scope,
	        case when expires_in_days is not null then now() + make_interval(days => expires_in_days) end)
	returning * into t;
	return jsonb_build_object('id', t.id, 'identity_id', t.identity_id, 'name', t.name,
		'scope', t.scope, 'prefix', t.prefix, 'expires_at', t.expires_at, 'token', plain);
end
$$;

create function public.forge_token_revoke(token uuid) returns boolean
language sql volatile
set search_path = ''
as $$
	update public.forge_tokens set revoked_at = coalesce(revoked_at, now())
	where id = token
	returning true
$$;

-- Turn a presented token into what the server needs to mint a forge_pat
-- session. Knowing the token is the credential, so this is callable without
-- a session; it reveals nothing for a wrong, revoked or expired token.
create function public.forge_token_resolve(presented text)
returns table (token_id uuid, identity_id uuid, owner uuid, scope text)
language plpgsql volatile security definer
set search_path = ''
as $$
begin
	return query
	update public.forge_tokens t set last_used_at = now()
	from public.identities i
	where t.token_hash = encode(extensions.digest(presented, 'sha256'), 'hex')
	  and t.revoked_at is null
	  and (t.expires_at is null or t.expires_at > now())
	  and i.id = t.identity_id and i.archived_at is null
	returning t.id, t.identity_id, i.owner, t.scope;
end
$$;

-- Record a push the server has just accepted. Called with the pusher's own
-- session, so the write check is the database's, not the server's word.
-- `commits` is a JSON array of {sha, author_name, author_email, authored_at,
-- summary}, newest first.
create function public.forge_record_push(repo uuid, ref text, old_sha text, new_sha text,
                                         commits jsonb default '[]')
returns uuid
language plpgsql volatile security definer
set search_path = ''
as $$
declare
	zero  text := repeat('0', 40);
	actor uuid := public.forge_acting_identity(repo);
	push  uuid;
	n     integer := coalesce(jsonb_array_length(commits), 0);
begin
	if not public.forge_can_write(repo) then
		raise exception 'no write access to this repository' using errcode = '42501';
	end if;

	if new_sha = zero then
		delete from public.forge_refs where repo_id = repo and name = ref;
	else
		insert into public.forge_refs (repo_id, name, sha) values (repo, ref, new_sha)
		on conflict (repo_id, name) do update set sha = excluded.sha, updated_at = now();
	end if;

	insert into public.forge_pushes (repo_id, pusher_identity_id, ref, old_sha, new_sha, commit_count)
	values (repo, actor, ref, old_sha, new_sha, n)
	returning id into push;

	insert into public.forge_commits (repo_id, sha, push_id, author_name, author_email, authored_at, summary)
	select repo, c ->> 'sha', push, coalesce(c ->> 'author_name', ''), coalesce(c ->> 'author_email', ''),
	       nullif(c ->> 'authored_at', '')::timestamptz, coalesce(c ->> 'summary', '')
	from jsonb_array_elements(coalesce(commits, '[]')) c
	on conflict (repo_id, sha) do nothing;

	update public.forge_repos set pushed_at = now() where id = repo;

	-- Open pull requests follow their head branch.
	if ref like 'refs/heads/%' then
		update public.forge_pulls p set head_sha = nullif(new_sha, zero)
		from public.forge_issues x
		where p.issue_id = x.id and x.state = 'open' and p.repo_id = repo
		  and p.head_ref = substr(ref, 12);
		update public.forge_pulls p set base_sha = nullif(new_sha, zero)
		from public.forge_issues x
		where p.issue_id = x.id and x.state = 'open' and p.repo_id = repo
		  and p.base_ref = substr(ref, 12);
	end if;

	perform public.forge_emit(repo, actor, 'push',
		jsonb_build_object('ref', ref, 'before', old_sha, 'after', new_sha, 'commits', n,
		                   'head', commits -> 0 -> 'summary'));
	return push;
end
$$;

-- Open a pull request: the issue and its forge_pulls row together, with the
-- shas taken from the mirrored refs.
create function public.forge_pull_open(repo uuid, title text, body text, head text, base text,
                                       author uuid default null)
returns jsonb
language plpgsql volatile
set search_path = ''
as $$
declare
	who uuid := coalesce(author, public.forge_acting_identity(repo));
	x   public.forge_issues;
	hs  text := (select sha from public.forge_refs where repo_id = repo and name = 'refs/heads/' || head);
	bs  text := (select sha from public.forge_refs where repo_id = repo and name = 'refs/heads/' || base);
begin
	if hs is null then
		raise exception 'no branch named %', head using errcode = 'P0002';
	end if;
	if bs is null then
		raise exception 'no branch named %', base using errcode = 'P0002';
	end if;
	insert into public.forge_issues (repo_id, author_identity_id, title, body, is_pull)
	values (repo, who, title, coalesce(body, ''), true)
	returning * into x;
	insert into public.forge_pulls (issue_id, repo_id, head_ref, base_ref, head_sha, base_sha)
	values (x.id, repo, head, base, hs, bs);
	return jsonb_build_object('id', x.id, 'number', x.number, 'head', head, 'base', base,
	                          'head_sha', hs, 'base_sha', bs);
end
$$;

-- Record a merge the server performed on disk. The server calls
-- forge_record_push for the base branch first.
create function public.forge_record_merge(repo uuid, num integer, method text, merged text)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
	actor uuid := public.forge_acting_identity(repo);
	x     public.forge_issues;
begin
	if not public.forge_can_write(repo) then
		raise exception 'no write access to this repository' using errcode = '42501';
	end if;
	select * into x from public.forge_issues where repo_id = repo and number = num and is_pull;
	if not found then
		raise exception 'no pull request #%', num using errcode = 'P0002';
	end if;
	if x.state <> 'open' then
		raise exception 'pull request #% is not open', num using errcode = '22023';
	end if;
	update public.forge_pulls set merge_method = method, merged_sha = merged, merged_at = now(),
	       merged_by_identity_id = actor
	where issue_id = x.id;
	update public.forge_issues set state = 'closed' where id = x.id;
	perform public.forge_emit(repo, actor, 'pull.merged',
		jsonb_build_object('number', num, 'method', method, 'sha', merged, 'title', x.title));
	return jsonb_build_object('number', num, 'method', method, 'sha', merged);
end
$$;

-- Grant by handle, for the interface and the CLI.
create function public.forge_grant(repo uuid, grantee_handle text, grant_role text)
returns uuid
language plpgsql volatile
set search_path = ''
as $$
declare
	g   uuid := (select c.id from public.forge_identity_card(grantee_handle) c limit 1);
	row uuid;
begin
	if g is null then
		raise exception 'no identity named %', grantee_handle using errcode = 'P0002';
	end if;
	update public.forge_collaborators set role = grant_role
	where repo_id = repo and grantee_identity_id = g and revoked_at is null
	returning id into row;
	if row is null then
		insert into public.forge_collaborators (repo_id, grantee_identity_id, role)
		values (repo, g, grant_role)
		returning id into row;
	end if;
	return row;
end
$$;

create function public.forge_revoke(repo uuid, grantee_handle text) returns boolean
language sql volatile
set search_path = ''
as $$
	update public.forge_collaborators set revoked_at = now()
	where repo_id = repo and revoked_at is null
	  and grantee_identity_id = (select c.id from public.forge_identity_card(grantee_handle) c limit 1)
	returning true
$$;

--------------------------------------------------------------------------------
-- Storage: release assets and LFS objects
--------------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('forge-releases', 'forge-releases', false), ('forge-lfs', 'forge-lfs', false)
on conflict (id) do nothing;

-- The repository an object belongs to: the first path segment.
create function public.forge_object_repo(object_name text) returns uuid
language sql immutable
as $$
	select case when split_part(object_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
	            then split_part(object_name, '/', 1)::uuid end
$$;

create policy forge_objects_select on storage.objects
	for select using (bucket_id in ('forge-releases', 'forge-lfs')
	                  and public.forge_can_read(public.forge_object_repo(name)));
create policy forge_objects_insert on storage.objects
	for insert with check (bucket_id in ('forge-releases', 'forge-lfs')
	                       and public.forge_can_write(public.forge_object_repo(name)));
create policy forge_objects_update on storage.objects
	for update using (bucket_id in ('forge-releases', 'forge-lfs')
	                  and public.forge_can_write(public.forge_object_repo(name)));
create policy forge_objects_delete on storage.objects
	for delete using (bucket_id = 'forge-releases'
	                  and public.forge_can_write(public.forge_object_repo(name)));

--------------------------------------------------------------------------------
-- Grants
--------------------------------------------------------------------------------

-- Anonymous readers see public repositories and their issues, nothing else.
revoke all on public.forge_tokens, public.forge_webhooks, public.forge_webhook_deliveries,
              public.forge_collaborators from anon;

grant select on public.forge_repos, public.forge_refs, public.forge_pushes, public.forge_commits,
                public.forge_issues, public.forge_pulls, public.forge_reviews, public.forge_comments,
                public.forge_labels, public.forge_issue_labels, public.forge_events,
                public.forge_collaborators, public.forge_webhooks, public.forge_webhook_deliveries,
                public.forge_releases, public.forge_release_assets, public.forge_lfs_objects,
                public.forge_repo_list, public.forge_issue_list, public.forge_comment_list,
                public.forge_event_list, public.forge_collaborator_list
	to forge_pat;
grant insert, update on public.forge_repos, public.forge_issues, public.forge_comments,
                        public.forge_labels, public.forge_issue_labels
	to forge_pat;
grant insert on public.forge_pulls, public.forge_reviews, public.forge_releases,
                public.forge_release_assets, public.forge_lfs_objects
	to forge_pat;
grant delete on public.forge_comments, public.forge_labels, public.forge_issue_labels
	to forge_pat;

grant select on public.forge_repo_list, public.forge_issue_list, public.forge_comment_list,
                public.forge_event_list
	to anon, authenticated;
grant select on public.forge_collaborator_list to authenticated;

-- The token functions belong to a person's own session, not to a token.
revoke execute on function public.forge_token_create(uuid, text, text, integer) from public, anon, forge_pat;
revoke execute on function public.forge_token_revoke(uuid) from public, anon, forge_pat;
grant execute on function public.forge_token_create(uuid, text, text, integer) to authenticated;
grant execute on function public.forge_token_revoke(uuid) to authenticated;
revoke execute on function public.forge_grant(uuid, text, text) from public, anon, forge_pat;
revoke execute on function public.forge_revoke(uuid, text) from public, anon, forge_pat;
grant execute on function public.forge_grant(uuid, text, text) to authenticated;
grant execute on function public.forge_revoke(uuid, text) to authenticated;
revoke execute on function public.forge_record_push(uuid, text, text, text, jsonb) from public, anon;
revoke execute on function public.forge_record_merge(uuid, integer, text, text) from public, anon;
grant execute on function public.forge_record_push(uuid, text, text, text, jsonb) to authenticated, forge_pat;
grant execute on function public.forge_record_merge(uuid, integer, text, text) to authenticated, forge_pat;
