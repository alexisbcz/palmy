-- Chat and calls' half of the contract test.
--
-- A session scoped to identity A reads none of B's spaces, channels, messages,
-- reactions, calls or attachments, and cannot write them. That holds between
-- two identities of the *same person* too. An invite grants exactly what it
-- names, and only once accepted; leaving or being removed takes it away.
begin;
create extension if not exists pgtap with schema extensions;
select plan(90);

-- Three people. Alice has a work and a personal identity, Bob a work and a
-- personal one, Carol (a contractor) one.
insert into auth.users (id, email) values
	('a0000000-0000-0000-0000-000000000001', 'alice@palm.test'),
	('b0000000-0000-0000-0000-000000000002', 'bob@palm.test'),
	('c0000000-0000-0000-0000-000000000003', 'carol@palm.test');
insert into public.identities (id, owner, handle, display_name, kind, color) values
	('a1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'alice', 'Alice', 'personal', 'rose'),
	('a2000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'alice.northwind', 'Alice Martin', 'work', 'indigo'),
	('b1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000002', 'bob', 'Bob', 'personal', 'amber'),
	('b2000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000002', 'bob.northwind', 'Bob Chen', 'work', 'emerald'),
	('c1000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000003', 'carol', 'Carol Diaz', 'work', 'sky');

create function pg_temp.become(uid text, ident text default null) returns void
language plpgsql as $$
begin
	perform set_config('request.jwt.claims', json_strip_nulls(json_build_object(
		'sub', uid, 'role', 'authenticated', 'palm_identity', ident))::text, true);
	set local role authenticated;
end
$$;
grant execute on function pg_temp.become(text, text) to public;

-- Short names for the ids, as psql variables would be awkward inside $$.
create temp table ids (k text primary key, v uuid);
grant all on ids to public;
insert into ids values
	('alice', 'a0000000-0000-0000-0000-000000000001'), ('bob', 'b0000000-0000-0000-0000-000000000002'),
	('carol', 'c0000000-0000-0000-0000-000000000003'),
	('a.home', 'a1000000-0000-0000-0000-000000000001'), ('a.work', 'a2000000-0000-0000-0000-000000000002'),
	('b.home', 'b1000000-0000-0000-0000-000000000001'), ('b.work', 'b2000000-0000-0000-0000-000000000002'),
	('c', 'c1000000-0000-0000-0000-000000000001'),
	('space', 'd0000000-0000-0000-0000-000000000001');
create function pg_temp.id(k text) returns uuid language sql stable as $$ select v from ids where ids.k = id.k $$;
grant execute on function pg_temp.id(text) to public;

-- ---------------------------------------------------------------------------
-- Alice, as her work identity, makes a space.
-- ---------------------------------------------------------------------------
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002');
insert into rtc_spaces (id, identity_id, name) values (pg_temp.id('space'), pg_temp.id('a.work'), 'Northwind');
select is((select count(*)::int from rtc_channels where space_id = pg_temp.id('space')), 1, 'a new space comes with #general');
select is((select role from rtc_members where identity_id = pg_temp.id('a.work')), 'owner', 'and its owner is its first member');
insert into rtc_channels (space_id, identity_id, kind, name, topic)
values (pg_temp.id('space'), pg_temp.id('a.work'), 'private', 'design', 'Pixels');
insert into ids select 'general', id from rtc_channels where name = 'general';
insert into ids select 'design', id from rtc_channels where name = 'design';
insert into rtc_messages (channel_id, identity_id, body) values (pg_temp.id('general'), pg_temp.id('a.work'), 'welcome to northwind');
insert into rtc_messages (channel_id, identity_id, body) values (pg_temp.id('general'), pg_temp.id('a.work'), 'the deploy is on thursday');
insert into rtc_messages (channel_id, identity_id, body) values (pg_temp.id('design'), pg_temp.id('a.work'), 'secret mockups');
select is((select array_agg(seq order by id) from rtc_messages where channel_id = pg_temp.id('general')), array[1,2]::bigint[],
	'messages take the channel''s next sequence number');
select is((select last_seq from rtc_channels where id = pg_temp.id('design')), 1::bigint, 'each channel counts on its own');
select throws_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('general'), pg_temp.id('a.home'), 'as personal') $$,
	'42501', null, 'scoped to work, Alice cannot post as her personal identity');
