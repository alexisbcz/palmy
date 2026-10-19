-- Carrying a note: an independent copy in another of your own identities,
-- and a row in both identities' carry logs. Only a session that can act in
-- both identities can do it; a scoped session cannot, by construction.
--
-- Identities: Alice's personal (A) and work (W), Bob's (B).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(33);

insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000d1', 'alice-k@example.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-0000000000d2', 'bob-k@example.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000da', 'a0000000-0000-4000-8000-0000000000d1', 'alice-k',      'Alice',        'personal'),
	('aaaaaaaa-0000-4000-8000-0000000000db', 'a0000000-0000-4000-8000-0000000000d1', 'alice-k.work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-4000-8000-0000000000db', 'b0000000-0000-4000-8000-0000000000d2', 'bob-k',        'Bob',          'personal');

create function pg_temp.as_user(sub text, ident text) returns void language sql as $$
	select set_config('request.jwt.claims',
		json_build_object('sub', sub, 'role', 'authenticated', 'palm_identity', nullif(ident, ''))::text, true)
$$;
create function pg_temp.as_server() returns void language sql as $$
	select set_config('request.jwt.claims', '{"role":"service_role"}', true)
$$;

set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000db');
select lives_ok($$select public.notes_create('d0000000-0000-4000-8000-0000000000a1',
	'aaaaaaaa-0000-4000-8000-0000000000db', 'Packing list', 'Travel')$$, 'W has a note');
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000d2', 'bbbbbbbb-0000-4000-8000-0000000000db');
select lives_ok($$select public.notes_create('d0000000-0000-4000-8000-0000000000b1',
	'bbbbbbbb-0000-4000-8000-0000000000db', 'Bob''s', '')$$, 'B has a note');
reset role;
set local role service_role;
select pg_temp.as_server();
select is(public.collab_append('d0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000db',
	'a0000000-0000-4000-8000-0000000000d1', 'a1', 'VQEA'), 1::bigint, 'with a revision');
reset role;

-- ---------------------------------------------------------------------------
-- Who cannot carry
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000db');
select throws_ok($$select public.notes_carry('d0000000-0000-4000-8000-0000000000a1', 'alice-k',
	'd0000000-0000-4000-8000-0000000000c1', repeat('ab', 32))$$, '42501', null,
	'a session scoped to W cannot carry into A: it cannot act there');
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000da');
select throws_ok($$select public.notes_carry('d0000000-0000-4000-8000-0000000000a1', 'alice-k',
	'd0000000-0000-4000-8000-0000000000c1', repeat('ab', 32))$$, '42501', null,
	'a session scoped to A cannot reach into W to take a copy');
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', '');
select throws_ok($$select public.notes_carry('d0000000-0000-4000-8000-0000000000a1', 'bob-k',
	'd0000000-0000-4000-8000-0000000000c1', repeat('ab', 32))$$, '42501', null,
	'carry goes between your own identities, never to someone else''s (that is a share)');
select throws_ok($$select public.notes_carry('d0000000-0000-4000-8000-0000000000a1', 'alice-k.work',
	'd0000000-0000-4000-8000-0000000000c1', repeat('ab', 32))$$, '22023', null,
	'carrying into the identity it is already in is refused');
select throws_ok($$select public.notes_carry('d0000000-0000-4000-8000-0000000000a1', 'alice-k',
	'd0000000-0000-4000-8000-0000000000c1', 'not-a-hash')$$, '22023', null,
	'the content hash must be a sha256');
select throws_ok($$select public.notes_carry('d0000000-0000-4000-8000-0000000000b1', 'alice-k',
	'd0000000-0000-4000-8000-0000000000c1', repeat('ab', 32))$$, '42501', null,
	'Alice cannot carry Bob''s note');

-- Bob, with the note shared to him, still cannot carry it into his identity.
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000db');
select is(public.notes_share('d0000000-0000-4000-8000-0000000000a1', 'bob-k', 'edit') ->> 'access', 'edit',
	'W shares the note with Bob');
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000d2', '');
select throws_ok($$select public.notes_carry('d0000000-0000-4000-8000-0000000000a1', 'bob-k',
	'd0000000-0000-4000-8000-0000000000c1', repeat('ab', 32))$$, '42501', null,
	'a grantee cannot carry a shared note out of its owner''s identity');

