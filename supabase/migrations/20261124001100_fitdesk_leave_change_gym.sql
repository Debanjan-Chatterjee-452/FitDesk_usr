-- ============================================================================
-- FitDesk: member-initiated "Leave Gym" / "Change Gym"
--
-- A member can unlink from their gym without losing their FitDesk account,
-- profile or legal documents. Their membership at that gym is deactivated,
-- the previous gym's admin is notified, and a permanent departure record is
-- kept so the old gym's Members panel still shows the member as "Left gym".
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permanent departure record (visible to the old gym only)
-- ---------------------------------------------------------------------------
create table if not exists public.gym_member_departures (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  full_name text,
  left_at timestamptz not null default now(),
  reason text not null default 'left'
);

create index if not exists gym_member_departures_member_idx
  on public.gym_member_departures (gym_id, user_id, left_at desc);

alter table public.gym_member_departures enable row level security;

drop policy if exists gym_member_departures_admin_all on public.gym_member_departures;
create policy gym_member_departures_admin_all
  on public.gym_member_departures
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'gym_member_departures'
  ) then
    alter publication supabase_realtime add table public.gym_member_departures;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. member_leave_gym() – unlink, deactivate, notify
-- ---------------------------------------------------------------------------
create or replace function public.member_leave_gym()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
  v_profile public.profiles;
  v_gym public.gyms;
  v_name text;
  v_now timestamptz := now();
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_profile
    from public.profiles
   where id = v_user
   for update;

  if not found then
    raise exception 'PROFILE_REQUIRED' using errcode = 'P0001';
  end if;

  if v_profile.gym_id is null then
    return jsonb_build_object('status', 'not_in_gym');
  end if;

  -- A gym owner must transfer ownership before leaving.
  if coalesce(v_profile.is_admin, false) then
    raise exception 'ACCOUNT_OWNS_GYM' using errcode = 'P0001';
  end if;

  select * into v_gym from public.gyms where id = v_profile.gym_id;
  if not found then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  v_name := coalesce(nullif(btrim(coalesce(v_profile.full_name, '')), ''), 'FitDesk member');

  -- Keep a permanent record for the gym the member is leaving.
  insert into public.gym_member_departures (gym_id, user_id, full_name, left_at, reason)
  values (v_gym.id, v_user, v_name, v_now, 'left');

  -- Only the gym link changes. Profile, documents, identity and account stay.
  update public.profiles
     set gym_id = null,
         is_admin = false,
         updated_at = v_now
   where id = v_user;

  -- Deactivate any live membership at that gym (old rows may not carry gym_id,
  -- so fall back to the package's gym).
  update public.memberships m
     set status = 'cancelled',
         updated_at = v_now
   where m.user_id = v_user
     and m.status in ('active', 'paused')
     and (
       m.gym_id = v_gym.id
       or (
         m.gym_id is null
         and exists (
           select 1 from public.packages pk
            where pk.id = m.package_id
              and pk.gym_id = v_gym.id
         )
       )
     );

  -- Nothing should remain payable at a gym the member has left.
  update public.payments
     set checkout_state = 'abandoned',
         reconciliation_required = false,
         reconciliation_reason = null,
         updated_at = v_now
   where user_id = v_user
     and gym_id = v_gym.id
     and status = 'pending';

  -- Close any open request to the old gym; a fresh request can still be made
  -- later because request_join_gym() reopens a decided row.
  update public.gym_join_requests
     set status = 'declined',
         decided_at = v_now
   where user_id = v_user
     and gym_id = v_gym.id
     and status = 'pending';

  -- Notify the previous gym's admin panel.
  insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id)
  values (
    v_gym.id,
    'member_left',
    v_name || ' has left your gym',
    v_name || ' has left your gym. Their membership has been deactivated and they can no longer check in.',
    jsonb_build_object(
      'user_id', v_user,
      'gym_id', v_gym.id,
      'left_at', v_now,
      'member_name', v_name
    ),
    v_user
  );

  return jsonb_build_object(
    'status', 'left',
    'user_id', v_user,
    'gym_id', v_gym.id,
    'gym_name', v_gym.name,
    'member_name', v_name,
    'left_at', v_now
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Admin member list: departed members stay visible as "Left gym"
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_members_page(text, text, integer, integer);

create function public.admin_list_members_page(
  p_search text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(
  user_id uuid, membership_id uuid, full_name text, email text, phone text,
  joined_at timestamptz, plan_name text, membership_status membership_status,
  starts_on date, ends_on date, payment_status text, pending_payment_id uuid,
  pending_amount_inr integer, pending_reference text, pending_since timestamptz,
  pending_plan_name text, pending_method text, pending_otp text,
  pending_otp_expires_at timestamptz, gym_state text, left_at timestamptz,
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

-- ---------------------------------------------------------------------------
-- 4. Member status counts include departed members
-- ---------------------------------------------------------------------------
create or replace function public.admin_member_status_counts()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_result jsonb;
begin
  with base as (
    select
      case
        when pr.gym_id is distinct from v_gym_id then 'Not Paid'
        when pend.id is not null then 'Pending'
        when m.status in ('active', 'paused') and m.ends_on >= v_today then 'Paid'
        else 'Not Paid'
      end as payment_status,
      case when pr.gym_id = v_gym_id then false else true end as has_left
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
        and pay.checkout_state <> 'abandoned'
        and (
          pay.provider_payment_id is not null
          or pay.checkout_state = 'submitted'
          or pay.provider = 'cash'
        )
      order by pay.created_at desc
      limit 1
    ) pend on true
    where pr.is_admin = false
      and (
        pr.gym_id = v_gym_id
        or exists (
          select 1 from public.gym_member_departures d
           where d.gym_id = v_gym_id and d.user_id = u.id
        )
      )
  )
  select jsonb_build_object(
    'all', count(*),
    'pending', count(*) filter (where payment_status = 'Pending'),
    'paid', count(*) filter (where payment_status = 'Paid'),
    'not_paid', count(*) filter (where payment_status = 'Not Paid'),
    'left', count(*) filter (where has_left)
  )
    into v_result
    from base;

  return v_result;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Grants + schema reload
-- ---------------------------------------------------------------------------
grant execute on function public.member_leave_gym() to authenticated;
grant execute on function public.admin_list_members_page(text, text, integer, integer) to authenticated;
grant execute on function public.admin_member_status_counts() to authenticated;

notify pgrst, 'reload schema';
