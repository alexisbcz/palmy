-- The test the browser area is held to (cloud/CONTRACT.md): a session scoped
-- to identity A, asking for identity B's bookmarks, gets nothing, and writing
-- them fails. Plus the merge rule the client relies on: per field group, the
-- larger clock wins, in either order, any number of times.
--
-- Alice owns a personal identity (A) and a work identity (W); Bob owns B.
-- W is the sharp case: same owner as A, so only the token's scope separates
-- them.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(27);

insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000b1', 'alice-b@example.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-0000000000b2', 'bob-b@example.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000ba', 'a0000000-0000-4000-8000-0000000000b1', 'alice-b',      'Alice',        'personal'),
	('aaaaaaaa-0000-4000-8000-0000000000bb', 'a0000000-0000-4000-8000-0000000000b1', 'alice-b.work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-4000-8000-0000000000bb', 'b0000000-0000-4000-8000-0000000000b2', 'bob-b',        'Bob',          'personal');

create function pg_temp.claims(sub text, ident text) returns void language sql as $$
	select set_config('request.jwt.claims',
		json_build_object('sub', sub, 'role', 'authenticated', 'palm_identity', nullif(ident, ''))::text, true)
$$;

create function pg_temp.bm(id text, title text, url text, cc text, pc text, lc text, deleted bool default false)
returns jsonb language sql as $$
	select jsonb_build_object('id', id, 'kind', 'bookmark', 'parent', '00000000-0000-4000-8000-000000000002',
		'position', 'V', 'title', title, 'url', url, 'created', 1760000000000, 'deleted', deleted,
		'content_clock', cc, 'place_clock', pc, 'life_clock', lc)
$$;

-- One bookmark in each identity, each pushed by its own scoped session.
set local role authenticated;

select pg_temp.claims('a0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ba');
select is((select count(*) from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000ba',
	jsonb_build_array(pg_temp.bm('11111111-0000-4000-8000-000000000001', 'Personal', 'https://a.example/',
		'1760000000000-0000-dev1', '1760000000000-0000-dev1', '1760000000000-0000-dev1')))),
	1::bigint, 'A pushes a bookmark into A');

select pg_temp.claims('a0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000bb');
select is((select count(*) from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000bb',
	jsonb_build_array(pg_temp.bm('22222222-0000-4000-8000-000000000002', 'Work', 'https://w.example/',
		'1760000000000-0000-dev2', '1760000000000-0000-dev2', '1760000000000-0000-dev2')))),
	1::bigint, 'W pushes a bookmark into W');

select pg_temp.claims('b0000000-0000-4000-8000-0000000000b2', 'bbbbbbbb-0000-4000-8000-0000000000bb');
select is((select count(*) from public.browser_merge_bookmarks('bbbbbbbb-0000-4000-8000-0000000000bb',
	jsonb_build_array(pg_temp.bm('33333333-0000-4000-8000-000000000003', 'Bob', 'https://b.example/',
		'1760000000000-0000-dev3', '1760000000000-0000-dev3', '1760000000000-0000-dev3')))),
	1::bigint, 'B pushes a bookmark into B');

-- ---------------------------------------------------------------------------
-- Scoped to A: sees A, nothing of W or B, and cannot write to them
-- ---------------------------------------------------------------------------

select pg_temp.claims('a0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ba');

select is((select count(*) from public.browser_bookmarks), 1::bigint, 'scoped to A: exactly one row visible');
select is((select title from public.browser_bookmarks), 'Personal', 'scoped to A: it is A''s');
select is((select count(*) from public.browser_bookmarks where identity_id = 'aaaaaaaa-0000-4000-8000-0000000000bb'),
	0::bigint, 'scoped to A: nothing of W, the same person''s other identity');
select is((select count(*) from public.browser_bookmarks where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000bb'),
	0::bigint, 'scoped to A: nothing of B');

select throws_ok(
	$$ select * from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000bb',
		jsonb_build_array(pg_temp.bm('44444444-0000-4000-8000-000000000004', 'x', 'https://x/',
			'1770000000000-0000-evil', '1770000000000-0000-evil', '1770000000000-0000-evil'))) $$,
	'42501', null, 'scoped to A: merging into W is refused');
select throws_ok(
	$$ select * from public.browser_merge_bookmarks('bbbbbbbb-0000-4000-8000-0000000000bb',
		jsonb_build_array(pg_temp.bm('33333333-0000-4000-8000-000000000003', 'hijack', 'https://evil/',
			'1770000000000-0000-evil', '1770000000000-0000-evil', '1770000000000-0000-evil'))) $$,
	'42501', null, 'scoped to A: merging into B is refused');
select throws_ok(
	$$ insert into public.browser_bookmarks (identity_id, id, content_clock, place_clock, life_clock)
	   values ('bbbbbbbb-0000-4000-8000-0000000000bb', '55555555-0000-4000-8000-000000000005',
	           '1770000000000-0000-evil', '1770000000000-0000-evil', '1770000000000-0000-evil') $$,
	'42501', null, 'scoped to A: a direct insert into B is refused');
