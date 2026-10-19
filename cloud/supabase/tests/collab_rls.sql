-- The test the collaboration area is held to (cloud/CONTRACT.md): a session
-- scoped to identity A, asking for identity B's documents or their updates,
-- gets nothing, and writing them fails; a grant gives exactly its level; a
-- revoked grant gives nothing.
--
-- Identities: Alice's personal (A) and work (W), Bob's (B), Carol's (C).
-- W is the sharp case: the same person owns it, so only the token's scope
-- separates it from A.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(59);

insert into auth.users (id, email, aud, role, instance_id) values
	('a0000000-0000-4000-8000-0000000000c1', 'alice-c@example.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('b0000000-0000-4000-8000-0000000000c2', 'bob-c@example.test',   'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000'),
	('c0000000-0000-4000-8000-0000000000c3', 'carol-c@example.test', 'authenticated', 'authenticated', '00000000-0000-0000-0000-000000000000');

insert into public.identities (id, owner, handle, display_name, kind) values
	('aaaaaaaa-0000-4000-8000-0000000000ca', 'a0000000-0000-4000-8000-0000000000c1', 'alice-c',      'Alice',        'personal'),
	('aaaaaaaa-0000-4000-8000-0000000000cb', 'a0000000-0000-4000-8000-0000000000c1', 'alice-c.work', 'Alice (work)', 'work'),
	('bbbbbbbb-0000-4000-8000-0000000000cb', 'b0000000-0000-4000-8000-0000000000c2', 'bob-c',        'Bob',          'personal'),
	('cccccccc-0000-4000-8000-0000000000cc', 'c0000000-0000-4000-8000-0000000000c3', 'carol-c',      'Carol',        'personal');

insert into public.collab_documents (id, identity_id, kind, title) values
	('d0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ca', 'doc',   'A plan'),
	('d0000000-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000cb', 'sheet', 'W budget'),
	('d0000000-0000-4000-8000-0000000000b1', 'bbbbbbbb-0000-4000-8000-0000000000cb', 'deck',  'B pitch');

create function pg_temp.as_user(sub text, ident text) returns void language sql as $$
	select set_config('request.jwt.claims',
		json_build_object('sub', sub, 'role', 'authenticated', 'palm_identity', nullif(ident, ''))::text, true)
$$;
create function pg_temp.affected(q text) returns bigint language plpgsql as $f$
declare n bigint;
begin
	execute q;
	get diagnostics n = row_count;
	return n;
end
$f$;
create function pg_temp.as_server() returns void language sql as $$
	select set_config('request.jwt.claims', '{"role":"service_role"}', true)
$$;

-- The sync server writes one update into each document.
set local role service_role;
select pg_temp.as_server();
select is(public.collab_append('d0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'a1', 'VQEA'), 1::bigint, 'the owner appends update 1');
select is(public.collab_append('d0000000-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000cb',
	'a0000000-0000-4000-8000-0000000000c1', 'a2', 'VQEA'), 1::bigint, 'W appends to its own sheet');
select is(public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'bbbbbbbb-0000-4000-8000-0000000000cb',
	'b0000000-0000-4000-8000-0000000000c2', 'b1', 'VQEA'), 1::bigint, 'Bob appends to his deck');
select is(public.collab_append('d0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'a1', 'VQEA'), 2::bigint, 'sequence numbers are dense per document');
select lives_ok($$select public.collab_put_snapshot('d0000000-0000-4000-8000-0000000000b1', 1, 'UwEA')$$,
	'the server stores a snapshot');
select throws_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'a1', 'VQEA')$$, '42501', null,
	'the server cannot append as an identity with no role on the document');
select throws_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'b0000000-0000-4000-8000-0000000000c2', 'a9', 'VQEA')$$, '42501', null,
	'the server cannot append as an identity the given user does not own');
reset role;

-- ---------------------------------------------------------------------------
-- A session scoped to Alice's personal identity
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000ca');

select is((select count(*) from public.collab_documents), 1::bigint, 'scoped A: sees exactly its own document');
select is((select count(*) from public.collab_documents where identity_id <> 'aaaaaaaa-0000-4000-8000-0000000000ca'), 0::bigint,
	'scoped A: no document of W (same person) or B');
select is((select count(*) from public.collab_updates where doc_id <> 'd0000000-0000-4000-8000-0000000000a1'), 0::bigint,
	'scoped A: no updates of other identities'' documents');
select is((select count(*) from public.collab_updates where doc_id = 'd0000000-0000-4000-8000-0000000000a1'), 2::bigint,
	'scoped A: reads its own log');
select is((select count(*) from public.collab_snapshots), 0::bigint, 'scoped A: no one else''s snapshots');
select is((select count(*) from public.collab_agents where doc_id <> 'd0000000-0000-4000-8000-0000000000a1'), 0::bigint,
	'scoped A: no one else''s agents');
select is(public.collab_join('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca') ->> 'role', null,
	'scoped A: joining B''s deck is refused');
