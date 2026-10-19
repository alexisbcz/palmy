-- The contract's core claim, for the accounts tables: a session scoped to
-- identity A, asking for identity B's rows, gets nothing, and writing them
-- fails. Across identities of one person and across people.
begin;
select plan(34);

-- Two people. Alice has a personal and a work identity; Bob has one.
insert into auth.users (id, email, aud, role) values
	('a0000000-0000-4000-8000-000000000001', 'alice@palm.test', 'authenticated', 'authenticated'),
	('b0000000-0000-4000-8000-000000000001', 'bob@palm.test', 'authenticated', 'authenticated');
insert into public.identities (id, owner, handle, display_name, kind, color) values
	('a1000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'alice', 'Alice', 'personal', 'emerald'),
	('a2000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'alice.work', 'Alice at work', 'work', 'sky'),
	('b1000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-000000000001', 'bob', 'Bob', 'personal', 'rose');
update public.profiles set bio = 'personal bio' where identity_id = 'a1000000-0000-4000-8000-00000000000a';

select is((select count(*)::int from public.profiles
           where identity_id in ('a1000000-0000-4000-8000-00000000000a', 'a2000000-0000-4000-8000-00000000000a',
                                 'b1000000-0000-4000-8000-00000000000b')),
          3, 'every identity is born with a profile');

-- Alice, unscoped: her whole account.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);

select is((select count(*)::int from public.identities), 2, 'unscoped: alice sees both her identities');
select is((select count(*)::int from public.profiles), 2, 'unscoped: alice sees both her profiles');
select ok(not exists (select 1 from public.identities where owner <> auth.uid()), 'unscoped: alice sees none of bob''s identities');
select is((public.whoami() ->> 'scoped')::boolean, false, 'whoami: unscoped');

-- Alice, scoped to work.
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","palm_identity":"a2000000-0000-4000-8000-00000000000a"}', true);

select is((select array_agg(handle) from public.identities), array['alice.work'], 'scoped to work: sees only the work identity');
select is((select count(*)::int from public.profiles), 1, 'scoped to work: sees only the work profile');
select is((select count(*)::int from public.profiles where identity_id = 'a1000000-0000-4000-8000-00000000000a'), 0,
          'scoped to work: asking for the personal profile by id gets nothing');
select ok(public.can_access_identity('a2000000-0000-4000-8000-00000000000a'), 'scoped to work: can_access_identity(work)');
select ok(not public.can_access_identity('a1000000-0000-4000-8000-00000000000a'), 'scoped to work: not can_access_identity(personal)');

with u as (update public.profiles set bio = 'overwritten'
                      where identity_id = 'a1000000-0000-4000-8000-00000000000a' returning 1)
select is(count(*)::int, 0, 'scoped to work: updating the personal profile touches nothing') from u;
select throws_ok($$ insert into public.profiles (identity_id) values ('a1000000-0000-4000-8000-00000000000a') $$,
                 '42501', null, 'scoped to work: inserting a personal profile fails');
select throws_ok($$ insert into public.devices (identity_id, name) values ('a1000000-0000-4000-8000-00000000000a', 'x') $$,
                 '42501', null, 'scoped to work: inserting a personal device fails');
select throws_ok($$ insert into public.devices (identity_id, name) values ('a2000000-0000-4000-8000-00000000000a', 'x') $$,
                 '42501', null, 'devices are only created by mint_scoped_session, even in scope');
with u as (update public.identities set display_name = 'Renamed' returning 1)
select is(count(*)::int, 0, 'scoped to work: cannot rename any identity, not even its own') from u;
select throws_ok($$ select public.create_identity('alice.side', 'Side') $$,
                 '42501', null, 'scoped to work: cannot create an identity');
select throws_ok($$ select public.mint_scoped_session('a1000000-0000-4000-8000-00000000000a', 'escape') $$,
                 '42501', null, 'scoped to work: cannot mint a session for personal');
select throws_ok($$ select public.mint_scoped_session('a2000000-0000-4000-8000-00000000000a', 'copy') $$,
                 '42501', null, 'scoped to work: cannot mint even for work (only the person delegates)');
with u as (update public.profiles set bio = 'work bio'
                      where identity_id = 'a2000000-0000-4000-8000-00000000000a' returning 1)
select is(count(*)::int, 1, 'scoped to work: writes its own profile') from u;
select is(public.whoami() -> 'identity' ->> 'handle', 'alice.work', 'whoami: names the scope');

-- Bob, unscoped, and Bob holding a forged scope naming Alice's identity.
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is((select array_agg(handle) from public.identities), array['bob'], 'bob sees only his identity');
with u as (update public.profiles set bio = 'bob was here'
                      where identity_id = 'a2000000-0000-4000-8000-00000000000a' returning 1)
select is(count(*)::int, 0, 'bob cannot update alice''s profile') from u;
select throws_ok($$ insert into public.identities (owner, handle, display_name)
                    values ('a0000000-0000-4000-8000-000000000001', 'alice.fake', 'Fake') $$,
                 '42501', null, 'bob cannot create an identity owned by alice');
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated","palm_identity":"a2000000-0000-4000-8000-00000000000a"}', true);
select is((select count(*)::int from public.profiles), 0, 'bob scoped to alice''s identity sees nothing');
select ok(not public.can_access_identity('a2000000-0000-4000-8000-00000000000a'), 'a scope claim does not grant ownership');

-- Anonymous.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select is((select count(*)::int from public.identities), 0, 'anon sees no identities');

-- Lifecycle rules.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select throws_ok($$ update public.identities set handle = 'alice2' where handle = 'alice' $$,
                 '42501', null, 'a handle is permanent');
select is((public.rename_identity('a1000000-0000-4000-8000-00000000000a', '  Alice B.  ')).display_name, 'Alice B.',
          'rename changes and trims the display name');
select throws_ok($$ select public.set_identity_color('a1000000-0000-4000-8000-00000000000a', 'chartreuse') $$,
                 '23514', null, 'colours come from the palette');
select throws_ok($$ select public.create_identity('postmaster', 'Mail') $$,
                 '23514', null, 'reserved handles are refused');
select is((public.create_identity('Alice.Side', 'Side project', 'project', 'amber')).handle, 'alice.side',
          'create_identity lower-cases the handle');

select isnt((public.archive_identity('a2000000-0000-4000-8000-00000000000a')).archived_at, null, 'archive sets archived_at');
select is((select count(*)::int from public.profiles where identity_id = 'a2000000-0000-4000-8000-00000000000a'), 0,
          'an archived identity''s data is unreachable, even unscoped');
select is((public.restore_identity('a2000000-0000-4000-8000-00000000000a')).archived_at, null, 'restore clears archived_at');

select * from finish();
rollback;