select throws_ok($$ insert into rtc_spaces (identity_id, name) values (pg_temp.id('a.home'), 'x') $$,
	'42501', null, '... nor create a space owned by it');
reset role;

-- ---------------------------------------------------------------------------
-- Nobody else sees any of it.
-- ---------------------------------------------------------------------------
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from rtc_spaces), 0, 'Alice scoped to personal does not see her work space');
select is((select count(*)::int from rtc_channels), 0, '... nor its channels');
select is((select count(*)::int from rtc_messages), 0, '... nor its messages');
select is((select count(*)::int from rtc_search('deploy')), 0, '... not even through search');
select throws_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('general'), pg_temp.id('a.home'), 'hello?') $$,
	'42501', null, '... and cannot post into it');
reset role;

select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002');
select is((select count(*)::int from rtc_messages), 0, 'Bob, not yet invited, sees no messages');
select is((select count(*)::int from rtc_members), 0, '... and no members');
select throws_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('general'), pg_temp.id('b.work'), 'let me in') $$,
	'42501', null, '... and cannot post');
select throws_ok($$ insert into rtc_invites (space_id, identity_id, invitee_handle)
	values (pg_temp.id('space'), pg_temp.id('b.work'), 'bob.northwind') $$,
	'42501', null, '... nor invite himself');
select is(rtc_object_channel('loose/file.txt'), null, 'a storage name without a channel folder resolves to no channel');
reset role;

select pg_temp.become('b0000000-0000-0000-0000-000000000002');
select is((select count(*)::int from rtc_channels), 0, 'Bob unscoped sees nothing either');
reset role;

-- ---------------------------------------------------------------------------
-- Invites grant exactly what they say.
-- ---------------------------------------------------------------------------
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002');
insert into rtc_invites (space_id, identity_id, invitee_handle, role)
values (pg_temp.id('space'), pg_temp.id('a.work'), 'bob.northwind', 'member');
insert into rtc_invites (space_id, channel_id, identity_id, invitee_handle, role)
values (pg_temp.id('space'), pg_temp.id('design'), pg_temp.id('a.work'), 'carol', 'guest');
insert into rtc_invites (space_id, identity_id, invitee_handle, role)
values (pg_temp.id('space'), pg_temp.id('a.work'), 'alice', 'member');
select throws_ok($$ insert into rtc_invites (space_id, identity_id, invitee_handle)
	values (pg_temp.id('space'), pg_temp.id('a.work'), 'nobody-here') $$,
	'P0002', null, 'an invite to a handle that does not exist is refused');
reset role;
insert into ids select 'inv.bob', id from rtc_invites where invitee_handle = 'bob.northwind';
insert into ids select 'inv.carol', id from rtc_invites where invitee_handle = 'carol';
insert into ids select 'inv.alice', id from rtc_invites where invitee_handle = 'alice';

select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002');
select is((select count(*)::int from rtc_invites), 1, 'Bob sees the invite addressed to him');
select is((select count(*)::int from rtc_messages), 0, 'but an unaccepted invite grants nothing');
select lives_ok($$ select rtc_accept_invite(pg_temp.id('inv.bob')) $$, 'Bob accepts');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('general')), 2, 'and now reads #general');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('design')), 0, 'but not the private #design');
select is((select count(*)::int from rtc_channels), 1, 'he sees one channel');
select is((select count(*)::int from rtc_search('deploy')), 1, 'search finds the message he can read');
select is((select count(*)::int from rtc_search('mockups')), 0, 'and not the one he cannot');
select is((select display_name from rtc_members where identity_id = pg_temp.id('a.work')), 'Alice Martin',
	'members see each other''s names through the member snapshot');
