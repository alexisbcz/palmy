-- Notifications delivered once across devices (migrations/20261020300000).
--
-- The test the contract holds every area to: a session scoped to identity A
-- sees nothing of W (the same person's other identity) or B (someone else),
-- and cannot write theirs. Then "once": the first device to claim a key
-- shows it, the second does not; the device in use wins; a read on one
-- device is a read on the others; states only move forward.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(24);

insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000e1', 'alice-n@example.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-0000000000e2', 'bob-n@example.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000ea', 'a0000000-0000-4000-8000-0000000000e1', 'alice-n',      'Alice',     'personal'),
	('aaaaaaaa-0000-4000-8000-0000000000eb', 'a0000000-0000-4000-8000-0000000000e1', 'alice-n.work', 'Northwind', 'work'),
	('bbbbbbbb-0000-4000-8000-0000000000eb', 'b0000000-0000-4000-8000-0000000000e2', 'bob-n',        'Bob',       'personal');

-- Alice's laptop and phone, each holding a Northwind session; the laptop also
-- holds a Personal one. Bob's phone.
insert into public.devices (id, identity_id, name) values
	('dddddddd-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000eb', 'laptop'),
	('dddddddd-0000-4000-8000-0000000000e2', 'aaaaaaaa-0000-4000-8000-0000000000eb', 'phone'),
	('dddddddd-0000-4000-8000-0000000000e3', 'aaaaaaaa-0000-4000-8000-0000000000ea', 'laptop'),
	('dddddddd-0000-4000-8000-0000000000e4', 'bbbbbbbb-0000-4000-8000-0000000000eb', 'phone');

create function pg_temp.claims(sub text, ident text) returns void language sql as $$
	select set_config('request.jwt.claims',
		json_build_object('sub', sub, 'role', 'authenticated', 'palm_identity', nullif(ident, ''))::text, true)
$$;

set local role authenticated;

-- ---------------------------------------------------------------------------
-- Once, inside Northwind
-- ---------------------------------------------------------------------------
select pg_temp.claims('a0000000-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000eb');

select is(public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e1'),
	'yours', 'no device in use: the first device to claim shows it');
select is(public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e2'),
	'elsewhere', 'the second device does not interrupt');
select is(public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e1'),
	'elsewhere', 'nor does the first, a second time');

select is(public.notify_mark('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e2', 'read'),
	'read', 'read on the phone');
select is(public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e1'),
	'read', 'the laptop learns it was read');
select is(public.notify_mark('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e1', 'shown'),
	'read', 'a stale "shown" never un-reads it');
select is(public.notify_mark('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e1', 'withdrawn'),
	'withdrawn', 'withdrawn is further still');

-- The device in use wins.
select lives_ok($$ select public.notify_here('aaaaaaaa-0000-4000-8000-0000000000eb', 'dddddddd-0000-4000-8000-0000000000e2') $$,
	'the phone is being used');
select is(public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'call:7f3a', 'dddddddd-0000-4000-8000-0000000000e1'),
	'elsewhere', 'a call arriving on the laptop stays quiet there: the phone is in use');
select is(public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'call:7f3a', 'dddddddd-0000-4000-8000-0000000000e2'),
	'yours', 'and rings on the phone');
select lives_ok($$ select public.notify_here('aaaaaaaa-0000-4000-8000-0000000000eb', 'dddddddd-0000-4000-8000-0000000000e1') $$,
	'then the laptop is used');
select is(public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'event:standup', 'dddddddd-0000-4000-8000-0000000000e1'),
	'yours', 'the next one shows on the laptop');

select throws_ok($$ select public.notify_mark('aaaaaaaa-0000-4000-8000-0000000000eb', 'x', 'dddddddd-0000-4000-8000-0000000000e1', 'gone') $$,
	'22023', null, 'an unknown state is refused');
select throws_ok($$ select public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'x', 'dddddddd-0000-4000-8000-0000000000e3') $$,
	'42501', null, 'a device of another identity cannot claim for Northwind');

select is((select count(*) from public.notify_state), 3::bigint, 'Northwind sees its three keys');

-- ---------------------------------------------------------------------------
-- Scope: Personal sees nothing of Northwind, and cannot write it
-- ---------------------------------------------------------------------------
select pg_temp.claims('a0000000-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000ea');

select is((select count(*) from public.notify_state), 0::bigint, 'scoped to Personal: none of Northwind''s state');
select is((select count(*) from public.notify_presence), 0::bigint, 'scoped to Personal: none of Northwind''s presence');
select throws_ok($$ select public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e1') $$,
	'42501', null, 'scoped to Personal: claiming a Northwind key is refused');
select throws_ok($$ select public.notify_mark('aaaaaaaa-0000-4000-8000-0000000000eb', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e3', 'read') $$,
	'42501', null, 'scoped to Personal: marking a Northwind key is refused');
select throws_ok($$ insert into public.notify_state (identity_id, key, state) values ('aaaaaaaa-0000-4000-8000-0000000000eb', 'forged', 'read') $$,
	'42501', null, 'scoped to Personal: a direct insert into Northwind is refused');
select is(public.notify_claim('aaaaaaaa-0000-4000-8000-0000000000ea', 'mail:<q4@nw>', 'dddddddd-0000-4000-8000-0000000000e3'),
	'yours', 'the same key in Personal is a different notification');

-- ---------------------------------------------------------------------------
-- Someone else
-- ---------------------------------------------------------------------------
select pg_temp.claims('b0000000-0000-4000-8000-0000000000e2', 'bbbbbbbb-0000-4000-8000-0000000000eb');
select is((select count(*) from public.notify_state), 0::bigint, 'Bob sees none of Alice''s');
select throws_ok($$ select public.notify_here('aaaaaaaa-0000-4000-8000-0000000000eb', 'dddddddd-0000-4000-8000-0000000000e4') $$,
	'42501', null, 'Bob cannot say he is looking at Alice''s Northwind');

-- The unscoped session (Home, the person themself) sees every identity's.
select pg_temp.claims('a0000000-0000-4000-8000-0000000000e1', '');
select is((select count(*) from public.notify_state), 4::bigint, 'unscoped: all of Alice''s identities, none of Bob''s');

select * from finish();
rollback;
