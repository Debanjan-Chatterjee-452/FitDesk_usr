-- Local test only. Safe to run against fitdesk_migration_test.

-- Fresh owner account with signup metadata, mimicking a confirmed signup.
insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
values (
  '11111111-1111-4111-8111-111111111111',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'owner-test@example.test', null,
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"gym_name":"Test New Gym","full_name":"Test Owner","phone":"9000099999"}'::jsonb,
  now(), now()
)
on conflict (id) do nothing;

select 'registered profile' as step, count(*) as n
  from public.profiles where id = '11111111-1111-4111-8111-111111111111';

-- Act as the new owner.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-4111-8111-111111111111', 'role', 'authenticated')::text,
  false
);
set role authenticated;

select 'first call' as step, public.register_gym_owner(null, null, null, null) as result;
select 'second call (idempotent)' as step, public.register_gym_owner('Test New Gym', 'Test Owner', '9000099999', null) as result;
reset role;

select 'gym count for owner' as step, count(*) as n
  from public.gyms where owner_id = '11111111-1111-4111-8111-111111111111';
select 'side rows' as step,
       (select count(*) from public.gym_settings s join public.gyms g on g.id=s.gym_id where g.owner_id = '11111111-1111-4111-8111-111111111111') as settings_rows,
       (select count(*) from public.gym_payment_methods m join public.gyms g on g.id=m.gym_id where g.owner_id = '11111111-1111-4111-8111-111111111111') as rail_rows,
       (select count(*) from public.gym_subscriptions s join public.gyms g on g.id=s.gym_id where g.owner_id = '11111111-1111-4111-8111-111111111111') as subscription_rows;
select 'new gym' as step, public_id, join_code, name, owner_id from public.gyms
 where owner_id = '11111111-1111-4111-8111-111111111111';
