-- The contract's test, for the vault tables: a session scoped to identity A,
-- asking for identity B's rows, gets nothing, and writing them fails. Then
-- the vault's own addition: an assistant's session gets nothing at all, even
-- for the identity it acts for, while a device scoped to that identity sees
-- everything the identity owns.
--
--   alice  owns  a-pers (A) and a-work (W)
--   bob    owns  b-pers (B)
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(48);

insert into auth.users (id, email, aud, role) values
	('a0000000-0000-4000-8000-0000000000a1', 'alice@vault-test.invalid', 'authenticated', 'authenticated'),
	('b0000000-0000-4000-8000-0000000000b1', 'bob@vault-test.invalid', 'authenticated', 'authenticated');
insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-0000000000a1', 'v-alice', 'Alice', 'personal'),
	('aaaaaaaa-0000-4000-8000-00000000000b', 'a0000000-0000-4000-8000-0000000000a1', 'v-alice-work', 'Alice at work', 'work'),
	('bbbbbbbb-0000-4000-8000-00000000000a', 'b0000000-0000-4000-8000-0000000000b1', 'v-bob', 'Bob', 'personal');

-- Opaque base64 standing in for keys and ciphertext. The server never reads
-- them, so neither does this test.
create temp table k as select
	encode(gen_random_bytes(32), 'base64') as k32,
	replace(encode(gen_random_bytes(592) || gen_random_bytes(592), 'base64'), E'\n', '') as k1184,
	encode(gen_random_bytes(16), 'base64') as salt,
	replace(encode(gen_random_bytes(73), 'base64'), E'\n', '') as w73,
	replace(encode(gen_random_bytes(169), 'base64'), E'\n', '') as w169,
	replace(encode(gen_random_bytes(600), 'base64'), E'\n', '') as blob,
	replace(encode(gen_random_bytes(64), 'base64'), E'\n', '') as sig;
grant select on k to authenticated;

insert into vault_keysets (identity_id, enc_pub, kem_pub, sign_pub, kdf_salt, kdf_m, kdf_t, kdf_p, account_key_wrap, private_wrap)
select id, k32, k1184, k32, salt, 262144, 3, 4, w73, w169 from k,
	(values ('aaaaaaaa-0000-4000-8000-00000000000a'::uuid), ('aaaaaaaa-0000-4000-8000-00000000000b'), ('bbbbbbbb-0000-4000-8000-00000000000a')) v(id);

insert into vault_vaults (id, identity_id, key_wrap, meta) select v.id, v.ident, k.blob, k.blob from k, (values
	('0a000000-0000-4000-8000-00000000000a'::uuid, 'aaaaaaaa-0000-4000-8000-00000000000a'::uuid),
	('0b000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b'),
	('0c000000-0000-4000-8000-00000000000c', 'bbbbbbbb-0000-4000-8000-00000000000a')) v(id, ident);

insert into vault_items (id, identity_id, vault_id, revision, key_wrap, blob) select v.id, v.ident, v.vault, 1, k.w73, k.blob from k, (values
	('1a000000-0000-4000-8000-000000000001'::uuid, 'aaaaaaaa-0000-4000-8000-00000000000a'::uuid, '0a000000-0000-4000-8000-00000000000a'::uuid),
	('1a000000-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-00000000000a', '0a000000-0000-4000-8000-00000000000a'),
	('1b000000-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-00000000000b', '0b000000-0000-4000-8000-00000000000b'),
	('1c000000-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-00000000000a', '0c000000-0000-4000-8000-00000000000c')) v(id, ident, vault);

