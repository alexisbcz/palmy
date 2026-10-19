-- A share grants exactly what it says -- that item, that role, that grantee
-- identity -- and revoking or expiring it takes the access away again.
--
--   alice  owns  a-work (A)
--   bob    owns  b-work (B) and b-home (BH)
--
-- A's tree:   Reports/            (folder R)
--               q3.pdf            (file F, chunk f…)
--             salaries.xlsx       (file S, chunk 5…)
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(34);

insert into auth.users (id, email) values
	('00000000-0000-0000-0000-00000000a11c', 'alice@palm.test'),
	('00000000-0000-0000-0000-000000000b0b', 'bob@palm.test');
insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000a11c', 'a-work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000b0b', 'b-work', 'Bob (work)', 'work'),
	('bbbbbbbb-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000b0b', 'b-home', 'Bob', 'personal');

insert into storage.objects (bucket_id, name, metadata) values
	('drive', 'aaaaaaaa-0000-0000-0000-000000000001/chunks/' || repeat('f', 64), '{"size": 100}'),
	('drive', 'aaaaaaaa-0000-0000-0000-000000000001/chunks/' || repeat('5', 64), '{"size": 200}');
insert into public.drive_items (id, identity_id, name, kind) values
	('a0000000-0000-0000-0000-00000000000d', 'aaaaaaaa-0000-0000-0000-000000000001', 'Reports', 'folder');
-- Fixtures commit as alice (still the database owner, so no RLS): the
-- chunk check answers only for someone who may see the identity.
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated"}', true);
select drive_commit('aaaaaaaa-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000d', 'q3.pdf',
	null, null, 100, repeat('f', 64), 'application/pdf', array[repeat('f', 64)], 4194304);
select drive_commit('aaaaaaaa-0000-0000-0000-000000000001', null, 'salaries.xlsx',
	null, null, 200, repeat('5', 64), 'application/vnd.ms-excel', array[repeat('5', 64)], 4194304);

create temp table ids as select
	(select id from drive_items where name = 'q3.pdf') as f,
	(select id from drive_items where name = 'salaries.xlsx') as s;
grant select on ids to authenticated, anon;
create temp table tok (t text, link uuid);
grant all on tok to authenticated, anon;

-- ------------------------------------------- alice shares Reports to bob's work
set local role authenticated;
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated","palm_identity":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
select lives_ok($$ select drive_share('a0000000-0000-0000-0000-00000000000d', 'b-work', 'viewer') $$,
	'alice shares Reports with b-work as viewer');
select throws_ok($$ select drive_share('a0000000-0000-0000-0000-00000000000d', 'nobody-here') $$,
	'PT404', null, 'sharing with an unknown handle is refused');

-- ------------------------------------------------------- bob, scoped to b-work
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-000000000b0b","role":"authenticated","palm_identity":"bbbbbbbb-0000-0000-0000-000000000001"}', true);
select is((select count(*)::int from drive_shares), 1, 'b-work sees the share made to it');
select is((select array_agg(name order by name collate "C") from drive_items), array['Reports', 'q3.pdf'],
	'b-work sees the shared folder and what is in it, nothing else');
select is((select count(*)::int from drive_items where name = 'salaries.xlsx'), 0, 'b-work does not see the unshared file');
select is((select count(*)::int from drive_versions), 1, 'b-work sees the current version of the shared file');
select is((select count(*)::int from storage.objects where name like '%' || repeat('f', 64)), 1,
	'b-work can read the shared file''s chunk');
select is((select count(*)::int from storage.objects where name like '%' || repeat('5', 64)), 0,
	'b-work cannot read the unshared file''s chunk');

select is_empty($q$ update drive_items set name = 'mine.pdf' where name = 'q3.pdf' returning 1 $q$,
	'a viewer cannot rename');
select throws_ok($$
	insert into drive_items (identity_id, parent_id, name, kind)
	values ('aaaaaaaa-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000d', 'planted', 'file')
$$, '42501', null, 'a viewer cannot add to the folder');
select throws_ok($$
	insert into storage.objects (bucket_id, name, metadata)
	values ('drive', 'aaaaaaaa-0000-0000-0000-000000000001/chunks/' || repeat('9', 64), '{"size":1}')
$$, '42501', null, 'a viewer cannot write chunks into the owner''s drive');
select throws_ok($$
	insert into drive_shares (identity_id, item_id, grantee_identity)
	values ('aaaaaaaa-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000d', 'bbbbbbbb-0000-0000-0000-000000000002')
$$, '42501', null, 'a grantee cannot re-share the owner''s item');
select is_empty($q$ update drive_shares set role = 'editor' returning 1 $q$,
	'a grantee cannot upgrade its own share');
select throws_ok($$ select drive_link_mint('a0000000-0000-0000-0000-00000000000d') $$, 'PT404', null,
	'a grantee cannot mint a public link to the owner''s item');

