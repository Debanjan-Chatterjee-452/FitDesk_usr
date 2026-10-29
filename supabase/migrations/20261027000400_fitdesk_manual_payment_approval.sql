-- FitDesk — manual payment approval workflow
--
-- Every purchase/renewal is submitted by the member and then reviewed by an
-- Admin-role user. A payment only activates a membership after approval.
-- Members can never change a payment to 'approved' or 'declined'.

-- ---------------------------------------------------------------------------
-- Admin role
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists is_admin boolean not null default false;

comment on column public.profiles.is_admin is
  'Admin role flag. Only service-role/SQL tooling can set it; members have no '
  'column grant for it. Admin-role users may review pending payments.';

-- Security-definer helper so RLS policies and triggers can read the flag
-- without exposing other members' profile rows.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth, pg_temp
as $$
  select coalesce(
    (select p.is_admin from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

comment on function public.is_admin() is
  'True when the signed-in user has the Admin role. Never trusts client input.';

-- ---------------------------------------------------------------------------
-- Payment status: pending -> approved | declined
--
-- The old enum mixed gateway state with settlement state. Replace it with the
-- three review states the app now uses. Historical rows are mapped so existing
-- receipts stay readable.
-- ---------------------------------------------------------------------------
drop function if exists public.complete_membership_payment(uuid, text, integer, text);

-- Preserve the old status before the enum is rewritten. The old enum mixed
-- gateway state with settlement state, and failed/refunded/cancelled must stay
-- distinguishable for accounting even though the review workflow only uses
-- pending/approved/declined.
alter table public.payments
  add column if not exists legacy_status text,
  add column if not exists reconciliation_required boolean not null default false,
  add column if not exists reconciliation_reason text;

update public.payments
   set legacy_status = status::text
 where status::text in ('failed', 'refunded', 'cancelled');

alter table public.payments alter column status drop default;
alter type public.payment_status rename to payment_status_legacy;
create type public.payment_status as enum ('pending', 'approved', 'declined');

alter table public.payments
  alter column status type public.payment_status
  using (
    case status::text
      when 'paid' then 'approved'
      when 'created' then 'pending'
      when 'pending' then 'pending'
      else 'declined'
    end
  )::public.payment_status;

alter table public.payments alter column status set default 'pending';
drop type public.payment_status_legacy;

-- Review audit columns.
alter table public.payments
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users (id) on delete set null,
  add column if not exists review_note text;

comment on column public.payments.status is
  'Manual review state: pending until an Admin-role user approves or declines. '
  'Only the admin_review_payment() function may change it.';
comment on column public.payments.paid_at is
  'When the gateway captured the payment. It does not grant membership access.';
comment on column public.payments.reviewed_at is
  'When an Admin-role user approved or declined this payment.';

update public.payments
   set reviewed_at = coalesce(paid_at, updated_at)
 where status = 'approved'
   and reviewed_at is null;

-- Only one submitted payment may wait for review per member. Older duplicate
-- pending rows are preserved for manual reconciliation instead of being
-- auto-declined: they may already have been captured by the gateway.
with ranked as (
  select id,
         row_number() over (partition by user_id order by created_at desc) as rn
    from public.payments
   where status = 'pending'
     and provider_payment_id is not null
)
update public.payments p
   set reconciliation_required = true,
       reconciliation_reason = coalesce(
         p.reconciliation_reason,
         'Duplicate pending payment preserved for manual reconciliation. Verify with Razorpay before approving, declining, or refunding.'
       ),
       updated_at = now()
  from ranked r
 where r.id = p.id
   and r.rn > 1;

create unique index if not exists payments_one_pending_review_per_user
  on public.payments (user_id)
  where status = 'pending'
    and provider_payment_id is not null
    and reconciliation_required = false;

create index if not exists payments_pending_queue_idx
  on public.payments (created_at)
  where status = 'pending' and provider_payment_id is not null;

-- ---------------------------------------------------------------------------
-- Guard direct status writes
--
-- RLS already restricts updates to Admin-role users. This trigger additionally
-- requires the review RPC context so an admin cannot set 'approved' directly
-- and bypass membership activation. Trusted server/SQL connections (no JWT)
-- are allowed for documented manual reconciliation.
-- ---------------------------------------------------------------------------
create or replace function public.guard_payment_review()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status is distinct from old.status then
    if auth.uid() is null then
      return new;
    end if;

    if not public.is_admin() then
      raise exception 'ADMIN_REQUIRED' using errcode = '42501';
    end if;

    if coalesce(current_setting('fitdesk.payment_review', true), '') <> 'on' then
      raise exception 'REVIEW_VIA_RPC_ONLY' using errcode = '42501';
    end if;

    if old.status <> 'pending' then
      raise exception 'PAYMENT_ALREADY_REVIEWED' using errcode = 'P0001';
    end if;

    if new.status not in ('approved', 'declined') then
      raise exception 'INVALID_REVIEW_DECISION' using errcode = 'P0001';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists payments_guard_review on public.payments;
create trigger payments_guard_review
  before update on public.payments
  for each row
  execute function public.guard_payment_review();

-- ---------------------------------------------------------------------------
-- RLS: Admin-role read/update only. Members keep select-own.
-- ---------------------------------------------------------------------------
create policy "payments_select_admin"
  on public.payments for select
  to authenticated
  using ((select public.is_admin()));

create policy "payments_update_admin"
  on public.payments for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

grant update (status, reviewed_at, reviewed_by, review_note, failure_reason)
  on public.payments to authenticated;

-- ---------------------------------------------------------------------------
-- Submit a verified gateway payment for manual review (service-role only)
--
-- Replaces the old instant-activation function. It validates the amount and
-- stored quote, records the provider ids, and leaves the payment pending.
-- ---------------------------------------------------------------------------
create or replace function public.submit_membership_payment(
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

  select name into v_package_name
    from public.packages
   where id = v_payment.package_id;

  if v_payment.status = 'approved' then
    if v_payment.membership_id is null then
      raise exception 'PAYMENT_INCONSISTENT' using errcode = 'P0001';
    end if;

    select * into v_membership
      from public.memberships
     where id = v_payment.membership_id;

    return jsonb_build_object(
      'status', 'already_approved',
      'payment_id', v_payment.id,
      'membership_id', v_membership.id,
      'starts_on', v_membership.starts_on,
      'ends_on', v_membership.ends_on,
      'package_name', coalesce(v_package_name, 'Membership'),
      'total_amount_inr', v_payment.total_amount_inr
    );
  end if;

  if v_payment.status = 'declined' then
    raise exception 'PAYMENT_DECLINED' using errcode = 'P0001';
  end if;

  if v_payment.provider_payment_id is not null then
    -- Idempotent retry after the member already submitted this payment.
    if p_provider_payment_id is distinct from v_payment.provider_payment_id then
      raise exception 'PAYMENT_ORDER_MISMATCH' using errcode = 'P0001';
    end if;

    v_quote := v_payment.quote;
    return jsonb_build_object(
      'status', 'already_pending',
      'payment_id', v_payment.id,
      'membership_id', null,
      'starts_on', v_quote ->> 'starts_on',
      'ends_on', v_quote ->> 'ends_on',
      'package_name', coalesce(v_package_name, 'Membership'),
      'total_amount_inr', v_payment.total_amount_inr
    );
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

  update public.payments
     set provider_payment_id = btrim(p_provider_payment_id),
         paid_at = v_now,
         failure_reason = null,
         updated_at = v_now
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'pending_approval',
    'payment_id', v_payment.id,
    'membership_id', null,
    'starts_on', v_starts,
    'ends_on', v_ends,
    'package_name', coalesce(v_package_name, 'Membership'),
    'total_amount_inr', v_payment.total_amount_inr
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin queue (authenticated, Admin-role only)
-- ---------------------------------------------------------------------------
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
  reviewed_by uuid
)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
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
    p.reviewed_by
  from public.payments p
  left join public.profiles pr on pr.id = p.user_id
  left join auth.users u on u.id = p.user_id
  left join public.packages pk on pk.id = p.package_id
  where p.status = 'pending'
    and p.provider_payment_id is not null
  order by coalesce(p.paid_at, p.created_at) asc;
end;
$$;

-- ---------------------------------------------------------------------------
-- Approve / decline (authenticated, Admin-role only, irreversible)
-- ---------------------------------------------------------------------------
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
  v_payment public.payments;
  v_membership public.memberships;
  v_quote jsonb;
  v_package_name text;
  v_starts date;
  v_ends date;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public.is_admin() then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;

  if p_decision not in ('approved', 'declined') then
    raise exception 'INVALID_REVIEW_DECISION' using errcode = 'P0001';
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

  if v_payment.provider_payment_id is null then
    raise exception 'PAYMENT_NOT_SUBMITTED' using errcode = 'P0001';
  end if;

  select name into v_package_name
    from public.packages
   where id = v_payment.package_id;

  -- Let the guard trigger know this is the trusted review path.
  perform set_config('fitdesk.payment_review', 'on', true);

  if p_decision = 'declined' then
    update public.payments
       set status = 'declined',
           failure_reason = coalesce(v_note, 'Payment declined by the gym.'),
           review_note = v_note,
           reviewed_at = v_now,
           reviewed_by = auth.uid(),
           updated_at = v_now
     where id = v_payment.id;

    return jsonb_build_object(
      'status', 'declined',
      'payment_id', v_payment.id,
      'membership_id', null,
      'starts_on', v_payment.quote ->> 'starts_on',
      'ends_on', v_payment.quote ->> 'ends_on',
      'package_name', coalesce(v_package_name, 'Membership'),
      'total_amount_inr', v_payment.total_amount_inr
    );
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
     set status = 'approved',
         membership_id = v_membership.id,
         failure_reason = null,
         review_note = v_note,
         reviewed_at = v_now,
         reviewed_by = auth.uid(),
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
revoke all on function public.is_admin() from public, anon, authenticated;
revoke all on function public.guard_payment_review() from public, anon, authenticated;
revoke all on function public.submit_membership_payment(uuid, text, integer, text) from public, anon, authenticated;
revoke all on function public.admin_list_pending_payments() from public, anon, authenticated;
revoke all on function public.admin_review_payment(uuid, text, text) from public, anon, authenticated;

grant execute on function public.is_admin() to authenticated;
grant execute on function public.admin_list_pending_payments() to authenticated;
grant execute on function public.admin_review_payment(uuid, text, text) to authenticated;

grant execute on function public.submit_membership_payment(uuid, text, integer, text) to service_role;
