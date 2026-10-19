-- The test the mail area is held to (cloud/CONTRACT.md): a session scoped to
-- identity A, asking for identity B's mail, gets nothing, and writing it fails.
--
-- Three identities: Alice's personal (A) and work (W) identities, and Bob's
-- (B). W is the sharper case: the same person owns it, so only the scope in
-- the token separates it from A.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(48);

-- ---------------------------------------------------------------------------
-- Fixtures, as the migration role
-- ---------------------------------------------------------------------------

insert into public.mail_domains (domain, is_default) values ('palm.test', true) on conflict do nothing;

insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-000000000001', 'alice@example.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-000000000002', 'bob@example.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'alice-t',      'Alice',        'personal'),
	('aaaaaaaa-0000-4000-8000-00000000000b', 'a0000000-0000-4000-8000-000000000001', 'alice-t.work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-000000000002', 'bob-t',        'Bob',          'personal');

-- One message into each identity over the MX path.
select is(
	(select count(*) from jsonb_array_elements(public.mail_deliver(
		convert_to(E'From: x@elsewhere.test\r\nTo: all\r\nSubject: hi\r\n\r\nhello\r\n', 'UTF8'),
		'{"subject":"hi","from":[{"name":"","email":"x@elsewhere.test"}],"messageId":"m1@elsewhere.test"}',
		array['alice-t@palm.test', 'alice-t.work@palm.test', 'bob-t@palm.test', 'ALICE-T@Palm.Test',
		      'nobody@palm.test', 'someone@gmail.com'])) e
	 where e ->> 'status' = 'delivered'),
	4::bigint, 'mail_deliver delivers to the three local identities (and a case-folded duplicate)');

select is(
	(select e ->> 'status' from jsonb_array_elements(public.mail_deliver(
		'\x41'::bytea, '{}', array['someone@gmail.com'])) e),
	'refused', 'mail_deliver refuses a non-local recipient: no relaying');

select is(
	(select count(*) from public.mail_messages m
	 where m.identity_id = 'aaaaaaaa-0000-4000-8000-00000000000a'),
	1::bigint, 'the duplicate envelope recipient got one copy, not two');

-- A submission from each identity, with one external recipient, so every
-- table (submissions, outbox) has a row for each.
create function pg_temp.claims(sub text, ident text) returns void language sql as $$
	select set_config('request.jwt.claims',
		json_build_object('sub', sub, 'role', 'authenticated', 'palm_identity', nullif(ident, ''))::text, true)
$$;

select pg_temp.claims('a0000000-0000-4000-8000-000000000001', '');
select public.mail_submit('aaaaaaaa-0000-4000-8000-00000000000a', convert_to('From: alice-t@palm.test', 'UTF8'),
	'{"from":[{"email":"alice-t@palm.test"}],"subject":"a"}', array['bob-t@palm.test', 'friend@example.com']);
select public.mail_submit('aaaaaaaa-0000-4000-8000-00000000000b', convert_to('From: alice-t.work@palm.test', 'UTF8'),
	'{"from":[{"email":"alice-t.work@palm.test"}],"subject":"w"}', array['client@example.com']);
select pg_temp.claims('b0000000-0000-4000-8000-000000000002', '');
select public.mail_submit('bbbbbbbb-0000-4000-8000-00000000000b', convert_to('From: bob-t@palm.test', 'UTF8'),
	'{"from":[{"email":"bob-t@palm.test"}],"subject":"b"}', array['alice-t@palm.test', 'x@example.org']);

select is(
	(select status from public.mail_outbox where rcpt = 'friend@example.com'),
	'held', 'an external recipient is held, not sent');

-- ---------------------------------------------------------------------------
-- A session scoped to Alice's personal identity
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.claims('a0000000-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-00000000000a');

