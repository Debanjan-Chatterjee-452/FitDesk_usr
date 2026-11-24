-- ============================================================================
-- Fix the admin Members panel data gaps found in production:
--   * avatar_path was never returned, so member photos never appeared.
--   * is_deactivated was never returned, so "Reactivate" never appeared after
--     a member was deactivated.
-- ============================================================================

drop function if exists public.admin_list_members_page(text, text, integer, integer);

create function public.admin_list_members_page(
  p_search text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(
  user_id uuid, membership_id uuid, full_name text, email text, phone text,
  avatar_path text, joined_at timestamptz, plan_name text,
  membership_status membership_status, starts_on date, ends_on date,
  payment_status text, pending_payment_id uuid, pending_amount_inr integer,
  pending_reference text, pending_since timestamptz, pending_plan_name text,
  pending_method text, pending_otp text, pending_otp_expires_at timestamptz,
  is_deactivated boolean, gym_state text, left_at timestamptz,
  activity_at timestamptz, total_count bigint
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
      pr.avatar_path as avatar_path,
      pr.created_at as joined_at,
      m.membership_id as membership_id,
      coalesce(m.package_name, pend_pkg.name) as plan_name,
      m.status as membership_status,
      m.starts_on,
      m.ends_on,
      case
        when pr.gym_id is distinct from v_gym_id then 'Not Paid'
        when pend.id is not null then 'Pending'
        when m.status in ('active', 'paused') and m.ends_on >= v_today then 'Paid'
        else 'Not Paid'
      end as payment_status,
      pend.id as pending_payment_id,
      pend.total_amount_inr as pending_amount_inr,
      pend.upi_reference as pending_reference,
      pend.created_at as pending_since,
      pend_pkg.name as pending_plan_name,
      pend.provider as pending_method,
      pend.otp_code as pending_otp,
      pend.otp_expires_at as pending_otp_expires_at,
      coalesce(pr.is_deactivated, false) as is_deactivated,
      case when pr.gym_id = v_gym_id then 'current' else 'left' end as gym_state,
      dep.left_at as left_at,
      greatest(
        coalesce(m.updated_at, pr.updated_at),
        coalesce(pend.created_at, pr.updated_at),
        coalesce(dep.left_at, pr.updated_at)
      ) as activity_at
    from auth.users u
    join public.profiles pr on pr.id = u.id
    left join lateral (
      select d.left_at
        from public.gym_member_departures d
       where d.gym_id = v_gym_id
         and d.user_id = u.id
       order by d.left_at desc
       limit 1
    ) dep on true
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
        pay.package_id,
        pay.provider,
        otp.otp_code,
        otp.expires_at as otp_expires_at
      from public.payments pay
      left join lateral (
        select o.otp_code, o.expires_at
          from public.cash_payment_otps o
         where o.payment_id = pay.id
           and o.used_at is null
           and o.expires_at > now()
         order by o.created_at desc
         limit 1
      ) otp on true
      where pay.user_id = u.id
        and pay.gym_id = v_gym_id
        and pay.status = 'pending'
        and pay.checkout_state <> 'abandoned'
        and (
          pay.provider_payment_id is not null
          or pay.checkout_state = 'submitted'
          or pay.provider = 'cash'
        )
      order by pay.created_at desc
      limit 1
    ) pend on true
    left join public.packages pend_pkg on pend_pkg.id = pend.package_id
    where pr.is_admin = false
      and (
        pr.gym_id = v_gym_id
        or (pr.gym_id is distinct from v_gym_id and dep.left_at is not null)
      )
  )
  select
    b.user_id,
    b.membership_id,
    b.full_name,
    b.email,
    b.phone,
    b.avatar_path,
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
    b.pending_method,
    b.pending_otp,
    b.pending_otp_expires_at,
    b.is_deactivated,
    b.gym_state,
    b.left_at,
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
    case b.gym_state when 'current' then 0 else 1 end,
    case b.payment_status when 'Pending' then 0 when 'Paid' then 1 else 2 end,
    b.full_name asc
  limit v_limit
  offset v_offset;
end;
$function$;

grant execute on function public.admin_list_members_page(text, text, integer, integer) to authenticated;

notify pgrst, 'reload schema';
