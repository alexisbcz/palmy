-- dav: identity isolation, grants, revocation, scheduling messages, app
-- passwords and the sync log. The contract's test (cloud/CONTRACT.md): a
-- session scoped to identity A, asking for B's rows, gets nothing, and
-- writing them fails.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(68);

-- People and identities ------------------------------------------------------

insert into auth.users (id, email, aud, role) values
	('a0000000-0000-0000-0000-00000000000a', 'alice@example.test', 'authenticated', 'authenticated'),
	('b0000000-0000-0000-0000-00000000000b', 'bob@example.test', 'authenticated', 'authenticated');

insert into public.identities (id, owner, handle, display_name, kind) values
	('a1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-00000000000a', 'alice', 'Alice', 'personal'),
	('a2000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-00000000000a', 'alice-work', 'Alice at work', 'work'),
	('b1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-00000000000b', 'bob', 'Bob', 'personal');

-- Sessions: as(user, identity or null for unscoped).
create function pg_temp.as_(usr uuid, ident uuid) returns void language plpgsql as $$
begin
	perform set_config('role', 'authenticated', true);
	perform set_config('request.jwt.claims', json_build_object(
		'sub', usr, 'role', 'authenticated',
		'palm_identity', coalesce(ident::text, ''))::text, true);
end $$;
create function pg_temp.as_postgres() returns void language plpgsql as $$
begin
	perform set_config('role', 'postgres', true);
	perform set_config('request.jwt.claims', '', true);
end $$;

-- A small event, and its index.
create function pg_temp.ev(uid text) returns text language sql as $$
	select 'BEGIN:VCALENDAR' || chr(13) || chr(10) || 'VERSION:2.0' || chr(13) || chr(10) ||
	       'BEGIN:VEVENT' || chr(13) || chr(10) || 'UID:' || uid || chr(13) || chr(10) ||
	       'DTSTART:20261020T090000Z' || chr(13) || chr(10) || 'SUMMARY:' || uid || chr(13) || chr(10) ||
	       'END:VEVENT' || chr(13) || chr(10) || 'END:VCALENDAR' || chr(13) || chr(10)
$$;
create function pg_temp.ix(uid text) returns jsonb language sql as $$
	select jsonb_build_object('uid', uid, 'component', 'VEVENT',
		'dtstart', '2026-10-20T09:00:00Z', 'dtend', '2026-10-20T10:00:00Z',
		'first_start', '2026-10-20T09:00:00Z', 'last_end', '2026-10-20T10:00:00Z',
		'summary', uid)
$$;

-- Each identity sets itself up -----------------------------------------------

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
select lives_ok($$ select public.dav_ensure_defaults('a1000000-0000-0000-0000-000000000001') $$,
	'alice gets a default calendar and address book');
select is((select count(*)::int from public.dav_collections), 2, 'alice sees her two collections');
select lives_ok($$ select * from public.dav_put_object(
	(select id from public.dav_collections where kind = 'calendar'), 'a.ics', null, true,
	pg_temp.ix('alice-1'), pg_temp.ev('alice-1')) $$, 'alice puts an event');
select is((select count(*)::int from public.dav_objects), 1, 'alice sees her event');

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000002');
select lives_ok($$ select public.dav_ensure_defaults('a2000000-0000-0000-0000-000000000002') $$,
	'alice-work gets defaults');
select lives_ok($$ select * from public.dav_put_object(
	(select id from public.dav_collections where kind = 'calendar'), 'w.ics', null, true,
	pg_temp.ix('work-1'), pg_temp.ev('work-1')) $$, 'alice-work puts an event');

select pg_temp.as_('b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001');
select lives_ok($$ select public.dav_ensure_defaults('b1000000-0000-0000-0000-000000000001') $$,
	'bob gets defaults');
select lives_ok($$ select * from public.dav_put_object(
	(select id from public.dav_collections where kind = 'calendar'), 'b.ics', null, true,
	pg_temp.ix('bob-1'), pg_temp.ev('bob-1')) $$, 'bob puts an event');

select pg_temp.as_postgres();
create temp table ids as select
	(select id from public.dav_collections where identity_id = 'a1000000-0000-0000-0000-000000000001' and kind = 'calendar') as a_cal,
	(select id from public.dav_collections where identity_id = 'a1000000-0000-0000-0000-000000000001' and kind = 'addressbook') as a_book,
	(select id from public.dav_collections where identity_id = 'a2000000-0000-0000-0000-000000000002' and kind = 'calendar') as w_cal,
	(select id from public.dav_collections where identity_id = 'b1000000-0000-0000-0000-000000000001' and kind = 'calendar') as b_cal;
