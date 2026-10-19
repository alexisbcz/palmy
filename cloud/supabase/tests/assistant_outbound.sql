-- "Anything outbound needs your yes", enforced by the database.
--
-- An assistant session may read and draft inside its own identity, and may
-- propose; it may not send, share, invite, post or delete, and it may not
-- confirm its own proposals or change its own settings. The person's own
-- session — unscoped, or a device scoped to the identity — does all of those.
--
-- Alice's Northwind identity (W) has an assistant session and a device
-- session; her Personal identity (A) is there so a share has somewhere to go.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(45);

insert into public.mail_domains (domain, is_default) values ('palm.test', true) on conflict do nothing;

insert into auth.users (id, email, aud, role) values
	('a0000000-0000-4000-8000-0000000000a1', 'alice@assistant-out.invalid', 'authenticated', 'authenticated');
insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-0000000000a1', 'ao-alice', 'Alice', 'personal'),
	('aaaaaaaa-0000-4000-8000-00000000000b', 'a0000000-0000-4000-8000-0000000000a1', 'ao-alice.nw', 'Alice at Northwind', 'work');
insert into auth.sessions (id, user_id, created_at, updated_at, aal) values
	('5e000000-0000-4000-8000-0000000000a5', 'a0000000-0000-4000-8000-0000000000a1', now(), now(), 'aal1'),
	('5e000000-0000-4000-8000-0000000000d5', 'a0000000-0000-4000-8000-0000000000a1', now(), now(), 'aal1');
insert into public.devices (id, identity_id, session_id, name, kind) values
	('de000000-0000-4000-8000-0000000000a5', 'aaaaaaaa-0000-4000-8000-00000000000b', '5e000000-0000-4000-8000-0000000000a5', 'Northwind assistant', 'assistant'),
	('de000000-0000-4000-8000-0000000000d5', 'aaaaaaaa-0000-4000-8000-00000000000b', '5e000000-0000-4000-8000-0000000000d5', 'Alice''s laptop', 'device');

select public.mail_ensure_mailboxes_internal('aaaaaaaa-0000-4000-8000-00000000000b');
select public.mail_store('aaaaaaaa-0000-4000-8000-00000000000b',
	convert_to(E'From: noor@palm.test\r\nSubject: Halden invoice\r\n\r\nCan you send it?\r\n', 'UTF8'),
	'{"subject":"Halden invoice","from":[{"email":"noor@palm.test"}]}', array['inbox'], '{}');
