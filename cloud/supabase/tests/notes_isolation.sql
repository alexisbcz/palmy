-- The test the notes area is held to (cloud/CONTRACT.md): a session scoped
-- to identity A, asking for identity B's notes, gets nothing, and writing
-- them fails. W is the sharp case: the same person owns it, so only the
-- token's scope separates it from A.
--
-- Identities: Alice's personal (A) and work (W), Bob's (B).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(44);

insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000e1', 'alice-n@example.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-0000000000e2', 'bob-n@example.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000ea', 'a0000000-0000-4000-8000-0000000000e1', 'alice-n',      'Alice',        'personal'),
	('aaaaaaaa-0000-4000-8000-0000000000eb', 'a0000000-0000-4000-8000-0000000000e1', 'alice-n.work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-4000-8000-0000000000eb', 'b0000000-0000-4000-8000-0000000000e2', 'bob-n',        'Bob',          'personal');

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

-- ---------------------------------------------------------------------------
-- Creating notes, as the devices do: the id is the device's.
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000e1', '');

select is((public.notes_create('e0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ea',
	'Shopping', '')).identity_id, 'aaaaaaaa-0000-4000-8000-0000000000ea'::uuid,
	'unscoped Alice creates a note in A with the id her device chose');
select is((public.notes_create('e0000000-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000eb',
	'Q4 plan', 'Projects')).notebook, 'Projects', 'and one in W, in a notebook');
select is((public.notes_create('e0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ea',
	'Shopping', '')).id, 'e0000000-0000-4000-8000-0000000000a1'::uuid,
	'creating again with the same id and identity is idempotent (an offline device retrying)');
select throws_ok($$select public.notes_create('e0000000-0000-4000-8000-0000000000a1',
	'aaaaaaaa-0000-4000-8000-0000000000eb', 'x', '')$$, '23505', null,
	'the same id cannot be reused in another identity');
select is((select kind from public.collab_documents where id = 'e0000000-0000-4000-8000-0000000000a1'), 'note',
	'a note is a collaboration document of kind note');
select throws_ok($$select public.notes_create('e0000000-0000-4000-8000-0000000000a9',
	'aaaaaaaa-0000-4000-8000-0000000000ea', 'x', '../escape')$$, '23514', null,
	'a notebook path cannot climb out of the identity''s folder');

select pg_temp.as_user('b0000000-0000-4000-8000-0000000000e2', 'bbbbbbbb-0000-4000-8000-0000000000eb');
select lives_ok($$select public.notes_create('e0000000-0000-4000-8000-0000000000b1',
	'bbbbbbbb-0000-4000-8000-0000000000eb', 'Bob''s diary', '')$$, 'scoped Bob creates a note in B');
reset role;

-- The sync server writes one revision into each.
set local role service_role;
select pg_temp.as_server();
select is(public.collab_append('e0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ea',
	'a0000000-0000-4000-8000-0000000000e1', 'a1', 'VQEA'), 1::bigint, 'revision 1 of A''s note');
select is(public.collab_append('e0000000-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000eb',
	'a0000000-0000-4000-8000-0000000000e1', 'a2', 'VQEA'), 1::bigint, 'revision 1 of W''s note');
select is(public.collab_append('e0000000-0000-4000-8000-0000000000b1', 'bbbbbbbb-0000-4000-8000-0000000000eb',
	'b0000000-0000-4000-8000-0000000000e2', 'b1', 'VQEA'), 1::bigint, 'revision 1 of B''s note');
reset role;

-- ---------------------------------------------------------------------------
-- A session scoped to Alice's personal identity
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000ea');

select is((select count(*) from public.notes), 1::bigint, 'scoped A: sees exactly its own note');
select is((select count(*) from public.notes where identity_id = 'aaaaaaaa-0000-4000-8000-0000000000eb'), 0::bigint,
	'scoped A: nothing of W, though the same person owns it');