grant select on ids to authenticated;

-- Isolation: scoped to A, B's rows do not exist --------------------------------

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.dav_collections where id = (select b_cal from ids)), 0,
	'scoped to alice: bob''s calendar is invisible');
select is((select count(*)::int from public.dav_objects where identity_id = 'b1000000-0000-0000-0000-000000000001'), 0,
	'scoped to alice: bob''s events are invisible');
select is((select count(*)::int from public.dav_changes where collection_id = (select b_cal from ids)), 0,
	'scoped to alice: bob''s change log is invisible');
select throws_ok($$ select * from public.dav_put_object((select b_cal from ids), 'x.ics', null, true,
	pg_temp.ix('intruder'), pg_temp.ev('intruder')) $$, '42501', null,
	'scoped to alice: writing into bob''s calendar fails');
select throws_ok($$ insert into public.dav_objects (identity_id, collection_id, name, uid, component, body, etag)
	values ('b1000000-0000-0000-0000-000000000001', (select b_cal from ids), 'y.ics', 'y', 'VEVENT', 'x', 'x') $$,
	'42501', null, 'scoped to alice: a raw insert into bob''s calendar fails');
update public.dav_objects set summary = 'pwned' where identity_id = 'b1000000-0000-0000-0000-000000000001';
delete from public.dav_objects where identity_id = 'b1000000-0000-0000-0000-000000000001';
update public.dav_collections set display_name = 'pwned' where id = (select b_cal from ids);
select is((select count(*)::int from public.dav_sync((select b_cal from ids), 0)), 0,
	'scoped to alice: bob''s sync log is empty');
select is((select count(*)::int from public.dav_list_collections('b1000000-0000-0000-0000-000000000001')), 0,
	'scoped to alice: listing bob''s home returns nothing');

-- Same person, other identity: scoped to alice, alice-work is just as closed.
select is((select count(*)::int from public.dav_objects where identity_id = 'a2000000-0000-0000-0000-000000000002'), 0,
	'scoped to alice: alice-work''s events are invisible');
select throws_ok($$ select * from public.dav_put_object((select w_cal from ids), 'z.ics', null, true,
	pg_temp.ix('cross'), pg_temp.ev('cross')) $$, '42501', null,
	'scoped to alice: writing into alice-work fails');

select pg_temp.as_postgres();
select is((select summary from public.dav_objects where uid = 'bob-1'), 'bob-1', 'bob''s event was not changed');
select is((select display_name from public.dav_collections where id = (select b_cal from ids)), 'Calendar',
	'bob''s calendar was not renamed');
select is((select count(*)::int from public.dav_objects where uid = 'intruder' or uid = 'cross'), 0,
	'nothing was written across identities');

-- Unscoped: the person sees all of their own identities, none of anyone else's.
select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', null);
select is((select count(*)::int from public.dav_objects), 2, 'unscoped alice sees alice and alice-work');
select is((select count(*)::int from public.dav_objects where identity_id = 'b1000000-0000-0000-0000-000000000001'), 0,
	'unscoped alice still does not see bob');

-- Grants: exactly what they say -----------------------------------------------

-- Bob cannot grant himself alice's calendar, either way round.
select pg_temp.as_('b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001');
select throws_ok($$ insert into public.dav_grants (identity_id, collection_id, grantee_identity, access)
	values ('a1000000-0000-0000-0000-000000000001', (select a_cal from ids), 'b1000000-0000-0000-0000-000000000001', 'read') $$,
	'42501', null, 'bob cannot make a grant in alice''s name');
select throws_ok($$ insert into public.dav_grants (identity_id, collection_id, grantee_identity, access)
	values ('b1000000-0000-0000-0000-000000000001', (select a_cal from ids), 'b1000000-0000-0000-0000-000000000001', 'read') $$,
	'42501', null, 'bob cannot grant a collection he does not own');

-- Alice shares her calendar with bob, read-only.
select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
select lives_ok($$ insert into public.dav_grants (identity_id, collection_id, grantee_identity, access)
	values ('a1000000-0000-0000-0000-000000000001', (select a_cal from ids), 'b1000000-0000-0000-0000-000000000001', 'read') $$,
	'alice shares her calendar with bob, read-only');

