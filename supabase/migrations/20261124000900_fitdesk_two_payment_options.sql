-- ============================================================================
-- FitDesk: two member payment options
--
--   1. "Pay via App (UPI / QR)" – the member scans/opens the gym UPI, pays,
--      then taps a single "I Have Paid" button. No UTR typing. The gym gets a
--      pending request and approves it.
--   2. "Pay by Cash (Manual Cash Payment)" – the member requests cash payment.
--      A 6-digit one-time code valid for 300 seconds is generated and shown to
--      the admin only. The member enters the code after handing over cash and
--      the payment is approved automatically.
--
-- Also removes the hard-coded Sunday weekly-off from the database defaults.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Plain-text OTP for the admin panel
-- ---------------------------------------------------------------------------
-- Members can never read this table: `authenticated` has no table privileges on
-- cash_payment_otps, and every read goes through a SECURITY DEFINER RPC.
alter table public.cash_payment_otps
  add column if not exists otp_code text;

comment on column public.cash_payment_otps.otp_code is
  'Plain 6-digit code. Readable only by SECURITY DEFINER admin RPCs; the member-facing surface never receives it.';

-- ---------------------------------------------------------------------------
-- 2. Weekly-off removal: no calendar day is closed by default
-- ---------------------------------------------------------------------------
alter table public.gym_settings
  alter column closed_weekdays set default '{}'::smallint[];

update public.gym_settings
   set closed_weekdays = '{}'::smallint[],
       updated_at = now()
 where closed_weekdays is not null
   and closed_weekdays <> '{}'::smallint[];

