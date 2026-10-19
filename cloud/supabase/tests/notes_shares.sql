-- Sharing a note: an explicit row made by the owning identity, read or
-- edit, which gives exactly that level and nothing after it is revoked.
--
-- Identities: Alice's personal (A) and work (W), Bob's personal (B) and
-- work (BW). A shares with B; BW, W and everyone else see nothing.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(39);

insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000f1', 'alice-s@example.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-0000000000f2', 'bob-s@example.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000fa', 'a0000000-0000-4000-8000-0000000000f1', 'alice-s',      'Alice',        'personal'),
	('aaaaaaaa-0000-4000-8000-0000000000fb', 'a0000000-0000-4000-8000-0000000000f1', 'alice-s.work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-4000-8000-0000000000fa', 'b0000000-0000-4000-8000-0000000000f2', 'bob-s',        'Bob',          'personal'),
	('bbbbbbbb-0000-4000-8000-0000000000fb', 'b0000000-0000-4000-8000-0000000000f2', 'bob-s.work',   'Bob (work)',   'work');

create function pg_temp.as_user(sub text, ident text) returns void language sql as $$
	select set_config('request.jwt.claims',
		json_build_object('sub', sub, 'role', 'authenticated', 'palm_identity', nullif(ident, ''))::text, true)
$$;
create function pg_temp.as_server() returns void language sql as $$
	select set_config('request.jwt.claims', '{"role":"service_role"}', true)
$$;
create function pg_temp.affected(q text) returns bigint language plpgsql as $f$
declare n bigint;
begin
	execute q;
	get diagnostics n = row_count;
	return n;
end
$f$;

set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000f1', 'aaaaaaaa-0000-4000-8000-0000000000fa');
select lives_ok($$select public.notes_create('f0000000-0000-4000-8000-0000000000a1',
	'aaaaaaaa-0000-4000-8000-0000000000fa', 'Trip to Lisbon', 'Travel')$$, 'A creates a note');
reset role;
set local role service_role;
select pg_temp.as_server();
select is(public.collab_append('f0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000fa',
	'a0000000-0000-4000-8000-0000000000f1', 'a1', 'VQEA'), 1::bigint, 'with one revision');
reset role;

-- ---------------------------------------------------------------------------
-- Before any share
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000f2', 'bbbbbbbb-0000-4000-8000-0000000000fa');
select is((select count(*) from public.notes), 0::bigint, 'B: nothing before a share');
select throws_ok($$select public.notes_share('f0000000-0000-4000-8000-0000000000a1', 'bob-s', 'edit')$$,
	'42501', null, 'B: cannot share itself into A''s note');

-- ---------------------------------------------------------------------------
-- Read
-- ---------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000f1', 'aaaaaaaa-0000-4000-8000-0000000000fa');
select throws_ok($$select public.notes_share('f0000000-0000-4000-8000-0000000000a1', 'bob-s', 'comment')$$,
	'22023', null, 'a note is shared to read or to edit, nothing else');
select throws_ok($$select public.notes_share('f0000000-0000-4000-8000-0000000000a1', 'nobody-at-all', 'read')$$,
	'P0002', null, 'sharing with an identity that does not exist says so');
select is(public.notes_share('f0000000-0000-4000-8000-0000000000a1', 'bob-s', 'read') ->> 'access', 'read',
	'A shares the note with B to read');

select pg_temp.as_user('b0000000-0000-4000-8000-0000000000f2', 'bbbbbbbb-0000-4000-8000-0000000000fa');
select is((select count(*) from public.notes), 1::bigint, 'read: B sees the note');
select is((select count(*) from public.collab_updates where doc_id = 'f0000000-0000-4000-8000-0000000000a1'), 1::bigint,
	'read: and reads its revisions');
select is((select access from public.notes_sync_state('bbbbbbbb-0000-4000-8000-0000000000fa')), 'read',
	'read: B''s sync state lists it, with its level');
select is((select owner_handle from public.notes_sync_state('bbbbbbbb-0000-4000-8000-0000000000fa')), 'alice-s',
	'read: and whose it is');
select is(public.collab_join('f0000000-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000fa') ->> 'role',
	'view', 'read: the sync server is told view');
select is(pg_temp.affected($q$update public.notes set title = 'mine now'
	where id = 'f0000000-0000-4000-8000-0000000000a1'$q$), 0::bigint, 'read: cannot rename it');
select throws_ok($$insert into public.note_attachments (note_id, identity_id, sha256, name, size)
	values ('f0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000fa', repeat('b', 64), 'b.png', 1)$$,
	'42501', null, 'read: cannot attach a file');
select throws_ok($$select public.notes_share('f0000000-0000-4000-8000-0000000000a1', 'bob-s.work', 'read')$$,
	'42501', null, 'read: cannot pass it on, not even to its own other identity');

select pg_temp.as_user('b0000000-0000-4000-8000-0000000000f2', 'bbbbbbbb-0000-4000-8000-0000000000fb');
select is((select count(*) from public.notes), 0::bigint, 'BW: a share to B is not a share to Bob''s other identity');

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000f1', 'aaaaaaaa-0000-4000-8000-0000000000fb');
select is((select count(*) from public.notes), 0::bigint, 'W: the owner''s own other identity does not see it either');
reset role;

