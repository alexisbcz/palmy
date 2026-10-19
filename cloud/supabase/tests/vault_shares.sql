-- A share grants exactly what it says -- that item or that vault, that role,
-- that grantee identity -- and revoking it stops the rows reaching the
-- grantee on the very next request.
--
-- What a database test cannot show, and vault.md says plainly: revoking does
-- not take back a secret the grantee already decrypted. The client answers
-- that by rotating the key on revoke (apps/vault, `t_share_rotate`), so what
-- the owner writes afterwards no longer opens under the key the grantee had.
--
--   alice  owns  s-alice (A) and s-alice-work (W)
--   bob    owns  s-bob (B) and s-bob-home (BH)
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(44);

insert into auth.users (id, email, aud, role) values
	('a0000000-0000-4000-8000-0000000000a2', 'alice@share-test.invalid', 'authenticated', 'authenticated'),
	('b0000000-0000-4000-8000-0000000000b2', 'bob@share-test.invalid', 'authenticated', 'authenticated');
insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-1111-4000-8000-00000000000a', 'a0000000-0000-4000-8000-0000000000a2', 's-alice', 'Alice', 'personal'),
	('aaaaaaaa-1111-4000-8000-00000000000b', 'a0000000-0000-4000-8000-0000000000a2', 's-alice-work', 'Alice at work', 'work'),
	('bbbbbbbb-1111-4000-8000-00000000000a', 'b0000000-0000-4000-8000-0000000000b2', 's-bob', 'Bob', 'personal'),
	('bbbbbbbb-1111-4000-8000-00000000000b', 'b0000000-0000-4000-8000-0000000000b2', 's-bob-home', 'Bob at home', 'personal');

create temp table k as select
	encode(gen_random_bytes(32), 'base64') as k32,
	replace(encode(gen_random_bytes(73), 'base64'), E'\n', '') as w73,
	replace(encode(gen_random_bytes(600), 'base64'), E'\n', '') as blob,
	replace(encode(gen_random_bytes(64), 'base64'), E'\n', '') as sig;
grant select on k to authenticated;

-- A's vault holds two logins; W's vault holds one.
insert into vault_vaults (id, identity_id, key_wrap, meta) select v.id, v.ident, k.blob, k.blob from k, (values
	('0a000000-1111-4000-8000-00000000000a'::uuid, 'aaaaaaaa-1111-4000-8000-00000000000a'::uuid),
	('0b000000-1111-4000-8000-00000000000b', 'aaaaaaaa-1111-4000-8000-00000000000b')) v(id, ident);
insert into vault_items (id, identity_id, vault_id, revision, key_wrap, blob) select v.id, v.ident, v.vault, 1, k.w73, k.blob from k, (values
	('1a000000-1111-4000-8000-000000000001'::uuid, 'aaaaaaaa-1111-4000-8000-00000000000a'::uuid, '0a000000-1111-4000-8000-00000000000a'::uuid),
	('1a000000-1111-4000-8000-000000000002', 'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a'),
	('1b000000-1111-4000-8000-000000000001', 'aaaaaaaa-1111-4000-8000-00000000000b', '0b000000-1111-4000-8000-00000000000b')) v(id, ident, vault);

set local role authenticated;

-- ----------------------------------------- alice (personal) shares one login with bob
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000a"}', true);
select lives_ok($$ insert into vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select '5a000000-1111-4000-8000-000000000001', 'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a',
	       '1a000000-1111-4000-8000-000000000001', 'bbbbbbbb-1111-4000-8000-00000000000a', 'read', 1, blob, sig from k $$,
	'alice shares one login, read-only, with bob');
select throws_ok($$ insert into vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select gen_random_uuid(), 'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a',
	       '1a000000-1111-4000-8000-000000000002', 'bbbbbbbb-1111-4000-8000-00000000000a', 'write', 1, blob, sig from k $$,
	'23514', null, 'a single item cannot be shared for writing');
select throws_ok($$ insert into vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select gen_random_uuid(), 'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a',
	       '1b000000-1111-4000-8000-000000000001', 'bbbbbbbb-1111-4000-8000-00000000000a', 'read', 1, blob, sig from k $$,
	'23503', null, 'an item can only be shared through the vault that holds it');
select throws_ok($$ insert into vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select gen_random_uuid(), 'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a',
	       null, 'aaaaaaaa-1111-4000-8000-00000000000a', 'read', 1, blob, sig from k $$,
	'23514', null, 'an identity cannot share with itself');

-- ---------------------------------------------------- bob, scoped to s-bob
select set_config('request.jwt.claims',
	'{"sub":"b0000000-0000-4000-8000-0000000000b2","role":"authenticated","palm_identity":"bbbbbbbb-1111-4000-8000-00000000000a"}', true);
select is((select array_agg(id::text) from vault_items), array['1a000000-1111-4000-8000-000000000001'],
	'bob sees the one shared login and nothing else of alice''s vault');
