-- Scoped sessions: minting, the access token hook, revocation, and the
-- invariant that a scoped session never exists without its device row.
begin;
select plan(28);

insert into auth.users (id, email, aud, role) values
	('a0000000-0000-4000-8000-000000000001', 'alice@palm.test', 'authenticated', 'authenticated'),
	('b0000000-0000-4000-8000-000000000001', 'bob@palm.test', 'authenticated', 'authenticated');
insert into public.identities (id, owner, handle, display_name, kind) values
	('a1000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'alice', 'Alice', 'personal'),
	('a2000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'alice.work', 'Alice at work', 'work'),
	('b1000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-000000000001', 'bob', 'Bob', 'personal');
-- Alice's own laptop: an ordinary unscoped GoTrue session.
insert into auth.sessions (id, user_id, created_at, updated_at, aal, user_agent) values
	('5e550000-0000-4000-8000-0000000000aa', 'a0000000-0000-4000-8000-000000000001', now(), now(), 'aal1', 'laptop');

create temporary table minted (label text primary key, result jsonb) on commit drop;
grant all on minted to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"5e550000-0000-4000-8000-0000000000aa"}', true);

insert into minted values
	('work', public.mint_scoped_session('a2000000-0000-4000-8000-00000000000a', 'Work assistant', 'assistant')),
	('personal', public.mint_scoped_session('a1000000-0000-4000-8000-00000000000a', 'Phone', 'device', 3600));

select is(char_length((select result ->> 'refresh_token' from minted where label = 'work')), 12,
          'mint returns a GoTrue-format refresh token');
select is((select result ->> 'identity_id' from minted where label = 'work'), 'a2000000-0000-4000-8000-00000000000a',
          'mint returns the identity it scoped to');
select isnt((select result ->> 'expires_at' from minted where label = 'personal'), null, 'an expiry can be set');
select throws_ok($$ select public.mint_scoped_session('b1000000-0000-4000-8000-00000000000b', 'theft') $$,
                 '42501', null, 'alice cannot mint a session for bob''s identity');
select throws_ok($$ select public.mint_scoped_session('a2000000-0000-4000-8000-00000000000a', 'brief', 'device', 5) $$,
                 '22023', null, 'a scoped session lasts at least a minute');
select is((select count(*)::int from public.list_sessions()), 3, 'unscoped: list_sessions shows every session');
select is((select count(*)::int from public.list_sessions() where current), 1, 'list_sessions marks the current one');

reset role;
select is((select user_id from auth.sessions where id = (select (result ->> 'session_id')::uuid from minted where label = 'work')),
          'a0000000-0000-4000-8000-000000000001'::uuid, 'the minted session belongs to alice');
select is((select session_id from auth.refresh_tokens where token = (select result ->> 'refresh_token' from minted where label = 'work')),
          (select (result ->> 'session_id')::uuid from minted where label = 'work'), 'its refresh token belongs to that session');

-- The hook, called the way GoTrue calls it (it is security definer, so the
-- caller's role does not change what it sees).
select is(public.custom_access_token_hook(jsonb_build_object('claims', jsonb_build_object(
	'sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated',
	'session_id', (select result ->> 'session_id' from minted where label = 'work')))) -> 'claims' ->> 'palm_identity',
	'a2000000-0000-4000-8000-00000000000a', 'hook: a device session gets palm_identity');
select is(public.custom_access_token_hook('{"claims":{"sub":"a0000000-0000-4000-8000-000000000001","session_id":"5e550000-0000-4000-8000-0000000000aa"}}')
          -> 'claims' ->> 'palm_identity', null, 'hook: an ordinary session gets no claim');
select is(public.custom_access_token_hook('{"claims":{"sub":"a0000000-0000-4000-8000-000000000001","session_id":"5e550000-0000-4000-8000-0000000000aa","palm_identity":"b1000000-0000-4000-8000-00000000000b"}}')
          -> 'claims' ->> 'palm_identity', null, 'hook: a claim that did not come from a device row is stripped');
select is(public.custom_access_token_hook('{"claims":{"sub":"x","role":"authenticated","aud":"authenticated"}}') -> 'claims' ->> 'aud',
          'authenticated', 'hook: other claims pass through');
select ok(has_function_privilege('supabase_auth_admin', 'public.custom_access_token_hook(jsonb)', 'execute'),
          'GoTrue''s role may call the hook');
select ok(not has_function_privilege('authenticated', 'public.custom_access_token_hook(jsonb)', 'execute'),
          'the hook is not callable through the API');

-- The scoped work session.
set local role authenticated;
select set_config('request.jwt.claims', jsonb_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated',
	'session_id', (select result ->> 'session_id' from minted where label = 'work'),
	'palm_identity', 'a2000000-0000-4000-8000-00000000000a')::text, true);

select is((select count(*)::int from public.list_sessions()), 1, 'scoped: list_sessions shows only itself');
select is((select array_agg(name) from public.devices), array['Work assistant'], 'scoped: sees only its own identity''s devices');
select throws_ok(format('select public.revoke_device(%L)', (select result ->> 'device_id' from minted where label = 'personal')),
                 '42501', null, 'scoped: cannot revoke a device of another identity');
select throws_ok($$ select public.end_session('5e550000-0000-4000-8000-0000000000aa') $$,
                 '42501', null, 'scoped: cannot end the person''s laptop session');
select is((public.whoami() -> 'device' ->> 'kind'), 'assistant', 'whoami: names the device');

-- Revocation, by the person.
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"5e550000-0000-4000-8000-0000000000aa"}', true);
select isnt((public.revoke_device((select (result ->> 'device_id')::uuid from minted where label = 'work'))).revoked_at, null,
            'revoke_device marks the device revoked');