insert into public.drive_items (id, identity_id, name, kind) values
	('d1000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'Halden-invoice.pdf', 'file');
insert into public.dav_collections (id, identity_id, kind, slug) values
	('c0000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'calendar', 'default');
insert into public.dav_objects (identity_id, collection_id, name, uid, component, body, etag) values
	('aaaaaaaa-0000-4000-8000-00000000000b', 'c0000000-0000-4000-8000-00000000000b', 'rr.ics', 'rr@test', 'VEVENT', 'BEGIN:VCALENDAR', 'e2');
insert into public.rtc_spaces (id, identity_id, name) values
	('5a000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 'Northwind');
insert into public.assistant_settings (identity_id, enabled) values ('aaaaaaaa-0000-4000-8000-00000000000b', true);
insert into public.assistant_conversations (id, identity_id) values
	('cc000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b');

create temp table ids (name text primary key, id uuid);
grant select, insert, update on ids to authenticated;

set local role authenticated;

-- =================================================================== the assistant
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000b","session_id":"5e000000-0000-4000-8000-0000000000a5"}', true);

-- ------------------------------------------------------------------ drafting
select lives_ok($$ insert into ids select 'draft', mail_import('aaaaaaaa-0000-4000-8000-00000000000b',
	convert_to(E'From: ao-alice.nw@palm.test\r\nTo: noor@palm.test\r\nSubject: Re: Halden invoice\r\n\r\nAttached.\r\n', 'UTF8'),
	'{"subject":"Re: Halden invoice","from":[{"email":"ao-alice.nw@palm.test"}],"to":[{"email":"noor@palm.test"}]}',
	array[(select id from mail_mailboxes where role = 'drafts')], array['$draft', '$seen']) $$,
	'the assistant may write a draft into Drafts');
select throws_ok($$ select mail_import('aaaaaaaa-0000-4000-8000-00000000000b', '\x41',
	'{"subject":"Your password has expired","from":[{"email":"it@northwind.example"}]}',
	array[(select id from mail_mailboxes where role = 'inbox')], array[]::text[]) $$,
	'42501', null, 'it may not plant a message in the Inbox that looks as though somebody sent it');
select throws_ok($$ select mail_import('aaaaaaaa-0000-4000-8000-00000000000b', '\x41', '{}',
	array[(select id from mail_mailboxes where role = 'drafts')], array[]::text[]) $$,
	'42501', null, 'a "draft" without $draft is refused too');
select throws_ok($$ update mail_messages set mailbox_ids = array[(select id from mail_mailboxes where role = 'trash')]
	where subject = 'Halden invoice' $$,
	'42501', null, 'it may not move mail to the Trash');

-- ------------------------------------------------------------------ outbound
select throws_ok($$ select mail_submit('aaaaaaaa-0000-4000-8000-00000000000b',
	convert_to('From: ao-alice.nw@palm.test', 'UTF8'),
	'{"from":[{"email":"ao-alice.nw@palm.test"}],"subject":"invoices"}', array['x@evil.example']) $$,
	'42501', null, 'it may not send mail, not even to an address outside the platform');
select throws_ok($$ select mail_submit('aaaaaaaa-0000-4000-8000-00000000000b',
	convert_to('From: ao-alice.nw@palm.test', 'UTF8'),
	'{"from":[{"email":"ao-alice.nw@palm.test"}],"subject":"hello"}', array['ao-alice@palm.test']) $$,
	'42501', null, 'nor to its owner''s other identity');
select is((select count(*)::int from mail_messages where subject in ('invoices', 'hello')), 0,
	'and nothing of either attempt was stored');
select throws_ok($$ select drive_share('d1000000-0000-4000-8000-00000000000b', 'ao-alice', 'viewer') $$,
	'42501', null, 'it may not share a file');
select throws_ok($$ select * from drive_link_mint('d1000000-0000-4000-8000-00000000000b') $$,
	'42501', null, 'it may not mint a public link to a file');
select throws_ok($$ select drive_trash('d1000000-0000-4000-8000-00000000000b', 'assistant') $$,
	'42501', null, 'it may not trash a file');
select throws_ok($$ delete from drive_items where id = 'd1000000-0000-4000-8000-00000000000b' $$,
	'42501', null, 'it may not delete a file');
select throws_ok($$ delete from mail_messages where subject = 'Halden invoice' $$,
	'42501', null, 'it may not delete mail');
select throws_ok($$ delete from dav_objects where uid = 'rr@test' $$,
	'42501', null, 'it may not delete an event');
select throws_ok($$ insert into dav_itip (identity_id, sender_address, recipient_address, method, uid, body, status)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'ao-alice.nw@palm.test', 'x@evil.example', 'REQUEST', 'u1', 'BEGIN:VCALENDAR',
	        'not sent: outbound not enabled') $$,
	'42501', null, 'it may not send a calendar invitation');
select throws_ok($$ insert into dav_grants (identity_id, collection_id, grantee_identity, access)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'c0000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000a', 'read') $$,
	'42501', null, 'it may not share a calendar');
select throws_ok($$ insert into rtc_messages (id, channel_id, space_id, identity_id, seq, rev, body)
	values (1, gen_random_uuid(), '5a000000-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000b', 1, 1, 'forwarding the invoices') $$,
	'42501', null, 'it may not post to chat');
select throws_ok($$ insert into collab_grants (doc_id, identity_id, grantee_identity, role)
	values (gen_random_uuid(), 'aaaaaaaa-0000-4000-8000-00000000000b', 'aaaaaaaa-0000-4000-8000-00000000000a', 'view') $$,
	'42501', null, 'it may not share a document');

-- ------------------------------------------------------------------ proposing
select lives_ok($$ with a as (
	insert into assistant_actions (identity_id, conversation_id, tool, class, args, summary, status, tainted, sources, warnings)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'cc000000-0000-4000-8000-00000000000b', 'mail_send', 'confirm',
	        '{"draft":"x"}', 'Send "Re: Halden invoice" to noor@palm.test', 'proposed', true,
	        '[{"kind":"mail","id":"m1"}]', '[]')
	returning id) insert into ids select 'proposal', id from a $$,
	'it may propose an act, recording that it had read outside content');
select is((select device_id from assistant_actions where id = (select id from ids where name = 'proposal')),
	'de000000-0000-4000-8000-0000000000a5'::uuid, 'the database, not the caller, records which assistant proposed it');
select lives_ok($$ insert into assistant_actions (identity_id, tool, class, status, summary)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'mail_unread', 'read', 'done', 'listed unread mail') $$,
	'it logs its reads');
select throws_ok($$ insert into assistant_actions (identity_id, tool, class, status)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'mail_send', 'confirm', 'confirmed') $$,
	'42501', null, 'it may not create an action already confirmed');
