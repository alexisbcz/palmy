-- The test the whole design is held to (cloud/CONTRACT.md): a session scoped
-- to identity A, asking for identity B's drive, gets nothing, and writing it
-- fails -- for the tables and for the blobs in Storage.
--
-- People and identities:
--   alice  owns  a-work  (A)  and  a-home  (H)
--   bob    owns  b-work  (B)
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(31);

insert into auth.users (id, email) values
	('00000000-0000-0000-0000-00000000a11c', 'alice@palm.test'),
	('00000000-0000-0000-0000-000000000b0b', 'bob@palm.test');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000a11c', 'a-work', 'Alice (work)', 'work'),
	('aaaaaaaa-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000a11c', 'a-home', 'Alice', 'personal'),
	('bbbbbbbb-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000b0b', 'b-work', 'Bob (work)', 'work');

-- Fixtures, written as the owner of the database (no RLS).
insert into public.drive_items (id, identity_id, parent_id, name, kind) values
	('a0000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', null, 'Reports', 'folder'),
	('b0000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', null, 'Bob plans', 'folder'),
	('c0000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002', null, 'Holidays', 'folder');

insert into storage.objects (bucket_id, name, metadata) values
	('drive', 'aaaaaaaa-0000-0000-0000-000000000001/chunks/' || repeat('a', 64), '{"size": 10}'),
	('drive', 'bbbbbbbb-0000-0000-0000-000000000001/chunks/' || repeat('b', 64), '{"size": 20}');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000b0b","role":"authenticated"}', true);
select lives_ok($$
	select public.drive_commit('bbbbbbbb-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001',
		'secret.txt', null, null, 20, repeat('b', 64), 'text/plain', array[repeat('b', 64)], 4194304)
$$, 'fixture: bob has a file');

-- ---------------------------------------------------------------- scoped to A
set local role authenticated;
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated","palm_identity":"aaaaaaaa-0000-0000-0000-000000000001"}', true);

select is((select count(*)::int from drive_items), 1, 'scoped to A: sees exactly its one item');
select is((select count(*)::int from drive_items where identity_id = 'bbbbbbbb-0000-0000-0000-000000000001'), 0,
	'scoped to A: sees none of B''s items');
select is((select count(*)::int from drive_items where identity_id = 'aaaaaaaa-0000-0000-0000-000000000002'), 0,
	'scoped to A: sees none of its owner''s other identity');
select is((select count(*)::int from drive_versions), 0, 'scoped to A: sees no versions of B');