reset role;
select ok(not exists (select 1 from auth.sessions where id = (select (result ->> 'session_id')::uuid from minted where label = 'work')),
          'revoking deletes the GoTrue session, and with it the refresh token');
select throws_ok(format($$ select set_config('request.jwt.claims', %L, true); select public.palm_pre_request() $$,
                        jsonb_build_object('sub', 'a0000000-0000-4000-8000-000000000001',
                                           'session_id', (select result ->> 'session_id' from minted where label = 'work'))::text),
                 'PT401', null, 'pre-request refuses a token whose session has ended');
select lives_ok($$ select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","session_id":"5e550000-0000-4000-8000-0000000000aa"}', true);
                   select public.palm_pre_request() $$, 'pre-request admits a live session');

-- The invariant: a device row cannot vanish and leave its session unscoped.
delete from public.devices where id = (select (result ->> 'device_id')::uuid from minted where label = 'personal');
select ok(not exists (select 1 from auth.sessions where id = (select (result ->> 'session_id')::uuid from minted where label = 'personal')),
          'deleting a device row deletes its session');
select throws_ok(format('update public.devices set identity_id = %L where id = %L', 'a1000000-0000-4000-8000-00000000000a',
                        (select result ->> 'device_id' from minted where label = 'work')),
                 '42501', null, 'a device''s identity cannot be changed');

-- Archiving an identity ends its sessions.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","session_id":"5e550000-0000-4000-8000-0000000000aa"}', true);
insert into minted values ('again', public.mint_scoped_session('a2000000-0000-4000-8000-00000000000a', 'Tablet'));
select public.archive_identity('a2000000-0000-4000-8000-00000000000a');
reset role;
select ok(not exists (select 1 from auth.sessions where id = (select (result ->> 'session_id')::uuid from minted where label = 'again')),
          'archiving an identity ends the sessions scoped to it');
set local role authenticated;
select throws_ok($$ select public.mint_scoped_session('a2000000-0000-4000-8000-00000000000a', 'late') $$,
                 '42501', null, 'no session can be minted for an archived identity');

select * from finish();
rollback;