select is((select count(*)::int from vault_shares), 1, 'bob sees the share row that carries his wrapped key');
select is((select count(*)::int from vault_vaults), 0, 'an item share does not reveal the vault''s (encrypted) name');
select is((select count(*)::int from vault_keysets), 0, 'nor anything of alice''s keyset');
select is((select vault_shared_role('0a000000-1111-4000-8000-00000000000a', '1a000000-1111-4000-8000-000000000001')), 'read',
	'the role bob holds on the shared login is read');
select is((select vault_shared_role('0a000000-1111-4000-8000-00000000000a', '1a000000-1111-4000-8000-000000000002')), null,
	'and none on the other login in the same vault');
select is_empty($q$ update vault_items set revision = revision + 1, blob = 'AAAA'
	where id = '1a000000-1111-4000-8000-000000000001' returning 1 $q$,
	'a reader cannot overwrite the shared login');
select throws_ok($$ select vault_put_item('1a000000-1111-4000-8000-000000000001', 'aaaaaaaa-1111-4000-8000-00000000000a',
	'0a000000-1111-4000-8000-00000000000a', 1, 1, 'AAAA', 'AAAA') $$,
	'42501', null, 'nor through vault_put_item');
select throws_ok($$ insert into vault_items (id, identity_id, vault_id, revision, key_wrap, blob)
	values (gen_random_uuid(), 'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a', 1, 'AAAA', 'AAAA') $$,
	'42501', null, 'a reader of one item cannot add items to the vault');
select is_empty($q$ update vault_shares set revoked_at = now() returning 1 $q$,
	'the grantee cannot revoke (or otherwise touch) the share');
select throws_ok($$ insert into vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select gen_random_uuid(), 'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a',
	       '1a000000-1111-4000-8000-000000000001', 'bbbbbbbb-1111-4000-8000-00000000000b', 'read', 1, blob, sig from k $$,
	'42501', null, 'the grantee cannot re-share alice''s login onward');

-- ------------------------------------------------- bob, scoped to his other identity
select set_config('request.jwt.claims',
	'{"sub":"b0000000-0000-4000-8000-0000000000b2","role":"authenticated","palm_identity":"bbbbbbbb-1111-4000-8000-00000000000b"}', true);
select is((select count(*)::int from vault_items), 0, 's-bob-home sees nothing: the share was to s-bob, not to bob');
select is((select count(*)::int from vault_shares), 0, 'nor the share row');

-- ------------------------------------- alice shares her work vault with her personal identity
-- The cross-identity rule inside one account: no ambient access between
-- alice's own identities, only this explicit row.
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000a"}', true);
select is((select count(*)::int from vault_items where vault_id = '0b000000-1111-4000-8000-00000000000b'), 0,
	'before the share: alice-personal cannot see the work vault');
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000b"}', true);
select lives_ok($$ insert into vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select '5b000000-1111-4000-8000-000000000001', 'aaaaaaaa-1111-4000-8000-00000000000b', '0b000000-1111-4000-8000-00000000000b',
	       null, 'aaaaaaaa-1111-4000-8000-00000000000a', 'write', 1, blob, sig from k $$,
	'alice-work shares its whole vault, read-write, with alice-personal');
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000a"}', true);
select is((select count(*)::int from vault_vaults where id = '0b000000-1111-4000-8000-00000000000b'), 1,
	'alice-personal now sees the work vault''s (encrypted) metadata');
select is((select count(*)::int from vault_items where vault_id = '0b000000-1111-4000-8000-00000000000b'), 1,
	'and its item');
select results_eq($q$ select revision from vault_put_item('1b000000-1111-4000-8000-000000000001',
	'aaaaaaaa-1111-4000-8000-00000000000b', '0b000000-1111-4000-8000-00000000000b', 1, 1,
	(select w73 from k), (select blob from k)) $q$, $q$ values (2::bigint) $q$,
	'a writer edits the shared item, through the same compare-and-swap');
select lives_ok($$ select vault_put_item('1b000000-1111-4000-8000-0000000000aa', 'aaaaaaaa-1111-4000-8000-00000000000b',
	'0b000000-1111-4000-8000-00000000000b', 0, 1, (select w73 from k), (select blob from k)) $$,
	'a writer adds an item to the shared vault, owned by the vault''s identity');
select throws_ok($$ select vault_put_item(gen_random_uuid(), 'aaaaaaaa-1111-4000-8000-00000000000a',
	'0b000000-1111-4000-8000-00000000000b', 0, 1, (select w73 from k), (select blob from k)) $$,
	'23503', null, 'an item in a shared vault cannot claim to belong to the writer''s own identity');
select is_empty($q$ delete from vault_items where vault_id = '0b000000-1111-4000-8000-00000000000b' returning 1 $q$,
	'a writer cannot purge items (tombstones only)');
select is_empty($q$ update vault_vaults set meta = 'AAAA' where id = '0b000000-1111-4000-8000-00000000000b' returning 1 $q$,
	'a writer cannot rename the vault');
select is((select count(*)::int from vault_keysets where identity_id = 'aaaaaaaa-1111-4000-8000-00000000000b'), 0,
	'sharing a vault does not share the work identity''s keyset');