-- New gyms must start with no weekly off days either.
create or replace function public.register_gym_owner(p_gym_name text, p_full_name text, p_phone text DEFAULT NULL::text, p_slug text DEFAULT NULL::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
  v_profile public.profiles;
  v_meta jsonb := '{}'::jsonb;
  v_gym public.gyms;
  v_gym_name text;
  v_full_name text;
  v_phone text;
  v_base text;
  v_slug text;
  v_counter integer := 1;
  v_gym_id uuid;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  -- Serialise concurrent calls for this account (double click / two tabs).
  perform pg_advisory_xact_lock(hashtextextended('fitdesk:register_gym_owner:' || v_user::text, 0));

  select raw_user_meta_data into v_meta
    from auth.users
   where id = v_user;

  select * into v_profile
    from public.profiles
   where id = v_user
   for update;

  if not found then
    raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001';
  end if;

  -- -------------------------------------------------------------------------
  -- Already registered: return the same gym, never create a second one.
  -- -------------------------------------------------------------------------
  if v_profile.is_admin then
    if v_profile.gym_id is null then
      raise exception 'ADMIN_WITHOUT_GYM' using errcode = 'P0001';
    end if;

    select * into v_gym from public.gyms where id = v_profile.gym_id;
    if not found then
      raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
    end if;

    -- Complete any missing side rows without duplicating them.
    insert into public.gym_settings
      (gym_id, name, open_time, close_time, closed_weekdays)
    values
      (v_gym.id, v_gym.name, '05:00'::time, '23:00'::time, '{}'::smallint[])
    on conflict (gym_id) do nothing;

    insert into public.gym_payment_methods (gym_id, method)
    select v_gym.id, m.method
      from (values ('google_pay'), ('phonepe'), ('paytm'), ('upi')) as m(method)
    on conflict (gym_id, method) do nothing;

    insert into public.gym_subscriptions (gym_id, plan, status, trial_ends_on)
    select v_gym.id, 'trial', 'trialing', (now() at time zone 'Asia/Kolkata')::date + 14
    where not exists (
      select 1 from public.gym_subscriptions s where s.gym_id = v_gym.id
    );

    return jsonb_build_object(
      'gym_id', v_gym.id,
      'public_id', v_gym.public_id,
      'join_code', v_gym.join_code,
      'slug', v_gym.slug,
      'name', v_gym.name,
      'is_admin', true,
      'already_registered', true
    );
  end if;

  -- -------------------------------------------------------------------------
  -- New owner. Fall back to the signup metadata when arguments are omitted.
  -- -------------------------------------------------------------------------
  v_gym_name := nullif(btrim(coalesce(p_gym_name, v_meta ->> 'gym_name', '')), '');
  v_full_name := nullif(btrim(coalesce(p_full_name, v_meta ->> 'full_name', '')), '');
  v_phone := nullif(btrim(coalesce(p_phone, v_meta ->> 'phone', '')), '');

  -- A member who already belongs to a gym must not silently take it over.
  -- Owner signups always carry a gym_name in auth metadata, which lets a
  -- pending owner created before the gym-less profile change finish setup.
  if v_profile.gym_id is not null
     and nullif(btrim(coalesce(v_meta ->> 'gym_name', '')), '') is null then
    raise exception 'MEMBER_ALREADY_IN_GYM' using errcode = '42501';
  end if;

  if v_gym_name is null or length(v_gym_name) < 2 then
    raise exception 'GYM_NAME_REQUIRED' using errcode = '22023';
  end if;

  if length(v_gym_name) > 80 then
    raise exception 'GYM_NAME_TOO_LONG' using errcode = '22023';
  end if;

  v_base := btrim(lower(regexp_replace(v_gym_name, '[^a-zA-Z0-9]+', '-', 'g')), '-');
  if v_base = '' then
    v_base := 'gym';
  end if;
  v_base := left(v_base, 40);

  v_slug := btrim(lower(coalesce(p_slug, '')), '-');
  if v_slug = '' or v_slug !~ '^[a-z0-9][a-z0-9-]{1,48}$' then
    v_slug := v_base;
  end if;

  while exists (select 1 from public.gyms g where g.slug = v_slug) loop
    v_counter := v_counter + 1;
    v_slug := v_base || '-' || v_counter;
  end loop;

  insert into public.gyms (slug, name, owner_id)
  values (v_slug, v_gym_name, v_user)
  returning id into v_gym_id;

  -- Per-gym settings (public_id and join_code are set by their triggers).
  insert into public.gym_settings
    (gym_id, name, open_time, close_time, closed_weekdays)
  values
    (v_gym_id, v_gym_name, '05:00'::time, '23:00'::time, '{}'::smallint[])
  on conflict (gym_id) do nothing;

  -- Four payment rails, disabled until the owner enters UPI details.
  insert into public.gym_payment_methods (gym_id, method)
  select v_gym_id, m.method
    from (values ('google_pay'), ('phonepe'), ('paytm'), ('upi')) as m(method)
  on conflict (gym_id, method) do nothing;

  -- Manual subscription tracking (no gateway): start on a trial.
  insert into public.gym_subscriptions (gym_id, plan, status, trial_ends_on)
  values (v_gym_id, 'trial', 'trialing', (now() at time zone 'Asia/Kolkata')::date + 14);

  update public.profiles
     set is_admin = true,
         gym_id = v_gym_id,
         full_name = coalesce(v_full_name, full_name),
         phone = coalesce(v_phone, phone),
         updated_at = now()
   where id = v_user;

  select * into v_gym from public.gyms where id = v_gym_id;

  return jsonb_build_object(
    'gym_id', v_gym.id,
    'public_id', v_gym.public_id,
    'join_code', v_gym.join_code,
    'slug', v_gym.slug,
    'name', v_gym.name,
    'is_admin', true,
    'already_registered', false
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3. reserve_upi_checkout – recognise the cash rail
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
set search_path to 'public', 'pg_temp'
as $function$
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

  v_method := lower(coalesce(v_method, 'upi'));

  if v_method = 'cash' then
    -- Cash never needs a UPI payee; the money changes hands at the desk.
    v_selected_method := 'cash';
  elsif v_method = 'upi' then
    -- Pick a payee rail that actually exists. An explicit method wins;
    -- otherwise prefer the 'upi' rail, then any enabled rail, then legacy fields.
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
    elsif not exists (
      select 1 from public.gym_payment_methods pm
       where pm.gym_id = v_gym_id and pm.is_enabled
    ) then
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
      'payment_method', v_existing.provider,
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
        'payment_method', v_existing.provider,
        'created_at', v_existing.created_at
      );
    end if;

    raise;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 4. member_request_cash_payment – issue the 6-digit / 300 s code
-- ---------------------------------------------------------------------------
create or replace function public.member_request_cash_payment(
  p_package_id uuid,
  p_duration_days integer default null,
  p_is_new_admission boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
  v_result jsonb;
  v_status text;
  v_payment_id uuid;
  v_payment public.payments;
  v_gym_name text;
  v_live public.cash_payment_otps;
  v_otp text;
  v_expires timestamptz;
  v_name text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  v_result := public.reserve_upi_checkout(
    p_package_id,
    p_duration_days,
    'cash',
    coalesce(p_is_new_admission, false)
  );
  v_status := v_result ->> 'status';
  v_payment_id := (v_result ->> 'payment_id')::uuid;

  if v_status = 'reconciliation_required' then
    return v_result;
  end if;

  if v_status = 'already_pending' then
    return v_result || jsonb_build_object('reason', 'PAYMENT_ALREADY_SUBMITTED');
  end if;

  -- The cash rail is authoritative for this request, even when an earlier
  -- UPI checkout row was still open.
  update public.payments
     set provider = 'cash',
         payee_upi_id = null,
         updated_at = now()
   where id = v_payment_id
     and status = 'pending'
     and checkout_state = 'open'
  returning * into v_payment;

  if v_payment.id is null then
    select * into v_payment from public.payments where id = v_payment_id;
  end if;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.user_id <> v_user then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status <> 'pending'
     or v_payment.checkout_state in ('submitted', 'reconciliation_required') then
    return jsonb_build_object(
      'status', 'already_pending',
      'payment_id', v_payment.id,
      'reason', 'PAYMENT_ALREADY_SUBMITTED',
      'amount_inr', v_payment.total_amount_inr
    );
  end if;

  -- One live code at a time: rebuilding it inside the 300 s window would let a
  -- member spam the admin panel, so the existing code is reused instead.
  select * into v_live
    from public.cash_payment_otps
   where payment_id = v_payment.id
     and used_at is null
     and expires_at > now()
   order by created_at desc
   limit 1;

  if found then
    select name into v_name from public.packages where id = v_payment.package_id;
    select name into v_gym_name from public.gyms where id = v_payment.gym_id;
    return jsonb_build_object(
      'status', 'otp_issued',
      'payment_id', v_payment.id,
      'amount_inr', v_payment.total_amount_inr,
      'package_name', coalesce(v_name, 'Membership'),
      'duration_days', v_payment.duration_days,
      'gym_name', v_gym_name,
      'expires_at', v_live.expires_at,
      'reused', true
    );
  end if;

  update public.cash_payment_otps
     set used_at = now()
   where payment_id = v_payment.id
     and used_at is null;

  v_otp := lpad((floor(random() * 900000) + 100000)::text, 6, '0');
  v_expires := now() + interval '300 seconds';

  insert into public.cash_payment_otps (
    gym_id, user_id, payment_id, otp_hash, otp_code, expires_at, created_by
  )
  values (
    v_payment.gym_id, v_user, v_payment.id,
    encode(extensions.digest(v_otp, 'sha256'), 'hex'), v_otp, v_expires, null
  );

  select name into v_name from public.packages where id = v_payment.package_id;
  select name into v_gym_name from public.gyms where id = v_payment.gym_id;

  insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id)
  values (
    v_payment.gym_id,
    'cash_payment_requested',
    'Cash payment requested – ' || coalesce(v_name, 'Membership'),
    'A member asked to pay ' || v_payment.total_amount_inr::text || ' INR in cash for the '
      || coalesce(v_name, 'Membership') || ' plan. Code ' || v_otp
      || ' is valid for 5 minutes. Collect the cash, then read the code to the member.',
    jsonb_build_object(
      'payment_id', v_payment.id,
      'payment_method', 'cash',
      'otp_code', v_otp,
      'otp_expires_at', v_expires,
      'amount_inr', v_payment.total_amount_inr,
      'package_name', coalesce(v_name, 'Membership'),
      'duration_days', v_payment.duration_days
    ),
    v_user
  );

  return jsonb_build_object(
    'status', 'otp_issued',
    'payment_id', v_payment.id,
    'amount_inr', v_payment.total_amount_inr,
    'package_name', coalesce(v_name, 'Membership'),
    'duration_days', v_payment.duration_days,
    'gym_name', v_gym_name,
    'expires_at', v_expires,
    'reused', false
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. get_my_cash_payment – the member's cash request state
-- ---------------------------------------------------------------------------
create or replace function public.get_my_cash_payment(p_payment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
  v_payment public.payments;
  v_package_name text;
  v_gym_name text;
  v_live public.cash_payment_otps;
  v_state text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id
     and user_id = v_user;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  v_state := case
    when v_payment.status = 'approved' then 'VERIFIED'
    when v_payment.status = 'declined' then 'FAILED'
    when v_payment.checkout_state = 'abandoned' then 'CANCELLED'
    when v_payment.checkout_state = 'reconciliation_required' then 'RECONCILIATION'
    else 'AWAITING_CASH'
  end;

  select name into v_package_name from public.packages where id = v_payment.package_id;
  select name into v_gym_name from public.gyms where id = v_payment.gym_id;

  select * into v_live
    from public.cash_payment_otps
   where payment_id = v_payment.id
     and used_at is null
     and expires_at > now()
   order by created_at desc
   limit 1;

  return jsonb_build_object(
    'payment_id', v_payment.id,
    'payment_state', v_state,
    'status', v_payment.status,
    'checkout_state', v_payment.checkout_state,
    'payment_method', v_payment.provider,
    'amount_inr', v_payment.total_amount_inr,
    'package_name', coalesce(v_package_name, 'Membership'),
    'duration_days', v_payment.duration_days,
    'gym_name', v_gym_name,
    'requested_at', v_payment.created_at,
    'otp_expires_at', v_live.expires_at,
    'has_live_otp', v_live.id is not null,
    'can_rerequest_at', v_live.expires_at,
    'starts_on', v_payment.quote ->> 'starts_on',
    'ends_on', v_payment.quote ->> 'ends_on'
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 6. member_mark_payment_paid – the one-tap "I Have Paid"
-- ---------------------------------------------------------------------------
create or replace function public.member_mark_payment_paid(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := auth.uid();
  v_payment public.payments;
  v_package_name text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id
   for update;

  if not found or v_payment.user_id <> v_user then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  select name into v_package_name from public.packages where id = v_payment.package_id;

  if v_payment.status = 'approved' then
    return jsonb_build_object(
      'status', 'already_approved',
      'payment_id', v_payment.id,
      'membership_id', v_payment.membership_id,
      'starts_on', v_payment.quote ->> 'starts_on',
      'ends_on', v_payment.quote ->> 'ends_on',
      'package_name', coalesce(v_package_name, 'Membership'),
      'total_amount_inr', v_payment.total_amount_inr
    );
  end if;

  if v_payment.status = 'declined' then
    raise exception 'PAYMENT_DECLINED' using errcode = 'P0001';
  end if;

  if v_payment.checkout_state = 'abandoned' then
    raise exception 'PAYMENT_NOT_PAYABLE' using errcode = 'P0001';
  end if;

  if v_payment.reconciliation_required
     or v_payment.checkout_state = 'reconciliation_required' then
    raise exception 'PAYMENT_RECONCILIATION_REQUIRED' using errcode = 'P0001';
  end if;

  if v_payment.provider = 'cash' then
    raise exception 'CASH_PAYMENT_REQUIRES_OTP' using errcode = 'P0001';
  end if;

  if v_payment.checkout_state = 'submitted' then
    return jsonb_build_object(
      'status', 'already_pending',
      'payment_id', v_payment.id,
      'membership_id', null,
      'starts_on', v_payment.quote ->> 'starts_on',
      'ends_on', v_payment.quote ->> 'ends_on',
      'package_name', coalesce(v_package_name, 'Membership'),
      'total_amount_inr', v_payment.total_amount_inr
    );
  end if;

  update public.payments
     set checkout_state = 'submitted',
         upi_submitted_at = now(),
         reconciliation_required = false,
         reconciliation_reason = null,
         updated_at = now()
   where id = v_payment.id;

  insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id)
  values (
    v_payment.gym_id,
    'payment_submitted',
    'UPI payment submitted – ' || coalesce(v_package_name, 'Membership'),
    'A member marked their ' || v_payment.total_amount_inr::text || ' INR UPI payment as paid for the '
      || coalesce(v_package_name, 'Membership') || ' plan. Check your bank or UPI statement, then approve.',
    jsonb_build_object(
      'payment_id', v_payment.id,
      'payment_method', coalesce(v_payment.provider, 'upi'),
      'amount_inr', v_payment.total_amount_inr,
      'package_name', coalesce(v_package_name, 'Membership'),
      'duration_days', v_payment.duration_days
    ),
    v_user
  );

  return jsonb_build_object(
    'status', 'pending_approval',
    'payment_id', v_payment.id,
    'membership_id', null,
    'starts_on', v_payment.quote ->> 'starts_on',
    'ends_on', v_payment.quote ->> 'ends_on',
    'package_name', coalesce(v_package_name, 'Membership'),
    'total_amount_inr', v_payment.total_amount_inr
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 7. verify_cash_otp – 6 digits, 300 s, auto-approve
-- ---------------------------------------------------------------------------
create or replace function public.verify_cash_otp(p_payment_id uuid, p_otp text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
  v_reviewer uuid;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if p_otp is null or btrim(p_otp) !~ '^[0-9]{6}$' then
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

  -- Attribute the approval to a real admin of the gym when one exists. A
  -- member-requested code has no created_by, so this stays null instead of
  -- recording the member as their own reviewer.
  select coalesce(
           (select g.owner_id from public.gyms g where g.id = v_payment.gym_id),
           (select p.id from public.profiles p
             where p.gym_id = v_payment.gym_id and p.is_admin = true
             order by p.created_at asc limit 1)
         )
    into v_reviewer;

  update public.memberships
     set status = 'expired',
         updated_at = v_now
   where user_id = v_payment.user_id
     and status = 'active'
     and ends_on < v_today;

  insert into public.memberships (
    user_id, package_id, starts_on, ends_on,
    price_paid_inr, fine_paid_inr, status, gym_id, created_at, updated_at
  )
  values (
    v_payment.user_id, v_payment.package_id, v_starts, v_ends,
    v_payment.base_amount_inr, v_payment.fine_amount_inr,
    'active', v_payment.gym_id, v_now, v_now
  )
  returning * into v_membership;

  update public.payments
     set status = 'approved',
         membership_id = v_membership.id,
         failure_reason = null,
         review_note = 'Verified via cash OTP.',
         reviewed_at = v_now,
         reviewed_by = v_reviewer,
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
$function$;

-- ---------------------------------------------------------------------------
-- 8. admin_generate_cash_otp – keep the desk-initiated path on the same rules
-- ---------------------------------------------------------------------------
create or replace function public.admin_generate_cash_otp(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_payment public.payments;
  v_otp text;
  v_hash text;
  v_expires timestamptz := now() + interval '300 seconds';
begin
  select * into v_payment
    from public.payments
   where id = p_payment_id
   for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.gym_id is distinct from v_gym_id then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status <> 'pending' then
    raise exception 'PAYMENT_ALREADY_REVIEWED' using errcode = 'P0001';
  end if;

  update public.cash_payment_otps
     set used_at = now()
   where payment_id = p_payment_id
     and used_at is null;

  v_otp := lpad((floor(random() * 900000) + 100000)::text, 6, '0');
  v_hash := encode(extensions.digest(v_otp, 'sha256'), 'hex');

  insert into public.cash_payment_otps (
    gym_id, user_id, payment_id, otp_hash, otp_code, expires_at, created_by
  )
  values (
    v_gym_id, v_payment.user_id, p_payment_id, v_hash, v_otp, v_expires, auth.uid()
  );

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'otp_code', v_otp,
    'expires_at', v_expires,
    'valid_seconds', 300
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 9. Clear the matching admin notification once a payment is reviewed
-- ---------------------------------------------------------------------------
create or replace function public.clear_payment_notifications()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if old.status = 'pending' and new.status in ('approved', 'declined') then
    update public.admin_notifications
       set is_read = true,
           read_at = coalesce(read_at, now())
     where gym_id = new.gym_id
       and is_read = false
       and (payload ->> 'payment_id') = new.id::text;
  end if;
  return new;
end;
$function$;

drop trigger if exists payments_clear_notifications on public.payments;
create trigger payments_clear_notifications
  after update of status on public.payments
  for each row
  execute function public.clear_payment_notifications();

-- ---------------------------------------------------------------------------
-- 10. Admin payment queues: expose the rail and the live cash code
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_pending_payments();
drop function if exists public.admin_list_pending_payments_all_gyms();

create function public.admin_list_pending_payments_all_gyms()
returns table(
  payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text,
  package_name text, duration_days integer, base_amount_inr integer, fine_amount_inr integer,
  total_amount_inr integer, status payment_status, provider_order_id text, provider_payment_id text,
  failure_reason text, quote jsonb, created_at timestamptz, paid_at timestamptz,
  reviewed_at timestamptz, reviewed_by uuid, checkout_state text, reconciliation_required boolean,
  reconciliation_reason text, legacy_status text, refund_status text, refund_note text,
  refunded_at timestamptz, refunded_by uuid, payment_method text, cash_otp text,
  cash_otp_expires_at timestamptz, upi_submitted_at timestamptz, is_new_admission boolean
)
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
begin
  if not public.is_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.user_id,
    coalesce(nullif(btrim(pr.full_name), ''), 'FitDesk member'),
    u.email::text,
    coalesce(nullif(btrim(pr.phone), ''), u.phone::text),
    coalesce(pk.name, 'Membership'),
    p.duration_days,
    p.base_amount_inr,
    p.fine_amount_inr,
    p.total_amount_inr,
    p.status,
    p.provider_order_id,
    p.provider_payment_id,
    p.failure_reason,
    p.quote,
    p.created_at,
    p.paid_at,
    p.reviewed_at,
    p.reviewed_by,
    p.checkout_state,
    p.reconciliation_required,
    p.reconciliation_reason,
    p.legacy_status,
    p.refund_status,
    p.refund_note,
    p.refunded_at,
    p.refunded_by,
    p.provider,
    otp.otp_code,
    otp.expires_at,
    p.upi_submitted_at,
    coalesce(p.is_new_admission, false)
  from public.payments p
  left join public.profiles pr on pr.id = p.user_id
  left join auth.users u on u.id = p.user_id
  left join public.packages pk on pk.id = p.package_id
  left join lateral (
    select o.otp_code, o.expires_at
      from public.cash_payment_otps o
     where o.payment_id = p.id
       and o.used_at is null
       and o.expires_at > now()
     order by o.created_at desc
     limit 1
  ) otp on true
  where p.status = 'pending'
    and (
      p.provider_payment_id is not null
      or p.reconciliation_required
      or p.checkout_state = 'submitted'
      or p.provider = 'cash'
    )
  order by p.reconciliation_required desc, coalesce(p.paid_at, p.created_at) asc;
end;
$function$;

create function public.admin_list_pending_payments()
returns table(
  payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text,
  package_name text, duration_days integer, base_amount_inr integer, fine_amount_inr integer,
  total_amount_inr integer, status payment_status, provider_order_id text, provider_payment_id text,
  failure_reason text, quote jsonb, created_at timestamptz, paid_at timestamptz,
  reviewed_at timestamptz, reviewed_by uuid, checkout_state text, reconciliation_required boolean,
  reconciliation_reason text, legacy_status text, refund_status text, refund_note text,
  refunded_at timestamptz, refunded_by uuid, payment_method text, cash_otp text,
  cash_otp_expires_at timestamptz, upi_submitted_at timestamptz, is_new_admission boolean,
  screenshot_path text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_gym_id uuid := public.admin_assert();
begin
  return query
  select q.*, p.screenshot_path
    from public.admin_list_pending_payments_all_gyms() q
    join public.payments p on p.id = q.payment_id
   where p.gym_id = v_gym_id
   order by q.reconciliation_required desc, coalesce(q.paid_at, q.created_at) asc;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 11. Member list: surface the pending rail and code
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
  pending_otp_expires_at timestamptz, activity_at timestamptz, total_count bigint
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
    b.pending_method,
    b.pending_otp,
    b.pending_otp_expires_at,
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
$function$;

-- ---------------------------------------------------------------------------
-- 12. Dashboard counter must see cash and one-tap submissions too
-- ---------------------------------------------------------------------------
create or replace function public.admin_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  return jsonb_build_object(
    'total_members', (
      select count(*)::integer
        from public.profiles p
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
    ),
    'deactivated_members', (
      select count(*)::integer
        from public.profiles p
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = true
    ),
    'active_members', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.starts_on <= v_today
         and m.ends_on >= v_today
    ),
    'pending_approvals', (
      select count(*)::integer
        from public.payments pay
       where pay.gym_id = v_gym_id
         and pay.status = 'pending'
         and (
           pay.provider_payment_id is not null
           or pay.checkout_state = 'submitted'
           or pay.provider = 'cash'
         )
    ),
    'expiring_1d', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.ends_on = v_today + 1
    ),
    'expiring_3d', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.ends_on between v_today + 1 and v_today + 3
    ),
    'expiring_7d', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.ends_on between v_today + 1 and v_today + 7
    ),
    'expired', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.ends_on < v_today
    ),
    'today_checkins', (
      select count(*)::integer
        from public.attendance a
        join public.profiles p on p.id = a.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and a.check_in_date = v_today
    ),
    'revenue_month_inr', (
      select coalesce(sum(pay.total_amount_inr), 0)::integer
        from public.payments pay
       where pay.gym_id = v_gym_id
         and pay.status = 'approved'
         and (pay.reviewed_at at time zone 'Asia/Kolkata')::date >= date_trunc('month', v_today)::date
    ),
    'active_packages', (
      select count(*)::integer
        from public.packages pk
       where pk.gym_id = v_gym_id
         and pk.is_active = true
    ),
    'is_open', (
      select g.is_open from public.gyms g where g.id = v_gym_id
    ),
    'today', v_today
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 13. Grants
-- ---------------------------------------------------------------------------
grant execute on function public.member_request_cash_payment(uuid, integer, boolean) to authenticated;
grant execute on function public.get_my_cash_payment(uuid) to authenticated;
grant execute on function public.member_mark_payment_paid(uuid) to authenticated;
grant execute on function public.verify_cash_otp(uuid, text) to authenticated;
grant execute on function public.reserve_upi_checkout(uuid, integer, text, boolean) to authenticated;
grant execute on function public.admin_list_pending_payments() to authenticated;
grant execute on function public.admin_generate_cash_otp(uuid) to authenticated;
grant execute on function public.admin_list_members_page(text, text, integer, integer) to authenticated;
grant execute on function public.admin_dashboard_stats() to authenticated;
grant execute on function public.register_gym_owner(text, text, text, text) to authenticated;

notify pgrst, 'reload schema';