-- ---------------------------------------------------------------------------
-- The carry
-- ---------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', '');
select is(public.notes_carry('d0000000-0000-4000-8000-0000000000a1', 'alice-k',
	'd0000000-0000-4000-8000-0000000000c1', repeat('ab', 32), null, 412, 'laptop') -> 'to' ->> 'handle', 'alice-k',
	'unscoped Alice carries the note from W into A');
select is((select identity_id from public.notes where id = 'd0000000-0000-4000-8000-0000000000c1'),
	'aaaaaaaa-0000-4000-8000-0000000000da'::uuid, 'the copy is A''s note');
select is((select title from public.notes where id = 'd0000000-0000-4000-8000-0000000000c1'), 'Packing list',
	'with the title it had');
select is((select notebook from public.notes where id = 'd0000000-0000-4000-8000-0000000000c1'), '',
	'and nothing else of W''s: it lands in A''s inbox, not in W''s notebook');
select is((select count(*) from public.collab_grants where doc_id = 'd0000000-0000-4000-8000-0000000000c1'), 0::bigint,
	'and W''s share to Bob did not come along');
select is((select identity_id from public.notes where id = 'd0000000-0000-4000-8000-0000000000a1'),
	'aaaaaaaa-0000-4000-8000-0000000000db'::uuid, 'the original stays in W');
reset role;

-- Independent: a revision of the original does not touch the copy.
set local role service_role;
select pg_temp.as_server();
select is(public.collab_append('d0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000db',
	'a0000000-0000-4000-8000-0000000000d1', 'a1', 'VQEA'), 2::bigint, 'the original gets a second revision');
select is((select head_seq from public.collab_documents where id = 'd0000000-0000-4000-8000-0000000000c1'), 0::bigint,
	'the copy''s log is its own, untouched');
reset role;
select is((select count(distinct carry_id) from public.note_carries
	where note_id in ('d0000000-0000-4000-8000-0000000000a1', 'd0000000-0000-4000-8000-0000000000c1')), 1::bigint,
	'one carry, two log rows with the same carry id');

-- ---------------------------------------------------------------------------
-- The log, as each side sees it
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000db');
select is((select count(*) from public.note_carries), 1::bigint, 'W''s log has one row');
select is((select direction || ' ' || peer_handle from public.note_carries), 'out alice-k',
	'W''s row says the copy went out to A');
select is((select peer_note from public.note_carries), 'd0000000-0000-4000-8000-0000000000c1'::uuid,
	'and names the copy');
select is((select content_hash from public.note_carries), repeat('ab', 32), 'and what the content hashed to');
select is((select count(*) from public.notes where id = 'd0000000-0000-4000-8000-0000000000c1'), 0::bigint,
	'W still cannot read the copy: the log names it, it does not open it');

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000da');
select is((select count(*) from public.note_carries), 1::bigint, 'A''s log has one row');
select is((select direction || ' ' || peer_handle || ' ' || device from public.note_carries), 'in alice-k.work laptop',
	'A''s row says the copy came in from W, from which device');
select is((select peer_note from public.note_carries), 'd0000000-0000-4000-8000-0000000000a1'::uuid,
	'and names the original');
select throws_ok($$update public.note_carries set title = 'rewritten'$$, '42501', null,
	'the log cannot be rewritten');
select throws_ok($$delete from public.note_carries$$, '42501', null, 'or erased');

select pg_temp.as_user('b0000000-0000-4000-8000-0000000000d2', '');
select is((select count(*) from public.note_carries), 0::bigint, 'Bob sees none of Alice''s carry log');

-- Deleting the original for good leaves the copy and both log rows.
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000d1', 'aaaaaaaa-0000-4000-8000-0000000000db');
select ok(public.notes_purge('d0000000-0000-4000-8000-0000000000a1'), 'W deletes the original');
reset role;
select is((select count(*) from public.note_carries where carry_id =
	(select carry_id from public.note_carries where note_id = 'd0000000-0000-4000-8000-0000000000c1')), 2::bigint,
	'both log rows outlive it, and the copy is still A''s');

select * from finish();
rollback;