-- ---------------------------------------------------------- revocation
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000a"}', true);
select results_eq($q$ update vault_shares set revoked_at = now()
	where id = '5a000000-1111-4000-8000-000000000001' returning 1 $q$, $q$ values (1) $q$,
	'alice revokes bob''s share');
select throws_ok($$ update vault_shares set revoked_at = null where id = '5a000000-1111-4000-8000-000000000001' $$,
	'42501', null, 'a revoked share stays revoked');
select throws_ok($$ update vault_shares set grantee_identity = 'bbbbbbbb-1111-4000-8000-00000000000b'
	where id = '5a000000-1111-4000-8000-000000000001' $$,
	'42501', null, 'a share cannot be redirected to another grantee');

select set_config('request.jwt.claims',
	'{"sub":"b0000000-0000-4000-8000-0000000000b2","role":"authenticated","palm_identity":"bbbbbbbb-1111-4000-8000-00000000000a"}', true);
select is((select count(*)::int from vault_items), 0, 'after revoking: bob receives no rows of alice''s, so sync stops');
select is((select vault_shared_role('0a000000-1111-4000-8000-00000000000a', '1a000000-1111-4000-8000-000000000001')), null,
	'and holds no role');
select is((select count(*)::int from vault_shares where revoked_at is not null), 1,
	'bob still sees that the share existed and was revoked, which is how his client knows to drop its copy');

-- Rotation, item share: alice re-encrypts the login under a fresh item key
-- (revision 2; the vault key is unchanged, so key_version stays 1).
-- Re-sharing to bob later is a new row, with a new signature.
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000a"}', true);
select results_eq($q$ select revision, key_version from vault_put_item('1a000000-1111-4000-8000-000000000001',
	'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a', 1, 1,
	(select w73 from k), (select blob from k)) $q$, $q$ values (2::bigint, 1) $q$,
	'on revoke the owner rotates the item key: revision 2');
select lives_ok($$ insert into vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select '5a000000-1111-4000-8000-000000000002', 'aaaaaaaa-1111-4000-8000-00000000000a', '0a000000-1111-4000-8000-00000000000a',
	       '1a000000-1111-4000-8000-000000000001', 'bbbbbbbb-1111-4000-8000-00000000000a', 'read', 1, blob, sig from k $$,
	'sharing again is a new row');
select set_config('request.jwt.claims',
	'{"sub":"b0000000-0000-4000-8000-0000000000b2","role":"authenticated","palm_identity":"bbbbbbbb-1111-4000-8000-00000000000a"}', true);
select is((select count(*)::int from vault_items), 1, 'the new share reaches bob again');
select is((select count(*)::int from vault_shares where revoked_at is null), 1, 'through exactly one live share');

-- Rotation, vault key: alice-work rotates its vault key to version 2. A
-- device still holding version 1 is refused rather than publishing an item
-- key wrapped under the key a revoked member may hold.
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000b"}', true);
select results_eq($q$ update vault_vaults set key_version = 2, key_wrap = (select blob from k)
	where id = '0b000000-1111-4000-8000-00000000000b' returning key_version $q$, $q$ values (2) $q$,
	'alice-work rotates its vault key');
select throws_ok($$ select vault_put_item('1b000000-1111-4000-8000-000000000001', 'aaaaaaaa-1111-4000-8000-00000000000b',
	'0b000000-1111-4000-8000-00000000000b', 2, 1, (select w73 from k), (select blob from k)) $$,
	'40001', null, 'a write wrapped under the old vault key is refused as stale');
select results_eq($q$ select revision, key_version from vault_put_item('1b000000-1111-4000-8000-000000000001',
	'aaaaaaaa-1111-4000-8000-00000000000b', '0b000000-1111-4000-8000-00000000000b', 2, 2,
	(select w73 from k), (select blob from k)) $q$, $q$ values (3::bigint, 2) $q$,
	're-wrapped under version 2, the same write goes through');

-- Revoking the vault share between alice's identities.
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000b"}', true);
select results_eq($q$ update vault_shares set revoked_at = now()
	where id = '5b000000-1111-4000-8000-000000000001' returning 1 $q$, $q$ values (1) $q$,
	'alice-work revokes the vault share');
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a2","role":"authenticated","palm_identity":"aaaaaaaa-1111-4000-8000-00000000000a"}', true);
select is((select count(*)::int from vault_items where vault_id = '0b000000-1111-4000-8000-00000000000b'), 0,
	'alice-personal sees nothing of the work vault again');
select throws_ok($$ select vault_put_item('1b000000-1111-4000-8000-000000000001', 'aaaaaaaa-1111-4000-8000-00000000000b',
	'0b000000-1111-4000-8000-00000000000b', 2, 1, 'AAAA', 'AAAA') $$,
	'PT404', null, 'and can no longer write to it');
select is((select count(*)::int from vault_vaults where id = '0b000000-1111-4000-8000-00000000000b'), 0,
	'nor read its metadata');

select * from finish();
rollback;
