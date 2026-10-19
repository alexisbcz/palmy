-- The forge's half of the contract test: a session scoped to identity A sees
-- none of identity B's private repositories, issues or tokens and cannot
-- write them; a collaborator grant gives exactly its role and revocation
-- takes it away; a public repository is readable anonymously; a personal
-- access token session is capped by its scope, confined to forge tables, and
-- dies with its token.
begin;
create extension if not exists pgtap with schema extensions;
select plan(66);

-- Two people. Alice has a personal and a work identity; Bob has one.
insert into auth.users (id, email) values
	('a0000000-0000-0000-0000-000000000001', 'alice@palm.test'),
	('b0000000-0000-0000-0000-000000000002', 'bob@palm.test');
insert into public.identities (id, owner, handle, display_name, kind) values
	('a1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'alice', 'Alice', 'personal'),
	('a2000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'alice-work', 'Alice at work', 'work'),
	('b1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'bob', 'Bob', 'personal');

-- Become a session: an authenticated person, optionally scoped to one identity.
create function pg_temp.become(uid text, ident text default null, role text default 'authenticated',
                               token text default null) returns void
language plpgsql as $$
begin
	perform set_config('request.jwt.claims', json_strip_nulls(json_build_object(
		'sub', uid, 'role', role, 'palm_identity', ident, 'forge_token', token))::text, true);
	execute format('set local role %I', role);
end
$$;
grant execute on function pg_temp.become(text, text, text, text) to public;

-- Alice (personal) creates a private and a public repository; Alice (work)
-- creates one shared with her other identities.
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
insert into public.forge_repos (id, identity_id, name, visibility) values
	('f0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'secret', 'private'),
	('f0000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'open', 'public');
insert into public.forge_issues (repo_id, author_identity_id, title)
values ('f0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'private bug'),
       ('f0000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'public bug');
select is((select forge_repo_role('f0000000-0000-0000-0000-000000000001')), 'admin', 'the owner is admin of her repository');
select lives_ok($$ insert into public.forge_repos (identity_id, name) values ('a1000000-0000-0000-0000-000000000001', 'scratch') returning id $$,
	'creating a repository can return the new row (as PostgREST asks)');
select is((select number from forge_issues where title = 'public bug'), 1, 'issues are numbered per repository');
select lives_ok($$ select forge_record_push('f0000000-0000-0000-0000-000000000001', 'refs/heads/main',
	repeat('0', 40), repeat('a', 40), '[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","summary":"first"}]') $$,
	'the owner records a push');
select is((select count(*)::int from forge_refs where repo_id = 'f0000000-0000-0000-0000-000000000001'), 1, 'the push mirrored the ref');
select is((select count(*)::int from forge_events where repo_id = 'f0000000-0000-0000-0000-000000000001' and kind = 'push'), 1, 'and wrote a push event');
create temp table tok on commit drop as
	select forge_token_create('a1000000-0000-0000-0000-000000000001', 'laptop', 'read') as t;
create temp table wtok on commit drop as
	select forge_token_create('a1000000-0000-0000-0000-000000000001', 'ci', 'write') as t;
grant select on tok, wtok to public;
select ok((select (t ->> 'token') like 'palmforge_%' from tok), 'a token is returned in plaintext once');
select is((select count(*)::int from forge_tokens where token_hash like 'palmforge_%'), 0, 'and only its hash is stored');
reset role;

select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002');
insert into public.forge_repos (id, identity_id, name, visibility) values
	('f0000000-0000-0000-0000-000000000003', 'a2000000-0000-0000-0000-000000000002', 'handbook', 'shared'),
	('f0000000-0000-0000-0000-000000000004', 'a2000000-0000-0000-0000-000000000002', 'payroll', 'private');

-- Scoped to work, Alice is a stranger to her personal identity's private rows.
select is((select count(*)::int from forge_repos where id = 'f0000000-0000-0000-0000-000000000001'), 0,
	'a session scoped to work does not see personal''s private repository');
select is((select count(*)::int from forge_issues where title = 'private bug'), 0, '... nor its issues');
select is((select count(*)::int from forge_tokens), 0, '... nor personal''s tokens');
select is((select count(*)::int from forge_repos where id = 'f0000000-0000-0000-0000-000000000002'), 1,
	'but does see the public one');
select throws_ok($$ insert into forge_repos (identity_id, name) values ('a1000000-0000-0000-0000-000000000001', 'sneaky') $$,
	'42501', null, 'and cannot create a repository for personal');
select throws_ok($$ insert into forge_issues (repo_id, author_identity_id, title)
	values ('f0000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'as personal') $$,
	'42501', null, 'nor open an issue signed as personal');
reset role;

-- Scoped to personal, the work identity's 'shared' repository is readable,
-- its private one is not, and neither is writable.
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select is((select forge_repo_role('f0000000-0000-0000-0000-000000000003')), 'read', 'a shared repository is readable by the other identities of its account');
select is((select forge_repo_role('f0000000-0000-0000-0000-000000000004')), null, 'a private one is not');
select throws_ok($$ select forge_record_push('f0000000-0000-0000-0000-000000000003', 'refs/heads/main', repeat('0', 40), repeat('b', 40)) $$,
	'42501', null, 'and a shared repository is not writable from the sibling identity');
reset role;

-- Bob: another person entirely.
select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from forge_repos where id = 'f0000000-0000-0000-0000-000000000001'), 0, 'Bob does not see Alice''s private repository');
select is((select count(*)::int from forge_repos where id = 'f0000000-0000-0000-0000-000000000003'), 0, '... nor her shared one');
select is((select count(*)::int from forge_repo_list where name = 'secret'), 0, '... nor through the list view');
select is((select count(*)::int from forge_resolve('alice', 'secret')), 0, '... nor by resolving its path');
select is((select count(*)::int from forge_issues where title = 'private bug'), 0, '... nor its issues');
select is((select count(*)::int from forge_refs where repo_id = 'f0000000-0000-0000-0000-000000000001'), 0, '... nor its refs');
select is((select count(*)::int from forge_events where repo_id = 'f0000000-0000-0000-0000-000000000001'), 0, '... nor its activity');
select is((select count(*)::int from forge_tokens), 0, '... nor any of her tokens');
select throws_ok($$ insert into forge_issues (repo_id, author_identity_id, title)
	values ('f0000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'hi') $$,
	'42501', null, 'Bob cannot open an issue on it');
select throws_ok($$ select forge_record_push('f0000000-0000-0000-0000-000000000001', 'refs/heads/main', repeat('a', 40), repeat('b', 40)) $$,
	'42501', null, 'nor push to it');
select throws_ok($$ insert into forge_collaborators (repo_id, grantee_identity_id, role)
	values ('f0000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'admin') $$,
	'42501', null, 'nor grant himself access');
update forge_repos set visibility = 'public' where id = 'f0000000-0000-0000-0000-000000000001';
reset role;
select is((select visibility from forge_repos where id = 'f0000000-0000-0000-0000-000000000001'), 'private', 'nor make it public');

-- On the public repository Bob can read and open issues as himself, but not
-- as Alice, and cannot push.
select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001');
select is((select forge_repo_role('f0000000-0000-0000-0000-000000000002')), 'read', 'Bob reads the public repository');
select lives_ok($$ insert into forge_issues (repo_id, author_identity_id, title)
	values ('f0000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', 'from bob') $$,
	'and opens an issue on it as himself');
select throws_ok($$ insert into forge_issues (repo_id, author_identity_id, title)
	values ('f0000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'forged') $$,
	'42501', null, 'but not signed as Alice');
select throws_ok($$ select forge_record_push('f0000000-0000-0000-0000-000000000002', 'refs/heads/main', repeat('0', 40), repeat('b', 40)) $$,
	'42501', null, 'and cannot push to it');
reset role;

-- Alice grants Bob write on the private repository.
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select lives_ok($$ select forge_grant('f0000000-0000-0000-0000-000000000001', 'bob', 'write') $$, 'Alice grants Bob write');
reset role;

select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001');
select is((select forge_repo_role('f0000000-0000-0000-0000-000000000001')), 'write', 'the grant gives Bob exactly write');
select is((select count(*)::int from forge_issues where title = 'private bug'), 1, 'Bob now reads its issues');
select lives_ok($$ select forge_record_push('f0000000-0000-0000-0000-000000000001', 'refs/heads/feature', repeat('0', 40), repeat('c', 40)) $$,
	'Bob can push');
select is((select pusher_identity_id from forge_pushes where ref = 'refs/heads/feature'),
	'b1000000-0000-0000-0000-000000000001'::uuid, 'and the push is recorded as his');
select is((select count(*)::int from forge_tokens), 0, 'a grant on a repository says nothing about Alice''s tokens');
select is((select count(*)::int from forge_webhooks), 0, 'nor about its webhooks, which are admin-only');
update forge_repos set description = 'mine now' where id = 'f0000000-0000-0000-0000-000000000001';
select throws_ok($$ select forge_grant('f0000000-0000-0000-0000-000000000001', 'alice-work', 'read') $$,
	'42501', null, 'a writer cannot grant others');
reset role;
select is((select description from forge_repos where id = 'f0000000-0000-0000-0000-000000000001'), '', 'and cannot change the repository''s settings');

-- Downgraded to read, then revoked.
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select forge_grant('f0000000-0000-0000-0000-000000000001', 'bob', 'read');
reset role;
select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001');
select is((select forge_repo_role('f0000000-0000-0000-0000-000000000001')), 'read', 'a read grant gives exactly read');
select throws_ok($$ select forge_record_push('f0000000-0000-0000-0000-000000000001', 'refs/heads/feature', repeat('c', 40), repeat('d', 40)) $$,
	'42501', null, 'so Bob can no longer push');
reset role;
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select ok((select forge_revoke('f0000000-0000-0000-0000-000000000001', 'bob')), 'Alice revokes the grant');
reset role;
select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from forge_repos where id = 'f0000000-0000-0000-0000-000000000001'), 0, 'after revocation Bob sees nothing again');
reset role;

-- Anonymous.
select pg_temp.become(null, null, 'anon');
select is((select count(*)::int from forge_repo_list where id::text like 'f0000000-%'), 1, 'anonymously, only the public repository is listed');
select is((select count(*)::int from forge_issues where repo_id = 'f0000000-0000-0000-0000-000000000002'), 2, 'and its issues are readable');
select throws_ok($$ insert into forge_issues (repo_id, author_identity_id, title)
	values ('f0000000-0000-0000-0000-000000000002', null, 'anon') $$,
	'42501', null, 'an anonymous caller cannot open an issue');
reset role;

-- A read token: Alice's personal identity, capped at read. (pgTAP lives in
-- `extensions`, which a token session has no use for outside this test.)
grant usage on schema extensions to forge_pat;
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'forge_pat',
	(select t ->> 'id' from tok));
select is((select forge_repo_role('f0000000-0000-0000-0000-000000000001')), 'read', 'a read token is capped at read on the owner''s own repository');
select throws_ok($$ select forge_record_push('f0000000-0000-0000-0000-000000000001', 'refs/heads/main', repeat('a', 40), repeat('e', 40)) $$,
	'42501', null, 'and cannot push');
select throws_ok($$ select count(*) from public.identities $$, '42501', null,
	'a token session has no grant outside the forge tables');
select throws_ok($$ select count(*) from public.forge_tokens $$, '42501', null,
	'not even on the token table');
reset role;

-- A write token pushes; revoking it ends the session at once.
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'forge_pat',
	(select t ->> 'id' from wtok));
select lives_ok($$ select forge_record_push('f0000000-0000-0000-0000-000000000001', 'refs/heads/main', repeat('a', 40), repeat('e', 40)) $$,
	'a write token pushes');
reset role;
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select ok((select forge_token_revoke((select (t ->> 'id')::uuid from wtok))), 'Alice revokes the write token');
reset role;
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'forge_pat',
	(select t ->> 'id' from wtok));
select is((select count(*)::int from forge_repos), 0, 'a revoked token''s session sees nothing, not even public repositories');
reset role;

-- Release assets and LFS objects in Storage follow the repository: the
-- first path segment is the repository id.
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select lives_ok($$ insert into storage.objects (bucket_id, name) values
	('forge-releases', 'f0000000-0000-0000-0000-000000000001/v1/notes.tar'),
	('forge-releases', 'f0000000-0000-0000-0000-000000000002/v1/site.zip') $$,
	'the owner stores release assets for her repositories');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('forge-releases', 'releases/loose.tar') $$,
	'42501', null, 'an object outside any repository folder is refused');
-- A webhook is disabled by default and never sent: an event records a
-- delivery that says so.
insert into public.forge_webhooks (repo_id, url) values ('f0000000-0000-0000-0000-000000000001', 'https://example.invalid/hook');
insert into public.forge_issues (repo_id, author_identity_id, title)
values ('f0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'with a hook');
select is((select status from forge_webhook_deliveries limit 1), 'disabled', 'a matching event records a disabled delivery, nothing is sent');
reset role;

select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from storage.objects where bucket_id = 'forge-releases' and name like 'f0000000-0000-0000-0000-000000000001/%'), 0,
	'Bob cannot see the private repository''s assets');
select is((select count(*)::int from storage.objects where bucket_id = 'forge-releases' and name like 'f0000000-0000-0000-0000-000000000002/%'), 1,
	'but sees the public one''s');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('forge-releases', 'f0000000-0000-0000-0000-000000000002/v2/evil.zip') $$,
	'42501', null, 'and cannot upload to a repository he can only read');
select is((select count(*)::int from forge_webhooks), 0, 'nor see its webhooks');
reset role;

select pg_temp.become(null, null, 'anon');
select is((select count(*)::int from storage.objects where bucket_id = 'forge-releases' and name like 'f0000000-%'), 1, 'anonymously, only the public repository''s assets are visible');
reset role;

-- A token presented for exchange.
select is((select count(*)::int from forge_token_resolve((select t ->> 'token' from tok))), 1, 'a live token resolves');
select is((select count(*)::int from forge_token_resolve((select t ->> 'token' from wtok))), 0, 'a revoked one does not');

select * from finish();
rollback;
