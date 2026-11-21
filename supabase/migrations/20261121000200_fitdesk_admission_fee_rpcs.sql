-- 20261121000200_fitdesk_admission_fee_rpcs.sql
-- Makes get_my_renewal_quote and reserve_upi_checkout admission-fee aware.

-- ---------------------------------------------------------------------------
-- get_my_renewal_quote: add p_is_new_admission, add admission fee to base
-- ---------------------------------------------------------------------------
create or replace function public.get_my_renewal_quote(
  p_package_id uuid,
  p_duration_days integer default null,
  p_is_new_admission boolean default false
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
  v_gym public.gyms;
  v_gym_id uuid;
  v_duration integer;
  v_days_past integer := 0;
  v_fine integer := 0;
  v_fine_reason text := null;
  v_base integer;
  v_admission_fee integer := 0;
  v_starts date;
  v_ends date;
  v_is_stacked boolean := false;
  v_effective_end date;
  v_is_paused boolean := false;
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

  select gym_id into v_gym_id from public.profiles where id = v_user;

  if v_gym_id is not null then
    select * into v_gym from public.gyms where id = v_gym_id;
    if p_is_new_admission then
      v_admission_fee := coalesce(v_gym.admission_fee_inr, 0);
    end if;
  end if;

  select * into v_latest
    from public.memberships
   where user_id = v_user
     and status <> 'cancelled'
   order by ends_on desc
   limit 1;

  v_effective_end := case
    when v_latest.id is null then null
    else v_latest.ends_on + coalesce(v_latest.total_paused_days, 0)
  end;

  v_is_paused := v_latest.status = 'paused';
  v_is_stacked := v_latest.id is not null and (v_effective_end >= v_today or v_is_paused);

  if v_latest.id is not null and not v_is_paused and v_effective_end < v_today then
    v_days_past := (v_today - v_effective_end)::integer;
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
    v_fine := 50 + 5 * (v_days_past - 8);
    v_fine_reason := v_days_past::text || ' days past expiry - ₹50 + ₹5/day after day 8';
  elsif v_days_past > 0 then
    v_fine_reason := v_days_past::text
      || case when v_days_past = 1 then ' day' else ' days' end
      || ' past expiry - inside the 7-day grace period';
  end if;

  v_base := case
    when v_pkg.pricing_mode = 'per_day' then v_pkg.price_inr * v_duration
    else v_pkg.price_inr
  end;

  if v_admission_fee > 0 then
    v_base := v_base + v_admission_fee;
  end if;

  v_starts := case when v_is_stacked then v_effective_end + 1 else v_today end;
  v_ends := v_starts + (v_duration - 1);

  v_breakdown := jsonb_build_array(
    jsonb_build_object(
      'label', v_pkg.name || ' · ' || v_duration::text || ' days',
      'amount', case when v_pkg.pricing_mode = 'per_day' then v_pkg.price_inr * v_duration else v_pkg.price_inr end
    )
  );

  if v_admission_fee > 0 then
    v_breakdown := v_breakdown || jsonb_build_array(
      jsonb_build_object('label', 'Admission fee', 'amount', v_admission_fee)
    );
  end if;

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
    'current_ends_on', v_effective_end,
    'is_stacked', v_is_stacked,
    'is_paused', v_is_paused,
    'fine_reason', v_fine_reason,
    'admission_fee', v_admission_fee,
    'is_new_admission', p_is_new_admission,
    'breakdown', v_breakdown
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- reserve_upi_checkout: add p_is_new_admission, pass to quote, store flag
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

  if v_method is null or v_method = 'upi' then
    if v_gym.upi_id is null then
      raise exception 'PAYMENT_METHOD_UNAVAILABLE' using errcode = 'P0001';
    end if;
    v_method := 'upi';
  else
    if not exists (
      select 1
        from public.gym_payment_methods pm
       where pm.gym_id = v_gym_id
         and pm.is_enabled
         and pm.method = v_method
         and (pm.upi_id is not null or pm.qr_path is not null)
    ) then
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
    user_id,
    membership_id,
    package_id,
    duration_days,
    base_amount_inr,
    fine_amount_inr,
    total_amount_inr,
    status,
    provider,
    provider_order_id,
    provider_payment_id,
    failure_reason,
    quote,
    paid_at,
    reviewed_at,
    reviewed_by,
    review_note,
    checkout_state,
    reconciliation_required,
    reconciliation_reason,
    legacy_status,
    refund_status,
    refund_note,
    refunded_at,
    refunded_by,
    gym_id,
    upi_reference,
    upi_submitted_at,
    payee_upi_id,
    is_new_admission,
    created_at,
    updated_at
  )
  values (
    v_user,
    null,
    p_package_id,
    (v_quote ->> 'duration_days')::integer,
    (v_quote ->> 'base_amount')::integer,
    (v_quote ->> 'fine_amount')::integer,
    (v_quote ->> 'total_amount')::integer,
    'pending',
    'upi',
    null,
    null,
    null,
    v_quote,
    null,
    null,
    null,
    null,
    'open',
    false,
    null,
    null,
    'not_required',
    null,
    null,
    null,
    v_gym_id,
    null,
    null,
    null,
    p_is_new_admission,
    now(),
    now()
  )
  returning * into v_payment;

  return jsonb_build_object(
    'status', 'reserved',
    'payment_id', v_payment.id,
    'quote', v_quote,
    'package_name', v_quote ->> 'package_name',
    'amount_inr', v_payment.total_amount_inr,
    'gym_id', v_payment.gym_id,
    'created_at', v_payment.created_at
  );
end;
$$;

-- Grants (signature changed -> drop old first)
drop function if exists public.reserve_upi_checkout(uuid, integer, text);
revoke execute on function public.reserve_upi_checkout(uuid, integer, text, boolean) from public, anon;
grant execute on function public.reserve_upi_checkout(uuid, integer, text, boolean) to authenticated;
grant execute on function public.reserve_upi_checkout(uuid, integer, text, boolean) to service_role;

revoke execute on function public.get_my_renewal_quote(uuid, integer, boolean) from public, anon;
grant execute on function public.get_my_renewal_quote(uuid, integer, boolean) to authenticated;
grant execute on function public.get_my_renewal_quote(uuid, integer, boolean) to service_role;