select is(public.collab_join('d0000000-0000-4000-8000-0000000000a2', 'aaaaaaaa-0000-4000-8000-0000000000cb') ->> 'reason', 'identity',
	'scoped A: cannot act as W, even though the same person owns it');
select is(public.collab_join('d0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ca') ->> 'role', 'owner',
	'scoped A: joins its own document as owner');
select throws_ok($$insert into public.collab_documents (identity_id, kind, title)
	values ('bbbbbbbb-0000-4000-8000-0000000000cb', 'doc', 'planted')$$, '42501', null,
	'scoped A: cannot create a document in B');
select throws_ok($$insert into public.collab_documents (identity_id, kind, title)
	values ('aaaaaaaa-0000-4000-8000-0000000000cb', 'doc', 'planted')$$, '42501', null,
	'scoped A: cannot create a document in W');
select throws_ok($$insert into public.collab_updates (doc_id, seq, identity_id, author_identity, agent, data)
	values ('d0000000-0000-4000-8000-0000000000a1', 99, 'aaaaaaaa-0000-4000-8000-0000000000ca',
	        'aaaaaaaa-0000-4000-8000-0000000000ca', 'ff', '\x00')$$, '42501', null,
	'scoped A: cannot write the log directly, even of its own document');
select throws_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000a1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'a1', 'VQEA')$$, '42501', null,
	'scoped A: cannot call the server''s append');
select is(pg_temp.affected($q$update public.collab_documents set title = 'stolen'
	where id = 'd0000000-0000-4000-8000-0000000000b1'$q$), 0::bigint,
	'scoped A: renaming B''s deck matches nothing');
select throws_ok($$select public.collab_share('d0000000-0000-4000-8000-0000000000b1', 'alice-c', 'edit')$$, '42501', null,
	'scoped A: cannot grant itself access to B''s deck');
select throws_ok($$select public.collab_state_at('d0000000-0000-4000-8000-0000000000b1', 1)$$, '42501', null,
	'scoped A: cannot read the history state of B''s deck');
select is(public.collab_history('d0000000-0000-4000-8000-0000000000b1') -> 'sessions', '[]'::jsonb,
	'scoped A: B''s version history is empty to it');
select is(public.collab_role_of('d0000000-0000-4000-8000-0000000000b1', 'bbbbbbbb-0000-4000-8000-0000000000cb'), null,
	'scoped A: cannot probe what role another identity holds');
select throws_ok($$update public.collab_documents set identity_id = 'aaaaaaaa-0000-4000-8000-0000000000cb'
	where id = 'd0000000-0000-4000-8000-0000000000a1'$$, '42501', null,
	'a document cannot be moved to another identity (carry a copy instead)');

-- ---------------------------------------------------------------------------
-- Unscoped Alice sees both of her identities, still not Bob's
-- ---------------------------------------------------------------------------

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000c1', '');
select is((select count(*) from public.collab_documents), 2::bigint, 'unscoped Alice: her two identities'' documents');
select is((select count(*) from public.collab_documents where identity_id = 'bbbbbbbb-0000-4000-8000-0000000000cb'), 0::bigint,
	'unscoped Alice: nothing of Bob''s');

-- ---------------------------------------------------------------------------
-- Bob shares his deck with A, one level at a time
-- ---------------------------------------------------------------------------

select pg_temp.as_user('b0000000-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000cb');
select is((public.collab_share('d0000000-0000-4000-8000-0000000000b1', 'alice-c', 'view')).role, 'view', 'Bob grants view to A');

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000ca');
select is((select count(*) from public.collab_documents where id = 'd0000000-0000-4000-8000-0000000000b1'), 1::bigint,
	'view: A now sees B''s deck');
select is((select count(*) from public.collab_updates where doc_id = 'd0000000-0000-4000-8000-0000000000b1'), 1::bigint,
	'view: and reads its updates');
select is(public.collab_join('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca') ->> 'role', 'view',
	'view: A joins as a viewer');
select is(pg_temp.affected($q$update public.collab_documents set title = 'renamed'
	where id = 'd0000000-0000-4000-8000-0000000000b1'$q$), 0::bigint,
	'view: A cannot rename');

select pg_temp.as_user('a0000000-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000cb');
select is((select count(*) from public.collab_documents where id = 'd0000000-0000-4000-8000-0000000000b1'), 0::bigint,
	'view: the grant is to A, so W still sees nothing');

reset role;
set local role service_role;
select pg_temp.as_server();
select throws_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'aa', 'VQEA', 'comment')$$, '42501', null,
	'view: the log refuses even a comment from a viewer');
reset role;

set local role authenticated;
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000cb');
select is((public.collab_share('d0000000-0000-4000-8000-0000000000b1', 'alice-c', 'comment')).role, 'comment',
	'Bob raises A to comment (the view grant is replaced)');
select is((select count(*) from public.collab_grants where doc_id = 'd0000000-0000-4000-8000-0000000000b1' and revoked_at is null),
	1::bigint, 'one live grant per grantee');
