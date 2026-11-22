-- 20261124000800_fitdesk_payment_execution_fixes.sql
-- Fixes the transaction drops observed during in-app checkout:
--   1. reserve_upi_checkout hard-coded provider='upi' and required the legacy
--      gyms.upi_id. Gyms configured only through gym_payment_methods (e.g.
--      PhonePe) always failed with PAYMENT_METHOD_UNAVAILABLE. It now selects
--      an enabled rail and stores it as the provider, and restores the
--      unique-violation recovery path.
--   2. get_my_upi_payment only used the per-rail payee when provider <> 'upi',
--      so older pending rows created with provider='upi' had no payee. It now
--      resolves the enabled rail regardless of the stored provider.
--   3. verify_cash_otp set fitdesk.payment_review, but the payments guard
--      requires fitdesk.payment_write AND is_admin(). It now uses a dedicated
--      transaction-local bypass flag that only this SECURITY DEFINER RPC sets.

-- ---------------------------------------------------------------------------
-- 1. reserve_upi_checkout
-- ---------------------------------------------------------------------------
create or replace function public.reserve_upi_checkout(
  p_package_id uuid,
  p_duration_days integer default null,
  p_method text default null,
  p_is_new_admission boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_gym_id uuid;
  v_gym public.gyms;
  v_existing public.payments;
  v_payment public.payments;
  v_quote jsonb;
  v_method text := nullif(btrim(coalesce(p_method, '')), '');
  v_selected_method text;
  v_upi_id text;
  v_payee_name text;
  v_qr_path text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select gym_id into v_gym_id
    from public.profiles
   where id = v_user;

  if v_gym_id is null then
    raise exception 'GYM_NOT_CONFIGURED' using errcode = 'P0001';
  end if;

  select * into v_gym
    from public.gyms
   where id = v_gym_id
     and is_active;

  if not found then
    raise exception 'GYM_NOT_CONFIGURED' using errcode = 'P0001';
  end if;

  if not exists (
    select 1
      from public.packages pk
     where pk.id = p_package_id
       and pk.is_active
       and pk.gym_id = v_gym_id
  ) then
    raise exception 'PACKAGE_NOT_FOUND' using errcode = 'P0001';
  end if;

  -- Pick a payee rail that actually exists. An explicit method wins;
  -- otherwise prefer the 'upi' rail, then any enabled rail, then legacy fields.
  if v_method is null or v_method = 'upi' then
    select pm.method, pm.upi_id, coalesce(pm.payee_name, v_gym.name), pm.qr_path
      into v_selected_method, v_upi_id, v_payee_name, v_qr_path
      from public.gym_payment_methods pm
     where pm.gym_id = v_gym_id
       and pm.is_enabled
       and pm.method = 'upi'
       and (pm.upi_id is not null or pm.qr_path is not null)
     order by pm.updated_at desc
     limit 1;

    if v_selected_method is null then
      select pm.method, pm.upi_id, coalesce(pm.payee_name, v_gym.name), pm.qr_path
        into v_selected_method, v_upi_id, v_payee_name, v_qr_path
        from public.gym_payment_methods pm
       where pm.gym_id = v_gym_id
         and pm.is_enabled
         and (pm.upi_id is not null or pm.qr_path is not null)
       order by case pm.method
                  when 'upi' then 0
                  when 'phonepe' then 1
                  when 'google_pay' then 2
                  when 'paytm' then 3
                  else 4
                end,
                pm.updated_at desc
       limit 1;
    end if;

    if v_selected_method is not null then
      v_method := v_selected_method;
    elsif v_gym.upi_id is not null or v_gym.payment_qr_path is not null then
      v_method := 'upi';
      v_upi_id := v_gym.upi_id;
      v_payee_name := coalesce(v_gym.upi_payee_name, v_gym.name);
      v_qr_path := v_gym.payment_qr_path;
    else
      raise exception 'PAYMENT_METHOD_UNAVAILABLE' using errcode = 'P0001';
    end if;
  else
    select pm.upi_id, coalesce(pm.payee_name, v_gym.name), pm.qr_path
      into v_upi_id, v_payee_name, v_qr_path
      from public.gym_payment_methods pm
     where pm.gym_id = v_gym_id
       and pm.is_enabled
       and pm.method = v_method
       and (pm.upi_id is not null or pm.qr_path is not null)
     limit 1;

    if not found then
      raise exception 'PAYMENT_METHOD_UNAVAILABLE' using errcode = 'P0001';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));

  select * into v_existing
    from public.payments
   where user_id = v_user
     and status = 'pending'
     and checkout_state <> 'abandoned'
   order by reconciliation_required desc, created_at desc
   limit 1;

  if found then
    if v_existing.reconciliation_required
       or v_existing.checkout_state = 'reconciliation_required' then
      return jsonb_build_object(
        'status', 'reconciliation_required',
        'payment_id', v_existing.id,
        'reconciliation_reason', v_existing.reconciliation_reason
      );
    end if;

    if v_existing.checkout_state = 'submitted'
       or v_existing.provider_payment_id is not null then
      return jsonb_build_object(
        'status', 'already_pending',
        'payment_id', v_existing.id,
        'upi_reference', v_existing.upi_reference,
        'amount_inr', v_existing.total_amount_inr
      );
    end if;

    return jsonb_build_object(
      'status', 'resume_checkout',
      'payment_id', v_existing.id,
      'quote', v_existing.quote,
      'package_name', v_existing.quote ->> 'package_name',
      'amount_inr', v_existing.total_amount_inr,
      'gym_id', v_existing.gym_id,
      'created_at', v_existing.created_at
    );
  end if;

  v_quote := public.get_my_renewal_quote(p_package_id, p_duration_days, p_is_new_admission);

  insert into public.payments (
    user_id, membership_id, package_id, duration_days,
    base_amount_inr, fine_amount_inr, total_amount_inr,
    status, provider, provider_order_id, provider_payment_id,
    failure_reason, quote, checkout_state, reconciliation_required,
    gym_id, payee_upi_id, is_new_admission, created_at, updated_at
  )
  values (
    v_user, null, p_package_id,
    (v_quote ->> 'duration_days')::integer,
    (v_quote ->> 'base_amount')::integer,
    (v_quote ->> 'fine_amount')::integer,
    (v_quote ->> 'total_amount')::integer,
    'pending', v_method, null, null, null, v_quote,
    'open', false, v_gym_id, v_upi_id, p_is_new_admission, now(), now()
  )
  returning * into v_payment;

  return jsonb_build_object(
    'status', 'reserved',
    'payment_id', v_payment.id,
    'quote', v_quote,
    'package_name', v_quote ->> 'package_name',
    'amount_inr', v_payment.total_amount_inr,
    'gym_id', v_gym_id,
    'payment_method', v_method,
    'payee_upi_id', v_upi_id,
    'created_at', v_payment.created_at
  );
