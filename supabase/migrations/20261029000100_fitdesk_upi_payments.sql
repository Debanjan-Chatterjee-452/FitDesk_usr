-- FitDesk — direct UPI payments (member side)
--
-- Replaces the gateway checkout in the member app with a direct UPI flow:
-- the member pays the gym's own UPI ID, then submits the transaction
-- reference. The payment stays PENDING until a gym admin verifies it against
-- the bank statement. Nothing in this file ever marks a payment approved.
--
-- Multi-gym from the start:
--   * public.gyms owns each gym's payment details (UPI ID, payee name, QR).
--   * profiles.gym_id binds a member to one gym and is NOT member-writable.
--   * packages.gym_id scopes plans to a gym.
--   * payments.gym_id records which gym the money is owed to.
--   * Members cannot read public.gyms at all. They receive only their own
--     payment's payee through get_my_upi_payment(), so one gym's UPI details
--     can never be rendered for another gym.
--
-- The amount is always the server-computed quote stored on the payment row.
-- No RPC in this file accepts an amount, a UPI ID, or a gym id from the
-- client.

-- ---------------------------------------------------------------------------
-- Gyms and their payment details
-- ---------------------------------------------------------------------------
create table if not exists public.gyms (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  -- Verified recipient for direct UPI payments. NULL until the gym owner
  -- configures it; the member app then shows "payment not available yet".
  upi_id text,
  upi_payee_name text,
  -- Object path inside the private-to-members `gym-payment-qr` bucket.
  -- Must be prefixed with this gym's id (enforced by the trigger below), so a
  -- gym can never point at another gym's QR image.
  payment_qr_path text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.gyms enable row level security;
-- Deliberately no policies: members and anon cannot read gym payment details.
-- They only ever see the payee attached to their own payment via RPC.
revoke all on table public.gyms from anon, authenticated;

create or replace function public.normalize_gym_payment_settings()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.slug := lower(btrim(new.slug));
  new.name := btrim(new.name);
  new.upi_id := nullif(lower(btrim(coalesce(new.upi_id, ''))), '');
  new.upi_payee_name := nullif(btrim(coalesce(new.upi_payee_name, '')), '');
  new.payment_qr_path := nullif(btrim(coalesce(new.payment_qr_path, '')), '');
  new.updated_at := now();

  if new.name is null or length(new.name) = 0 then
    raise exception 'GYM_NAME_REQUIRED' using errcode = '22023';
  end if;

  -- Standard UPI VPA shape: <handle>@<psp>. Format only; the PSP cannot be
  -- verified from SQL, so the member app always shows the payee next to the
  -- amount for a human check.
  if new.upi_id is not null
     and new.upi_id !~ '^[a-z0-9][a-z0-9._-]{1,60}@[a-z][a-z0-9]{1,40}$' then
    raise exception 'INVALID_UPI_ID' using errcode = '22023';
  end if;

  if new.payment_qr_path is not null
     and new.payment_qr_path not like new.id::text || '/%' then
    raise exception 'QR_PATH_GYM_MISMATCH' using errcode = '22023';
  end if;

  return new;
end;
$$;

drop trigger if exists gyms_normalize_payment_settings on public.gyms;
create trigger gyms_normalize_payment_settings
  before insert or update on public.gyms
  for each row
  execute function public.normalize_gym_payment_settings();

-- Seed exactly one gym, reusing the name the app already shows. No UPI ID or
-- QR is invented: payments stay unavailable until the owner configures them.
-- The id is fixed so it can be used as a column default (PostgreSQL does not
-- allow subqueries in DEFAULT expressions).
insert into public.gyms (id, slug, name)
select
  '7a1d0d7e-0000-4000-8000-000000000001'::uuid,
  'fitdesk',
  coalesce(nullif(btrim((select name from public.gym_settings where id = 1)), ''), 'FitDesk')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Which gym does a member / plan belong to?
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists gym_id uuid references public.gyms(id) on delete restrict;

update public.profiles
   set gym_id = '7a1d0d7e-0000-4000-8000-000000000001'::uuid
 where gym_id is null;

alter table public.profiles
  alter column gym_id set default '7a1d0d7e-0000-4000-8000-000000000001'::uuid;

-- Column-level grants on profiles are not touched: members can update exactly
-- the seven profile fields granted in 00300. gym_id is not one of them.
alter table public.profiles alter column gym_id set not null;

alter table public.packages
  add column if not exists gym_id uuid references public.gyms(id) on delete restrict;

update public.packages
   set gym_id = '7a1d0d7e-0000-4000-8000-000000000001'::uuid
 where gym_id is null;

alter table public.packages
  alter column gym_id set default '7a1d0d7e-0000-4000-8000-000000000001'::uuid;

alter table public.packages alter column gym_id set not null;

create index if not exists packages_gym_idx on public.packages (gym_id, sort_order);

-- A member may only read plans that belong to their own gym.
drop policy if exists "packages_select_active" on public.packages;
create policy "packages_select_active"
  on public.packages for select
  to authenticated
  using (
    is_active = true
    and gym_id = (select gym_id from public.profiles where id = (select auth.uid()))
  );

-- ---------------------------------------------------------------------------
-- Payment columns
-- ---------------------------------------------------------------------------
alter table public.payments
  add column if not exists gym_id uuid references public.gyms(id) on delete restrict,
  add column if not exists upi_reference text,
  add column if not exists upi_submitted_at timestamptz,
  add column if not exists payee_upi_id text;

update public.payments p
   set gym_id = pr.gym_id
  from public.profiles pr
 where p.gym_id is null
   and pr.id = p.user_id;

update public.payments
   set gym_id = (select id from public.gyms where slug = 'fitdesk')
 where gym_id is null;

alter table public.payments alter column gym_id set not null;

alter table public.payments
  drop constraint if exists payments_upi_reference_format;
alter table public.payments
  add constraint payments_upi_reference_format
  check (upi_reference is null or upi_reference ~ '^[A-Z0-9]{6,40}$');

create index if not exists payments_gym_created_idx
  on public.payments (gym_id, created_at desc);

comment on column public.payments.gym_id is
  'Gym the money is owed to. Set server-side from the member profile.';
comment on column public.payments.upi_reference is
  'UTR / transaction reference claimed by the member. NOT proof of payment.';
comment on column public.payments.payee_upi_id is
  'UPI ID recorded when the member submitted the reference, for manual verification.';

-- ---------------------------------------------------------------------------
-- QR images: public read by exact path, no listing, no member uploads.
-- Public because a QR image is meant to be scanned and holds no secret; paths
-- are gym-scoped UUIDs and the app only ever builds the path returned for the
-- member's own payment.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'gym-payment-qr',
  'gym-payment-qr',
  true,
  5242880,
  array['image/png', 'image/jpeg', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Remove any broad member policies that might have been added by hand: uploads
-- are an admin/service-role operation only.
drop policy if exists "gym_payment_qr_select" on storage.objects;
drop policy if exists "gym_payment_qr_insert" on storage.objects;
drop policy if exists "gym_payment_qr_update" on storage.objects;

-- ---------------------------------------------------------------------------
-- Reserve a direct-UPI checkout (member)
--
-- Same reservation rules as reserve_renewal_checkout: one open payment per
-- member, never invent a second row while one is being reviewed or needs
-- reconciliation. The amount comes from get_my_renewal_quote(), never from
-- the browser.
-- ---------------------------------------------------------------------------
create or replace function public.reserve_upi_checkout(
  p_package_id uuid,
  p_duration_days integer default null
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

  v_quote := public.get_my_renewal_quote(p_package_id, p_duration_days);

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
    checkout_state,
    reconciliation_required,
    gym_id
  )
  values (
    v_user,
    null,
    (v_quote ->> 'package_id')::uuid,
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
    'open',
    false,
    v_gym_id
  )
  returning * into v_payment;

  return jsonb_build_object(
    'status', 'reserved',
    'payment_id', v_payment.id,
    'quote', v_quote,
    'package_name', v_quote ->> 'package_name',
    'amount_inr', v_payment.total_amount_inr,
    'gym_id', v_gym_id,
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

-- ---------------------------------------------------------------------------
-- Read the member's own payment instructions
--
-- Everything here is derived server-side from the payment row and its gym.
-- The client cannot ask for another gym, another member, or another amount.
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
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id;

  -- Same error for "not found" and "someone else's": never leak existence.
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
    elsif v_gym.upi_id is null then
      v_reason := 'NOT_CONFIGURED';
    elsif v_payment.total_amount_inr is null or v_payment.total_amount_inr <= 0 then
      v_reason := 'AMOUNT_INVALID';
    else
      v_available := true;
      v_gym_name := v_gym.name;
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
      'upi_id', case when v_available then v_gym.upi_id else null end,
      'name', case when v_available then coalesce(v_gym.upi_payee_name, v_gym.name) else null end,
      'qr_path', case when v_available then v_gym.payment_qr_path else null end,
      'qr_bucket', case when v_available then 'gym-payment-qr' else null end
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Submit the UPI transaction reference for manual verification (member)
--
-- This is a claim, not a confirmation. It moves the checkout to 'submitted'
-- and leaves status = 'pending'. Only admin_review_payment() can approve it,
-- and only after a human checks the reference in the gym's bank/UPI app.
-- ---------------------------------------------------------------------------
create or replace function public.submit_upi_payment_reference(
  p_payment_id uuid,
  p_reference text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_payment public.payments;
  v_gym public.gyms;
  v_reference text;
  v_quote jsonb;
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

  if v_payment.gym_id is null then
    raise exception 'PAYMENT_NOT_CONFIGURED' using errcode = 'P0001';
  end if;

  select * into v_gym
    from public.gyms
   where id = v_payment.gym_id;

  if not found or not v_gym.is_active or v_gym.upi_id is null then
    raise exception 'PAYMENT_NOT_CONFIGURED' using errcode = 'P0001';
  end if;

  select name into v_package_name
    from public.packages
   where id = v_payment.package_id;

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

  v_reference := upper(regexp_replace(btrim(coalesce(p_reference, '')), '[\s\-]+', '', 'g'));

  if v_reference !~ '^[A-Z0-9]{6,40}$' then
    raise exception 'INVALID_UPI_REFERENCE' using errcode = 'P0001';
  end if;

  if v_payment.provider_payment_id is not null then
    if v_payment.provider_payment_id = v_reference then
      return jsonb_build_object(
        'status', 'already_pending',
        'payment_id', v_payment.id,
        'membership_id', null,
        'starts_on', v_payment.quote ->> 'starts_on',
        'ends_on', v_payment.quote ->> 'ends_on',
        'package_name', coalesce(v_package_name, 'Membership'),
        'total_amount_inr', v_payment.total_amount_inr,
        'provider_payment_id', v_payment.provider_payment_id
      );
    end if;

    raise exception 'PAYMENT_ORDER_MISMATCH' using errcode = 'P0001';
  end if;

  v_quote := v_payment.quote;
  if v_quote is null then
    raise exception 'PAYMENT_QUOTE_MISSING' using errcode = 'P0001';
  end if;

  if coalesce((v_quote ->> 'total_amount')::integer, -1) <> v_payment.total_amount_inr
     or coalesce((v_quote ->> 'base_amount')::integer, -1) <> v_payment.base_amount_inr
     or coalesce((v_quote ->> 'fine_amount')::integer, -1) <> v_payment.fine_amount_inr
     or (v_quote ->> 'package_id')::uuid is distinct from v_payment.package_id then
    raise exception 'PAYMENT_QUOTE_MISMATCH' using errcode = 'P0001';
  end if;

  if v_payment.base_amount_inr + v_payment.fine_amount_inr <> v_payment.total_amount_inr then
    raise exception 'PAYMENT_AMOUNT_MISMATCH' using errcode = 'P0001';
  end if;

  -- provider_payment_id keeps the existing review/visibility pipeline working:
  -- the admin queue already lists pending rows that carry a payment id, and
  -- admin_review_payment() already refuses to approve a row without one.
  -- The same UTR can therefore never be claimed twice (unique index).
  update public.payments
     set provider = 'upi',
         provider_payment_id = v_reference,
         upi_reference = v_reference,
         upi_submitted_at = now(),
         payee_upi_id = v_gym.upi_id,
         checkout_state = 'submitted',
         reconciliation_required = false,
         reconciliation_reason = null,
         updated_at = now()
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'pending_approval',
    'payment_id', v_payment.id,
    'membership_id', null,
    'starts_on', v_quote ->> 'starts_on',
    'ends_on', v_quote ->> 'ends_on',
    'package_name', coalesce(v_package_name, 'Membership'),
    'total_amount_inr', v_payment.total_amount_inr,
    'provider_payment_id', v_reference
  );
exception
  when unique_violation then
    raise exception 'REFERENCE_ALREADY_USED' using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants: members may call the three member RPCs and nothing else.
-- ---------------------------------------------------------------------------
revoke all on function public.reserve_upi_checkout(uuid, integer) from public, anon, authenticated;
revoke all on function public.get_my_upi_payment(uuid) from public, anon, authenticated;
revoke all on function public.submit_upi_payment_reference(uuid, text) from public, anon, authenticated;
revoke all on function public.normalize_gym_payment_settings() from public, anon, authenticated;

grant execute on function public.reserve_upi_checkout(uuid, integer) to authenticated;
grant execute on function public.get_my_upi_payment(uuid) to authenticated;
grant execute on function public.submit_upi_payment_reference(uuid, text) to authenticated;

grant execute on function public.reserve_upi_checkout(uuid, integer) to service_role;
grant execute on function public.get_my_upi_payment(uuid) to service_role;
grant execute on function public.submit_upi_payment_reference(uuid, text) to service_role;

comment on table public.gyms is
  'One row per gym. Holds the gym-owned UPI recipient and QR used for direct payments.';
comment on function public.reserve_upi_checkout(uuid, integer) is
  'Creates the member''s pending UPI payment from the server-side quote. Amount and gym are never client-supplied.';
comment on function public.get_my_upi_payment(uuid) is
  'Returns the payee and amount for the member''s own payment only.';
comment on function public.submit_upi_payment_reference(uuid, text) is
  'Records the member''s claimed UTR. Never approves the payment or activates a membership.';
