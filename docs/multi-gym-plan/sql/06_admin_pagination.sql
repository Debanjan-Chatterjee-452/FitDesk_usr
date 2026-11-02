-- ============================================================================
-- FitDesk multi-gym SaaS — draft migration 06
-- Paginated member list (additive; the existing RPC is untouched)
--
-- STATUS: DRAFT — DO NOT APPLY TO PRODUCTION WITHOUT APPROVAL.
--
-- The admin app currently calls admin_list_members(p_search, p_status), which
-- returns every member in the gym. This adds admin_list_members_page() with
-- the same columns plus total_count. The old function keeps working, so the
-- admin app can switch when its UI change is approved.
--
-- It also adds admin_member_status_counts(), because the admin page shows four
-- status-tab counts (all / pending / paid / not_paid) and those cannot be
-- derived from one page of results. The counts intentionally ignore search,
-- matching the current browser-side behaviour.
-- ============================================================================

begin;

create index if not exists profiles_gym_admin_idx
  on public.profiles (gym_id, is_admin);

create or replace function public.admin_list_members_page(
  p_search text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  user_id uuid,
  membership_id uuid,
  full_name text,
  email text,
  phone text,
  joined_at timestamptz,
  plan_name text,
  membership_status public.membership_status,
  starts_on date,
  ends_on date,
  payment_status text,
  pending_payment_id uuid,
  pending_amount_inr integer,
  pending_reference text,
  pending_since timestamptz,
  pending_plan_name text,
  activity_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_status text := lower(nullif(btrim(coalesce(p_status, '')), ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 200));
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  return query
  with base as (
    select
      u.id as user_id,
      coalesce(nullif(btrim(pr.full_name), ''), split_part(u.email::text, '@', 1), 'FitDesk member') as full_name,
      u.email::text as email,
      nullif(btrim(coalesce(pr.phone, '')), '') as phone,
      pr.created_at as joined_at,
      m.membership_id as membership_id,
      coalesce(m.package_name, pend_pkg.name) as plan_name,
      m.status as membership_status,
      m.starts_on,
      m.ends_on,
      case
        when pend.id is not null then 'Pending'
        when m.status in ('active', 'paused') and m.ends_on >= v_today then 'Paid'
        else 'Not Paid'
      end as payment_status,
      pend.id as pending_payment_id,
      pend.total_amount_inr as pending_amount_inr,
      pend.upi_reference as pending_reference,
      pend.created_at as pending_since,
      pend_pkg.name as pending_plan_name,
      greatest(
        coalesce(m.updated_at, pr.updated_at),
        coalesce(pend.created_at, pr.updated_at)
      ) as activity_at
    from auth.users u
    join public.profiles pr on pr.id = u.id
    left join lateral (
      select
        mem.id as membership_id,
        mem.id,
        mem.status,
        mem.starts_on,
        mem.ends_on,
        mem.updated_at,
        pk.name as package_name
      from public.memberships mem
      join public.packages pk on pk.id = mem.package_id
      where mem.user_id = u.id
        and mem.gym_id = v_gym_id
      order by
        case when mem.status in ('active', 'paused') and mem.ends_on >= v_today then 0 else 1 end,
        mem.ends_on desc,
        mem.created_at desc
      limit 1
    ) m on true
    left join lateral (
      select
        pay.id,
        pay.total_amount_inr,
        pay.upi_reference,
        pay.created_at,
        pay.package_id
      from public.payments pay
      where pay.user_id = u.id
        and pay.gym_id = v_gym_id
        and pay.status = 'pending'
        and pay.provider_payment_id is not null
        and pay.checkout_state <> 'abandoned'
      order by pay.created_at desc
      limit 1
    ) pend on true
    left join public.packages pend_pkg on pend_pkg.id = pend.package_id
    where pr.gym_id = v_gym_id
      and pr.is_admin = false
  )
  select
    b.user_id,
    b.membership_id,
    b.full_name,
    b.email,
    b.phone,
    b.joined_at,
    b.plan_name,
    b.membership_status,
    b.starts_on,
    b.ends_on,
    b.payment_status,
    b.pending_payment_id,
    b.pending_amount_inr,
    b.pending_reference,
    b.pending_since,
    b.pending_plan_name,
    b.activity_at,
    count(*) over() as total_count
  from base b
  where (v_search is null
         or b.full_name ilike '%' || v_search || '%'
         or b.email ilike '%' || v_search || '%'
         or coalesce(b.phone, '') ilike '%' || v_search || '%')
    and (v_status is null
         or v_status = 'all'
         or b.payment_status = case v_status
              when 'pending' then 'Pending'
              when 'paid' then 'Paid'
              when 'not_paid' then 'Not Paid'
              else b.payment_status
            end)
  order by
    case b.payment_status when 'Pending' then 0 when 'Paid' then 1 else 2 end,
    b.full_name asc
  limit v_limit
  offset v_offset;
end;
$$;

revoke all on function public.admin_list_members_page(text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.admin_list_members_page(text, text, integer, integer) to authenticated;

comment on function public.admin_list_members_page(text, text, integer, integer) is
  'Same as admin_list_members plus total_count and offset paging. max page size 200.';

-- ---------------------------------------------------------------------------
-- Status-tab counts for the members page.
-- Mirrors the payment_status classification used by admin_list_members_page().
-- Search is intentionally not applied: the tab badges show whole-gym totals,
-- exactly as the browser-side counts do today.
-- ---------------------------------------------------------------------------
create or replace function public.admin_member_status_counts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_result jsonb;
begin
  with base as (
    select
      case
        when pend.id is not null then 'Pending'
        when m.status in ('active', 'paused') and m.ends_on >= v_today then 'Paid'
        else 'Not Paid'
      end as payment_status
    from auth.users u
    join public.profiles pr on pr.id = u.id
    left join lateral (
      select mem.status, mem.ends_on
      from public.memberships mem
      where mem.user_id = u.id
        and mem.gym_id = v_gym_id
      order by
        case when mem.status in ('active', 'paused') and mem.ends_on >= v_today then 0 else 1 end,
        mem.ends_on desc,
        mem.created_at desc
      limit 1
    ) m on true
    left join lateral (
      select pay.id
      from public.payments pay
      where pay.user_id = u.id
        and pay.gym_id = v_gym_id
        and pay.status = 'pending'
        and pay.provider_payment_id is not null
        and pay.checkout_state <> 'abandoned'
      order by pay.created_at desc
      limit 1
    ) pend on true
    where pr.gym_id = v_gym_id
      and pr.is_admin = false
  )
  select jsonb_build_object(
    'all', count(*),
    'pending', count(*) filter (where payment_status = 'Pending'),
    'paid', count(*) filter (where payment_status = 'Paid'),
    'not_paid', count(*) filter (where payment_status = 'Not Paid')
  )
    into v_result
    from base;

  return v_result;
end;
$$;

revoke all on function public.admin_member_status_counts() from public, anon, authenticated;
grant execute on function public.admin_member_status_counts() to authenticated;

comment on function public.admin_member_status_counts() is
  'Returns {all,pending,paid,not_paid} member counts for the admin gym. Search is not applied.';

commit;