reset role;
set local role service_role;
select pg_temp.as_server();
select is(public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'aa', 'VQEA', 'comment'), 2::bigint, 'comment: a comment is accepted');
select throws_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'aa', 'VQEA', 'suggest')$$, '42501', null,
	'comment: a suggestion is refused');
select throws_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'bbbbbbbb-0000-4000-8000-0000000000cb',
	'b0000000-0000-4000-8000-0000000000c2', 'aa', 'VQEA', 'edit')$$, '42501', null,
	'an agent that wrote as A cannot later write as B');
reset role;

set local role authenticated;
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000cb');
select is((public.collab_share('d0000000-0000-4000-8000-0000000000b1', 'alice-c', 'suggest')).role, 'suggest', 'Bob raises A to suggest');
reset role;
set local role service_role;
select pg_temp.as_server();
select lives_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'aa', 'VQEA', 'suggest')$$, 'suggest: a suggestion is accepted');
select throws_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'aa', 'VQEA', 'edit')$$, '42501', null,
	'suggest: a direct edit is refused');
reset role;

set local role authenticated;
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000cb');
select is((public.collab_share('d0000000-0000-4000-8000-0000000000b1', 'alice-c', 'edit')).role, 'edit', 'Bob raises A to edit');
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000ca');
select is(pg_temp.affected($q$update public.collab_documents set title = 'Pitch v2'
	where id = 'd0000000-0000-4000-8000-0000000000b1'$q$), 1::bigint,
	'edit: A can rename');
select is(pg_temp.affected($q$delete from public.collab_documents
	where id = 'd0000000-0000-4000-8000-0000000000b1'$q$), 0::bigint,
	'edit: but only the owner can delete');
reset role;
set local role service_role;
select pg_temp.as_server();
select lives_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'aa', 'VQEA', 'edit')$$, 'edit: a direct edit is accepted');
reset role;

-- ---------------------------------------------------------------------------
-- Revocation
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000cb');
select is(pg_temp.affected($q$update public.collab_grants set revoked_at = now()
	where doc_id = 'd0000000-0000-4000-8000-0000000000b1' and revoked_at is null$q$),
	1::bigint, 'Bob revokes A''s grant');
select pg_temp.as_user('a0000000-0000-4000-8000-0000000000c1', 'aaaaaaaa-0000-4000-8000-0000000000ca');
select is((select count(*) from public.collab_documents where id = 'd0000000-0000-4000-8000-0000000000b1'), 0::bigint,
	'revoked: A sees nothing of the deck');
select is((select count(*) from public.collab_updates where doc_id = 'd0000000-0000-4000-8000-0000000000b1'), 0::bigint,
	'revoked: nor its updates');
select is(public.collab_join('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca') ->> 'role', null,
	'revoked: joining is refused');
reset role;
set local role service_role;
select pg_temp.as_server();
select throws_ok($$select public.collab_append('d0000000-0000-4000-8000-0000000000b1', 'aaaaaaaa-0000-4000-8000-0000000000ca',
	'a0000000-0000-4000-8000-0000000000c1', 'aa', 'VQEA', 'comment')$$, '42501', null,
	'revoked: the log refuses A at once');
reset role;

-- ---------------------------------------------------------------------------
-- Link shares
-- ---------------------------------------------------------------------------

set local role authenticated;
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000cb');
select is(length(set_config('collab.test_link', public.collab_make_link('d0000000-0000-4000-8000-0000000000b1', 'comment'), true)), 48, 'Bob makes a comment link; its token is shown once');
select throws_ok($$select public.collab_make_link('d0000000-0000-4000-8000-0000000000b1', 'edit')$$, '22023', null,
	'a link cannot grant edit');
select pg_temp.as_user('c0000000-0000-4000-8000-0000000000c3', 'cccccccc-0000-4000-8000-0000000000cc');
select is(public.collab_join('d0000000-0000-4000-8000-0000000000b1', 'cccccccc-0000-4000-8000-0000000000cc',
	current_setting('collab.test_link')) ->> 'role', 'comment', 'link: Carol joins with the token as a commenter');
select is(public.collab_join('d0000000-0000-4000-8000-0000000000b1', 'cccccccc-0000-4000-8000-0000000000cc',
	'not-the-token') ->> 'role', null, 'link: a wrong token gives nothing');
select is((select count(*) from public.collab_links), 0::bigint, 'link: Carol cannot list Bob''s links or their hashes');
select pg_temp.as_user('b0000000-0000-4000-8000-0000000000c2', 'bbbbbbbb-0000-4000-8000-0000000000cb');
select is(pg_temp.affected($q$update public.collab_links set revoked_at = now()$q$), 1::bigint,
	'Bob revokes the link');
select pg_temp.as_user('c0000000-0000-4000-8000-0000000000c3', 'cccccccc-0000-4000-8000-0000000000cc');
select is(public.collab_join('d0000000-0000-4000-8000-0000000000b1', 'cccccccc-0000-4000-8000-0000000000cc',
	current_setting('collab.test_link')) ->> 'role', null, 'link: a revoked link gives nothing');

select * from finish();
rollback;
