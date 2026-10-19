-- Avatars in Storage follow the same rule: the first path segment is the
-- identity, and a scoped session reaches only its own.
begin;
select plan(8);

insert into auth.users (id, email, aud, role) values
	('a0000000-0000-4000-8000-000000000001', 'alice@palm.test', 'authenticated', 'authenticated');
insert into public.identities (id, owner, handle, display_name, kind) values
	('a1000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'alice', 'Alice', 'personal'),
	('a2000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'alice.work', 'Alice at work', 'work');
insert into storage.objects (bucket_id, name) values
	('avatars', 'a1000000-0000-4000-8000-00000000000a/avatar.png');

select is(public.storage_identity('a1000000-0000-4000-8000-00000000000a/avatar.png'),
          'a1000000-0000-4000-8000-00000000000a'::uuid, 'storage_identity reads the first segment');
select is(public.storage_identity('../avatar.png'), null, 'storage_identity: anything else is no identity');
select is((select public from storage.buckets where id = 'avatars'), false, 'the avatars bucket is private');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated","palm_identity":"a2000000-0000-4000-8000-00000000000a"}', true);

select is((select count(*)::int from storage.objects where bucket_id = 'avatars'), 0,
          'scoped to work: the personal avatar is invisible');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', 'a1000000-0000-4000-8000-00000000000a/other.png') $$,
                 '42501', null, 'scoped to work: writing under personal fails');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', 'avatar.png') $$,
                 '42501', null, 'an object outside any identity folder is refused');
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', 'a2000000-0000-4000-8000-00000000000a/avatar.png') $$,
                'scoped to work: writes its own avatar');

select set_config('request.jwt.claims', '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is((select count(*)::int from storage.objects where bucket_id = 'avatars'), 2, 'unscoped: alice sees both avatars');

select * from finish();
rollback;