-- ---------------------------------------- bob, scoped to his *other* identity
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-000000000b0b","role":"authenticated","palm_identity":"bbbbbbbb-0000-0000-0000-000000000002"}', true);
select is((select count(*)::int from drive_items), 0, 'b-home sees nothing: the share was to b-work, not to bob');
select is((select count(*)::int from storage.objects where bucket_id = 'drive'), 0, 'b-home reads no chunks');

-- ------------------------------------------------- alice upgrades to editor
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated","palm_identity":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
select lives_ok($$ select drive_share('a0000000-0000-0000-0000-00000000000d', 'b-work', 'editor') $$,
	're-sharing as editor replaces the viewer share');
select is((select count(*)::int from drive_shares where revoked_at is null), 1, 'one live share, not two');

select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-000000000b0b","role":"authenticated","palm_identity":"bbbbbbbb-0000-0000-0000-000000000001"}', true);
select results_eq($q$ update drive_items set name = 'q3-final.pdf' where name = 'q3.pdf' returning 1 $q$, $q$ values (1) $q$,
	'an editor can rename inside the share');
select lives_ok($$
	insert into storage.objects (bucket_id, name, metadata)
	values ('drive', 'aaaaaaaa-0000-0000-0000-000000000001/chunks/' || repeat('9', 64), '{"size":1}')
$$, 'an editor can upload chunks into the owner''s drive');
select lives_ok($$
	select drive_commit('aaaaaaaa-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000d', 'notes.txt',
		null, null, 1, repeat('9', 64), 'text/plain', array[repeat('9', 64)], 4194304)
$$, 'an editor can add a file to the shared folder');
select throws_ok($$
	update drive_items set parent_id = null where name = 'notes.txt'
$$, '42501', null, 'an editor cannot move a file out of the share');
select is_empty($q$ delete from drive_items where name = 'notes.txt' returning 1 $q$,
	'an editor cannot delete for good');
select is((select count(*)::int from drive_items where name = 'salaries.xlsx'), 0,
	'an editor still does not see the rest of the drive');

-- --------------------------------------------------------- alice revokes
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated","palm_identity":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
select results_eq($q$ update drive_shares set revoked_at = now() where revoked_at is null returning 1 $q$, $q$ values (1) $q$,
	'alice revokes the share');

select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-000000000b0b","role":"authenticated","palm_identity":"bbbbbbbb-0000-0000-0000-000000000001"}', true);
select is((select count(*)::int from drive_items), 0, 'after revocation b-work sees nothing');
select is((select count(*)::int from storage.objects where bucket_id = 'drive'), 0, 'after revocation b-work reads no chunks');
select throws_ok($$
	insert into storage.objects (bucket_id, name, metadata)
	values ('drive', 'aaaaaaaa-0000-0000-0000-000000000001/chunks/' || repeat('7', 64), '{"size":1}')
$$, '42501', null, 'after revocation b-work cannot write chunks');

-- --------------------------------------------------------- expiry
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated","palm_identity":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
select drive_share((select s from ids), 'b-work', 'viewer', now() - interval '1 minute');
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-000000000b0b","role":"authenticated","palm_identity":"bbbbbbbb-0000-0000-0000-000000000001"}', true);
select is((select count(*)::int from drive_items), 0, 'an expired share grants nothing');

-- --------------------------------------------------------- read-only links
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated","palm_identity":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
insert into tok select token, link_id from drive_link_mint('a0000000-0000-0000-0000-00000000000d', '1 hour');
select is((select count(*)::int from drive_links where token_hash = (select t from tok)), 0,
	'the token itself is not stored');

reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is((select array_agg(path order by path collate "C") from drive_link_resolve((select t from tok))),
	array['Reports', 'Reports/notes.txt', 'Reports/q3-final.pdf'],
	'anyone with the link resolves the folder and its files');
select is((select count(*)::int from drive_link_resolve((select t from tok)) where path like '%salaries%'), 0,
	'the link reaches only what was linked');

reset role;
set local role authenticated;
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated","palm_identity":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
update drive_links set revoked_at = now() where id = (select link from tok);
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$ select drive_link_resolve((select t from tok)) $$, 'PT404', null,
	'a revoked link resolves to nothing');

reset role;
set local role authenticated;
select set_config('request.jwt.claims',
	'{"sub":"00000000-0000-0000-0000-00000000a11c","role":"authenticated","palm_identity":"aaaaaaaa-0000-0000-0000-000000000001"}', true);
delete from tok;
insert into tok select token, link_id from drive_link_mint((select s from ids), '-1 minute');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$ select drive_link_resolve((select t from tok)) $$, 'PT404', null,
	'an expired link resolves to nothing');

select * from finish();
rollback;
