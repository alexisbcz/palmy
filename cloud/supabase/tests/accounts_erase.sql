-- Deleting a person deletes them everywhere. One auth user with two
-- identities owns data in every area (accounts, mail, drive, dav, notes,
-- collab, vault, rtc, forge, browser, notify, assistant), shares with a second
-- person and is shared with. Deleting the auth user (what GoTrue's admin
-- delete does) must succeed, leave no row anywhere that names either of
-- the identities, and leave the other person's own data where it was.
--
-- Each area's foreign keys and triggers decide what a deletion means there;
-- this file only holds them to "it works and nothing is left over".
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(19);

insert into public.mail_domains (domain, is_default) values ('palm.test', true) on conflict do nothing;
insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000e1', 'alice@erase.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-0000000000e2', 'bob@erase.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000ea', 'a0000000-0000-4000-8000-0000000000e1', 'erase-alice',      'Alice',        'personal'),
	('aaaaaaaa-0000-4000-8000-0000000000eb', 'a0000000-0000-4000-8000-0000000000e1', 'erase-alice.work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-4000-8000-0000000000ea', 'b0000000-0000-4000-8000-0000000000e2', 'erase-bob',        'Bob',          'personal');
create temp table ids (k text primary key, v uuid);
insert into ids values ('a','aaaaaaaa-0000-4000-8000-0000000000ea'),('w','aaaaaaaa-0000-4000-8000-0000000000eb'),('b','bbbbbbbb-0000-4000-8000-0000000000ea');
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where ids.k = $1 $$;

-- ---------------------------------------------------------------------------
-- Fixtures, as the migration role (and as each person where an area's
-- functions insist on it)
-- ---------------------------------------------------------------------------

-- accounts
insert into auth.sessions (id, user_id, created_at, updated_at, aal) values
	('5e000000-0000-4000-8000-0000000000e1', 'a0000000-0000-4000-8000-0000000000e1', now(), now(), 'aal1');
insert into public.devices (identity_id, session_id, name, kind) values
	(pg_temp.id('a'), '5e000000-0000-4000-8000-0000000000e1', 'laptop', 'device');
-- mail: delivered both ways, submitted
select public.mail_deliver(convert_to(E'From: x@e.test\r\n\r\nhi\r\n','UTF8'),'{"subject":"hi","messageId":"erase1@e"}',
	array['erase-alice@palm.test','erase-alice.work@palm.test','erase-bob@palm.test']);
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-0000000000e1','role','authenticated')::text, true);
select public.mail_submit(pg_temp.id('a'), convert_to('From: erase-alice@palm.test','UTF8'),
	'{"from":[{"email":"erase-alice@palm.test"}],"subject":"a"}', array['erase-bob@palm.test','friend@example.com']);