select is((select count(*)::int from identities), 1, 'while identities themselves stay private');
select lives_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('general'), pg_temp.id('b.work'), 'hi all') $$, 'Bob posts in #general');
select throws_ok($$ insert into rtc_channels (space_id, identity_id, kind, name)
	values (pg_temp.id('space'), pg_temp.id('b.work'), 'dm', 'sneaky') $$,
	'42501', null, 'a DM cannot be made by a plain insert');
reset role;

select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from rtc_messages), 0, 'Bob scoped to personal sees nothing his work identity joined');
select throws_ok($$ select rtc_accept_invite(pg_temp.id('inv.bob')) $$, 'P0002', null,
	'... and cannot use his work identity''s invite');
reset role;

select pg_temp.become('b0000000-0000-0000-0000-000000000002');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('general')), 3,
	'Bob unscoped reads through his work identity''s membership');
select throws_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('general'), pg_temp.id('b.home'), 'from home') $$,
	'42501', null, '... but cannot post as his personal identity, which is not a member');
reset role;

-- Carol: a guest invited to one private channel gets that channel and nothing else.
select pg_temp.become('c0000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000001');
select lives_ok($$ select rtc_accept_invite(pg_temp.id('inv.carol')) $$, 'Carol accepts a guest invite to #design');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('design')), 1, 'Carol reads #design');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('general')), 0, 'but not #general');
select is((select role from rtc_members where identity_id = pg_temp.id('c')), 'guest', 'she is a guest of the space');
select throws_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('general'), pg_temp.id('c'), 'hello?') $$, '42501', null, 'and cannot post in #general');
select lives_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('design'), pg_temp.id('c'), 'mockups look great') $$, 'she can post in #design');
select throws_ok($$ insert into rtc_channels (space_id, identity_id, kind, name)
	values (pg_temp.id('space'), pg_temp.id('c'), 'public', 'guests-rule') $$,
	'42501', null, 'a guest cannot create channels');
select throws_ok($$ select rtc_open_dm(pg_temp.id('space'), pg_temp.id('c'), pg_temp.id('b.work')) $$,
	'42501', null, 'a guest cannot DM someone she shares no channel with');
reset role;

create temp table mids as select 'design' as k, max(id) as id from rtc_messages where channel_id = pg_temp.id('design');
grant select on mids to public;

-- Alice's personal identity: same person, still needs the invite.
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from rtc_messages), 0, 'Alice''s own personal identity is not in until it accepts');
select lives_ok($$ select rtc_accept_invite(pg_temp.id('inv.alice')) $$, 'it accepts');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('general')), 3, 'and reads #general');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('design')), 0,
	'but not #design, which only her work identity is in');
reset role;

-- ---------------------------------------------------------------------------
-- Threads, reactions, edits, read cursors, sync.
-- ---------------------------------------------------------------------------
select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002');
insert into rtc_messages (channel_id, identity_id, body) values (pg_temp.id('general'), pg_temp.id('b.work'), 'which time?');
create temp table t_root on commit drop as select id from rtc_messages where body = 'the deploy is on thursday';
grant select on t_root to public;
insert into rtc_messages (channel_id, identity_id, body, thread_root)
values (pg_temp.id('general'), pg_temp.id('b.work'), 'in the thread: 10am?', (select id from t_root));
insert into rtc_messages (channel_id, identity_id, body, thread_root)
values (pg_temp.id('general'), pg_temp.id('b.work'), 'reply to the reply',
        (select id from rtc_messages where body = 'in the thread: 10am?'));
select is((select replies from rtc_messages where id = (select id from t_root)), 2, 'the root counts its replies');
select is((select count(*)::int from rtc_messages where thread_root = (select id from t_root)), 2,
	'a reply to a reply lands in the same thread');
select throws_ok($$ insert into rtc_messages (channel_id, identity_id, body, thread_root)
	values (pg_temp.id('general'), pg_temp.id('b.work'), 'x',
	        (select id from mids where k = 'design')) $$,
	'22023', null, 'a thread root in another channel is refused');
