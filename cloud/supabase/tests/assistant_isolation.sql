-- The README's promise, as an assertion that runs: an assistant scoped to one
-- identity, asked for another identity's mail, files, events, notes or
-- conversations, gets nothing — and writing them fails.
--
-- The sharp case is the same person's other identity. Alice owns Personal (A)
-- and Northwind (W). Her Northwind assistant holds a session delegated by
-- mint_scoped_session with kind 'assistant'; only the scope in its token
-- separates it from Personal. Bob (B) is a stranger, for completeness.
--
-- Notes are local Markdown files today, not a table; their isolation is the
-- sandbox's job and cloud/assistant/e2e.sh asserts it. This file covers every
-- table the assistant's tools read through.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(50);

insert into public.mail_domains (domain, is_default) values ('palm.test', true) on conflict do nothing;

insert into auth.users (id, email, aud, role) values
	('a0000000-0000-4000-8000-0000000000a1', 'alice@assistant-test.invalid', 'authenticated', 'authenticated'),
	('b0000000-0000-4000-8000-0000000000b1', 'bob@assistant-test.invalid', 'authenticated', 'authenticated');
insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-0000000000a1', 'as-alice', 'Alice', 'personal'),
	('aaaaaaaa-0000-4000-8000-00000000000b', 'a0000000-0000-4000-8000-0000000000a1', 'as-alice.nw', 'Alice at Northwind', 'work'),
	('bbbbbbbb-0000-4000-8000-00000000000a', 'b0000000-0000-4000-8000-0000000000b1', 'as-bob', 'Bob', 'personal');

-- Northwind's assistant session and Northwind's own device session, exactly
-- as mint_scoped_session leaves them.
insert into auth.sessions (id, user_id, created_at, updated_at, aal) values
	('5e000000-0000-4000-8000-0000000000a5', 'a0000000-0000-4000-8000-0000000000a1', now(), now(), 'aal1'),
	('5e000000-0000-4000-8000-0000000000d5', 'a0000000-0000-4000-8000-0000000000a1', now(), now(), 'aal1');
insert into public.devices (id, identity_id, session_id, name, kind) values
	('de000000-0000-4000-8000-0000000000a5', 'aaaaaaaa-0000-4000-8000-00000000000b', '5e000000-0000-4000-8000-0000000000a5', 'Northwind assistant', 'assistant'),
	('de000000-0000-4000-8000-0000000000d5', 'aaaaaaaa-0000-4000-8000-00000000000b', '5e000000-0000-4000-8000-0000000000d5', 'Alice''s laptop', 'device');

-- Mail in every identity. The personal one carries a canary the assistant
-- must never see.
select public.mail_store('aaaaaaaa-0000-4000-8000-00000000000a',
	convert_to(E'From: mum@example.test\r\nSubject: Sunday\r\n\r\nPERSONAL-CANARY-7731\r\n', 'UTF8'),
	'{"subject":"Sunday dinner PERSONAL-CANARY-7731","from":[{"email":"mum@example.test"}],"preview":"PERSONAL-CANARY-7731"}',
	array['inbox'], '{}');
select public.mail_store('aaaaaaaa-0000-4000-8000-00000000000b',
	convert_to(E'From: noor@palm.test\r\nSubject: Halden invoice\r\n\r\nCan you send it?\r\n', 'UTF8'),
	'{"subject":"Halden invoice","from":[{"email":"noor@palm.test"}],"preview":"Can you send it?"}',
	array['inbox'], '{}');
select public.mail_store('bbbbbbbb-0000-4000-8000-00000000000a',
	convert_to(E'From: x@example.test\r\nSubject: Bob\r\n\r\nBOB-CANARY\r\n', 'UTF8'),
	'{"subject":"BOB-CANARY","from":[{"email":"x@example.test"}]}', array['inbox'], '{}');