-- Reads: nothing of W (same owner, other identity) or B, something of A.
select is((select count(*) from public.mail_mailboxes   where identity_id <> 'aaaaaaaa-0000-4000-8000-00000000000a'), 0::bigint, 'scoped: no other identity''s mailboxes');
select is((select count(*) from public.mail_threads     where identity_id <> 'aaaaaaaa-0000-4000-8000-00000000000a'), 0::bigint, 'scoped: no other identity''s threads');
select is((select count(*) from public.mail_blobs       where identity_id <> 'aaaaaaaa-0000-4000-8000-00000000000a'), 0::bigint, 'scoped: no other identity''s raw messages');
select is((select count(*) from public.mail_messages    where identity_id <> 'aaaaaaaa-0000-4000-8000-00000000000a'), 0::bigint, 'scoped: no other identity''s messages');
select is((select count(*) from public.mail_submissions where identity_id <> 'aaaaaaaa-0000-4000-8000-00000000000a'), 0::bigint, 'scoped: no other identity''s submissions');
select is((select count(*) from public.mail_outbox      where identity_id <> 'aaaaaaaa-0000-4000-8000-00000000000a'), 0::bigint, 'scoped: no other identity''s outbox');
select is((select count(*) from public.mail_changes     where identity_id <> 'aaaaaaaa-0000-4000-8000-00000000000a'), 0::bigint, 'scoped: no other identity''s change log');

select ok((select count(*) from public.mail_mailboxes)   = 7, 'scoped: its own seven mailboxes');
select ok((select count(*) from public.mail_threads)     > 0, 'scoped: its own threads');
select ok((select count(*) from public.mail_blobs)       > 0, 'scoped: its own raw messages');
select ok((select count(*) from public.mail_messages)    = 3, 'scoped: its own three messages (received, sent, Bob''s reply)');
select ok((select count(*) from public.mail_submissions) = 1, 'scoped: its own submission');
select ok((select count(*) from public.mail_outbox)      = 1, 'scoped: its own held recipient');
select ok((select count(*) from public.mail_changes)     > 0, 'scoped: its own change log');

select is((select count(*) from public.mail_identities()), 1::bigint, 'scoped: mail_identities lists only A');
select is(public.mail_address_of('bbbbbbbb-0000-4000-8000-00000000000b'), null, 'scoped: cannot look up B''s address by id');
select is((select count(*) from public.mail_mailbox_counts('aaaaaaaa-0000-4000-8000-00000000000b')), 0::bigint,
	'scoped: mailbox counts of W are empty');

-- Writes into W and B fail.
select throws_ok($$insert into public.mail_mailboxes (identity_id, name) values ('aaaaaaaa-0000-4000-8000-00000000000b', 'Sneaky')$$,
	'42501', null, 'scoped: cannot create a mailbox in W');
select throws_ok($$insert into public.mail_mailboxes (identity_id, name) values ('bbbbbbbb-0000-4000-8000-00000000000b', 'Sneaky')$$,
	'42501', null, 'scoped: cannot create a mailbox in B');
select throws_ok($$insert into public.mail_threads (identity_id) values ('bbbbbbbb-0000-4000-8000-00000000000b')$$,
	'42501', null, 'scoped: cannot create a thread in B');
select throws_ok($$insert into public.mail_blobs (identity_id, sha256, size, raw)
	values ('aaaaaaaa-0000-4000-8000-00000000000b', repeat('0', 64), 1, '\x41')$$,
	'42501', null, 'scoped: cannot write a raw message into W');
select is_empty($$update public.mail_messages set keywords = '{$seen}'
	where identity_id in ('aaaaaaaa-0000-4000-8000-00000000000b', 'bbbbbbbb-0000-4000-8000-00000000000b') returning id$$,
	'scoped: updating W''s and B''s messages touches nothing');
select is_empty($$delete from public.mail_messages
	where identity_id in ('aaaaaaaa-0000-4000-8000-00000000000b', 'bbbbbbbb-0000-4000-8000-00000000000b') returning id$$,
	'scoped: deleting W''s and B''s messages touches nothing');
select is_empty($$delete from public.mail_mailboxes
	where identity_id <> 'aaaaaaaa-0000-4000-8000-00000000000a' returning id$$,
	'scoped: deleting other identities'' mailboxes touches nothing');
select throws_ok($$update public.mail_mailboxes set identity_id = 'aaaaaaaa-0000-4000-8000-00000000000b' where role = 'junk'$$,
	'42501', null, 'scoped: cannot move its own mailbox into W');
select throws_ok($$select public.mail_submit('aaaaaaaa-0000-4000-8000-00000000000b', '\x41',
	'{"from":[{"email":"alice-t.work@palm.test"}]}', array['bob-t@palm.test'])$$,
	'42501', null, 'scoped: cannot send as W');
select throws_ok($$select public.mail_submit('aaaaaaaa-0000-4000-8000-00000000000a', '\x41',
	'{"from":[{"email":"bob-t@palm.test"}]}', array['alice-t.work@palm.test'])$$,
	'42501', null, 'scoped: cannot forge another identity''s From');
