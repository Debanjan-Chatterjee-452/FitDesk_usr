-- ===========================================================================
-- FitDesk — multi-gym ownership, per-method UPI configuration, isolation fixes
-- ---------------------------------------------------------------------------
-- Builds on 20261031000100_fitdesk_admin_portal.sql.
--
-- What this migration does
--   1. Adds public.gym_payment_methods so a gym can configure Google Pay,
--      PhonePe, Paytm and General UPI independently, each with its own UPI ID
--      and/or QR image (both are allowed at the same time).
--   2. Adds memberships.gym_id and announcements.gym_id so membership history
--      and closures belong to exactly one gym.
--   3. Closes the gym-isolation holes in the payment review queue, the members
--      list, the closure calendar and QR check-in.
--   4. Adds self-service gym-owner onboarding (register_gym_owner) so every
--      gym gets its own admin account, slug and payment configuration.
--   5. Adds a private payment-proofs bucket for member screenshots.
--   6. Stops new payments defaulting to the retired 'razorpay' provider.
--
-- Nothing here deletes member, payment, membership or attendance history.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Per-method payment configuration
-- ---------------------------------------------------------------------------
create table if not exists public.gym_payment_methods (
  gym_id uuid not null references public.gyms (id) on delete cascade,
  method text not null,
  is_enabled boolean not null default false,
  upi_id text,
  payee_name text,
  qr_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (gym_id, method),
  constraint gym_payment_methods_method_valid
    check (method in ('google_pay', 'phonepe', 'paytm', 'upi'))
);

comment on table public.gym_payment_methods is
  'One row per gym and payment rail. UPI ID and QR path are independent: either, both, or neither.';
comment on column public.gym_payment_methods.method is
  'google_pay | phonepe | paytm | upi (general UPI).';
comment on column public.gym_payment_methods.qr_path is
  'Object path inside gym-payment-qr. Always prefixed with the owning gym id.';

create or replace function public.normalize_gym_payment_method()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  new.upi_id := nullif(lower(btrim(coalesce(new.upi_id, ''))), '');
  new.payee_name := nullif(btrim(coalesce(new.payee_name, '')), '');
  new.qr_path := nullif(btrim(coalesce(new.qr_path, '')), '');
  new.updated_at := now();

  if new.upi_id is not null
     and new.upi_id !~ '^[a-z0-9][a-z0-9._-]{1,60}@[a-z][a-z0-9]{1,40}$' then
    raise exception 'INVALID_UPI_ID' using errcode = '22023';
  end if;

  if new.qr_path is not null and new.qr_path not like new.gym_id::text || '/%' then
    raise exception 'QR_PATH_GYM_MISMATCH' using errcode = '22023';
  end if;

  -- A rail that is switched on must have at least one way to pay.
  if new.is_enabled and new.upi_id is null and new.qr_path is null then
    raise exception 'PAYMENT_METHOD_INCOMPLETE' using errcode = '22023';
  end if;

  return new;
end;
$$;

drop trigger if exists gym_payment_methods_normalize on public.gym_payment_methods;
create trigger gym_payment_methods_normalize
  before insert or update on public.gym_payment_methods
  for each row
  execute function public.normalize_gym_payment_method();

alter table public.gym_payment_methods enable row level security;
-- No policies and no table grants: the table is reachable only through the
-- SECURITY DEFINER admin/member RPCs below.
revoke all on table public.gym_payment_methods from anon, authenticated;

-- Every gym always has exactly four rail rows so the admin UI can render a
-- stable card list even before anything is configured.
insert into public.gym_payment_methods (gym_id, method)
select g.id, m.method
  from public.gyms g
 cross join (values ('google_pay'), ('phonepe'), ('paytm'), ('upi')) as m(method)
on conflict (gym_id, method) do nothing;

-- Carry any existing single-UPI configuration into the General UPI rail.
update public.gym_payment_methods pm
   set is_enabled = true,
       upi_id = g.upi_id,
       payee_name = g.upi_payee_name,
       qr_path = g.payment_qr_path
  from public.gyms g
 where pm.gym_id = g.id
   and pm.method = 'upi'
   and pm.upi_id is null
   and pm.qr_path is null
   and (g.upi_id is not null or g.payment_qr_path is not null);

