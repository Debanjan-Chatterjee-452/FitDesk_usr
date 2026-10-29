-- FitDesk member app — server-side business logic
-- These functions are the only write path for profiles, attendance, and payments.

-- ---------------------------------------------------------------------------
-- Profile self-healing (in case the auth trigger was installed later)
-- ---------------------------------------------------------------------------
create or replace function public.ensure_my_profile()
returns public.profiles
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_phone text;
  v_profile public.profiles;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_profile from public.profiles where id = v_user;
  if found then
    return v_profile;
  end if;

  select phone into v_phone from auth.users where id = v_user;

  insert into public.profiles (id, phone)
  values (v_user, coalesce(v_phone, ''))
  on conflict (id) do nothing;

  select * into v_profile from public.profiles where id = v_user;
  if not found then
    raise exception 'PROFILE_CREATE_FAILED' using errcode = 'P0001';
  end if;

  return v_profile;
end;
$$;

-- ---------------------------------------------------------------------------
-- Renewal quote
--
-- Rules (Asia/Kolkata calendar days):
--   • 0–7 days past expiry ......... no late fee
--   • exactly day 8 ................ ₹50
--   • day 9 and beyond ............. ₹50 + ₹10 for each day after day 8
--   • An active plan starts the day after its current end date (stacking).
--   • An expired/lapsed plan starts today.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_renewal_quote(
  p_package_id uuid,
  p_duration_days integer default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_pkg public.packages;
  v_latest public.memberships;
  v_duration integer;
  v_days_past integer := 0;
  v_fine integer := 0;
  v_fine_reason text := null;
  v_base integer;
  v_starts date;
  v_ends date;
  v_is_stacked boolean := false;
  v_breakdown jsonb;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_pkg
    from public.packages
   where id = p_package_id
     and is_active = true;

  if not found then
    raise exception 'PACKAGE_NOT_FOUND' using errcode = 'P0001';
  end if;

  select * into v_latest
    from public.memberships
   where user_id = v_user
     and status <> 'cancelled'
   order by ends_on desc
   limit 1;

  v_is_stacked := v_latest.id is not null and v_latest.ends_on >= v_today;

  if v_latest.id is not null and v_latest.ends_on < v_today then
    v_days_past := (v_today - v_latest.ends_on)::integer;
  end if;

  v_duration := v_pkg.duration_days;
  if v_pkg.pricing_mode = 'per_day' then
    v_duration := coalesce(p_duration_days, v_pkg.min_days, v_pkg.duration_days);
    v_duration := greatest(
      coalesce(v_pkg.min_days, 1),
      least(v_duration, coalesce(v_pkg.max_days, 365))
    );
  end if;

  if v_days_past = 8 then
    v_fine := 50;
    v_fine_reason := '8 days past expiry - ₹50 flat late fee';
  elsif v_days_past >= 9 then
    v_fine := 50 + 10 * (v_days_past - 8);
    v_fine_reason := v_days_past::text || ' days past expiry - ₹50 + ₹10/day after day 8';
  elsif v_days_past > 0 then
    v_fine_reason := v_days_past::text
      || case when v_days_past = 1 then ' day' else ' days' end
      || ' past expiry - inside the 7-day grace period';
  end if;

  v_base := case
    when v_pkg.pricing_mode = 'per_day' then v_pkg.price_inr * v_duration
    else v_pkg.price_inr
  end;

  v_starts := case when v_is_stacked then v_latest.ends_on + 1 else v_today end;
  v_ends := v_starts + (v_duration - 1);

  v_breakdown := jsonb_build_array(
    jsonb_build_object(
      'label', v_pkg.name || ' · ' || v_duration::text || ' days',
      'amount', v_base
    )
  );

  if v_fine > 0 then
    v_breakdown := v_breakdown || jsonb_build_array(
      jsonb_build_object('label', 'Late renewal fee', 'amount', v_fine)
    );
  end if;

  return jsonb_build_object(
    'package_id', v_pkg.id,
    'package_name', v_pkg.name,
    'description', v_pkg.description,
    'pricing_mode', v_pkg.pricing_mode,
    'duration_days', v_duration,
    'base_amount', v_base,
    'fine_amount', v_fine,
    'total_amount', v_base + v_fine,
    'days_past_expiry', v_days_past,
    'grace_days', 7,
    'starts_on', v_starts,
    'ends_on', v_ends,
    'current_ends_on', v_latest.ends_on,
    'is_stacked', v_is_stacked,
    'fine_reason', v_fine_reason,
    'breakdown', v_breakdown
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- QR check-in
-- ---------------------------------------------------------------------------
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
  v_has_closure boolean := false;
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

  if not exists (
    select 1 from public.profiles
     where id = v_user
       and profile_completed = true
  ) then
    raise exception 'PROFILE_INCOMPLETE' using errcode = 'P0001';
  end if;

  select exists (
    select 1
      from public.announcements
     where is_active = true
       and kind in ('holiday', 'closure')
       and starts_on <= v_today
       and (ends_on is null or ends_on >= v_today)
  ) into v_has_closure;

  if v_has_closure then
    raise exception 'GYM_CLOSED' using errcode = 'P0001';
  end if;

  select * into v_membership
    from public.memberships
   where user_id = v_user
     and status = 'active'
     and starts_on <= v_today
     and ends_on >= v_today
   order by ends_on desc
   limit 1;

  if not found then
    raise exception 'MEMBERSHIP_INACTIVE' using errcode = 'P0001';
  end if;

  -- Return the existing row rather than failing if the member scans twice.
  select * into v_attendance
    from public.attendance
   where user_id = v_user
     and check_in_date = v_today;

  if found then
    select coalesce(name, 'FitDesk') into v_gym_name
      from public.gym_settings where id = 1;

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
    -- A concurrent scan won the race; return that check-in.
    select * into v_attendance
      from public.attendance
     where user_id = v_user
       and check_in_date = v_today;

    select coalesce(name, 'FitDesk') into v_gym_name
      from public.gym_settings where id = 1;

    return jsonb_build_object(
      'status', 'already_checked_in',
      'attendance_id', v_attendance.id,
      'check_in_at', v_attendance.check_in_at,
      'check_in_date', v_attendance.check_in_date,
      'gym_name', coalesce(v_gym_name, 'FitDesk'),
      'message', 'You already checked in today. One scan per day is enough.'
    );
  end if;

  select coalesce(name, 'FitDesk') into v_gym_name
    from public.gym_settings where id = 1;

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

-- ---------------------------------------------------------------------------
-- Payment activation (service-role only)
--
-- Razorpay signature/amount verification happens in the verify-payment Edge
-- Function. This function only accepts an already verified, captured amount
-- and is idempotent, so a retry cannot create a second membership.
-- ---------------------------------------------------------------------------
create or replace function public.complete_membership_payment(
  p_payment_id uuid,
  p_provider_payment_id text,
  p_paid_amount_inr integer,
  p_provider_order_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
  v_membership public.memberships;
  v_quote jsonb;
  v_package_name text;
  v_starts date;
  v_ends date;
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if p_payment_id is null then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id
   for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status = 'paid' then
    if v_payment.membership_id is null then
      raise exception 'PAYMENT_INCONSISTENT' using errcode = 'P0001';
    end if;

    select * into v_membership
      from public.memberships
     where id = v_payment.membership_id;

    select name into v_package_name
      from public.packages
     where id = v_payment.package_id;

    return jsonb_build_object(
      'status', 'already_paid',
      'membership_id', v_membership.id,
      'starts_on', v_membership.starts_on,
      'ends_on', v_membership.ends_on,
      'package_name', coalesce(v_package_name, 'Membership')
    );
  end if;

  if v_payment.status not in ('created', 'pending') then
    raise exception 'PAYMENT_NOT_PAYABLE' using errcode = 'P0001';
  end if;

  if p_provider_payment_id is null or length(btrim(p_provider_payment_id)) = 0 then
    raise exception 'PAYMENT_FAILED' using errcode = 'P0001';
  end if;

  if p_paid_amount_inr is distinct from v_payment.total_amount_inr then
    raise exception 'PAYMENT_AMOUNT_MISMATCH' using errcode = 'P0001';
  end if;

  if v_payment.provider_order_id is not null
     and (
       p_provider_order_id is null
       or p_provider_order_id <> v_payment.provider_order_id
     ) then
    raise exception 'PAYMENT_ORDER_MISMATCH' using errcode = 'P0001';
  end if;

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

  -- Mark older lapsed plans as expired; future stacked plans stay untouched.
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
     set status = 'paid',
         membership_id = v_membership.id,
         provider_payment_id = btrim(p_provider_payment_id),
         failure_reason = null,
         paid_at = v_now,
         updated_at = v_now
   where id = v_payment.id;

  select name into v_package_name
    from public.packages
   where id = v_payment.package_id;

  return jsonb_build_object(
    'status', 'paid',
    'membership_id', v_membership.id,
    'starts_on', v_membership.starts_on,
    'ends_on', v_membership.ends_on,
    'package_name', coalesce(v_package_name, 'Membership')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Front-desk QR management (service-role only)
-- ---------------------------------------------------------------------------
create or replace function public.create_gym_qr_code(p_label text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_label text := btrim(coalesce(p_label, ''));
  v_token text;
  v_qr public.gym_qr_codes;
begin
  if length(v_label) = 0 then
    raise exception 'LABEL_REQUIRED' using errcode = 'P0001';
  end if;

  v_token := 'FITDESK-' || upper(encode(extensions.gen_random_bytes(24), 'hex'));

  insert into public.gym_qr_codes (label, token_hash, created_by)
  values (
    v_label,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    auth.uid()
  )
  returning * into v_qr;

  -- The raw token is intentionally returned only once. Print it, then discard.
  return jsonb_build_object(
    'id', v_qr.id,
    'label', v_qr.label,
    'token', v_token,
    'created_at', v_qr.created_at
  );
end;
$$;

create or replace function public.revoke_gym_qr_code(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.gym_qr_codes
     set is_active = false,
         revoked_at = now()
   where id = p_id
     and revoked_at is null;

  return found;
end;
$$;