-- Files.
insert into public.drive_items (id, identity_id, name, kind) values
	('d1000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-00000000000a', 'tax-return-PERSONAL-CANARY.pdf', 'file'),
	('d1000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'Halden-invoice.pdf', 'file'),
	('d1000000-0000-4000-8000-0000000000bb', 'bbbbbbbb-0000-4000-8000-00000000000a', 'bob.txt', 'file');

-- Events.
insert into public.dav_collections (id, identity_id, kind, slug) values
	('c0000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-00000000000a', 'calendar', 'default'),
	('c0000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'calendar', 'default');
insert into public.dav_objects (identity_id, collection_id, name, uid, component, body, etag, summary) values
	('aaaaaaaa-0000-4000-8000-00000000000a', 'c0000000-0000-4000-8000-00000000000a', 'gp.ics', 'gp@test', 'VEVENT', 'BEGIN:VCALENDAR', 'e1', 'GP appointment PERSONAL-CANARY'),
	('aaaaaaaa-0000-4000-8000-00000000000b', 'c0000000-0000-4000-8000-00000000000b', 'rr.ics', 'rr@test', 'VEVENT', 'BEGIN:VCALENDAR', 'e2', 'Roadmap review');

-- Notes (the notes area's cloud tables): a note is a collab document.
insert into public.collab_documents (id, identity_id, kind, title) values
	('d0c00000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-00000000000a', 'doc', 'Diary PERSONAL-CANARY'),
	('d0c00000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'doc', 'Q4 roadmap');
insert into public.notes (id, identity_id, title) values
	('d0c00000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-00000000000a', 'Diary PERSONAL-CANARY'),
	('d0c00000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'Q4 roadmap');

-- The assistant's own history, in both identities.
insert into public.assistant_settings (identity_id, enabled) values
	('aaaaaaaa-0000-4000-8000-00000000000a', true), ('aaaaaaaa-0000-4000-8000-00000000000b', true);
insert into public.assistant_conversations (id, identity_id, title) values
	('cc000000-0000-4000-8000-00000000000a', 'aaaaaaaa-0000-4000-8000-00000000000a', 'Personal chat'),
	('cc000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'Northwind chat');
insert into public.assistant_messages (identity_id, conversation_id, seq, role, content) values
	('aaaaaaaa-0000-4000-8000-00000000000a', 'cc000000-0000-4000-8000-00000000000a', 0, 'user', 'remind me PERSONAL-CANARY'),
	('aaaaaaaa-0000-4000-8000-00000000000b', 'cc000000-0000-4000-8000-00000000000b', 0, 'user', 'summarise my mail');
insert into public.assistant_actions (identity_id, tool, class, status, summary) values
	('aaaaaaaa-0000-4000-8000-00000000000a', 'mail_read', 'read', 'done', 'read PERSONAL-CANARY');

set local role authenticated;

-- ------------------------------------------------- the Northwind assistant
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000b","session_id":"5e000000-0000-4000-8000-0000000000a5"}', true);

select ok(public.assistant_session(), 'the delegated session is recognised as an assistant''s');
select is((select array_agg(handle) from identities), array['as-alice.nw'],
	'the assistant sees one identity, its own; it cannot learn that Personal exists');

-- It sees its own data, so the zeros below mean something.
select is((select count(*)::int from mail_messages), 1, 'the assistant sees Northwind''s one message');
select is((select count(*)::int from drive_items), 1, 'the assistant sees Northwind''s one file');
select is((select count(*)::int from dav_objects), 1, 'the assistant sees Northwind''s one event');
select is((select count(*)::int from assistant_conversations), 1, 'the assistant sees Northwind''s conversation');

-- Asked for Personal's, by every route a tool has.
select is((select count(*)::int from mail_messages where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'), 0,
	'Personal''s mail, asked for by identity: nothing');
select is((select count(*)::int from mail_messages where search like '%personal-canary%'), 0,
	'Personal''s mail, searched for by its content: nothing');
select is((select count(*)::int from mail_blobs where convert_from(raw, 'UTF8') like '%PERSONAL-CANARY%'), 0,
	'Personal''s raw message bytes: nothing');
select is((select count(*)::int from mail_mailboxes where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'), 0,
	'Personal''s mailboxes: nothing');
select is((select count(*)::int from mail_mailbox_counts('aaaaaaaa-0000-4000-8000-00000000000a')), 0,
	'Personal''s unread counts: nothing, not even zeros');
select is((select count(*)::int from mail_identities()), 1, 'mail_identities() lists Northwind alone');
select is((select count(*)::int from drive_items where id = 'd1000000-0000-4000-8000-00000000000a'), 0,
	'Personal''s file, asked for by id: nothing');
select is((select count(*)::int from drive_items where name like '%PERSONAL-CANARY%'), 0,
	'Personal''s file, searched for by name: nothing');
select is((select row(stored_bytes, quota_bytes, files)::text from drive_usage('aaaaaaaa-0000-4000-8000-00000000000a')), '(,,0)',
	'Personal''s drive usage: an empty row (no bytes, no quota, no files)');
select is((select count(*)::int from dav_objects where summary like '%PERSONAL-CANARY%'), 0,
	'Personal''s events, searched for: nothing');
select is((select count(*)::int from dav_collections where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'), 0,
	'Personal''s calendars: nothing');
select is((select count(*)::int from notes), 1, 'notes: the assistant sees Northwind''s one note');
select is((select count(*)::int from notes where title like '%PERSONAL-CANARY%'), 0, 'notes: Personal''s diary, searched for by title: nothing');
select is((select count(*)::int from collab_documents where id = 'd0c00000-0000-4000-8000-00000000000a'), 0,
	'notes: Personal''s note document, asked for by id: nothing');
select throws_ok($$ insert into note_carries (carry_id, identity_id, direction, note_id, peer_identity, peer_handle, peer_name, peer_note, content_hash)
	values (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000b', 'out', 'd0c00000-0000-4000-8000-00000000000b',
	        'aaaaaaaa-0000-4000-8000-00000000000a', 'as-alice', 'Alice', gen_random_uuid(), repeat('0', 64)) $$,
	'42501', null, 'notes: the assistant cannot carry a Northwind note into Personal');
select is((select count(*)::int from assistant_conversations where id = 'cc000000-0000-4000-8000-00000000000a'), 0,
	'the Personal assistant''s conversation, asked for by id: nothing');
select is((select count(*)::int from assistant_messages where content like '%PERSONAL-CANARY%'), 0,
	'the Personal assistant''s messages: nothing');
select is((select count(*)::int from assistant_actions), 0,
	'the Personal assistant''s action log: nothing (and Northwind has none yet)');
select is((select count(*)::int from assistant_settings), 1, 'the assistant reads Northwind''s settings only');
select is((select count(*)::int from devices where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'), 0,
	'Personal''s devices: nothing');
select is((select count(*)::int from mail_messages where identity_id = 'bbbbbbbb-0000-4000-8000-00000000000a'), 0,
	'Bob''s mail: nothing');
select is((select count(*)::int from drive_items where identity_id = 'bbbbbbbb-0000-4000-8000-00000000000a'), 0,
	'Bob''s files: nothing');

-- Writing into Personal fails.
select throws_ok($$ select mail_import('aaaaaaaa-0000-4000-8000-00000000000a', '\x41', '{}',
	array[(select id from mail_mailboxes limit 1)], array['$draft']) $$,
	'42501', null, 'a draft into Personal''s mailbox is refused');
select throws_ok($$ insert into drive_items (identity_id, name, kind)
	values ('aaaaaaaa-0000-4000-8000-00000000000a', 'planted.txt', 'file') $$,
	'42501', null, 'planting a file in Personal''s drive is refused');
select throws_ok($$ insert into assistant_messages (identity_id, conversation_id, seq, role, content)
	values ('aaaaaaaa-0000-4000-8000-00000000000a', 'cc000000-0000-4000-8000-00000000000a', 1, 'assistant', 'hi') $$,
	'42501', null, 'writing into the Personal assistant''s conversation is refused');
select throws_ok($$ insert into assistant_messages (identity_id, conversation_id, seq, role, content)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'cc000000-0000-4000-8000-00000000000a', 1, 'assistant', 'hi') $$,
	'23503', null, 'a Northwind message cannot point at a Personal conversation either');
select throws_ok($$ insert into assistant_actions (identity_id, tool, class, status)
	values ('aaaaaaaa-0000-4000-8000-00000000000a', 'mail_read', 'read', 'done') $$,
	'42501', null, 'writing into the Personal action log is refused');
select is_empty($$ update assistant_settings set enabled = false
	where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a' returning 1 $$,
	'switching off the Personal assistant touches nothing');

-- And it cannot widen its own scope.
select throws_ok($$ select mint_scoped_session('aaaaaaaa-0000-4000-8000-00000000000a', 'escape', 'device', null) $$,
	'42501', null, 'the assistant cannot mint itself a session for Personal');
select throws_ok($$ select mint_scoped_session('aaaaaaaa-0000-4000-8000-00000000000b', 'copy', 'device', null) $$,
	'42501', null, 'nor copy its own scope into an unscoped-looking device session');
select throws_ok($$ select create_identity('as-escape', 'Escape', 'personal', 'red') $$,
	'42501', null, 'nor create an identity');
select is_empty($$ update devices set kind = 'device' where id = 'de000000-0000-4000-8000-0000000000a5' returning 1 $$,
	'nor turn its own device row into an ordinary device');
select is_empty($$ update identities set archived_at = now() where id = 'aaaaaaaa-0000-4000-8000-00000000000a' returning 1 $$,
	'nor archive Personal');
select is((select count(*)::int from vault_items), 0, 'and the vault stays closed to it, as before');

-- ------------------------------------------------- Northwind's own device
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000b","session_id":"5e000000-0000-4000-8000-0000000000d5"}', true);
select ok(not public.assistant_session(), 'a device session for the same identity is not an assistant''s');
select is((select count(*)::int from mail_messages where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'), 0,
	'the device scoped to Northwind sees none of Personal''s mail either: the scope is the contract''s, not the assistant''s');

-- ------------------------------------------------- the person, unscoped
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
select is((select count(*)::int from assistant_conversations), 2, 'the person sees both identities'' conversations');
select is((select count(*)::int from assistant_actions), 1, 'the person sees both identities'' action logs');
select is((select count(*)::int from mail_messages where search like '%personal-canary%'), 1,
	'the person can of course read Personal''s mail: the canary is real');

-- ------------------------------------------------- the Personal scope, from the other side
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000a"}', true);
select is((select count(*)::int from assistant_conversations where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000b'), 0,
	'scoped to Personal: Northwind''s conversations are invisible');
select is((select count(*)::int from mail_messages where subject = 'Halden invoice'), 0,
	'scoped to Personal: Northwind''s mail is invisible');

-- ------------------------------------------------- Bob
select set_config('request.jwt.claims', '{"sub":"b0000000-0000-4000-8000-0000000000b1","role":"authenticated"}', true);
select is((select count(*)::int from assistant_conversations), 0, 'Bob sees none of Alice''s conversations');
select is((select count(*)::int from assistant_settings), 0, 'Bob sees none of Alice''s assistant settings');
select throws_ok($$ insert into assistant_conversations (identity_id, title)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'mine now') $$,
	'42501', null, 'Bob cannot start a conversation in Alice''s Northwind identity');

select * from finish();
rollback;
