-- Local test only. Safe to run against fitdesk_migration_test.
-- The whole script runs in one transaction and is rolled back at the end.
--
-- Covers draft 06:
--   1. admin_member_status_counts() matches admin_list_members_page() per gym.
--   2. The Pending branch is counted and filtered correctly.
--   3. Search, status filter, offset and total_count behave.
--   4. Non-admin and suspended-gym calls are rejected.

begin;

-- 1. Counts must match the paged RPC for every admin.
do $$
declare
  v_admin record;
  v_counts jsonb;
  v_all bigint;
  v_pending bigint;
  v_paid bigint;
  v_not_paid bigint;
begin
  for v_admin in
    select p.id, u.email, g.name
      from public.profiles p
      join auth.users u on u.id = p.id
      join public.gyms g on g.id = p.gym_id
     where p.is_admin = true
     order by u.email
  loop
    perform set_config(
      'request.jwt.claims',
      json_build_object('sub', v_admin.id, 'role', 'authenticated')::text,
      false
    );

    v_counts := public.admin_member_status_counts();

    select count(*),
           count(*) filter (where payment_status = 'Pending'),
           count(*) filter (where payment_status = 'Paid'),
           count(*) filter (where payment_status = 'Not Paid')
      into v_all, v_pending, v_paid, v_not_paid
      from public.admin_list_members_page(null, null, 200, 0);

    if (v_counts->>'all')::bigint <> v_all
       or (v_counts->>'pending')::bigint <> v_pending
       or (v_counts->>'paid')::bigint <> v_paid
       or (v_counts->>'not_paid')::bigint <> v_not_paid then
      raise exception
        'COUNT_MISMATCH for % (%): counts=% page=all %, pending %, paid %, not_paid %',
        v_admin.email, v_admin.name, v_counts, v_all, v_pending, v_paid, v_not_paid;
    end if;

    raise notice 'OK % (%): %', v_admin.email, v_admin.name, v_counts;
  end loop;
end;
$$;

-- 2. A real pending payment must move one member from "Paid" to "Pending".
--    Golden Iron Gym (FD-0004) has 4 members: before this row, 2 paid
--    (Join A, member-b) and 2 not paid (Expired Member, member-a cancelled).
insert into public.payments (
  id, user_id, package_id, duration_days,
  base_amount_inr, fine_amount_inr, total_amount_inr,
  status, provider, provider_payment_id, checkout_state, gym_id
)
values (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '0a0f735a-fd90-498f-88f9-5c59ee0cbc8d',
  '9f2a7e31-ac01-47cb-a825-87b2be068601',
  30, 500, 0, 500,
  'pending', 'upi', 'TESTPENDING0001', 'submitted',
  '3a32c00a-9e78-4ee2-825c-0a4982814614'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '2382b68b-c90c-435d-9527-be204d814827', 'role', 'authenticated')::text,
  false
);

do $$
declare
  v_counts jsonb := public.admin_member_status_counts();
begin
  if v_counts <> '{"all": 4, "pending": 1, "paid": 1, "not_paid": 2}'::jsonb then
    raise exception 'PENDING_BRANCH_MISMATCH: %', v_counts;
  end if;
  raise notice 'OK pending branch: %', v_counts;
end;
$$;

-- 3. Search / status / offset / total_count.
do $$
declare
  v_total bigint;
  v_rows bigint;
  v_first_page uuid[];
  v_second_page uuid[];
begin
  select count(*), max(total_count)
    into v_rows, v_total
    from public.admin_list_members_page(null, 'pending', 50, 0);
  if v_rows <> 1 or v_total <> 1 then
    raise exception 'STATUS_FILTER_FAILED: rows %, total %', v_rows, v_total;
  end if;

  select count(*), max(total_count)
    into v_rows, v_total
    from public.admin_list_members_page('member-b-1793467300', null, 50, 0);
  if v_rows <> 1 or v_total <> 1 then
    raise exception 'SEARCH_FAILED: rows %, total %', v_rows, v_total;
  end if;

  select count(*) into v_rows
    from public.admin_list_members_page('no-such-member-xyz', null, 50, 0);
  if v_rows <> 0 then
    raise exception 'EMPTY_SEARCH_FAILED: rows %', v_rows;
  end if;

  select array_agg(user_id) into v_first_page
    from public.admin_list_members_page(null, null, 2, 0);
  select array_agg(user_id) into v_second_page
    from public.admin_list_members_page(null, null, 2, 2);

  if array_length(v_first_page, 1) <> 2 or array_length(v_second_page, 1) <> 2 then
    raise exception 'PAGE_SIZE_FAILED: first %, second %', v_first_page, v_second_page;
  end if;

  if v_first_page && v_second_page then
    raise exception 'PAGE_OVERLAP: % / %', v_first_page, v_second_page;
  end if;

  select max(total_count) into v_total
    from public.admin_list_members_page(null, null, 2, 0);
  if v_total <> 4 then
    raise exception 'TOTAL_COUNT_FAILED: %', v_total;
  end if;

  raise notice 'OK search/status/offset/total_count';
end;
$$;

-- 4a. A normal member must be rejected.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '22222222-2222-4222-8222-222222222222', 'role', 'authenticated')::text,
  false
);
do $$
begin
  perform public.admin_member_status_counts();
  raise exception 'EXPECTED_REJECTION_BUT_CALL_SUCCEEDED';
exception
  when others then
    if sqlerrm = 'EXPECTED_REJECTION_BUT_CALL_SUCCEEDED' then
      raise;
    end if;
    raise notice 'OK non-admin rejected: %', sqlerrm;
end;
$$;

-- 4b. A suspended gym must be rejected.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '11111111-1111-4111-8111-111111111111', 'role', 'authenticated')::text,
  false
);
update public.gyms
   set is_active = false, suspended_at = now(), suspension_reason = 'local test'
 where public_id = 'FD-0006';
do $$
begin
  perform public.admin_member_status_counts();
  raise exception 'EXPECTED_SUSPENSION_BUT_CALL_SUCCEEDED';
exception
  when others then
    if sqlerrm = 'EXPECTED_SUSPENSION_BUT_CALL_SUCCEEDED' then
      raise;
    end if;
    raise notice 'OK suspended gym rejected: %', sqlerrm;
end;
$$;

rollback;