select pg_temp.as_('b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.dav_collections where id = (select a_cal from ids)), 1,
	'read grant: bob sees the shared calendar');
select is((select count(*)::int from public.dav_objects where collection_id = (select a_cal from ids)), 1,
	'read grant: bob sees its event');
select is((select count(*)::int from public.dav_collections where id = (select a_book from ids)), 0,
	'read grant: bob does not see alice''s address book, which was not shared');
select is((select count(*)::int from public.dav_objects where identity_id = 'a2000000-0000-0000-0000-000000000002'), 0,
	'read grant: bob does not see alice-work');
select is((select access from public.dav_list_collections('b1000000-0000-0000-0000-000000000001', 'calendar')
	where id = (select a_cal from ids)), 'read', 'bob''s home lists the share with read access');
select is((select owner_handle from public.dav_list_collections('b1000000-0000-0000-0000-000000000001', 'calendar')
	where id = (select a_cal from ids)), 'alice', 'and names its owner');
select throws_ok($$ select * from public.dav_put_object((select a_cal from ids), 'bob.ics', null, true,
	pg_temp.ix('bob-in-alice'), pg_temp.ev('bob-in-alice')) $$, '42501', null,
	'read grant: bob cannot add an event');
select throws_ok($$ select * from public.dav_put_object((select a_cal from ids), 'a.ics', null, false,
	pg_temp.ix('alice-1'), pg_temp.ev('alice-1') || 'X') $$, '42501', null,
	'read grant: bob cannot change an event');
select throws_ok($$ select public.dav_delete_object((select a_cal from ids), 'a.ics', null) $$, '42501', null,
	'read grant: bob cannot delete an event');
update public.dav_collections set display_name = 'Bob was here' where id = (select a_cal from ids);
select is((select count(*)::int from public.dav_sync((select a_cal from ids), 0)), 1,
	'read grant: bob can sync the shared calendar');

-- The grant is to bob, the identity: alice-work (another identity, even of the
-- same owner) gets nothing from it.
select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.dav_objects where collection_id = (select a_cal from ids)), 0,
	'scoped to alice-work: alice''s calendar stays closed');

select pg_temp.as_postgres();
select is((select display_name from public.dav_collections where id = (select a_cal from ids)), 'Calendar',
	'a grantee cannot rename the collection');

-- Upgrade to read-write.
select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
update public.dav_grants set access = 'read-write' where collection_id = (select a_cal from ids);

select pg_temp.as_('b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001');
select lives_ok($$ select * from public.dav_put_object((select a_cal from ids), 'bob.ics', null, true,
	pg_temp.ix('bob-in-alice'), pg_temp.ev('bob-in-alice')) $$, 'read-write grant: bob adds an event');
select is((select identity_id from public.dav_objects where uid = 'bob-in-alice'),
	'a1000000-0000-0000-0000-000000000001'::uuid, 'and it belongs to alice, the owner');
select lives_ok($$ select public.dav_delete_object((select a_cal from ids), 'bob.ics', null) $$,
	'read-write grant: bob deletes it again');
select throws_ok($$ insert into public.dav_grants (identity_id, collection_id, grantee_identity, access)
	values ('b1000000-0000-0000-0000-000000000001', (select a_cal from ids), 'a2000000-0000-0000-0000-000000000002', 'read') $$,
	'42501', null, 'read-write grant: bob still cannot re-share alice''s calendar');

-- Revocation.
select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
delete from public.dav_grants where collection_id = (select a_cal from ids);
select pg_temp.as_('b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.dav_collections where id = (select a_cal from ids)), 0,
	'revoked: the calendar is gone from bob''s view');
select is((select count(*)::int from public.dav_objects where collection_id = (select a_cal from ids)), 0,
	'revoked: so are its events');
select is((select count(*)::int from public.dav_changes where collection_id = (select a_cal from ids)), 0,
	'revoked: and its change log');
select throws_ok($$ select * from public.dav_put_object((select a_cal from ids), 'late.ics', null, true,
	pg_temp.ix('late'), pg_temp.ev('late')) $$, '42501', null, 'revoked: bob can no longer write');

-- The grantee may decline.
select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
insert into public.dav_grants (identity_id, collection_id, grantee_identity, access)
	values ('a1000000-0000-0000-0000-000000000001', (select a_cal from ids), 'b1000000-0000-0000-0000-000000000001', 'read');
select pg_temp.as_('b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001');
delete from public.dav_grants where collection_id = (select a_cal from ids);
select pg_temp.as_postgres();
select is((select count(*)::int from public.dav_grants), 0, 'bob declined the share');