select throws_ok($$
	insert into drive_items (identity_id, name, kind) values ('bbbbbbbb-0000-0000-0000-000000000001', 'planted', 'file')
$$, '42501', null, 'scoped to A: cannot create an item in B');
select throws_ok($$
	insert into drive_items (identity_id, name, kind) values ('aaaaaaaa-0000-0000-0000-000000000002', 'planted', 'file')
$$, '42501', null, 'scoped to A: cannot create an item in its owner''s other identity');
select throws_ok($$
	insert into drive_items (identity_id, parent_id, name, kind)
	values ('aaaaaaaa-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'x', 'file')
$$, null, null, 'scoped to A: cannot hang an item under B''s folder');

select is_empty($q$ update drive_items set name = 'pwned' where identity_id = 'bbbbbbbb-0000-0000-0000-000000000001' returning 1 $q$,
	'scoped to A: updating B''s items touches nothing');
select is_empty($q$ delete from drive_items where identity_id = 'bbbbbbbb-0000-0000-0000-000000000001' returning 1 $q$,
	'scoped to A: deleting B''s items touches nothing');
select throws_ok($$
	update drive_items set identity_id = 'bbbbbbbb-0000-0000-0000-000000000001'
	where id = 'a0000000-0000-0000-0000-000000000001'
$$, '42501', null, 'scoped to A: cannot move its own item into B');

select throws_ok($$
	select drive_trash('b0000000-0000-0000-0000-000000000001')
$$, 'PT404', null, 'scoped to A: cannot trash B''s folder');
select throws_ok($$
	select drive_commit('bbbbbbbb-0000-0000-0000-000000000001', null, 'planted.txt', null, null,
		20, repeat('b', 64), 'text/plain', array[repeat('b', 64)], 4194304)
$$, 'PT412', null, 'scoped to A: cannot commit into B (B''s chunks are invisible)');
select throws_ok($$
	select drive_link_mint('b0000000-0000-0000-0000-000000000001')
$$, 'PT404', null, 'scoped to A: cannot mint a link to B''s folder');
select throws_ok($$
	select drive_share('b0000000-0000-0000-0000-000000000001', 'a-work')
$$, 'PT404', null, 'scoped to A: cannot share B''s folder to itself');
select is((select stored_bytes from drive_usage('bbbbbbbb-0000-0000-0000-000000000001')), null,
	'scoped to A: cannot read B''s storage use');

-- Storage
select is((select count(*)::int from storage.objects where bucket_id = 'drive'), 1,
	'scoped to A: sees exactly its own chunk');
select is((select count(*)::int from storage.objects where name like 'bbbbbbbb%'), 0,
	'scoped to A: sees none of B''s chunks');
select throws_ok($$
	insert into storage.objects (bucket_id, name, metadata)
	values ('drive', 'bbbbbbbb-0000-0000-0000-000000000001/chunks/' || repeat('c', 64), '{"size":1}')
$$, '42501', null, 'scoped to A: cannot write a chunk into B''s prefix');
select throws_ok($$
	insert into storage.objects (bucket_id, name, metadata)
	values ('drive', 'aaaaaaaa-0000-0000-0000-000000000002/chunks/' || repeat('c', 64), '{"size":1}')
$$, '42501', null, 'scoped to A: cannot write a chunk into its owner''s other identity');
select throws_ok($$
	insert into storage.objects (bucket_id, name, metadata)
	values ('drive', 'aaaaaaaa-0000-0000-0000-000000000001/notachunk.exe', '{"size":1}')
$$, '42501', null, 'scoped to A: cannot write outside the chunk layout, even in its own prefix');
select lives_ok($$
	insert into storage.objects (bucket_id, name, metadata)
	values ('drive', 'aaaaaaaa-0000-0000-0000-000000000001/chunks/' || repeat('d', 64), '{"size":1}')
$$, 'scoped to A: can write a chunk into its own prefix');
select is((select count(*)::int from drive_missing_chunks('aaaaaaaa-0000-0000-0000-000000000001',
	array[repeat('a', 64), repeat('e', 64)])), 1, 'scoped to A: dedupe sees its own chunk, asks for the new one');
select is((select count(*)::int from drive_missing_chunks('aaaaaaaa-0000-0000-0000-000000000001',
	array[repeat('b', 64)])), 1, 'scoped to A: B holding a chunk does not count as A holding it (no cross-identity dedupe)');

-- ------------------------------------------------------- unscoped, as alice
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated"}', true);
select is((select count(*)::int from drive_items), 2, 'alice unscoped: sees both her identities');
select is((select count(*)::int from drive_items where identity_id = 'bbbbbbbb-0000-0000-0000-000000000001'), 0,
	'alice unscoped: still sees nothing of bob''s');
select is((select count(*)::int from storage.objects where name like 'bbbbbbbb%'), 0,
	'alice unscoped: still sees none of bob''s chunks');

-- ---------------------------------------------------------------- as bob
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-000000000b0b","role":"authenticated","palm_identity":"bbbbbbbb-0000-0000-0000-000000000001"}', true);
select is((select count(*)::int from drive_items), 2, 'bob scoped to B: sees his folder and file');
select is((select name from drive_items where kind = 'file'), 'secret.txt', 'bob scoped to B: reads his own file');

-- ---------------------------------------------------------------- anonymous
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$ select count(*) from drive_items $$, '42501', null, 'anon: no table access at all');
select throws_ok($$ select drive_link_resolve('not-a-token') $$, 'PT404', null, 'anon: a made-up link token resolves to nothing');

select * from finish();
rollback;
