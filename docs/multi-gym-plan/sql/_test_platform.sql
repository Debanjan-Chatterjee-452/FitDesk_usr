insert into public.platform_admins (user_id, role)
values ('5dc7d7d4-3922-43f3-9e8e-e81413399a18', 'owner')
on conflict (user_id) do nothing;

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '5dc7d7d4-3922-43f3-9e8e-e81413399a18', 'role', 'authenticated')::text,
  false
);

set role authenticated;

select public.platform_me() as me;
select public.platform_dashboard_totals() as totals;
select * from public.platform_list_gyms(null, null, 10, 0);
select public.platform_gym_detail('7a1d0d7e-0000-4000-8000-000000000001') as detail;