create temp table t_rev on commit drop as select last_seq as rev from rtc_channels where id = pg_temp.id('general');
grant select on t_rev to public;
insert into rtc_reactions (message_id, identity_id, key) values ((select id from t_root), pg_temp.id('b.work'), 'thumbsup');
select ok((select rev from rtc_messages where id = (select id from t_root)) > (select rev from t_rev),
	'a reaction moves its message''s rev');
select is((select count(*)::int from rtc_changes(pg_temp.id('general'), (select rev from t_rev))), 1,
	'and sync since the old rev returns exactly that message');
select is((select count(*)::int from rtc_changes(pg_temp.id('general'), 0)),
          (select count(*)::int from rtc_messages where channel_id = pg_temp.id('general')),
	'sync from zero returns every message once');
select is((select count(*)::int from (select seq from rtc_messages where channel_id = pg_temp.id('general')) s),
          (select count(distinct seq)::int from rtc_messages where channel_id = pg_temp.id('general')),
	'sequence numbers are unique in a channel');
select is((select count(*)::int from (
	select m.rev from rtc_messages m where m.channel_id = pg_temp.id('general')
	union all select 0) x where rev > (select last_seq from rtc_channels where id = pg_temp.id('general'))), 0,
	'no rev is above the channel''s counter');
update rtc_messages set body = 'edited by bob' where body = 'welcome to northwind';
select is((select count(*)::int from rtc_messages where body = 'welcome to northwind'), 1, 'Bob cannot edit Alice''s message');
select lives_ok($$ update rtc_messages set body = 'hi all (edited)' where body = 'hi all' $$, 'but edits his own');
select isnt((select edited_at from rtc_messages where body = 'hi all (edited)'), null, 'which marks it edited');
select throws_ok($$ update rtc_messages set thread_root = null where body = 'in the thread: 10am?' $$,
	'42501', null, 'columns other than the body cannot be changed');
select lives_ok($$ update rtc_messages set deleted_at = now() where body = 'which time?' $$, 'he deletes one');
select is((select count(*)::int from rtc_messages where deleted_at is not null and body = ''), 1, 'it becomes a tombstone');
insert into rtc_reads (channel_id, identity_id, message_id) values (pg_temp.id('general'), pg_temp.id('b.work'), 9223372036854775807);
select is((select message_id from rtc_reads where identity_id = pg_temp.id('b.work')),
          (select max(id) from rtc_messages where channel_id = pg_temp.id('general')),
	'a read cursor is clamped to a message that exists');
update rtc_reads set message_id = 1 where identity_id = pg_temp.id('b.work');
select is((select message_id from rtc_reads where identity_id = pg_temp.id('b.work')),
          (select max(id) from rtc_messages where channel_id = pg_temp.id('general')),
	'and only moves forward');
reset role;

select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002');
select is((select count(*)::int from rtc_reads where identity_id = pg_temp.id('b.work')), 1,
	'a co-member sees Bob''s read receipt');
select is((select count(*)::int from rtc_reactions where identity_id = pg_temp.id('b.work')), 1, 'and his reaction');
select lives_ok($$ select rtc_open_dm(pg_temp.id('space'), pg_temp.id('a.work'), pg_temp.id('b.work')) $$,
	'Alice opens a DM with Bob');
insert into ids select 'dm', id from rtc_channels where kind = 'dm';
select is((select rtc_open_dm(pg_temp.id('space'), pg_temp.id('a.work'), pg_temp.id('b.work'))), pg_temp.id('dm'),
	'opening it again finds the same one');
insert into rtc_messages (channel_id, identity_id, body) values (pg_temp.id('dm'), pg_temp.id('a.work'), 'just between us');
reset role;

select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('dm')), 0,
	'Alice''s personal identity, a member of the space, does not see her work DM');
