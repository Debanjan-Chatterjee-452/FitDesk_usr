-- Local test only. Safe to run against fitdesk_migration_test.

-- A member with no gym yet.
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
values (
  '22222222-2222-4222-8222-222222222222',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'join-test@example.test', null,
  now(), '{"provider":"email","providers":["email"]}'::jsonb,
  '{"full_name":"Join Test"}'::jsonb, now(), now()
)
on conflict (id) do nothing;

update public.profiles set gym_id = null, profile_completed = true
 where id = '22222222-2222-4222-8222-222222222222';

select set_config('test.join_code',
  (select join_code from public.gyms where owner_id = '11111111-1111-4111-8111-111111111111'),
  false);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222222', 'role', 'authenticated')::text,
  false
);
set role authenticated;
select 'request 1' as step, public.request_join_gym(current_setting('test.join_code')) as result;
select 'request 2 (no duplicate)' as step, public.request_join_gym(current_setting('test.join_code')) as result;
reset role;

select 'request rows' as step, count(*) as n
  from public.gym_join_requests
 where user_id = '22222222-2222-4222-8222-222222222222';

select set_config('test.request_id',
  (select id::text from public.gym_join_requests where user_id = '22222222-2222-4222-8222-222222222222'),
  false);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-4111-8111-111111111111', 'role', 'authenticated')::text,
  false
);
set role authenticated;
select 'pending count' as step, public.admin_pending_join_request_count() as n;
select 'request list' as step, status, member_name, member_phone
  from public.admin_list_join_requests();

select 'approve' as step, public.admin_review_join_request(
  current_setting('test.request_id')::uuid,
  true
) as result;
select 'approve again' as step, public.admin_review_join_request(
  current_setting('test.request_id')::uuid,
  true
) as result;
reset role;

select 'member gym set' as step, p.gym_id is not null as assigned, g.name as gym_name
  from public.profiles p join public.gyms g on g.id = p.gym_id
 where p.id = '22222222-2222-4222-8222-222222222222';