select set_config('request.jwt.claims', '', true);
-- drive
insert into public.drive_items (id, identity_id, parent_id, name, kind) values
	('d1000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), null, 'Reports', 'folder'),
	('d1000000-0000-4000-8000-0000000000e2', pg_temp.id('a'), 'd1000000-0000-4000-8000-0000000000e1', 'q3.txt', 'file'),
	('d1000000-0000-4000-8000-0000000000e3', pg_temp.id('b'), null, 'Bob plans', 'folder');
insert into public.drive_versions (identity_id, item_id, size, content_hash, chunk_size, chunks)
	values (pg_temp.id('a'), 'd1000000-0000-4000-8000-0000000000e2', 1, repeat('a',64), 4194304, array[repeat('a',64)]);
insert into public.drive_shares (identity_id, item_id, grantee_identity) values
	(pg_temp.id('a'), 'd1000000-0000-4000-8000-0000000000e1', pg_temp.id('b')),
	(pg_temp.id('b'), 'd1000000-0000-4000-8000-0000000000e3', pg_temp.id('a'));
insert into public.drive_links (identity_id, item_id, token_hash) values (pg_temp.id('a'), 'd1000000-0000-4000-8000-0000000000e1', 'h1');
-- dav: a calendar with an event, shared with Bob; Bob's shared to Alice
insert into public.dav_collections (id, identity_id, kind, slug) values
	('dc000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'calendar', 'home'),
	('dc000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), 'calendar', 'bobs');
insert into public.dav_objects (identity_id, collection_id, name, uid, component, body, etag) values
	(pg_temp.id('a'), 'dc000000-0000-4000-8000-0000000000e1', 'x.ics', 'x', 'VEVENT', 'x', 'e1'),
	(pg_temp.id('b'), 'dc000000-0000-4000-8000-0000000000e2', 'y.ics', 'y', 'VEVENT', 'y', 'e2');
insert into public.dav_grants (identity_id, collection_id, grantee_identity, access) values
	(pg_temp.id('a'), 'dc000000-0000-4000-8000-0000000000e1', pg_temp.id('b'), 'read'),
	(pg_temp.id('b'), 'dc000000-0000-4000-8000-0000000000e2', pg_temp.id('a'), 'read');
insert into public.dav_itip (identity_id, sender_address, recipient_address, method, uid, body)
	values (pg_temp.id('a'), 'mailto:erase-alice@palm.test', 'mailto:erase-bob@palm.test', 'REQUEST', 'x', 'x');
insert into public.dav_app_passwords (identity_id, token_hash, prefix) values (pg_temp.id('a'), 'h', 'p');
-- notes
select set_config('request.jwt.claims', json_build_object('sub','b0000000-0000-4000-8000-0000000000e2','role','authenticated')::text, true);
select public.notes_create('e0000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), 'bob');
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-0000000000e1','role','authenticated')::text, true);
select public.notes_create('e0000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'diary');
select set_config('request.jwt.claims', '', true);
insert into public.note_attachments (note_id, identity_id, sha256, name, size)
	values ('e0000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), repeat('b',64), 'a.png', 1);
select set_config('request.jwt.claims', json_build_object('sub','a0000000-0000-4000-8000-0000000000e1','role','authenticated')::text, true);
select public.notes_carry('e0000000-0000-4000-8000-0000000000e1', 'erase-alice.work', 'e0000000-0000-4000-8000-0000000000e3', repeat('c',64), 'diary');
select set_config('request.jwt.claims', '', true);
-- collab
insert into public.collab_documents (id, identity_id, kind, title) values
	('cd000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'doc', 'plan'),
	('cd000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), 'doc', 'bob');
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.collab_append('cd000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'a0000000-0000-4000-8000-0000000000e1', 'a1', 'VQEA');
insert into public.collab_grants (doc_id, identity_id, grantee_identity, role) values
	('cd000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), pg_temp.id('b'), 'edit'),
	('cd000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), pg_temp.id('a'), 'edit');
select public.collab_append('cd000000-0000-4000-8000-0000000000e2', pg_temp.id('a'), 'a0000000-0000-4000-8000-0000000000e1', 'a2', 'VQEA');
select set_config('request.jwt.claims', '', true);
insert into public.collab_links (doc_id, identity_id, token_hash, role) values ('cd000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'h', 'view');
-- vault
create temp table k as select
	encode(gen_random_bytes(32), 'base64') as k32,
	replace(encode(gen_random_bytes(592) || gen_random_bytes(592), 'base64'), E'\n', '') as k1184,
	encode(gen_random_bytes(16), 'base64') as salt,
	replace(encode(gen_random_bytes(73), 'base64'), E'\n', '') as w73,
	replace(encode(gen_random_bytes(169), 'base64'), E'\n', '') as w169,
	replace(encode(gen_random_bytes(600), 'base64'), E'\n', '') as blob,
	replace(encode(gen_random_bytes(64), 'base64'), E'\n', '') as sig;
insert into public.vault_keysets (identity_id, enc_pub, kem_pub, sign_pub, kdf_salt, kdf_m, kdf_t, kdf_p, account_key_wrap, private_wrap)
	select v, k32, k1184, k32, salt, 262144, 3, 4, w73, w169 from k, ids;
insert into public.vault_vaults (id, identity_id, key_wrap, meta) select '0a000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), blob, blob from k;
insert into public.vault_vaults (id, identity_id, key_wrap, meta) select '0a000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), blob, blob from k;
insert into public.vault_items (id, identity_id, vault_id, revision, key_wrap, blob)
	select '1a000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), '0a000000-0000-4000-8000-0000000000e1', 1, w73, blob from k;
insert into public.vault_devices (id, identity_id, name, pub) select 'd0000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'laptop', k32 from k;
insert into public.vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select '5a000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), '0a000000-0000-4000-8000-0000000000e1', null, pg_temp.id('b'), 'read', 1, blob, sig from k;
insert into public.vault_shares (id, identity_id, vault_id, item_id, grantee_identity, role, key_version, wrapped_key, signature)
	select '5a000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), '0a000000-0000-4000-8000-0000000000e2', null, pg_temp.id('a'), 'read', 1, blob, sig from k;
-- rtc: Alice's work identity owns a space Bob is in; Bob's space has Alice in it
create function pg_temp.become(uid text, ident text default null) returns void
language plpgsql as $$
begin
	perform set_config('request.jwt.claims', json_strip_nulls(json_build_object(
		'sub', uid, 'role', 'authenticated', 'palm_identity', ident))::text, true);
	set local role authenticated;
end
$$;
grant execute on function pg_temp.become(text, text) to public;
grant all on ids to public;
grant execute on function pg_temp.id(text) to public;
select pg_temp.become('a0000000-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000eb');
insert into public.rtc_spaces (id, identity_id, name) values ('5c000000-0000-4000-8000-0000000000e1', pg_temp.id('w'), 'Northwind');
insert into public.rtc_messages (channel_id, identity_id, body)
	select id, pg_temp.id('w'), 'welcome' from public.rtc_channels where space_id = '5c000000-0000-4000-8000-0000000000e1' and name = 'general';
insert into public.rtc_invites (space_id, identity_id, invitee_handle, role)
	values ('5c000000-0000-4000-8000-0000000000e1', pg_temp.id('w'), 'erase-bob', 'member');
reset role;
select pg_temp.become('b0000000-0000-4000-8000-0000000000e2', 'bbbbbbbb-0000-4000-8000-0000000000ea');
insert into public.rtc_spaces (id, identity_id, name) values ('5c000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), 'Bobs');
select public.rtc_accept_invite((select id from public.rtc_invites where invitee_handle = 'erase-bob'));
insert into public.rtc_messages (channel_id, identity_id, body)
	select id, pg_temp.id('b'), 'hi from bob' from public.rtc_channels where space_id = '5c000000-0000-4000-8000-0000000000e1' and name = 'general';
insert into public.rtc_invites (space_id, identity_id, invitee_handle, role)
	values ('5c000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), 'erase-alice', 'member');
reset role;
select pg_temp.become('a0000000-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000ea');
select public.rtc_accept_invite((select id from public.rtc_invites where invitee_handle = 'erase-alice'));
insert into public.rtc_messages (channel_id, identity_id, body)
	select id, pg_temp.id('a'), 'hi from alice' from public.rtc_channels where space_id = '5c000000-0000-4000-8000-0000000000e2' and name = 'general';
insert into public.rtc_reactions (message_id, identity_id, key)
	select m.id, pg_temp.id('a'), '+1' from public.rtc_messages m where m.body = 'hi from bob';
reset role;
-- forge: Alice's public repo with an issue Bob commented on; Bob's repo Alice collaborates on
insert into public.forge_repos (id, identity_id, name, visibility) values
	('f0000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'site', 'public'),
	('f0000000-0000-4000-8000-0000000000e2', pg_temp.id('b'), 'tool', 'public');
insert into public.forge_issues (id, repo_id, author_identity_id, title) values
	('f1000000-0000-4000-8000-0000000000e1', 'f0000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'alice bug'),
	('f1000000-0000-4000-8000-0000000000e2', 'f0000000-0000-4000-8000-0000000000e2', pg_temp.id('a'), 'alice files on bob');
insert into public.forge_comments (repo_id, issue_id, author_identity_id, body) values
	('f0000000-0000-4000-8000-0000000000e1', 'f1000000-0000-4000-8000-0000000000e1', pg_temp.id('b'), 'bob was here'),
	('f0000000-0000-4000-8000-0000000000e2', 'f1000000-0000-4000-8000-0000000000e2', pg_temp.id('a'), 'alice was here');
insert into public.forge_collaborators (repo_id, grantee_identity_id, role) values
	('f0000000-0000-4000-8000-0000000000e2', pg_temp.id('a'), 'write'),
	('f0000000-0000-4000-8000-0000000000e1', pg_temp.id('b'), 'write');
insert into public.forge_tokens (identity_id, name, token_hash, prefix, scope) values (pg_temp.id('a'), 't', 'h', 'p', 'read');
-- browser
insert into public.browser_bookmarks (identity_id, id, content_clock, place_clock, life_clock, title, url)
	values (pg_temp.id('a'), 'b1000000-0000-4000-8000-0000000000e1', '1770000000000-0000-dev1', '1770000000000-0000-dev1', '1770000000000-0000-dev1', 'x', 'https://x.test');
-- notify
insert into public.devices (id, identity_id, name) values ('dddddddd-0000-4000-8000-0000000000e1', pg_temp.id('w'), 'phone');
insert into public.notify_state (identity_id, key, state, device_id) values (pg_temp.id('w'), 'mail:<x>', 'shown', 'dddddddd-0000-4000-8000-0000000000e1');
insert into public.notify_presence (identity_id, device_id) values (pg_temp.id('w'), 'dddddddd-0000-4000-8000-0000000000e1');
-- assistant
insert into public.assistant_settings (identity_id, enabled) values (pg_temp.id('a'), true);
insert into public.assistant_conversations (id, identity_id, title) values ('a5000000-0000-4000-8000-0000000000e1', pg_temp.id('a'), 'c');
insert into public.assistant_messages (identity_id, conversation_id, seq, role, content) values (pg_temp.id('a'), 'a5000000-0000-4000-8000-0000000000e1', 0, 'user', 'hi');
insert into public.assistant_actions (identity_id, conversation_id, tool, class, status) values (pg_temp.id('a'), 'a5000000-0000-4000-8000-0000000000e1', 'mail_search', 'read', 'done');
-- profiles
insert into public.profiles (identity_id, bio) values (pg_temp.id('a'), 'hi') on conflict (identity_id) do update set bio = 'hi';

-- Every row in public that names an identity, through any foreign key to
-- public.identities: (table, column) pairs with a row naming Alice's.
create function pg_temp.naming_alice() returns text[] language plpgsql as $f$
declare
	r record;
	n bigint;
	found text[] := '{}';
begin
	for r in
		select c.conrelid::regclass::text as tbl, a.attname as col
		from pg_constraint c
		join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
		where c.contype = 'f' and c.confrelid = 'public.identities'::regclass
		order by 1, 2
	loop
		execute format('select count(*) from %s where %I in (%L::uuid, %L::uuid)', r.tbl, r.col,
			'aaaaaaaa-0000-4000-8000-0000000000ea', 'aaaaaaaa-0000-4000-8000-0000000000eb') into n;
		if n > 0 then found := found || (r.tbl || '.' || r.col); end if;
	end loop;
	return found;
end
$f$;

select ok(array_length(pg_temp.naming_alice(), 1) >= 12, 'before: Alice''s identities are named across the areas');

-- What the delete may do, a plain update may not: the guards that let the
-- foreign keys unlink an author still refuse anyone else.
select throws_ok($$ update public.forge_issues set author_identity_id = null where title = 'alice bug' $$,
	'42501', 'that column is fixed once an issue exists', 'forge: an issue cannot be un-attributed by an update');
select throws_ok($$ update public.rtc_messages set identity_id = null where body = 'hi from alice' $$,
	'42501', 'only the body of a message can be changed', 'rtc: a message cannot be un-attributed by an update');

-- ---------------------------------------------------------------------------
-- The delete
-- ---------------------------------------------------------------------------

select lives_ok($$ delete from auth.users where id = 'a0000000-0000-4000-8000-0000000000e1' $$,
	'deleting a person who has data in every area succeeds');
select is((select count(*) from public.identities where owner = 'a0000000-0000-4000-8000-0000000000e1'), 0::bigint,
	'their identities are gone');
select is(pg_temp.naming_alice(), '{}'::text[], 'no row anywhere still names one of their identities');
select is((select count(*) from auth.sessions where user_id = 'a0000000-0000-4000-8000-0000000000e1'), 0::bigint,
	'their sessions are gone');

-- ---------------------------------------------------------------------------
-- Bob's own data stays
-- ---------------------------------------------------------------------------

select is((select count(*) from public.mail_messages where identity_id = pg_temp.id('b')), 2::bigint,
	'mail: Bob keeps his mail, including what Alice sent him');
select ok((select count(*) from public.mail_changes where identity_id = pg_temp.id('b')) > 0,
	'mail: Bob''s change log is intact');
select is((select count(*) from public.drive_items where identity_id = pg_temp.id('b')), 1::bigint,
	'drive: Bob keeps his folder (only the share to Alice went)');
select is((select count(*) from public.dav_objects where identity_id = pg_temp.id('b')), 1::bigint,
	'dav: Bob keeps his calendar and its event');
select is((select count(*) from public.notes where identity_id = pg_temp.id('b')), 1::bigint,
	'notes: Bob keeps his note');
select is((select head_seq from public.collab_documents where id = 'cd000000-0000-4000-8000-0000000000e2'), 1::bigint,
	'collab: Bob keeps his document, with the update Alice made to it');
select is((select count(*) from public.vault_vaults where identity_id = pg_temp.id('b')), 1::bigint,
	'vault: Bob keeps his vault');
select is((select count(*) from public.rtc_spaces where identity_id = pg_temp.id('b')), 1::bigint,
	'rtc: Bob keeps his space; Alice''s own space is gone with her');
select is((select author_name || ':' || coalesce(identity_id::text, 'unlinked') from public.rtc_messages where body = 'hi from alice'),
	'Alice:unlinked', 'rtc: Alice''s message in Bob''s space keeps her name and loses the link');
select is((select count(*) from public.rtc_members where space_id = '5c000000-0000-4000-8000-0000000000e2'), 1::bigint,
	'rtc: Bob is the only member of his space left');
select is((select coalesce(author_identity_id::text, 'unlinked') from public.forge_issues where title = 'alice files on bob'),
	'unlinked', 'forge: Alice''s issue on Bob''s repository stays, unattributed');
select is((select count(*) from public.forge_comments where body = 'alice was here' and author_identity_id is null), 1::bigint,
	'forge: and so does her comment');

select * from finish();
rollback;