select throws_ok(
	$$ insert into public.browser_bookmarks (identity_id, id, content_clock, place_clock, life_clock)
	   values ('aaaaaaaa-0000-4000-8000-0000000000bb', '55555555-0000-4000-8000-000000000005',
	           '1770000000000-0000-evil', '1770000000000-0000-evil', '1770000000000-0000-evil') $$,
	'42501', null, 'scoped to A: a direct insert into W is refused');

select is_empty(
	$$ update public.browser_bookmarks set title = 'hijack'
	   where identity_id in ('bbbbbbbb-0000-4000-8000-0000000000bb', 'aaaaaaaa-0000-4000-8000-0000000000bb')
	   returning id $$,
	'scoped to A: updating W''s or B''s rows touches nothing');
select throws_ok(
	$$ delete from public.browser_bookmarks $$,
	'42501', null, 'nobody deletes rows: tombstones are kept');
select throws_ok(
	$$ update public.browser_bookmarks set identity_id = 'bbbbbbbb-0000-4000-8000-0000000000bb' returning id $$,
	'42501', null, 'scoped to A: moving A''s row into B is refused');

-- ---------------------------------------------------------------------------
-- Unscoped Alice sees both of her identities, never Bob's
-- ---------------------------------------------------------------------------

select pg_temp.claims('a0000000-0000-4000-8000-0000000000b1', '');
select is((select count(*) from public.browser_bookmarks), 2::bigint, 'unscoped Alice: A and W');
select is((select count(*) from public.browser_bookmarks where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000bb'),
	0::bigint, 'unscoped Alice: nothing of Bob');

-- Bob, unscoped, sees only his own.
select pg_temp.claims('b0000000-0000-4000-8000-0000000000b2', '');
select is((select count(*) from public.browser_bookmarks), 1::bigint, 'Bob sees one row');
select is((select title from public.browser_bookmarks), 'Bob', 'and it is untouched');

-- Anonymous: nothing at all.
reset role;
set local role anon;
select pg_temp.claims('', '');
select throws_ok($$ select count(*) from public.browser_bookmarks $$, '42501', null, 'anon cannot read the table');

-- ---------------------------------------------------------------------------
-- The merge rule
-- ---------------------------------------------------------------------------

reset role;
set local role authenticated;
select pg_temp.claims('a0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ba');

-- Laptop renames (newer content clock) while the phone moves it (newer place
-- clock): both survive, whichever arrives first.
select is((select count(*) from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000ba',
	jsonb_build_array(jsonb_set(pg_temp.bm('11111111-0000-4000-8000-000000000001', 'Renamed', 'https://a.example/',
		'1760000000500-0000-laptop', '1760000000000-0000-dev1', '1760000000000-0000-dev1'), '{position}', '"a"')))),
	1::bigint, 'a rename merges');
select is((select count(*) from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000ba',
	jsonb_build_array(jsonb_set(pg_temp.bm('11111111-0000-4000-8000-000000000001', 'Stale title', 'https://a.example/',
		'1760000000100-0000-phone', '1760000000600-0000-phone', '1760000000000-0000-dev1'), '{position}', '"z"')))),
	1::bigint, 'a concurrent move merges');
select is((select title || ' @ ' || position from public.browser_bookmarks where id = '11111111-0000-4000-8000-000000000001'),
	'Renamed @ z', 'both edits kept: the newer title and the newer position');

-- Replaying an older record changes nothing and is not even a write.
select is((select count(*) from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000ba',
	jsonb_build_array(pg_temp.bm('11111111-0000-4000-8000-000000000001', 'Personal', 'https://a.example/',
		'1760000000000-0000-dev1', '1760000000000-0000-dev1', '1760000000000-0000-dev1')))),
	0::bigint, 'an old record is a no-op (idempotent, no new seq)');

-- A tombstone wins over the older life clock, and a later undelete wins over it.
select is((select deleted from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000ba',
	jsonb_build_array(pg_temp.bm('11111111-0000-4000-8000-000000000001', 'x', 'x',
		'1760000000000-0000-dev1', '1760000000000-0000-dev1', '1760000000900-0000-phone', true)))),
	true, 'a delete propagates as a tombstone');
select is((select title from public.browser_bookmarks where id = '11111111-0000-4000-8000-000000000001'),
	'Renamed', 'the tombstone did not overwrite the title');
select is((select deleted from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000ba',
	jsonb_build_array(pg_temp.bm('11111111-0000-4000-8000-000000000001', 'x', 'x',
		'1760000000000-0000-dev1', '1760000000000-0000-dev1', '1760000001000-0000-laptop', false)))),
	false, 'a later undelete wins');

select throws_ok(
	$$ select * from public.browser_merge_bookmarks('aaaaaaaa-0000-4000-8000-0000000000ba',
		jsonb_build_array(pg_temp.bm('66666666-0000-4000-8000-000000000006', 'x', 'x', 'yesterday', 'x', 'x'))) $$,
	'23514', null, 'a malformed clock is rejected');

select * from finish();
rollback;
