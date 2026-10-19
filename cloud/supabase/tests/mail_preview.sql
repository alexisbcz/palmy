-- The preview rule's database half: the summarising server's partsDiffer
-- reaches mail_messages.parts_differ through every entry point (delivery,
-- submission, import), and a message without it is not flagged.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(6);

insert into public.mail_domains (domain, is_default) values ('palm.test', true) on conflict do nothing;
insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000f1', 'alice@mail-preview.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');
insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000fa', 'a0000000-0000-4000-8000-0000000000f1', 'preview-alice', 'Alice', 'personal');

select has_column('public', 'mail_messages', 'parts_differ', 'mail_messages has parts_differ');

select public.mail_deliver(convert_to(E'From: x@e.test\r\n\r\nx\r\n', 'UTF8'),
	'{"subject":"differs","messageId":"pv-1@e.test","preview":"Dear Camille","partsDiffer":true}',
	array['preview-alice@palm.test']);
select public.mail_deliver(convert_to(E'From: x@e.test\r\n\r\ny\r\n', 'UTF8'),
	'{"subject":"agrees","messageId":"pv-2@e.test","preview":"Hi","partsDiffer":false}',
	array['preview-alice@palm.test']);
select public.mail_deliver(convert_to(E'From: x@e.test\r\n\r\nz\r\n', 'UTF8'),
	'{"subject":"older server","messageId":"pv-3@e.test","preview":"Hi"}',
	array['preview-alice@palm.test']);

select is((select parts_differ from public.mail_messages where subject = 'differs'), true, 'delivery: partsDiffer true is stored');
select is((select parts_differ from public.mail_messages where subject = 'agrees'), false, 'delivery: partsDiffer false is stored');
select is((select parts_differ from public.mail_messages where subject = 'older server'), false, 'delivery: no partsDiffer means not flagged');

select set_config('request.jwt.claims',
	json_build_object('sub', 'a0000000-0000-4000-8000-0000000000f1', 'role', 'authenticated')::text, true);
select public.mail_submit('aaaaaaaa-0000-4000-8000-0000000000fa', convert_to('From: preview-alice@palm.test', 'UTF8'),
	'{"from":[{"email":"preview-alice@palm.test"}],"subject":"sent","partsDiffer":true}', array['friend@example.com']);
select public.mail_import('aaaaaaaa-0000-4000-8000-0000000000fa', convert_to(E'From: y@e.test\r\n\r\ni\r\n', 'UTF8'),
	'{"subject":"imported","messageId":"pv-4@e.test","partsDiffer":true}',
	(select array[id] from public.mail_mailboxes where identity_id = 'aaaaaaaa-0000-4000-8000-0000000000fa' and role = 'inbox'), '{}');

select is((select parts_differ from public.mail_messages where subject = 'sent'), true, 'submission: the sender''s copy is flagged too');
select is((select parts_differ from public.mail_messages where subject = 'imported'), true, 'import: flagged');

select * from finish();
rollback;
