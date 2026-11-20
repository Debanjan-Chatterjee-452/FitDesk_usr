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