insert into vault_devices (id, identity_id, name, pub) select v.id, v.ident, v.name, k.k32 from k, (values
	('d0000000-0000-4000-8000-00000000000a'::uuid, 'aaaaaaaa-0000-4000-8000-00000000000a'::uuid, 'laptop'),
	('d0000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'work laptop'),
	('d0000000-0000-4000-8000-00000000000c', 'bbbbbbbb-0000-4000-8000-00000000000a', 'bob''s phone')) v(id, ident, name);

-- Two GoTrue sessions for alice, each bound to her personal identity by a
-- devices row: one a device, one an assistant. This is exactly what
-- mint_scoped_session leaves behind.
insert into auth.sessions (id, user_id, created_at, updated_at, aal) values
	('5e000000-0000-4000-8000-00000000000d', 'a0000000-0000-4000-8000-0000000000a1', now(), now(), 'aal1'),
	('5e000000-0000-4000-8000-00000000000e', 'a0000000-0000-4000-8000-0000000000a1', now(), now(), 'aal1');
insert into public.devices (identity_id, session_id, name, kind) values
	('aaaaaaaa-0000-4000-8000-00000000000a', '5e000000-0000-4000-8000-00000000000d', 'Alice''s laptop', 'device'),
	('aaaaaaaa-0000-4000-8000-00000000000a', '5e000000-0000-4000-8000-00000000000e', 'Alice''s assistant', 'assistant');

set local role authenticated;

-- ------------------------------------------------------------- alice, unscoped
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select is((select count(*)::int from vault_keysets), 2, 'unscoped: alice sees both her identities'' keysets');
select is((select count(*)::int from vault_items), 3, 'unscoped: alice sees the items of both her identities');
select is((select count(*)::int from vault_items where identity_id = 'bbbbbbbb-0000-4000-8000-00000000000a'), 0,
	'unscoped: alice sees none of bob''s items');
select is((select count(*)::int from vault_devices), 2, 'unscoped: alice sees her two identities'' vault devices');

-- ------------------------------------------------------- alice, scoped to work
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000b"}', true);
select is((select count(*)::int from vault_keysets), 1, 'scoped to work: one keyset');
select is((select count(*)::int from vault_keysets where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'), 0,
	'scoped to work: asking for the personal keyset by id gets nothing');
select is((select count(*)::int from vault_vaults where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'), 0,
	'scoped to work: the personal vault is invisible');
select is((select array_agg(id::text) from vault_items), array['1b000000-0000-4000-8000-000000000001'],
	'scoped to work: sees only the work item');
select is((select count(*)::int from vault_devices where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'), 0,
	'scoped to work: the personal identity''s devices are invisible');
select is_empty($q$ update vault_items set revision = revision + 1, blob = 'AAAA'
	where id = '1a000000-0000-4000-8000-000000000001' returning 1 $q$,
	'scoped to work: overwriting a personal item touches nothing');
select is_empty($q$ update vault_keysets set private_wrap = 'AAAA'
	where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a' returning 1 $q$,
	'scoped to work: replacing the personal keyset touches nothing');
select throws_ok($$ insert into vault_items (id, identity_id, vault_id, revision, key_wrap, blob)
	values (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a', '0a000000-0000-4000-8000-00000000000a', 1, 'AAAA', 'AAAA') $$,
	'42501', null, 'scoped to work: planting an item in the personal vault fails');
select throws_ok($$ select vault_put_item('1a000000-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-00000000000a',
	'0a000000-0000-4000-8000-00000000000a', 1, 1, 'AAAA', 'AAAA') $$,
	'PT404', null, 'scoped to work: vault_put_item on a personal item fails, without confirming it exists');
select throws_ok($$ insert into vault_shares (id, identity_id, vault_id, grantee_identity, key_version, wrapped_key, signature)
	values (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a', '0a000000-0000-4000-8000-00000000000a',
	        'aaaaaaaa-0000-4000-8000-00000000000b', 1, 'AAAA', 'AAAA') $$,
	'42501', null, 'scoped to work: sharing the personal vault to itself fails (only the source may share)');
select throws_ok($$ insert into vault_devices (id, identity_id, name, pub)
	values (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a', 'rogue', 'AAAA') $$,
	'42501', null, 'scoped to work: enrolling a device for the personal identity fails');
select results_eq($q$ select revision from vault_put_item('1b000000-0000-4000-8000-000000000001',
	'aaaaaaaa-0000-4000-8000-00000000000b', '0b000000-0000-4000-8000-00000000000b', 1, 1,
	(select w73 from k), (select blob from k)) $q$, $q$ values (2::bigint) $q$,
	'scoped to work: writes its own item, revision 1 -> 2');
select throws_ok($$ select vault_put_item('1b000000-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-00000000000b',
	'0b000000-0000-4000-8000-00000000000b', 1, 1, 'AAAA', 'AAAA') $$,
	'40001', null, 'a write from a stale revision is a conflict, not a silent overwrite');
select throws_ok($$ update vault_items set revision = 9 where id = '1b000000-0000-4000-8000-000000000001' $$,
	'40001', null, 'a revision cannot skip ahead');
select throws_ok($$ update vault_items set vault_id = '0a000000-0000-4000-8000-00000000000a', revision = revision + 1
	where id = '1b000000-0000-4000-8000-000000000001' $$,
	'42501', null, 'an item cannot move to another vault in place');

-- -------------------------------------------------------------- bob, scoped
select set_config('request.jwt.claims',
	'{"sub":"b0000000-0000-4000-8000-0000000000b1","role":"authenticated","palm_identity":"bbbbbbbb-0000-4000-8000-00000000000a"}', true);
select is((select count(*)::int from vault_items), 1, 'bob sees his one item and nothing of alice''s');
select is((select count(*)::int from vault_keysets), 1, 'bob sees only his own keyset row');
select is((select count(*)::int from vault_public_keys('v-alice')), 1,
	'bob can look up alice''s public keys by handle, to share with her');
select is((select count(*)::int from vault_public_keys('v-alice') where kem_pub is not null and enc_pub is not null), 1,
	'the lookup returns public keys and nothing else of the keyset');

-- ------------------------------------------------- the device and the assistant
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000a","session_id":"5e000000-0000-4000-8000-00000000000d"}', true);
select is((select count(*)::int from vault_items), 2, 'a device scoped to personal sees the personal items');
select is((select count(*)::int from vault_keysets), 1, 'a device scoped to personal reads the personal keyset');

select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000a","session_id":"5e000000-0000-4000-8000-00000000000e"}', true);
select ok(public.can_access_identity('aaaaaaaa-0000-4000-8000-00000000000a'),
	'the assistant may act for the personal identity (mail, calendar, drive...)');
select is((select count(*)::int from vault_items), 0, 'the assistant gets no vault items');
select is((select count(*)::int from vault_keysets), 0, 'the assistant gets no keyset, not even the wrapped one');
select is((select count(*)::int from vault_vaults), 0, 'the assistant gets no vaults');
select is((select count(*)::int from vault_shares), 0, 'the assistant gets no share rows');
select is((select count(*)::int from vault_devices), 0, 'the assistant gets no vault devices');
select is((select count(*)::int from vault_public_keys('v-alice')), 0, 'the assistant cannot even look up public keys');
select throws_ok($$ select vault_put_item(gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a',
	'0a000000-0000-4000-8000-00000000000a', 0, 1, 'AAAA', 'AAAA') $$,
	'42501', null, 'the assistant cannot write an item');
select throws_ok($$ insert into vault_items (id, identity_id, vault_id, revision, key_wrap, blob)
	values (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a', '0a000000-0000-4000-8000-00000000000a', 1, 'AAAA', 'AAAA') $$,
	'42501', null, 'the assistant cannot insert an item directly either');
select is_empty($q$ update vault_keysets set private_wrap = 'AAAA' returning 1 $q$,
	'the assistant cannot replace the keyset');
select throws_ok($$ insert into vault_devices (id, identity_id, name, pub)
	values (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a', 'assistant as a device', 'AAAA') $$,
	'42501', null, 'the assistant cannot enrol itself as a vault device to receive the Secret Key');
select ok(not vault_session_ok(), 'vault_session_ok() is false for the assistant');

-- An assistant session with no session_id in its token is not possible
-- (GoTrue always issues one), but a token without session_id must not read
-- as "not an assistant" by accident either: it is a plain session, and the
-- identity rule still applies to it.
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000a"}', true);
select is((select count(*)::int from vault_items where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000b'), 0,
	'a scoped token without a session id still sees only its identity');

-- --------------------------------------------------------------------- anon
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select throws_ok($$ select count(*) from vault_items $$, '42501', null, 'anon cannot read vault items at all');
select throws_ok($$ select * from vault_public_keys('v-alice') $$, '42501', null, 'anon cannot look up public keys');
reset role;
set local role authenticated;

-- ------------------------------------------- an archived identity loses its vault
reset role;
update public.identities set archived_at = now() where id = 'aaaaaaaa-0000-4000-8000-00000000000b';
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select is((select count(*)::int from vault_items where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000b'), 0,
	'archiving the work identity hides its vault, even from the unscoped owner');
select is((select count(*)::int from vault_keysets), 1, 'and its keyset');
select is((select count(*)::int from vault_public_keys('v-alice-work')), 0,
	'and nobody can find its public keys to share with it any more');

-- ------------------------------------------------------- tombstones
reset role;
update public.identities set archived_at = null where id = 'aaaaaaaa-0000-4000-8000-00000000000b';
set local role authenticated;
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000a"}', true);
select results_eq($q$ select revision, deleted, blob is null, key_wrap is null from vault_put_item(
	'1a000000-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-00000000000a',
	'0a000000-0000-4000-8000-00000000000a', 1, 1, null, null, true) $q$,
	$q$ values (2::bigint, true, true, true) $q$,
	'deleting is a tombstone: a new revision, no key, no ciphertext');
select is((select count(*)::int from vault_items where id = '1a000000-0000-4000-8000-000000000002'), 1,
	'the tombstone stays, so the deletion reaches every device');
select throws_ok($$ select vault_put_item(gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a',
	'0a000000-0000-4000-8000-00000000000a', 0, 1, null, null, false) $$,
	'23514', null, 'a live item must carry a key and ciphertext');
select throws_ok($$ select vault_put_item(gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a',
	'0a000000-0000-4000-8000-00000000000a', 0, 1, 'not base64!', 'AAAA', false) $$,
	'23514', null, 'a key wrap that is not base64 is refused');
select throws_ok($$ select vault_put_item(gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000a',
	'0a000000-0000-4000-8000-00000000000a', 5, 1, 'AAAA', 'AAAA', false) $$,
	'PT404', null, 'writing a missing item from a nonzero revision is not found, not an insert');

select * from finish();
rollback;
