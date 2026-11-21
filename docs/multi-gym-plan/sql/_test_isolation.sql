-- Local test only. Safe to run against fitdesk_migration_test.

-- Member C (iron-temple) overview
select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'ebe2d0be-5fac-468c-a31c-f0f8e55e0266', 'role', 'authenticated')::text,
  false
);
set role authenticated;
select 'member overview' as step, public.member_gym_overview() ->> 'gym_name' as gym_name,
       public.member_gym_overview() ->> 'status' as status;
reset role;

-- Member C scanning another gym's QR must be refused.
select set_config('test.qr_token',
  (select token_value from public.gym_qr_codes where id = '80702df1-42f9-46f1-8076-cb057c3c550a'),
  false);
select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'ebe2d0be-5fac-468c-a31c-f0f8e55e0266', 'role', 'authenticated')::text,
  false
);
set role authenticated;
do $$
declare v_token text := current_setting('test.qr_token');
begin
  begin
    perform public.check_in_with_qr(v_token);
    raise notice 'QR MISMATCH TEST: UNEXPECTED SUCCESS';
  exception when others then
    raise notice 'QR MISMATCH TEST: %', sqlerrm;
  end;
end $$;
reset role;

-- Owner A (iron-temple): paged members, join requests, pending count.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '5dc7d7d4-3922-43f3-9e8e-e81413399a18', 'role', 'authenticated')::text,
  false
);
set role authenticated;
select 'page 1' as step, full_name, payment_status, total_count
  from public.admin_list_members_page(null, null, 2, 0);
select 'join requests' as step, count(*) as n from public.admin_list_join_requests();
select 'pending count' as step, public.admin_pending_join_request_count() as n;

-- Cross-gym refund must not be found.
do $$
begin
  perform public.admin_mark_payment_refunded('f0806a6e-208a-466f-ad84-7801ee08129e', 'cross-gym test');
  raise notice 'CROSS-GYM REFUND TEST: UNEXPECTED SUCCESS';
exception when others then
  raise notice 'CROSS-GYM REFUND TEST: %', sqlerrm;
end $$;
reset role;

-- Suspend iron-temple, confirm admin + check-in are blocked, then restore.
update public.gyms set is_active = false where id = 'b7863e48-9d3d-4772-9e5b-78b4fdcff0d7';

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '5dc7d7d4-3922-43f3-9e8e-e81413399a18', 'role', 'authenticated')::text,
  false
);
set role authenticated;
do $$
begin
  perform public.admin_list_members_page(null, null, 5, 0);
  raise notice 'SUSPENDED ADMIN TEST: UNEXPECTED SUCCESS';
exception when others then
  raise notice 'SUSPENDED ADMIN TEST: %', sqlerrm;
end $$;
reset role;

select set_config('test.qr_token',
  (select token_value from public.gym_qr_codes where id = '89dc007f-02bb-4bae-99e7-312f4054524e'),
  false);
select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'ebe2d0be-5fac-468c-a31c-f0f8e55e0266', 'role', 'authenticated')::text,
  false
);
set role authenticated;
do $$
declare v_token text := current_setting('test.qr_token');
begin
  begin
    perform public.check_in_with_qr(v_token);
    raise notice 'SUSPENDED CHECKIN TEST: UNEXPECTED SUCCESS';
  exception when others then
    raise notice 'SUSPENDED CHECKIN TEST: %', sqlerrm;
  end;
end $$;
reset role;

update public.gyms set is_active = true where id = 'b7863e48-9d3d-4772-9e5b-78b4fdcff0d7';

-- Owner A can still check the refund scoping after reactivation.
select 'restored' as step, is_active from public.gyms where id = 'b7863e48-9d3d-4772-9e5b-78b4fdcff0d7';