select throws_ok($$select public.mail_deliver('\x41', '{}', array['alice-t@palm.test'])$$,
	'42501', null, 'scoped: the MX entry point is not callable by a person');
select throws_ok($$insert into public.mail_outbox (identity_id, submission_id, email_id, rcpt, status)
	select identity_id, id, email_id, 'x@example.com', 'queued' from public.mail_submissions$$,
	'42501', null, 'scoped: cannot queue its own held mail for sending');
select is_empty($$update public.mail_outbox set status = 'queued' returning id$$,
	'scoped: cannot promote a held recipient to queued');

-- A message of its own may not be filed into another identity's mailbox,
-- even by someone who learned that mailbox's id.
reset role;
create temp table w_box as select id from public.mail_mailboxes
	where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000b' and role = 'inbox';
grant select on w_box to authenticated;
set local role authenticated;
select throws_ok($$update public.mail_messages set mailbox_ids = mailbox_ids || (select id from w_box)$$,
	'23503', null, 'scoped: cannot file its own message into W''s mailbox');

-- Its own data stays writable.
select lives_ok($$update public.mail_messages set keywords = '{$seen,$flagged}' where subject = 'hi'$$,
	'scoped: can flag its own message');
select lives_ok($$insert into public.mail_mailboxes (identity_id, name) values ('aaaaaaaa-0000-4000-8000-00000000000a', 'Receipts')$$,
	'scoped: can create its own folder');

-- ---------------------------------------------------------------------------
-- Alice unscoped: both of her identities, never Bob's
-- ---------------------------------------------------------------------------

select pg_temp.claims('a0000000-0000-4000-8000-000000000001', '');
select is((select count(distinct identity_id) from public.mail_messages), 2::bigint, 'unscoped: Alice sees A and W');
select is((select count(*) from public.mail_messages where identity_id = 'bbbbbbbb-0000-4000-8000-00000000000b'), 0::bigint,
	'unscoped: Alice sees none of Bob''s messages');
select is((select count(*) from public.mail_blobs where identity_id = 'bbbbbbbb-0000-4000-8000-00000000000b'), 0::bigint,
	'unscoped: Alice sees none of Bob''s raw messages');
select is((select count(*) from public.mail_identities()), 2::bigint, 'unscoped: mail_identities lists A and W');
select throws_ok($$select public.mail_submit('bbbbbbbb-0000-4000-8000-00000000000b', '\x41',
	'{"from":[{"email":"bob-t@palm.test"}]}', array['alice-t@palm.test'])$$,
	'42501', null, 'unscoped: Alice cannot send as Bob');

-- ---------------------------------------------------------------------------
-- Bob, scoped to B
-- ---------------------------------------------------------------------------

select pg_temp.claims('b0000000-0000-4000-8000-000000000002', 'bbbbbbbb-0000-4000-8000-00000000000b');
select is((select count(*) from public.mail_messages where identity_id <> 'bbbbbbbb-0000-4000-8000-00000000000b'), 0::bigint,
	'Bob: none of Alice''s messages');
select is((select count(*) from public.mail_messages), 3::bigint, 'Bob: his own three (received, sent, Alice''s)');

-- A token scoped to an identity its subject does not own is worth nothing.
select pg_temp.claims('b0000000-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-00000000000a');
select is((select count(*) from public.mail_messages), 0::bigint, 'a scope naming someone else''s identity sees nothing');

-- Anonymous sees nothing at all.
reset role;
set local role anon;
select throws_ok($$select count(*) from public.mail_messages$$, '42501', null, 'anon: no access to messages at all');

-- An archived identity neither reads nor receives.
reset role;
update public.identities set archived_at = now() where id = 'aaaaaaaa-0000-4000-8000-00000000000b';
select is((select e ->> 'status' from jsonb_array_elements(public.mail_deliver('\x41', '{}', array['alice-t.work@palm.test'])) e),
	'unknown', 'an archived identity receives nothing');
set local role authenticated;
select pg_temp.claims('a0000000-0000-4000-8000-000000000001', '');
select is((select count(*) from public.mail_messages where identity_id = 'aaaaaaaa-0000-4000-8000-00000000000b'), 0::bigint,
	'an archived identity''s mail is not readable');

select * from finish();
rollback;