set local role service_role;
select pg_temp.as_server();
select throws_ok($$select public.collab_append('f0000000-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000fa',
	'b0000000-0000-4000-8000-0000000000f2', 'b1', 'VQEA')$$, '42501', null,
	'read: the server refuses to append a revision from B');
reset role;

-- ---------------------------------------------------------------------------
-- Edit
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000f1', 'aaaaaaaa-0000-4000-8000-0000000000fa');
select is(public.notes_share('f0000000-0000-4000-8000-0000000000a1', 'bob-s', 'edit') ->> 'access', 'edit',
	'A raises B to edit');
select is((select count(*) from public.collab_grants where doc_id = 'f0000000-0000-4000-8000-0000000000a1'
	and revoked_at is null), 1::bigint, 'there is one live share row, not two');
select is((select access from public.notes_people('f0000000-0000-4000-8000-0000000000a1') where handle = 'bob-s'),
	'edit', 'A''s share dialog lists B with edit');
reset role;

set local role service_role;
select pg_temp.as_server();
select is(public.collab_append('f0000000-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000fa',
	'b0000000-0000-4000-8000-0000000000f2', 'b1', 'VQEA'), 2::bigint, 'edit: the server appends B''s revision');
reset role;

set local role authenticated;
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000f2', 'bbbbbbbb-0000-4000-8000-0000000000fa');
select is(public.collab_join('f0000000-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000fa') ->> 'role',
	'edit', 'edit: the sync server is told edit');
select is(pg_temp.affected($q$update public.notes set notebook = 'Bob''s'
	where id = 'f0000000-0000-4000-8000-0000000000a1'$q$), 0::bigint,
	'edit: the text is shared, where the owner files it is not');
select lives_ok($$insert into public.note_attachments (note_id, identity_id, sha256, name, size)
	values ('f0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000fa', repeat('b', 64), 'map.png', 1)$$,
	'edit: attaches a file to the note');
select lives_ok($$insert into storage.objects (bucket_id, name, metadata)
	values ('notes', 'aaaaaaaa-0000-4000-8000-0000000000fa/' || repeat('b', 64), '{"size":1}')$$,
	'edit: and stores it under the owner''s prefix');
select is((select count(*) from storage.objects where bucket_id = 'notes'), 1::bigint,
	'edit: sees that attachment''s blob');
select throws_ok($$select public.notes_purge('f0000000-0000-4000-8000-0000000000a1')$$, '42501', null,
	'edit: cannot delete the note');

-- ---------------------------------------------------------------------------
-- Trash, then revocation
-- ---------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000f1', 'aaaaaaaa-0000-4000-8000-0000000000fa');
select is(pg_temp.affected($q$update public.notes set trashed_at = now()
	where id = 'f0000000-0000-4000-8000-0000000000a1'$q$), 1::bigint, 'A moves the note to the trash');
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000f2', 'bbbbbbbb-0000-4000-8000-0000000000fa');
select is((select count(*) from public.notes_sync_state('bbbbbbbb-0000-4000-8000-0000000000fa')), 0::bigint,
	'a trashed note leaves the grantee''s list');
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000f1', 'aaaaaaaa-0000-4000-8000-0000000000fa');
select is(pg_temp.affected($q$update public.notes set trashed_at = null
	where id = 'f0000000-0000-4000-8000-0000000000a1'$q$), 1::bigint, 'A restores it');

select ok(public.notes_unshare('f0000000-0000-4000-8000-0000000000a1', 'bob-s'), 'A revokes B''s access');

select pg_temp.as_user('b0000000-0000-4000-8000-0000000000f2', 'bbbbbbbb-0000-4000-8000-0000000000fa');
select is((select count(*) from public.notes), 0::bigint, 'revoked: B sees nothing');
select is((select count(*) from public.collab_updates where doc_id = 'f0000000-0000-4000-8000-0000000000a1'), 0::bigint,
	'revoked: and none of its revisions');
select is((select count(*) from public.notes_sync_state('bbbbbbbb-0000-4000-8000-0000000000fa')), 0::bigint,
	'revoked: B''s sync state drops it, so B''s devices remove their copy');
select is(public.collab_join('f0000000-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000fa') ->> 'role',
	null, 'revoked: the sync server refuses B');
select is((select count(*) from public.note_attachments), 0::bigint, 'revoked: no attachment rows');
select is((select count(*) from storage.objects where bucket_id = 'notes'), 0::bigint, 'revoked: no attachment blobs');
reset role;

set local role service_role;
select pg_temp.as_server();
select throws_ok($$select public.collab_append('f0000000-0000-4000-8000-0000000000a1', 'bbbbbbbb-0000-4000-8000-0000000000fa',
	'b0000000-0000-4000-8000-0000000000f2', 'b1', 'VQEA')$$, '42501', null,
	'revoked: a revision B sent late is refused at the database');
reset role;

select * from finish();
rollback;
