-- Deleting a person (the auth user) who has mail. The delete cascades
-- through public.identities to every mail table; the change-log trigger
-- must not make it fail, nothing of theirs may remain, and the other
-- person's mail and change log must be untouched.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(12);

insert into public.mail_domains (domain, is_default) values ('palm.test', true) on conflict do nothing;

insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000d1', 'alice@mail-erase.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-0000000000d2', 'bob@mail-erase.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000da', 'a0000000-0000-4000-8000-0000000000d1', 'erase-m-alice',      'Alice',        'personal'),
	('aaaaaaaa-0000-4000-8000-0000000000db', 'a0000000-0000-4000-8000-0000000000d1', 'erase-m-alice.work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-4000-8000-0000000000da', 'b0000000-0000-4000-8000-0000000000d2', 'erase-m-bob',        'Bob',          'personal');

-- Mail into all three, and Alice writes to Bob and to the outside.
select public.mail_deliver(
	convert_to(E'From: x@elsewhere.test\r\nSubject: hi\r\n\r\nhello\r\n', 'UTF8'),
	'{"subject":"hi","from":[{"name":"","email":"x@elsewhere.test"}],"messageId":"erase-1@elsewhere.test"}',
	array['erase-m-alice@palm.test', 'erase-m-alice.work@palm.test', 'erase-m-bob@palm.test']);

select set_config('request.jwt.claims',
	json_build_object('sub', 'a0000000-0000-4000-8000-0000000000d1', 'role', 'authenticated')::text, true);
select public.mail_submit('aaaaaaaa-0000-4000-8000-0000000000da', convert_to('From: erase-m-alice@palm.test', 'UTF8'),
	'{"from":[{"email":"erase-m-alice@palm.test"}],"subject":"from alice"}',
	array['erase-m-bob@palm.test', 'friend@example.com']);
select set_config('request.jwt.claims', '', true);

create temp table bob_before as
	select (select count(*) from public.mail_messages where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000da') as messages,
	       (select count(*) from public.mail_changes  where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000da') as changes;

select ok((select messages from bob_before) = 2, 'Bob has the delivered mail and Alice''s');
select ok((select count(*) from public.mail_changes where identity_id = 'aaaaaaaa-0000-4000-8000-0000000000da') > 0,
	'Alice''s writes are in the change log');

-- The delete itself.
select lives_ok($$ delete from auth.users where id = 'a0000000-0000-4000-8000-0000000000d1' $$,
	'deleting a person with mail succeeds');

select is((select count(*) from public.identities where owner = 'a0000000-0000-4000-8000-0000000000d1'), 0::bigint,
	'their identities are gone');

-- Nothing of theirs remains, in any mail table.
select is((select count(*) from public.mail_mailboxes   where identity_id not in (select id from public.identities)), 0::bigint, 'no orphan mailboxes');
select is((select count(*) from public.mail_messages    where identity_id not in (select id from public.identities)), 0::bigint, 'no orphan messages');
select is((select count(*) from public.mail_threads     where identity_id not in (select id from public.identities)), 0::bigint, 'no orphan threads');
select is((select count(*) from public.mail_blobs       where identity_id not in (select id from public.identities)), 0::bigint, 'no orphan raw messages');
select is((select count(*) from public.mail_submissions where identity_id not in (select id from public.identities)) +
          (select count(*) from public.mail_outbox      where identity_id not in (select id from public.identities)), 0::bigint, 'no orphan submissions or outbox rows');
select is((select count(*) from public.mail_changes     where identity_id not in (select id from public.identities)), 0::bigint, 'no orphan change-log rows');

-- Bob is untouched: his copy of Alice's mail is his.
select is((select count(*) from public.mail_messages where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000da'),
	(select messages from bob_before), 'Bob keeps his mail, including what Alice sent him');

-- For a live identity, destroying a message is still logged.
delete from public.mail_messages where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000da';
select is((select count(*) from public.mail_changes
           where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000da' and type = 'Email' and kind = 'destroyed'), 2::bigint,
	'a live identity''s deletes are still in its change log');

select * from finish();
rollback;