-- ---------------------------------------------------------------------------
-- 2. Memberships belong to a gym
-- ---------------------------------------------------------------------------
alter table public.memberships
  add column if not exists gym_id uuid references public.gyms (id) on delete restrict;

-- Fills gym_id from the package on every write path, including the older
-- admin_review_payment() body that predates this column.
create or replace function public.fill_membership_gym()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.gym_id is null then
    select pk.gym_id into new.gym_id
      from public.packages pk
     where pk.id = new.package_id;
  end if;

  if new.gym_id is null then
    raise exception 'MEMBERSHIP_GYM_REQUIRED' using errcode = '23502';
  end if;

  return new;
end;
$$;

drop trigger if exists memberships_fill_gym on public.memberships;
create trigger memberships_fill_gym
  before insert or update of package_id on public.memberships
  for each row
  execute function public.fill_membership_gym();

update public.memberships m
   set gym_id = pk.gym_id
  from public.packages pk
 where pk.id = m.package_id
   and m.gym_id is null;

update public.memberships
   set gym_id = (select id from public.gyms where slug = 'fitdesk')
 where gym_id is null;

alter table public.memberships alter column gym_id set not null;

create index if not exists memberships_gym_user_idx
  on public.memberships (gym_id, user_id, ends_on desc);

comment on column public.memberships.gym_id is
  'Gym this membership belongs to. Derived from the package, never client input.';

-- ---------------------------------------------------------------------------
-- 2b. Phone numbers are unique per gym, not globally
--
-- profiles_phone_unique was global, so two different gyms could never have a
-- member or owner with the same mobile number.
-- ---------------------------------------------------------------------------
drop index if exists public.profiles_phone_unique;
create unique index if not exists profiles_gym_phone_unique
  on public.profiles (gym_id, phone)
  where phone <> '';

-- ---------------------------------------------------------------------------
-- 3. Announcements / closures belong to a gym
-- ---------------------------------------------------------------------------
alter table public.announcements
  add column if not exists gym_id uuid references public.gyms (id) on delete cascade;

update public.announcements
   set gym_id = (select id from public.gyms where slug = 'fitdesk')
 where gym_id is null;

alter table public.announcements alter column gym_id set not null;

create index if not exists announcements_gym_active_idx
  on public.announcements (gym_id, is_active, starts_on);

-- Replace the global "one closure per date" rule with a per-gym rule.
drop index if exists public.announcements_one_active_closure_per_date;
create unique index if not exists announcements_one_active_closure_per_gym_date
  on public.announcements (gym_id, starts_on)
  where kind = 'closure' and is_active = true;

