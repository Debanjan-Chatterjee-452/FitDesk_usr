-- ============================================================================
-- FitDesk production migration bundle
-- Target project: psgepyvdwvunjkbacsxe (canonical production)
-- Apply in the Supabase Dashboard -> SQL Editor, in order, as a single transaction.
-- ============================================================================

-- ===== 20261119000100_fitdesk_profile_avatar.sql =====
-- 20261119000100_fitdesk_profile_avatar.sql
-- Adds an optional profile picture to member profiles, stored in a private
-- bucket with per-user RLS, mirroring the legal-documents bucket.

alter table public.profiles
  add column if not exists avatar_path text;

comment on column public.profiles.avatar_path is
  'Private object path inside the profile-avatars bucket: <user-id>/<file-name>.';

-- ---------------------------------------------------------------------------
-- Private storage bucket for profile pictures
-- ---------------------------------------------------------------------------
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'profile-avatars',
  'profile-avatars',
  false,
  5242880,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif'
  ]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "profile_avatars_insert_own" on storage.objects;
drop policy if exists "profile_avatars_select_own" on storage.objects;
drop policy if exists "profile_avatars_update_own" on storage.objects;
drop policy if exists "profile_avatars_delete_own" on storage.objects;

create policy "profile_avatars_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'profile-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "profile_avatars_select_own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'profile-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "profile_avatars_update_own"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'profile-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'profile-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "profile_avatars_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'profile-avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );


-- ===== 20261119000200_fitdesk_join_code_preview.sql =====
-- 20261119000200_fitdesk_join_code_preview.sql
-- Lets a member preview the gym name for a join code before submitting a
-- request. Read-only: no row is created and no gym data beyond the name is
-- exposed.