exception
  when unique_violation then
    select * into v_existing
      from public.payments
     where user_id = v_user
       and status = 'pending'
       and checkout_state <> 'abandoned'
     order by reconciliation_required desc, created_at desc
     limit 1;

    if found then
      if v_existing.reconciliation_required then
        return jsonb_build_object(
          'status', 'reconciliation_required',
          'payment_id', v_existing.id,
          'reconciliation_reason', v_existing.reconciliation_reason
        );
      end if;

      return jsonb_build_object(
        'status', 'resume_checkout',
        'payment_id', v_existing.id,
        'quote', v_existing.quote,
        'package_name', v_existing.quote ->> 'package_name',
        'amount_inr', v_existing.total_amount_inr,
        'gym_id', v_existing.gym_id,
        'created_at', v_existing.created_at
      );
    end if;

    raise;
end;
$$;

revoke all on function public.reserve_upi_checkout(uuid, integer, text, boolean) from public, anon;
grant execute on function public.reserve_upi_checkout(uuid, integer, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. get_my_upi_payment — resolve payee for any rail, including legacy 'upi'
-- ---------------------------------------------------------------------------
create or replace function public.get_my_upi_payment(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_payment public.payments;
  v_gym public.gyms;
  v_package_name text;
  v_gym_name text;
  v_state text;
  v_reason text;
  v_available boolean := false;
  v_reference text;
  v_upi_id text;
  v_payee_name text;
  v_qr_path text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id;

  if not found or v_payment.user_id <> v_user then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  v_state := case
    when v_payment.status = 'approved' then 'VERIFIED'
    when v_payment.status = 'declined' then 'FAILED'
    when v_payment.checkout_state = 'abandoned' then 'CANCELLED'
    when v_payment.checkout_state = 'submitted'
      or v_payment.provider_payment_id is not null then 'PENDING_VERIFICATION'
    else 'NOT_STARTED'
  end;

  select name into v_package_name
    from public.packages
   where id = v_payment.package_id;

  v_reference := 'FD' || upper(substr(replace(v_payment.id::text, '-', ''), 1, 12));

  if v_payment.gym_id is null then
    v_reason := 'NOT_CONFIGURED';
  else
    select * into v_gym
      from public.gyms
     where id = v_payment.gym_id;

    if not found or not v_gym.is_active then
      v_reason := 'NOT_CONFIGURED';
    elsif v_payment.total_amount_inr is null or v_payment.total_amount_inr <= 0 then
      v_reason := 'AMOUNT_INVALID';
    else
      -- Prefer the rail recorded on the payment, then any enabled rail, then
      -- the legacy gym-level UPI settings. This also repairs pending rows
      -- created before rail selection was implemented.
      select pm.upi_id, coalesce(pm.payee_name, v_gym.name), pm.qr_path
        into v_upi_id, v_payee_name, v_qr_path
        from public.gym_payment_methods pm
       where pm.gym_id = v_payment.gym_id
         and pm.is_enabled
         and pm.method = coalesce(v_payment.provider, 'upi')
         and (pm.upi_id is not null or pm.qr_path is not null)
       limit 1;

      if v_upi_id is null and v_qr_path is null then
        select pm.upi_id, coalesce(pm.payee_name, v_gym.name), pm.qr_path
          into v_upi_id, v_payee_name, v_qr_path
          from public.gym_payment_methods pm
         where pm.gym_id = v_payment.gym_id
           and pm.is_enabled
           and (pm.upi_id is not null or pm.qr_path is not null)
         order by case pm.method
                    when 'upi' then 0
                    when 'phonepe' then 1
                    when 'google_pay' then 2
                    when 'paytm' then 3
                    else 4
                  end
         limit 1;
      end if;

      if v_upi_id is null and v_qr_path is null then
        v_upi_id := v_gym.upi_id;
        v_payee_name := coalesce(v_gym.upi_payee_name, v_gym.name);
        v_qr_path := v_gym.payment_qr_path;
      end if;

      if v_upi_id is not null or v_qr_path is not null then
        v_available := true;
        v_gym_name := v_gym.name;
      else
        v_reason := 'NOT_CONFIGURED';
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'payment_id', v_payment.id,
    'payment_state', v_state,
    'status', v_payment.status,
    'checkout_state', v_payment.checkout_state,
    'payment_method', v_payment.provider,
    'amount_inr', v_payment.total_amount_inr,
    'currency', 'INR',
    'reference', v_reference,
    'gym_id', v_payment.gym_id,
    'gym_name', coalesce(v_gym_name, (select name from public.gyms where slug = 'fitdesk')),
    'package_name', coalesce(v_package_name, 'Membership'),
    'duration_days', v_payment.duration_days,
    'starts_on', v_payment.quote ->> 'starts_on',
    'ends_on', v_payment.quote ->> 'ends_on',
    'upi_reference', v_payment.upi_reference,
    'submitted_at', v_payment.upi_submitted_at,
    'payee', jsonb_build_object(
      'available', v_available,
      'reason', v_reason,
      'upi_id', case when v_available then v_upi_id else null end,
      'name', case when v_available then v_payee_name else null end,
      'qr_path', case when v_available then v_qr_path else null end,
      'qr_bucket', case when v_available then 'gym-payment-qr' else null end
    )
  );
end;
$$;

revoke all on function public.get_my_upi_payment(uuid) from public, anon;
grant execute on function public.get_my_upi_payment(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Payments guard: allow the dedicated cash-OTP verification RPC through
-- ---------------------------------------------------------------------------
create or replace function public.guard_payment_review()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Only set inside verify_cash_otp() after a valid, single-use admin OTP.
  if coalesce(current_setting('fitdesk.cash_otp_verification', true), '') = 'on' then
    return new;
  end if;

  if new.status is distinct from old.status
     or new.reviewed_at is distinct from old.reviewed_at
     or new.reviewed_by is distinct from old.reviewed_by
     or new.review_note is distinct from old.review_note
     or new.failure_reason is distinct from old.failure_reason
     or new.refund_status is distinct from old.refund_status
     or new.refund_note is distinct from old.refund_note
     or new.refunded_at is distinct from old.refunded_at
     or new.refunded_by is distinct from old.refunded_by then
    if auth.uid() is null then
      return new;
    end if;

    if not public.is_admin() then
      raise exception 'ADMIN_REQUIRED' using errcode = '42501';
    end if;

    if coalesce(current_setting('fitdesk.payment_write', true), '') <> 'on' then
      raise exception 'PAYMENT_WRITE_VIA_RPC_ONLY' using errcode = '42501';
    end if;

    if new.status is distinct from old.status then
      if old.status <> 'pending' then
        raise exception 'PAYMENT_ALREADY_REVIEWED' using errcode = 'P0001';
      end if;

      if new.status not in ('approved', 'declined') then
        raise exception 'INVALID_REVIEW_DECISION' using errcode = 'P0001';
      end if;

      if new.status = 'approved'
         and new.reviewed_by is not null
         and new.reviewed_by = new.user_id then
        raise exception 'SELF_REVIEW_FORBIDDEN' using errcode = '42501';
      end if;
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. verify_cash_otp — use the supported guard flags
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

  update public.cash_payment_otps set used_at = now() where id = v_otp_row.id;

  select name into v_package_name
    from public.packages
   where id = v_payment.package_id;

  perform set_config('fitdesk.cash_otp_verification', 'on', true);
  perform set_config('fitdesk.payment_write', 'on', true);

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

  update public.memberships
     set status = 'expired',
         updated_at = v_now
   where user_id = v_payment.user_id
     and status = 'active'
     and ends_on < v_today;

  insert into public.memberships (
    user_id, package_id, starts_on, ends_on,
    price_paid_inr, fine_paid_inr, status, created_at, updated_at
  )
  values (
    v_payment.user_id, v_payment.package_id, v_starts, v_ends,
    v_payment.base_amount_inr, v_payment.fine_amount_inr,
    'active', v_now, v_now
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

revoke all on function public.verify_cash_otp(uuid, text) from public, anon;
grant execute on function public.verify_cash_otp(uuid, text) to authenticated;

notify pgrst, 'reload schema';