-- Scheduling messages ------------------------------------------------------------

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
select lives_ok($$ insert into public.dav_itip (identity_id, sender_address, recipient_address, method, uid, body)
	values ('a1000000-0000-0000-0000-000000000001', 'mailto:alice@palm.test', 'mailto:bob@palm.test', 'REQUEST', 'm1', 'x') $$,
	'alice invites bob');
select lives_ok($$ insert into public.dav_itip (identity_id, sender_address, recipient_address, method, uid, body)
	values ('a1000000-0000-0000-0000-000000000001', 'mailto:alice@palm.test', 'mailto:carol@example.com', 'REQUEST', 'm1', 'x') $$,
	'alice invites someone outside');
select throws_ok($$ insert into public.dav_itip (identity_id, sender_address, recipient_address, method, uid, body)
	values ('b1000000-0000-0000-0000-000000000001', 'mailto:bob@palm.test', 'mailto:alice@palm.test', 'REPLY', 'm1', 'x') $$,
	'42501', null, 'alice cannot send in bob''s name');
select is((select status from public.dav_itip where recipient_address = 'mailto:carol@example.com'),
	'not sent: outbound not enabled', 'the outside invitation is queued, not sent');
select is((select recipient_identity from public.dav_itip where recipient_address = 'mailto:bob@palm.test'),
	'b1000000-0000-0000-0000-000000000001'::uuid, 'the local one is routed to bob');
update public.dav_itip set processed_at = now() where recipient_address = 'mailto:bob@palm.test';

select pg_temp.as_('b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.dav_itip), 1, 'bob sees the invitation, not the outside one');
select is((select processed_at from public.dav_itip), null, 'the sender could not mark it processed');
update public.dav_itip set processed_at = now();
select isnt((select processed_at from public.dav_itip), null, 'bob marks it processed');
select is(public.dav_identity_handle('a1000000-0000-0000-0000-000000000001'), 'alice',
	'bob may name the identity that wrote to him');
select is(public.dav_identity_handle('a2000000-0000-0000-0000-000000000002'), null,
	'but not alice''s other identities');

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000002');
select is((select count(*)::int from public.dav_itip), 0, 'scoped to alice-work: alice''s invitations are invisible');

-- App passwords -----------------------------------------------------------------

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
select throws_ok($$ select * from public.dav_app_password_create('a1000000-0000-0000-0000-000000000001', 'x') $$,
	'42501', null, 'a scoped session cannot mint an app password');

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', null);
create temp table pw as select * from public.dav_app_password_create('a1000000-0000-0000-0000-000000000001', 'Thunderbird');
select is((select length(secret) from pw), 32, 'an unscoped session mints one, shown once');
reset role;
grant select on pw to service_role;
select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', null);
select throws_ok($$ select * from public.dav_app_password_create('b1000000-0000-0000-0000-000000000001', 'x') $$,
	'42501', null, 'nobody mints one for an identity they do not own');

select pg_temp.as_('b0000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from public.dav_app_passwords), 0, 'bob cannot list alice''s app passwords');
select throws_ok($$ select * from public.dav_app_password_check('alice', 'whatever') $$, '42501', null,
	'a user session cannot call the credential check');

select pg_temp.as_postgres();
set local role service_role;
select is((select handle from public.dav_app_password_check('alice@palm.test', (select secret from pw))), 'alice',
	'the server checks the secret and gets the identity');
select is((select count(*)::int from public.dav_app_password_check('bob', (select secret from pw))), 0,
	'the secret is bound to its identity');

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', null);
select ok(public.dav_app_password_revoke((select id from pw)), 'alice revokes it');
select pg_temp.as_postgres();
set local role service_role;
select is((select count(*)::int from public.dav_app_password_check('alice', (select secret from pw))), 0,
	'a revoked app password stops working at once');

-- Sync log and tombstones ------------------------------------------------------

select pg_temp.as_('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001');
create temp table tok as select sync_seq from public.dav_collections where id = (select a_cal from ids);
select public.dav_delete_object((select a_cal from ids), 'a.ics', null);
select is((select deleted from public.dav_sync((select a_cal from ids), (select sync_seq from tok)) where name = 'a.ics'),
	true, 'a delete leaves a tombstone in the sync log');
select is((select invalid from public.dav_sync((select a_cal from ids), 99999) limit 1), true,
	'a token from the future is refused');

select * from finish();
rollback;