select is((select count(*) from public.notes where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000eb'), 0::bigint,
	'scoped A: nothing of B');
select is((select count(*) from public.collab_updates where doc_id = 'e0000000-0000-4000-8000-0000000000a2'), 0::bigint,
	'scoped A: none of W''s revisions');
select is((select count(*) from public.collab_updates where doc_id = 'e0000000-0000-4000-8000-0000000000a1'), 1::bigint,
	'scoped A: its own revisions');
select is((select count(*) from public.notes_sync_state('aaaaaaaa-0000-4000-8000-0000000000ea')), 1::bigint,
	'scoped A: its sync state lists its note');
select is((select count(*) from public.notes_sync_state('aaaaaaaa-0000-4000-8000-0000000000eb')), 0::bigint,
	'scoped A: asking for W''s sync state gets nothing');
select is((select count(*) from public.notes_sync_state('bbbbbbbb-0000-4000-8000-0000000000eb')), 0::bigint,
	'scoped A: asking for B''s sync state gets nothing');
select is(public.collab_join('e0000000-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000eb') ->> 'reason',
	'identity', 'scoped A: cannot open W''s note through the sync server');
select is(public.collab_join('e0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ea') ->> 'role',
	null, 'scoped A: cannot open B''s note as A either');
select throws_ok($$select public.notes_create('e0000000-0000-4000-8000-0000000000a3',
	'aaaaaaaa-0000-4000-8000-0000000000eb', 'planted', '')$$, '42501', null,
	'scoped A: cannot create a note in W');
select throws_ok($$select public.notes_create('e0000000-0000-4000-8000-0000000000a4',
	'bbbbbbbb-0000-4000-8000-0000000000eb', 'planted', '')$$, '42501', null,
	'scoped A: cannot create a note in B');
select throws_ok($$insert into public.notes (id, identity_id) values
	('e0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ea')$$, '42501', null,
	'scoped A: cannot insert note rows directly, even its own');
select is(pg_temp.affected($q$update public.notes set title = 'stolen'
	where id = 'e0000000-0000-4000-8000-0000000000a2'$q$), 0::bigint, 'scoped A: renaming W''s note matches nothing');
select is(pg_temp.affected($q$update public.notes set trashed_at = now()
	where id = 'e0000000-0000-4000-8000-0000000000b1'$q$), 0::bigint, 'scoped A: trashing B''s note matches nothing');
select is(pg_temp.affected($q$update public.notes set pinned = true
	where id = 'e0000000-0000-4000-8000-0000000000a1'$q$), 1::bigint, 'scoped A: pins its own note');
select throws_ok($$update public.notes set identity_id = 'aaaaaaaa-0000-4000-8000-0000000000eb'
	where id = 'e0000000-0000-4000-8000-0000000000a1'$$, '42501', null,
	'scoped A: a note cannot be moved to W (carry a copy instead)');
select throws_ok($$select public.notes_purge('e0000000-0000-4000-8000-0000000000a2')$$, '42501', null,
	'scoped A: cannot delete W''s note');
select throws_ok($$select public.notes_purge('e0000000-0000-4000-8000-0000000000b1')$$, '42501', null,
	'scoped A: cannot delete B''s note');
select throws_ok($$insert into public.note_attachments (note_id, identity_id, sha256, name, size)
	values ('e0000000-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000eb', repeat('a', 64), 'x.png', 1)$$,
	'42501', null, 'scoped A: cannot attach a file to W''s note');
select lives_ok($$insert into public.note_attachments (note_id, identity_id, sha256, name, size)
	values ('e0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ea', repeat('a', 64), 'list.png', 1)$$,
	'scoped A: attaches a file to its own note');
select throws_ok($$insert into storage.objects (bucket_id, name, metadata)
	values ('notes', 'aaaaaaaa-0000-4000-8000-0000000000eb/' || repeat('c', 64), '{"size":1}')$$, '42501', null,
	'scoped A: cannot store an attachment under W''s prefix');
select throws_ok($$insert into storage.objects (bucket_id, name, metadata)
	values ('notes', 'aaaaaaaa-0000-4000-8000-0000000000ea/notes.exe', '{"size":1}')$$, '42501', null,
	'scoped A: cannot store anything but a content-addressed blob, even in its own prefix');
select lives_ok($$insert into storage.objects (bucket_id, name, metadata)
	values ('notes', 'aaaaaaaa-0000-4000-8000-0000000000ea/' || repeat('a', 64), '{"size":1}')$$,
	'scoped A: stores an attachment under its own prefix');
reset role;

-- A blob in W's prefix, put there by the database owner, is still invisible to A.
insert into storage.objects (bucket_id, name, metadata)
	values ('notes', 'aaaaaaaa-0000-4000-8000-0000000000eb/' || repeat('d', 64), '{"size":1}');
set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000ea');
select is((select count(*) from storage.objects where bucket_id = 'notes'), 1::bigint,
	'scoped A: sees its own attachment blob and not W''s');

-- ---------------------------------------------------------------------------
-- Other sessions
-- ---------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000eb');
select is((select count(*) from public.notes), 1::bigint, 'scoped W: sees exactly its own note');
select is((select title from public.notes), 'Q4 plan', 'scoped W: and it is W''s');

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000e1', '');
select is((select count(*) from public.notes), 2::bigint, 'unscoped Alice: both of her identities'' notes');
select is((select count(*) from public.notes where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000eb'), 0::bigint,
	'unscoped Alice: nothing of Bob''s');

select pg_temp.as_user('b0000000-0000-4000-8000-0000000000e2', '');
select is((select count(*) from public.notes), 1::bigint, 'unscoped Bob: only his own');
select is((select count(*) from public.note_attachments), 0::bigint, 'unscoped Bob: none of Alice''s attachments');

-- ---------------------------------------------------------------------------
-- Deleting for good takes the log with it
-- ---------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000e1', 'aaaaaaaa-0000-4000-8000-0000000000ea');
select ok(public.notes_purge('e0000000-0000-4000-8000-0000000000a1'), 'scoped A: deletes its own note');
reset role;
select is((select count(*) from public.collab_updates where doc_id = 'e0000000-0000-4000-8000-0000000000a1'), 0::bigint,
	'its revisions are gone');
select is((select count(*) from public.note_attachments where note_id = 'e0000000-0000-4000-8000-0000000000a1'), 0::bigint,
	'and its attachment rows');

select * from finish();
rollback;