-- Members only ever see announcements for their own gym.
drop policy if exists "announcements_select_published" on public.announcements;
create policy "announcements_select_published"
  on public.announcements for select
  to authenticated
  using (
    is_active = true
    and starts_on <= (now() at time zone 'Asia/Kolkata')::date
    and gym_id = (
      select p.gym_id from public.profiles p where p.id = (select auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- 4. Payments: proof screenshot + no new Razorpay defaults
-- ---------------------------------------------------------------------------
alter table public.payments
  add column if not exists screenshot_path text;

alter table public.payments alter column provider set default 'upi';

comment on column public.payments.screenshot_path is
  'Optional member-uploaded proof in the private payment-proofs bucket. NOT proof of payment.';

-- Dead gateway-only activation function. It referenced the removed 'paid'
-- status and can never run against the current enum.
drop function if exists public.complete_membership_payment(uuid, text, integer, text);

-- ---------------------------------------------------------------------------
-- 5. Private payment-proof storage
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'payment-proofs',
  'payment-proofs',
  false,
  5242880,
  array['image/png', 'image/jpeg', 'image/webp']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "payment_proofs_member_insert" on storage.objects;
drop policy if exists "payment_proofs_member_select" on storage.objects;
drop policy if exists "payment_proofs_admin_select" on storage.objects;
drop policy if exists "payment_proofs_admin_delete" on storage.objects;

create policy "payment_proofs_member_insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "payment_proofs_member_select"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "payment_proofs_admin_select"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (select public.is_admin())
    and exists (
      select 1
        from public.profiles p
       where p.id::text = (storage.foldername(name))[1]
         and p.gym_id = (
           select me.gym_id from public.profiles me where me.id = (select auth.uid())
         )
    )
  );

create policy "payment_proofs_admin_delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (select public.is_admin())
    and exists (
      select 1
        from public.profiles p
       where p.id::text = (storage.foldername(name))[1]
         and p.gym_id = (
           select me.gym_id from public.profiles me where me.id = (select auth.uid())
         )
    )
  );

-- ---------------------------------------------------------------------------
-- 6. Admin payment-method RPCs
-- ---------------------------------------------------------------------------
create or replace function public.admin_get_payment_methods()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_result jsonb;
begin
  select jsonb_agg(
           jsonb_build_object(
             'method', m.method,
             'is_enabled', coalesce(pm.is_enabled, false),
             'upi_id', pm.upi_id,
             'payee_name', pm.payee_name,
             'qr_path', pm.qr_path,
             'updated_at', pm.updated_at
           )
           order by m.ord
         )
    into v_result
    from (values ('google_pay'::text, 1),
                 ('phonepe'::text, 2),
                 ('paytm'::text, 3),
                 ('upi'::text, 4)) as m(method, ord)
    left join public.gym_payment_methods pm
      on pm.gym_id = v_gym_id
     and pm.method = m.method;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

create or replace function public.admin_save_payment_method(
  p_method text,
  p_is_enabled boolean,
  p_upi_id text default null,
  p_payee_name text default null,
  p_qr_path text default null,
  p_clear_qr boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_method text := lower(btrim(coalesce(p_method, '')));
  v_upi text := nullif(lower(btrim(coalesce(p_upi_id, ''))), '');
  v_payee text := nullif(btrim(coalesce(p_payee_name, '')), '');
  v_qr text := nullif(btrim(coalesce(p_qr_path, '')), '');
  v_existing public.gym_payment_methods;
  v_effective_qr text;
begin
  if v_method not in ('google_pay', 'phonepe', 'paytm', 'upi') then
    raise exception 'INVALID_PAYMENT_METHOD' using errcode = '22023';
  end if;

  if v_upi is not null
     and v_upi !~ '^[a-z0-9][a-z0-9._-]{1,60}@[a-z][a-z0-9]{1,40}$' then
    raise exception 'INVALID_UPI_ID' using errcode = '22023';
  end if;

  if v_qr is not null and v_qr not like v_gym_id::text || '/%' then
    raise exception 'QR_PATH_GYM_MISMATCH' using errcode = '22023';
  end if;

  select * into v_existing
    from public.gym_payment_methods
   where gym_id = v_gym_id
     and method = v_method;

  v_effective_qr := case
    when coalesce(p_clear_qr, false) then null
    else coalesce(v_qr, v_existing.qr_path)
  end;

  if coalesce(p_is_enabled, false) and v_upi is null and v_effective_qr is null then
    raise exception 'PAYMENT_METHOD_INCOMPLETE' using errcode = '22023';
  end if;

  insert into public.gym_payment_methods (
    gym_id, method, is_enabled, upi_id, payee_name, qr_path
  )
  values (
    v_gym_id, v_method, coalesce(p_is_enabled, false), v_upi, v_payee, v_effective_qr
  )
  on conflict (gym_id, method) do update
    set is_enabled = excluded.is_enabled,
        upi_id = excluded.upi_id,
        payee_name = excluded.payee_name,
        qr_path = excluded.qr_path,
        updated_at = now();

  -- Keep the legacy single-UPI columns on gyms in step with the General UPI
  -- rail so older member-app builds keep showing the same payee.
  if v_method = 'upi' then
    update public.gyms
       set upi_id = v_upi,
           upi_payee_name = case when v_upi is null then null else coalesce(v_payee, name) end,
           payment_qr_path = v_effective_qr,
           updated_at = now()
     where id = v_gym_id;
  end if;

  return public.admin_get_payment_methods();
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Members see only their own gym's enabled rails
-- ---------------------------------------------------------------------------
create or replace function public.member_payment_methods()
returns table (
  method text,
  upi_id text,
  payee_name text,
  qr_path text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_gym_id uuid;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select p.gym_id into v_gym_id from public.profiles p where p.id = v_user;

  if v_gym_id is null then
    return;
  end if;

  return query
  select pm.method,
         pm.upi_id,
         coalesce(pm.payee_name, g.name),
         pm.qr_path
    from public.gym_payment_methods pm
    join public.gyms g on g.id = pm.gym_id
   where pm.gym_id = v_gym_id
     and pm.is_enabled = true
     and (pm.upi_id is not null or pm.qr_path is not null)
   order by case pm.method
              when 'google_pay' then 1
              when 'phonepe' then 2
              when 'paytm' then 3
              else 4
            end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. UPI submission accepts any enabled rail, not only the legacy column
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
  v_payee text;
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

  if not found or not v_gym.is_active then
    raise exception 'PAYMENT_NOT_CONFIGURED' using errcode = 'P0001';
  end if;

  -- At least one rail must be switched on for this gym.
  select coalesce(pm.upi_id, v_gym.upi_id) into v_payee
    from public.gym_payment_methods pm
   where pm.gym_id = v_gym.id
     and pm.is_enabled = true
     and pm.upi_id is not null
   order by case pm.method when 'upi' then 0 else 1 end
   limit 1;

  if v_payee is null and not exists (
    select 1
      from public.gym_payment_methods pm
     where pm.gym_id = v_gym.id
       and pm.is_enabled = true
       and (pm.upi_id is not null or pm.qr_path is not null)
  ) then
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

  update public.payments
     set provider = 'upi',
         provider_payment_id = v_reference,
         upi_reference = v_reference,
         upi_submitted_at = now(),
         payee_upi_id = v_payee,
         checkout_state = 'submitted',
         reconciliation_required = false,
         reconciliation_reason = null,
         updated_at = now()
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'pending_approval',
    'payment_id', v_payment.id,
    'membership_id', null,
    'starts_on', v_payment.quote ->> 'starts_on',
    'ends_on', v_payment.quote ->> 'ends_on',
    'package_name', coalesce(v_package_name, 'Membership'),
    'total_amount_inr', v_payment.total_amount_inr,
    'provider_payment_id', v_reference
  );
end;
$$;

create or replace function public.submit_payment_screenshot(
  p_payment_id uuid,
  p_path text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_payment public.payments;
  v_path text := nullif(btrim(coalesce(p_path, '')), '');
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if v_path is null or v_path not like v_user::text || '/%' then
    raise exception 'PROOF_PATH_USER_MISMATCH' using errcode = '22023';
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

  update public.payments
     set screenshot_path = v_path,
         updated_at = now()
   where id = v_payment.id;

  return jsonb_build_object('status', 'attached', 'payment_id', v_payment.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Gym-isolation fixes for the admin portal
-- ---------------------------------------------------------------------------

-- 9a. Payment review queue: the previous body returned every gym's queue.
alter function public.admin_list_pending_payments() rename to admin_list_pending_payments_all_gyms;
alter function public.admin_list_refund_payments() rename to admin_list_refund_payments_all_gyms;

create or replace function public.admin_list_pending_payments()
returns table (
  payment_id uuid,
  user_id uuid,
  member_name text,
  member_email text,
  member_phone text,
  package_name text,
  duration_days integer,
  base_amount_inr integer,
  fine_amount_inr integer,
  total_amount_inr integer,
  status public.payment_status,
  provider_order_id text,
  provider_payment_id text,
  failure_reason text,
  quote jsonb,
  created_at timestamptz,
  paid_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  checkout_state text,
  reconciliation_required boolean,
  reconciliation_reason text,
  legacy_status text,
  refund_status text,
  refund_note text,
  refunded_at timestamptz,
  refunded_by uuid,
  screenshot_path text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
$$;

create or replace function public.admin_list_refund_payments()
returns table (
  payment_id uuid,
  user_id uuid,
  member_name text,
  member_email text,
  member_phone text,
  package_name text,
  total_amount_inr integer,
  provider_payment_id text,
  review_note text,
  refund_status text,
  refund_note text,
  reviewed_at timestamptz,
  refunded_at timestamptz,
  refunded_by uuid,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
begin
  return query
  select q.*
    from public.admin_list_refund_payments_all_gyms() q
    join public.payments p on p.id = q.payment_id
   where p.gym_id = v_gym_id
   order by q.created_at asc;
end;
$$;

-- 9b. Approve / decline: refuse a payment that belongs to another gym.
alter function public.admin_review_payment(uuid, text, text) rename to admin_review_payment_unscoped;

create or replace function public.admin_review_payment(
  p_payment_id uuid,
  p_decision text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_payment_gym uuid;
begin
  if p_payment_id is null then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  select p.gym_id into v_payment_gym
    from public.payments p
   where p.id = p_payment_id;

  -- Same error as "missing" so another gym's ids are not enumerable.
  if v_payment_gym is null or v_payment_gym <> v_gym_id then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  return public.admin_review_payment_unscoped(p_payment_id, p_decision, p_note);
end;
$$;

-- 9c. Members list: only memberships from this admin's gym.
create or replace function public.admin_list_members(
  p_search text default null,
  p_status text default null
)
returns table (
  user_id uuid,
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
      pr.created_at as joined_at,
      coalesce(m.package_name, pend_pkg.name) as plan_name,
      m.status as membership_status,
      m.starts_on,
      m.ends_on,
      case
        when pend.id is not null then 'Pending'
        when m.status = 'active' and m.ends_on >= v_today then 'Paid'
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
        case when mem.status = 'active' and mem.ends_on >= v_today then 0 else 1 end,
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

-- 9d. Closure calendar is per gym.
create or replace function public.admin_list_closures(
  p_from date default null,
  p_to date default null
)
returns table (
  closure_date date,
  reason text,
  announcement_id uuid
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_from date := coalesce(p_from, v_today);
  v_to date := coalesce(p_to, coalesce(p_from, v_today) + 120);
begin
  return query
  select a.starts_on,
         coalesce(nullif(btrim(a.body), ''), a.title),
         a.id
    from public.announcements a
   where a.gym_id = v_gym_id
     and a.kind = 'closure'
     and a.is_active = true
     and a.starts_on between v_from and v_to
   order by a.starts_on;
end;
$$;

create or replace function public.admin_set_closure(
  p_date date,
  p_closed boolean,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_id uuid;
begin
  if p_date is null then
    raise exception 'DATE_REQUIRED' using errcode = '22023';
  end if;

  if p_date < v_today then
    raise exception 'PAST_DATE_NOT_EDITABLE' using errcode = '22023';
  end if;

  if not p_closed then
    update public.announcements
       set is_active = false,
           updated_at = now()
     where gym_id = v_gym_id
       and kind = 'closure'
       and starts_on = p_date
       and is_active = true;

    return jsonb_build_object(
      'date', p_date,
      'is_closed', false,
      'reason', null
    );
  end if;

  select a.id into v_id
    from public.announcements a
   where a.gym_id = v_gym_id
     and a.kind = 'closure'
     and a.starts_on = p_date
     and a.is_active = true
   order by a.created_at desc
   limit 1;

  if v_id is null then
    insert into public.announcements (title, body, kind, starts_on, ends_on, is_active, gym_id)
    values (
      'Gym closed',
      coalesce(v_reason, 'Closed by the gym team.'),
      'closure',
      p_date,
      p_date,
      true,
      v_gym_id
    );
  else
    update public.announcements
       set body = coalesce(v_reason, 'Closed by the gym team.'),
           ends_on = p_date,
           updated_at = now()
     where id = v_id;
  end if;

  return jsonb_build_object(
    'date', p_date,
    'is_closed', true,
    'reason', coalesce(v_reason, 'Closed by the gym team.')
  );
end;
$$;

-- 9e. QR check-in: a QR code only works for members of its own gym, and
-- closures are read from that gym only.
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

  select * into v_membership
    from public.memberships
   where user_id = v_user
     and gym_id = v_profile.gym_id
     and status = 'active'
     and starts_on <= v_today
     and ends_on >= v_today
   order by ends_on desc
   limit 1;

  if not found then
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

-- ---------------------------------------------------------------------------
-- 10. Self-service gym owner onboarding
-- ---------------------------------------------------------------------------
create or replace function public.register_gym_owner(
  p_gym_name text,
  p_full_name text,
  p_phone text default null,
  p_slug text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_profile public.profiles;
  v_gym_name text := nullif(btrim(coalesce(p_gym_name, '')), '');
  v_full_name text := nullif(btrim(coalesce(p_full_name, '')), '');
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_base text;
  v_slug text;
  v_counter integer := 1;
  v_gym_id uuid;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_profile from public.profiles where id = v_user;
  if not found then
    raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_profile.is_admin then
    raise exception 'ALREADY_AN_ADMIN' using errcode = '42501';
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

  insert into public.gyms (slug, name)
  values (v_slug, v_gym_name)
  returning id into v_gym_id;

  insert into public.gym_payment_methods (gym_id, method)
  select v_gym_id, m.method
    from (values ('google_pay'), ('phonepe'), ('paytm'), ('upi')) as m(method)
  on conflict (gym_id, method) do nothing;

  update public.profiles
     set is_admin = true,
         gym_id = v_gym_id,
         full_name = coalesce(v_full_name, full_name),
         phone = coalesce(v_phone, phone),
         updated_at = now()
   where id = v_user;

  return jsonb_build_object(
    'gym_id', v_gym_id,
    'slug', v_slug,
    'name', v_gym_name,
    'is_admin', true
  );
end;
$$;

create or replace function public.admin_update_gym_name(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if v_name is null or length(v_name) < 2 then
    raise exception 'GYM_NAME_REQUIRED' using errcode = '22023';
  end if;

  if length(v_name) > 80 then
    raise exception 'GYM_NAME_TOO_LONG' using errcode = '22023';
  end if;

  update public.gyms
     set name = v_name,
         updated_at = now()
   where id = v_gym_id;

  return public.admin_get_gym_settings();
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.admin_get_payment_methods() from public, anon, authenticated;
revoke all on function public.admin_save_payment_method(text, boolean, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.admin_update_gym_name(text) from public, anon, authenticated;
revoke all on function public.register_gym_owner(text, text, text, text) from public, anon, authenticated;
revoke all on function public.member_payment_methods() from public, anon, authenticated;
revoke all on function public.submit_payment_screenshot(uuid, text) from public, anon, authenticated;
revoke all on function public.submit_upi_payment_reference(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_list_pending_payments() from public, anon, authenticated;
revoke all on function public.admin_list_refund_payments() from public, anon, authenticated;
revoke all on function public.admin_review_payment(uuid, text, text) from public, anon, authenticated;
revoke all on function public.admin_list_members(text, text) from public, anon, authenticated;
revoke all on function public.admin_list_closures(date, date) from public, anon, authenticated;
revoke all on function public.admin_set_closure(date, boolean, text) from public, anon, authenticated;
revoke all on function public.check_in_with_qr(text) from public, anon, authenticated;
revoke all on function public.normalize_gym_payment_method() from public, anon, authenticated;
revoke all on function public.fill_membership_gym() from public, anon, authenticated;
revoke all on function public.admin_list_pending_payments_all_gyms() from public, anon, authenticated;
revoke all on function public.admin_list_refund_payments_all_gyms() from public, anon, authenticated;
revoke all on function public.admin_review_payment_unscoped(uuid, text, text) from public, anon, authenticated;

grant execute on function public.admin_get_payment_methods() to authenticated;
grant execute on function public.admin_save_payment_method(text, boolean, text, text, text, boolean) to authenticated;
grant execute on function public.admin_update_gym_name(text) to authenticated;
grant execute on function public.register_gym_owner(text, text, text, text) to authenticated;
grant execute on function public.member_payment_methods() to authenticated;
grant execute on function public.submit_payment_screenshot(uuid, text) to authenticated;
grant execute on function public.submit_upi_payment_reference(uuid, text) to authenticated;
grant execute on function public.admin_list_pending_payments() to authenticated;
grant execute on function public.admin_list_refund_payments() to authenticated;
grant execute on function public.admin_review_payment(uuid, text, text) to authenticated;
grant execute on function public.admin_list_members(text, text) to authenticated;
grant execute on function public.admin_list_closures(date, date) to authenticated;
grant execute on function public.admin_set_closure(date, boolean, text) to authenticated;
grant execute on function public.check_in_with_qr(text) to authenticated;