reset role;
select pg_temp.become('c0000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('dm')), 0, 'nor does Carol');
reset role;

-- ---------------------------------------------------------------------------
-- Calls and attachments follow the channel.
-- ---------------------------------------------------------------------------
select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002');
select lives_ok($$ insert into rtc_calls (channel_id, identity_id) values (pg_temp.id('general'), pg_temp.id('b.work')) $$,
	'Bob starts a call in #general');
insert into ids select 'call', id from rtc_calls;
select lives_ok($$ insert into rtc_call_participants (call_id, identity_id) values (pg_temp.id('call'), pg_temp.id('b.work')) $$,
	'and joins it');
select lives_ok($$ insert into storage.objects (bucket_id, name, owner_id)
	values ('rtc', pg_temp.id('general')::text || '/f1/notes.txt', 'b0000000-0000-0000-0000-000000000002') $$,
	'he may upload into #general''s folder');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id)
	values ('rtc', pg_temp.id('design')::text || '/f2/peek.txt', 'b0000000-0000-0000-0000-000000000002') $$,
	'42501', null, 'but not into #design''s');
select throws_ok($$ insert into storage.objects (bucket_id, name, owner_id)
	values ('rtc', 'loose/file.txt', 'b0000000-0000-0000-0000-000000000002') $$,
	'42501', null, 'nor anywhere outside a channel folder');
reset role;

select pg_temp.become('c0000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from rtc_calls), 0, 'Carol does not see a call in a channel she is not in');
select throws_ok($$ insert into rtc_call_participants (call_id, identity_id) values (pg_temp.id('call'), pg_temp.id('c')) $$,
	'42501', null, '... and cannot join it');
select is((select count(*)::int from storage.objects where bucket_id = 'rtc'), 0, '... nor read its attachments');
reset role;

-- ---------------------------------------------------------------------------
-- Leaving and revoking.
-- ---------------------------------------------------------------------------
select pg_temp.become('a0000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002');
select lives_ok($$ update rtc_invites set revoked_at = now() where invitee_handle = 'carol' $$, 'Alice may revoke an invite row');
select lives_ok($$ delete from rtc_members where identity_id = pg_temp.id('c') $$, 'and removes Carol from the space');
select throws_ok($$ delete from rtc_members where identity_id = pg_temp.id('a.work') $$, '42501', null,
	'the owner cannot leave her own space');
insert into rtc_invites (space_id, channel_id, identity_id, invitee_handle, role)
values (pg_temp.id('space'), pg_temp.id('design'), pg_temp.id('a.work'), 'bob.northwind', 'member');
update rtc_invites set revoked_at = now() where invitee_handle = 'bob.northwind' and channel_id is not null;
reset role;

select pg_temp.become('c0000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000001');
select is((select count(*)::int from rtc_messages), 0, 'once removed, Carol reads nothing');
select is((select count(*)::int from rtc_channel_members), 0, 'and her channel membership went with the space');
select throws_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('design'), pg_temp.id('c'), 'still here?') $$, '42501', null, 'and she cannot post');
select throws_ok($$ select rtc_accept_invite(pg_temp.id('inv.carol')) $$, '22023', null,
	'a revoked invite cannot be used to come back');
reset role;

select pg_temp.become('b0000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002');
select throws_ok($$ select rtc_accept_invite((select id from rtc_invites where channel_id is not null and invitee_handle = 'bob.northwind')) $$,
	'22023', null, 'Bob cannot accept a channel invite revoked before he saw it');
select is((select count(*)::int from rtc_messages where channel_id = pg_temp.id('design')), 0, 'so #design stays closed');
select lives_ok($$ delete from rtc_members where identity_id = pg_temp.id('b.work') $$, 'Bob leaves the space');
select is((select count(*)::int from rtc_messages), 0, 'and reads nothing');
select is((select count(*)::int from rtc_channels), 0, 'not even the DM he was in');
select is((select count(*)::int from rtc_calls), 0, 'nor the call he started');
select throws_ok($$ insert into rtc_messages (channel_id, identity_id, body)
	values (pg_temp.id('general'), pg_temp.id('b.work'), 'one more') $$, '42501', null, 'and cannot post');
reset role;

select * from finish();
rollback;