create or replace function public.preview_gym_by_join_code(p_join_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code text := upper(nullif(btrim(coalesce(p_join_code, '')), ''));
  v_gym public.gyms;
begin
  if v_code is null then
    return jsonb_build_object('status', 'empty');
  end if;

  select * into v_gym
    from public.gyms
   where upper(join_code) = v_code
     and is_active = true;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  return jsonb_build_object(
    'status', 'found',
    'gym_id', v_gym.id,
    'gym_name', v_gym.name
  );
end;
$$;

revoke all on function public.preview_gym_by_join_code(text) from public, anon;
grant execute on function public.preview_gym_by_join_code(text) to authenticated;
grant execute on function public.preview_gym_by_join_code(text) to service_role;


-- ===== 20261119000300_fitdesk_attendance_error_codes.sql =====
-- 20261119000300_fitdesk_attendance_error_codes.sql
-- Distinguishes expired vs pending vs inactive memberships when a member
-- scans the attendance QR. Backward-compatible: still raises
-- MEMBERSHIP_INACTIVE for any other non-active case.

create or replace function public.check_in_with_qr(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_qr public.gym_qr_codes;
  v_membership public.memberships;
  v_attendance public.attendance;
  v_gym_name text;
  v_profile public.profiles;
  v_has_closure boolean := false;
  v_latest_membership public.memberships;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if p_token is null or length(btrim(p_token)) = 0 then
    raise exception 'INVALID_QR' using errcode = 'P0001';
  end if;

  select * into v_qr
    from public.gym_qr_codes
   where token_hash = encode(extensions.digest(btrim(p_token), 'sha256'), 'hex')
     and is_active = true
     and revoked_at is null
   limit 1;

  if not found then
    raise exception 'INVALID_QR' using errcode = 'P0001';
  end if;

  select * into v_profile
    from public.profiles
   where id = v_user;

  if not found or v_profile.profile_completed = false then
    raise exception 'PROFILE_INCOMPLETE' using errcode = 'P0001';
  end if;

  -- A member may only scan their own gym's code.
  if v_qr.gym_id is not null and v_qr.gym_id <> v_profile.gym_id then
    raise exception 'QR_GYM_MISMATCH' using errcode = '42501';
  end if;

  -- Not yet approved into a gym.
  if v_profile.gym_id is null then
    -- Pending join request?
    if exists (
      select 1 from public.gym_join_requests
       where user_id = v_user and status = 'pending'
    ) then
      raise exception 'MEMBERSHIP_PENDING' using errcode = 'P0001';
    end if;
    raise exception 'MEMBERSHIP_INACTIVE' using errcode = 'P0001';
  end if;

  select exists (
    select 1
      from public.announcements
     where gym_id = v_profile.gym_id
       and is_active = true
       and kind in ('holiday', 'closure')
       and starts_on <= v_today
       and (ends_on is null or ends_on >= v_today)
  ) into v_has_closure;

  if v_has_closure then
    raise exception 'GYM_CLOSED' using errcode = 'P0001';
  end if;

  -- Active membership covering today?
  select * into v_membership
    from public.memberships
   where user_id = v_user
     and gym_id = v_profile.gym_id
     and status = 'active'
     and starts_on <= v_today
     and ends_on >= v_today
   order by ends_on desc
   limit 1;

  if found then
    -- proceed to record attendance below
    null;
  else
    -- Distinguish expired vs pending/inactive.
    select * into v_latest_membership
      from public.memberships
     where user_id = v_user
       and gym_id = v_profile.gym_id
     order by ends_on desc
     limit 1;

    if found and v_latest_membership.ends_on < v_today then
      raise exception 'MEMBERSHIP_EXPIRED' using errcode = 'P0001';
    end if;

    -- Pending approval membership?
    if exists (
      select 1 from public.memberships
       where user_id = v_user
         and gym_id = v_profile.gym_id
         and status = 'pending'
    ) then
      raise exception 'MEMBERSHIP_PENDING' using errcode = 'P0001';
    end if;

    raise exception 'MEMBERSHIP_INACTIVE' using errcode = 'P0001';
  end if;

  select coalesce(name, 'FitDesk') into v_gym_name
    from public.gyms
   where id = v_profile.gym_id;

  -- Return the existing row rather than failing if the member scans twice.
  select * into v_attendance
    from public.attendance
   where user_id = v_user
     and check_in_date = v_today;

  if found then
    return jsonb_build_object(
      'status', 'already_checked_in',
      'attendance_id', v_attendance.id,
      'check_in_at', v_attendance.check_in_at,
      'check_in_date', v_attendance.check_in_date,
      'gym_name', coalesce(v_gym_name, 'FitDesk'),
      'message', 'You already checked in today. One scan per day is enough.'
    );
  end if;

  insert into public.attendance (user_id, check_in_at, source, gym_qr_id)
  values (v_user, now(), 'qr', v_qr.id)
  on conflict (user_id, check_in_date) do nothing
  returning * into v_attendance;

  if v_attendance.id is null then
    select * into v_attendance
      from public.attendance
     where user_id = v_user
       and check_in_date = v_today;

    return jsonb_build_object(
      'status', 'already_checked_in',
      'attendance_id', v_attendance.id,
      'check_in_at', v_attendance.check_in_at,
      'check_in_date', v_attendance.check_in_date,
      'gym_name', coalesce(v_gym_name, 'FitDesk'),
      'message', 'You already checked in today. One scan per day is enough.'
    );
  end if;

  return jsonb_build_object(
    'status', 'checked_in',
    'attendance_id', v_attendance.id,
    'check_in_at', v_attendance.check_in_at,
    'check_in_date', v_attendance.check_in_date,
    'gym_name', coalesce(v_gym_name, 'FitDesk'),
    'message', 'You''re in. Have a strong session.'
  );
end;
$$;


-- ===== 20261119000400_fitdesk_cash_payment_otp.sql =====
-- 20261119000400_fitdesk_cash_payment_otp.sql
-- Five-digit cash payment confirmation OTP system.
-- Admin generates an OTP for a specific pending payment; the member enters it
-- to verify the cash handover. On success the payment is approved and the
-- membership is activated, exactly as in admin_review_payment.

create table if not exists public.cash_payment_otps (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  payment_id uuid not null references public.payments(id) on delete cascade,
  otp_hash text not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists cash_payment_otps_payment_idx
  on public.cash_payment_otps (payment_id, created_at desc);

alter table public.cash_payment_otps enable row level security;

drop policy if exists "cash_otps_select_own" on public.cash_payment_otps;
drop policy if exists "cash_otps_admin_all" on public.cash_payment_otps;

create policy "cash_otps_select_own"
  on public.cash_payment_otps for select
  to authenticated
  using (user_id = auth.uid());

create policy "cash_otps_admin_all"
  on public.cash_payment_otps for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------------
-- Admin generates a fresh 5-digit OTP for a pending payment.
-- Returns the plain OTP (shown once to the admin) plus its expiry.
-- ---------------------------------------------------------------------------
create or replace function public.admin_generate_cash_otp(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_payment public.payments;
  v_otp text;
  v_hash text;
  v_expires timestamptz := now() + interval '10 minutes';
begin
  if not public.is_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id
   for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status <> 'pending' then
    raise exception 'PAYMENT_ALREADY_REVIEWED' using errcode = 'P0001';
  end if;

  -- Invalidate any still-live OTPs for this payment.
  update public.cash_payment_otps
     set used_at = now()
   where payment_id = p_payment_id
     and used_at is null;

  v_otp := lpad((floor(random() * 90000) + 10000)::text, 5, '0');
  v_hash := encode(extensions.digest(v_otp, 'sha256'), 'hex');

  insert into public.cash_payment_otps (
    gym_id, user_id, payment_id, otp_hash, expires_at, created_by
  )
  values (
    v_payment.gym_id, v_payment.user_id, v_payment.id, v_hash, v_expires, auth.uid()
  );

  return jsonb_build_object(
    'otp', v_otp,
    'expires_at', v_expires,
    'payment_id', v_payment.id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Member verifies a cash OTP. On success the payment is approved and the
-- membership is activated, mirroring admin_review_payment.
-- ---------------------------------------------------------------------------
create or replace function public.verify_cash_otp(p_payment_id uuid, p_otp text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_payment public.payments;
  v_otp_row public.cash_payment_otps;
  v_membership public.memberships;
  v_quote jsonb;
  v_package_name text;
  v_starts date;
  v_ends date;
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_hash text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if p_otp is null or length(btrim(p_otp)) <> 5 then
    raise exception 'OTP_INVALID' using errcode = 'P0001';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id
     and user_id = v_user
   for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status <> 'pending' then
    raise exception 'PAYMENT_ALREADY_REVIEWED' using errcode = 'P0001';
  end if;

  v_hash := encode(extensions.digest(btrim(p_otp), 'sha256'), 'hex');

  select * into v_otp_row
    from public.cash_payment_otps
   where payment_id = p_payment_id
     and otp_hash = v_hash
     and used_at is null
   order by created_at desc
   limit 1
   for update;

  if not found then
    raise exception 'OTP_INVALID' using errcode = 'P0001';
  end if;

  if v_otp_row.expires_at < now() then
    update public.cash_payment_otps set used_at = now() where id = v_otp_row.id;
    raise exception 'OTP_EXPIRED' using errcode = 'P0001';
  end if;

  -- Mark the OTP as used (single-use).
  update public.cash_payment_otps set used_at = now() where id = v_otp_row.id;

  select name into v_package_name
    from public.packages
   where id = v_payment.package_id;

  perform set_config('fitdesk.payment_review', 'on', true);

  v_quote := v_payment.quote;
  if v_quote is null then
    raise exception 'PAYMENT_QUOTE_MISSING' using errcode = 'P0001';
  end if;

  if coalesce((v_quote ->> 'base_amount')::integer, -1) <> v_payment.base_amount_inr
     or coalesce((v_quote ->> 'fine_amount')::integer, -1) <> v_payment.fine_amount_inr
     or coalesce((v_quote ->> 'total_amount')::integer, -1) <> v_payment.total_amount_inr
     or coalesce((v_quote ->> 'duration_days')::integer, -1) <> v_payment.duration_days
     or (v_quote ->> 'package_id')::uuid is distinct from v_payment.package_id then
    raise exception 'PAYMENT_QUOTE_MISMATCH' using errcode = 'P0001';
  end if;

  if v_payment.base_amount_inr + v_payment.fine_amount_inr <> v_payment.total_amount_inr then
    raise exception 'PAYMENT_AMOUNT_MISMATCH' using errcode = 'P0001';
  end if;

  v_starts := (v_quote ->> 'starts_on')::date;
  v_ends := (v_quote ->> 'ends_on')::date;

  if v_starts is null or v_ends is null or v_ends < v_starts then
    raise exception 'PAYMENT_QUOTE_MISMATCH' using errcode = 'P0001';
  end if;

  -- Mark older lapsed plans as expired.
  update public.memberships
     set status = 'expired',
         updated_at = v_now
   where user_id = v_payment.user_id
     and status = 'active'
     and ends_on < v_today;

  insert into public.memberships (
    user_id,
    package_id,
    starts_on,
    ends_on,
    price_paid_inr,
    fine_paid_inr,
    status,
    created_at,
    updated_at
  )
  values (
    v_payment.user_id,
    v_payment.package_id,
    v_starts,
    v_ends,
    v_payment.base_amount_inr,
    v_payment.fine_amount_inr,
    'active',
    v_now,
    v_now
  )
  returning * into v_membership;

  update public.payments
     set status = 'approved',
         membership_id = v_membership.id,
         failure_reason = null,
         review_note = 'Verified via cash OTP.',
         reviewed_at = v_now,
         reviewed_by = v_otp_row.created_by,
         updated_at = v_now
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'approved',
    'payment_id', v_payment.id,
    'membership_id', v_membership.id,
    'starts_on', v_membership.starts_on,
    'ends_on', v_membership.ends_on,
    'package_name', coalesce(v_package_name, 'Membership'),
    'total_amount_inr', v_payment.total_amount_inr
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.admin_generate_cash_otp(uuid) from public, anon, authenticated;
grant execute on function public.admin_generate_cash_otp(uuid) to authenticated;

revoke all on function public.verify_cash_otp(uuid, text) from public, anon;
grant execute on function public.verify_cash_otp(uuid, text) to authenticated;
grant execute on function public.verify_cash_otp(uuid, text) to service_role;


-- ===== 20261119000500_fitdesk_admin_member_avatar.sql =====
-- 20261119000500_fitdesk_admin_member_avatar.sql
-- Adds avatar_path to admin_list_members so the admin UI can display member
-- profile pictures from the shared profile-avatars bucket.

drop function if exists public.admin_list_members(text, text);

create or replace function public.admin_list_members(
  p_search text default null,
  p_status text default null
)
returns table (
  user_id uuid,
  membership_id uuid,
  full_name text,
  email text,
  phone text,
  avatar_path text,
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
  activity_at timestamptz
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
    b.activity_at
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
    b.full_name asc;
end;
$$;