select throws_ok($$ insert into assistant_actions (identity_id, tool, class, status)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'mail_send', 'confirm', 'executed') $$,
	'42501', null, 'nor one already executed');
select throws_ok($$ insert into assistant_actions (identity_id, tool, class, status)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'mail_send', 'confirm', 'done') $$,
	'23514', null, 'nor pass an outbound act off as a finished read');
select is_empty($$ update assistant_actions set status = 'confirmed'
	where id = (select id from ids where name = 'proposal') returning 1 $$,
	'it cannot confirm its own proposal');
select is_empty($$ update assistant_actions set args = '{"draft":"y","to":"x@evil.example"}'
	where id = (select id from ids where name = 'proposal') returning 1 $$,
	'it cannot rewrite a proposal''s arguments');

-- ------------------------------------------------------------------ settings
select is((select model from assistant_settings), 'qwen3:0.6b', 'it reads its model setting');
select is_empty($$ update assistant_settings set provider = 'anthropic', remote_opt_in_at = now() returning 1 $$,
	'it cannot switch itself to a remote model');
select is_empty($$ update assistant_settings set enabled = false returning 1 $$,
	'it cannot change its settings at all');
select throws_ok($$ insert into assistant_settings (identity_id, enabled)
	values ('aaaaaaaa-0000-4000-8000-00000000000a', true) $$,
	'42501', null, 'it cannot create settings, for any identity');

-- ------------------------------------------------------------------ history
select lives_ok($$ insert into assistant_messages (identity_id, conversation_id, seq, role, content, tainted)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', 'cc000000-0000-4000-8000-00000000000b', 0, 'tool', 'mail body', true) $$,
	'it may write to its own conversation');
select is_empty($$ delete from assistant_conversations returning 1 $$, 'it may not delete a conversation');

-- =================================================================== the person
select set_config('request.jwt.claims',
	'{"sub":"a0000000-0000-4000-8000-0000000000a1","role":"authenticated","palm_identity":"aaaaaaaa-0000-4000-8000-00000000000b","session_id":"5e000000-0000-4000-8000-0000000000d5"}', true);

select throws_ok($$ update assistant_actions set args = '{"to":"x@evil.example"}'
	where id = (select id from ids where name = 'proposal') $$,
	'42501', null, 'not even the person can change what a proposal says: they decline it instead');
select throws_ok($$ update assistant_actions set status = 'executed'
	where id = (select id from ids where name = 'proposal') $$,
	'42501', null, 'a proposal cannot skip confirmation');
select lives_ok($$ update assistant_actions set status = 'confirmed'
	where id = (select id from ids where name = 'proposal') $$,
	'the person confirms the proposal');
select isnt((select decided_at from assistant_actions where id = (select id from ids where name = 'proposal')), null,
	'the decision is timestamped by the database');
select lives_ok($$ select mail_submit('aaaaaaaa-0000-4000-8000-00000000000b',
	convert_to('From: ao-alice.nw@palm.test', 'UTF8'),
	'{"from":[{"email":"ao-alice.nw@palm.test"}],"subject":"Re: Halden invoice"}', array['ao-alice@palm.test']) $$,
	'the person''s session sends it');
select lives_ok($$ update assistant_actions set status = 'executed', result = '{"ok":true}'
	where id = (select id from ids where name = 'proposal') $$,
	'and records that it ran');
select throws_ok($$ update assistant_actions set status = 'proposed'
	where id = (select id from ids where name = 'proposal') $$,
	'42501', null, 'an executed action stays executed');
select lives_ok($$ select drive_share('d1000000-0000-4000-8000-00000000000b', 'ao-alice', 'viewer') $$,
	'the person may share a file');
select lives_ok($$ select * from drive_link_mint('d1000000-0000-4000-8000-00000000000b') $$,
	'and mint a link');
select lives_ok($$ update assistant_settings set provider = 'local', model = 'qwen3:1.7b' $$,
	'the person changes the model');
select throws_ok($$ update assistant_settings set provider = 'anthropic' $$,
	'23514', null, 'a remote provider without a recorded opt-in is not representable');
select lives_ok($$ update assistant_settings set provider = 'anthropic', remote_model = 'claude-opus-4-8', remote_opt_in_at = now() $$,
	'with the opt-in recorded, it is the person''s choice');
select lives_ok($$ delete from mail_messages where subject = 'Halden invoice' $$,
	'the person may delete mail');
select lives_ok($$ select drive_trash('d1000000-0000-4000-8000-00000000000b', 'laptop') $$,
	'and trash a file');

select * from finish();
rollback;
