-- FitDesk — payment safety, checkout coordination, reconciliation, refunds
--
-- Additive follow-up to 20261027000400 and 20261028000100.
--
-- Goals:
--   * never hide or delete a payment that may have been captured;
--   * serialize checkout creation per member;
--   * preserve legacy payment history instead of silently collapsing it;
--   * keep review audit fields writable only through authorized RPCs;
--   * track manual refunds without claiming a refund happened automatically.

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.payments
  add column if not exists checkout_state text not null default 'open',
  add column if not exists reconciliation_required boolean not null default false,
  add column if not exists reconciliation_reason text,
  add column if not exists legacy_status text,
  add column if not exists refund_status text not null default 'not_required',
  add column if not exists refund_note text,
  add column if not exists refunded_at timestamptz,
  add column if not exists refunded_by uuid references auth.users (id) on delete set null;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'payments_checkout_state_valid'
       and conrelid = 'public.payments'::regclass
  ) then
    alter table public.payments
      add constraint payments_checkout_state_valid
      check (checkout_state in ('open', 'verifying', 'submitted', 'reconciliation_required', 'abandoned'));
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'payments_refund_status_valid'
       and conrelid = 'public.payments'::regclass
  ) then
    alter table public.payments
      add constraint payments_refund_status_valid
      check (refund_status in ('not_required', 'pending_manual_refund', 'refunded'));
  end if;
end $$;

comment on column public.payments.checkout_state is
  'Checkout lifecycle: open -> verifying -> submitted, or reconciliation_required / abandoned.';
comment on column public.payments.reconciliation_required is
  'True when a payment may have been captured but cannot be safely approved or declined without manual Razorpay reconciliation.';
comment on column public.payments.legacy_status is
  'Original status from the pre-approval enum. Preserves failed/refunded/cancelled history.';
comment on column public.payments.refund_status is
  'Manual refund tracking. FitDesk never calls a live refund API.';

-- ---------------------------------------------------------------------------
-- Backfill existing rows without changing payment status
-- ---------------------------------------------------------------------------
update public.payments
   set checkout_state = case
     when status = 'approved' then 'submitted'
     when status = 'declined' then 'abandoned'
     when status = 'pending' and reconciliation_required then 'reconciliation_required'
     when status = 'pending' and provider_payment_id is not null then 'submitted'
     else 'open'
   end;

-- Legacy refunded rows were already refunded outside FitDesk. Captured
-- declined rows created before refund tracking need a manual refund. No row is
-- marked refunded unless the legacy status says it was refunded.
update public.payments
   set refund_status = case
     when legacy_status = 'refunded' then 'refunded'
     when status = 'declined'
       and provider_payment_id is not null
       and refund_status = 'not_required' then 'pending_manual_refund'
     else refund_status
   end,
   refund_note = case
     when legacy_status = 'refunded' and refund_note is null
       then 'Imported legacy refunded status.'
     when status = 'declined'
       and provider_payment_id is not null
       and refund_status = 'not_required'
       and refund_note is null
       then 'Captured payment declined before refund tracking existed. Manual refund required.'
     else refund_note
   end,
   refunded_at = case
     when legacy_status = 'refunded' and refunded_at is null
       then coalesce(reviewed_at, updated_at)
     else refunded_at
   end;

-- Preserve duplicate pending rows for reconciliation. Never auto-decline them:
-- an older row may already have been captured.
with ranked as (
  select id,
         row_number() over (partition by user_id order by created_at desc, id desc) as rn
    from public.payments
   where status = 'pending'
)
update public.payments p
   set reconciliation_required = true,
       reconciliation_reason = coalesce(
         p.reconciliation_reason,
         'Multiple pending payments existed before the payment-safety migration. Verify this payment in Razorpay before approving, declining, or refunding.'
       ),
       checkout_state = 'reconciliation_required'
  from ranked r
 where r.id = p.id
   and r.rn > 1;

update public.payments
   set checkout_state = case
     when provider_payment_id is not null then 'submitted'
     else 'open'
   end
 where status = 'pending'
   and reconciliation_required = false
   and checkout_state not in ('open', 'verifying', 'submitted');

-- Replace the narrower submitted-only index with one active checkout per
-- member. Reconciliation rows are excluded so historical duplicates can be
-- preserved and handled manually.
drop index if exists public.payments_one_pending_review_per_user;
create unique index if not exists payments_one_active_checkout_per_user
  on public.payments (user_id)
  where status = 'pending'
    and checkout_state in ('open', 'verifying', 'submitted');

create index if not exists payments_reconciliation_queue_idx
  on public.payments (created_at)
  where reconciliation_required = true;

create index if not exists payments_refund_queue_idx
  on public.payments (created_at)
  where refund_status = 'pending_manual_refund';

-- ---------------------------------------------------------------------------
-- Guard direct writes to review and refund audit fields
-- ---------------------------------------------------------------------------
create or replace function public.guard_payment_review()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
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
-- Submit a verified gateway payment for manual review (service-role only)
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
   where id = p_payment_id;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_payment.user_id::text, 0));

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
         checkout_state = 'submitted',
         reconciliation_required = false,
         reconciliation_reason = null,
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
-- Checkout coordination (authenticated member)
-- ---------------------------------------------------------------------------
create or replace function public.reserve_renewal_checkout(
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
  v_existing public.payments;
  v_payment public.payments;
  v_quote jsonb;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
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

    -- A submitted payment must be reviewed before a new checkout starts. A
    -- 'verifying' row has no provider payment id yet and is safe to resume:
    -- the caller inspects the gateway order before reusing or abandoning it.
    if v_existing.checkout_state = 'submitted' then
      return jsonb_build_object(
        'status', 'already_pending',
        'payment_id', v_existing.id
      );
    end if;

    return jsonb_build_object(
      'status', 'resume_checkout',
      'payment_id', v_existing.id,
      'order_id', v_existing.provider_order_id,
      'quote', v_existing.quote,
      'package_name', v_existing.quote ->> 'package_name',
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
    reconciliation_required
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
    'razorpay',
    null,
    null,
    null,
    v_quote,
    'open',
    false
  )
  returning * into v_payment;

  return jsonb_build_object(
    'status', 'reserved',
    'payment_id', v_payment.id,
    'quote', v_quote,
    'package_name', v_quote ->> 'package_name',
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
        'order_id', v_existing.provider_order_id,
        'quote', v_existing.quote,
        'package_name', v_existing.quote ->> 'package_name',
        'created_at', v_existing.created_at
      );
    end if;

    raise;
end;
$$;

create or replace function public.attach_checkout_order(
  p_payment_id uuid,
  p_provider_order_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
begin
  select * into v_payment
    from public.payments
   where id = p_payment_id
   for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status <> 'pending' or v_payment.checkout_state <> 'open' then
    raise exception 'CHECKOUT_NOT_OPEN' using errcode = 'P0001';
  end if;

  if v_payment.provider_order_id is not null
     and v_payment.provider_order_id <> p_provider_order_id then
    raise exception 'PAYMENT_ORDER_MISMATCH' using errcode = 'P0001';
  end if;

  update public.payments
     set provider_order_id = btrim(p_provider_order_id),
         updated_at = now()
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'attached',
    'payment_id', v_payment.id,
    'order_id', btrim(p_provider_order_id)
  );
end;
$$;

create or replace function public.abandon_checkout(
  p_payment_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into v_payment
    from public.payments
   where id = p_payment_id
   for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status <> 'pending' then
    raise exception 'PAYMENT_NOT_PAYABLE' using errcode = 'P0001';
  end if;

  if v_payment.provider_payment_id is not null then
    raise exception 'PAYMENT_MAY_BE_CAPTURED' using errcode = 'P0001';
  end if;

  update public.payments
     set checkout_state = 'abandoned',
         reconciliation_required = false,
         reconciliation_reason = null,
         failure_reason = coalesce(v_reason, failure_reason),
         updated_at = now()
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'abandoned',
    'payment_id', v_payment.id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Verification / capture reconciliation (service-role only)
-- ---------------------------------------------------------------------------
create or replace function public.begin_payment_verification(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
begin
  select * into v_payment
    from public.payments
   where id = p_payment_id
   for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status <> 'pending' then
    return jsonb_build_object(
      'status', 'not_pending',
      'payment_id', v_payment.id,
      'payment_status', v_payment.status
    );
  end if;

  if v_payment.provider_payment_id is not null then
    return jsonb_build_object(
      'status', 'already_submitted',
      'payment_id', v_payment.id,
      'provider_payment_id', v_payment.provider_payment_id
    );
  end if;

  if v_payment.checkout_state = 'reconciliation_required'
     or v_payment.reconciliation_required then
    return jsonb_build_object(
      'status', 'reconciliation_required',
      'payment_id', v_payment.id,
      'reconciliation_reason', v_payment.reconciliation_reason
    );
  end if;

  if v_payment.checkout_state = 'abandoned' then
    raise exception 'PAYMENT_NOT_VERIFIABLE' using errcode = 'P0001';
  end if;

  update public.payments
     set checkout_state = 'verifying',
         updated_at = now()
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'verifying',
    'payment_id', v_payment.id
  );
end;
$$;

create or replace function public.record_captured_payment(
  p_payment_id uuid,
  p_provider_payment_id text,
  p_provider_order_id text,
  p_paid_amount_inr integer,
  p_failure_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
  v_reason text;
begin
  if p_provider_payment_id is null or length(btrim(p_provider_payment_id)) = 0 then
    raise exception 'PAYMENT_FAILED' using errcode = 'P0001';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_payment.user_id::text, 0));

  select * into v_payment
    from public.payments
   where id = p_payment_id
   for update;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status = 'approved' then
    return jsonb_build_object(
      'status', 'already_approved',
      'payment_id', v_payment.id
    );
  end if;

  if v_payment.status = 'declined' then
    return jsonb_build_object(
      'status', 'declined',
      'payment_id', v_payment.id
    );
  end if;

  v_reason := concat_ws(
    ' ',
    nullif(btrim(coalesce(p_failure_reason, '')), ''),
    'Razorpay payment: ' || btrim(p_provider_payment_id) || '.',
    case
      when nullif(btrim(coalesce(p_provider_order_id, '')), '') is not null
        then 'Order: ' || btrim(p_provider_order_id) || '.'
      else null
    end,
    case
      when v_payment.provider_order_id is not null
       and nullif(btrim(coalesce(p_provider_order_id, '')), '') is not null
       and v_payment.provider_order_id <> btrim(p_provider_order_id)
        then 'Stored order ' || v_payment.provider_order_id
          || ' does not match the gateway order ' || btrim(p_provider_order_id) || '.'
      else null
    end,
    'Capture may have succeeded; manual reconciliation is required.'
  );

  begin
    update public.payments
       set provider_payment_id = coalesce(v_payment.provider_payment_id, btrim(p_provider_payment_id)),
           provider_order_id = coalesce(
             v_payment.provider_order_id,
             nullif(btrim(coalesce(p_provider_order_id, '')), '')
           ),
           paid_at = coalesce(v_payment.paid_at, now()),
           failure_reason = v_reason,
           reconciliation_required = true,
           reconciliation_reason = v_reason,
           checkout_state = 'reconciliation_required',
           updated_at = now()
     where id = v_payment.id;
  exception
    when unique_violation then
      -- Another payment already owns this provider payment id. Preserve the id
      -- in the reconciliation reason instead of losing it.
      update public.payments
         set provider_order_id = coalesce(
               v_payment.provider_order_id,
               nullif(btrim(coalesce(p_provider_order_id, '')), '')
             ),
             paid_at = coalesce(v_payment.paid_at, now()),
             failure_reason = v_reason,
             reconciliation_required = true,
             reconciliation_reason = v_reason,
             checkout_state = 'reconciliation_required',
             updated_at = now()
       where id = v_payment.id;
  end;

  return jsonb_build_object(
    'status', 'reconciliation_required',
    'payment_id', v_payment.id,
    'provider_payment_id', coalesce(v_payment.provider_payment_id, btrim(p_provider_payment_id)),
    'provider_order_id', coalesce(
      v_payment.provider_order_id,
      nullif(btrim(coalesce(p_provider_order_id, '')), '')
    ),
    'reconciliation_reason', v_reason,
    'total_amount_inr', v_payment.total_amount_inr
  );
end;
$$;

-- Flags a checkout whose gateway order is paid/unknown but for which no
-- provider payment id is available yet. The order id and reason are preserved;
-- nothing is deleted and the payment is not auto-declined.
create or replace function public.flag_checkout_reconciliation(
  p_payment_id uuid,
  p_provider_order_id text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
  v_reason text;
begin
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

  v_reason := concat_ws(
    ' ',
    nullif(btrim(coalesce(p_reason, '')), ''),
    case
      when nullif(btrim(coalesce(p_provider_order_id, '')), '') is not null
        then 'Razorpay order: ' || btrim(p_provider_order_id) || '.'
      else null
    end,
    'Manual reconciliation is required before this checkout can be approved, declined, or restarted.'
  );

  update public.payments
     set provider_order_id = coalesce(
           v_payment.provider_order_id,
           nullif(btrim(coalesce(p_provider_order_id, '')), '')
         ),
         failure_reason = coalesce(v_payment.failure_reason, v_reason),
         reconciliation_required = true,
         reconciliation_reason = v_reason,
         checkout_state = 'reconciliation_required',
         updated_at = now()
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'reconciliation_required',
    'payment_id', v_payment.id,
    'provider_order_id', coalesce(
      v_payment.provider_order_id,
      nullif(btrim(coalesce(p_provider_order_id, '')), '')
    ),
    'reconciliation_reason', v_reason,
    'total_amount_inr', v_payment.total_amount_inr
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin queue: pending approvals plus reconciliation rows
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_pending_payments();

create function public.admin_list_pending_payments()
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
  refunded_by uuid
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
    p.reviewed_by,
    p.checkout_state,
    p.reconciliation_required,
    p.reconciliation_reason,
    p.legacy_status,
    p.refund_status,
    p.refund_note,
    p.refunded_at,
    p.refunded_by
  from public.payments p
  left join public.profiles pr on pr.id = p.user_id
  left join auth.users u on u.id = p.user_id
  left join public.packages pk on pk.id = p.package_id
  where p.status = 'pending'
    and (p.provider_payment_id is not null or p.reconciliation_required)
  order by p.reconciliation_required desc, coalesce(p.paid_at, p.created_at) asc;
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
    p.total_amount_inr,
    p.provider_payment_id,
    p.review_note,
    p.refund_status,
    p.refund_note,
    p.reviewed_at,
    p.refunded_at,
    p.refunded_by,
    p.created_at
  from public.payments p
  left join public.profiles pr on pr.id = p.user_id
  left join auth.users u on u.id = p.user_id
  left join public.packages pk on pk.id = p.package_id
  where p.status = 'declined'
    and p.refund_status = 'pending_manual_refund'
  order by p.created_at asc;
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
  v_latest public.memberships;
  v_membership public.memberships;
  v_quote jsonb;
  v_package_name text;
  v_starts date;
  v_ends date;
  v_is_stacked boolean := false;
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

  if p_payment_id is null then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  select * into v_payment
    from public.payments
   where id = p_payment_id;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_payment.user_id::text, 0));

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

  if v_payment.membership_id is not null then
    raise exception 'PAYMENT_INCONSISTENT' using errcode = 'P0001';
  end if;

  if v_payment.user_id = auth.uid() then
    raise exception 'SELF_REVIEW_FORBIDDEN' using errcode = '42501';
  end if;

  if v_payment.reconciliation_required and v_note is null then
    raise exception 'RECONCILIATION_NOTE_REQUIRED' using errcode = 'P0001';
  end if;

  if p_decision = 'approved' and v_payment.provider_payment_id is null then
    raise exception 'PAYMENT_NOT_SUBMITTED' using errcode = 'P0001';
  end if;

  select name into v_package_name
    from public.packages
   where id = v_payment.package_id;

  perform set_config('fitdesk.payment_write', 'on', true);

  if p_decision = 'declined' then
    update public.payments
       set status = 'declined',
           failure_reason = coalesce(v_note, 'Payment declined by the gym.'),
           review_note = v_note,
           reviewed_at = v_now,
           reviewed_by = auth.uid(),
           checkout_state = 'abandoned',
           reconciliation_required = false,
           reconciliation_reason = null,
           refund_status = case
             when v_payment.provider_payment_id is not null then 'pending_manual_refund'
             else 'not_required'
           end,
           refund_note = case
             when v_payment.provider_payment_id is not null
               then coalesce(v_note, 'Captured payment declined. Manual refund required.')
             else null
           end,
           updated_at = v_now
     where id = v_payment.id;

    return jsonb_build_object(
      'status', 'declined',
      'payment_id', v_payment.id,
      'membership_id', null,
      'starts_on', v_payment.quote ->> 'starts_on',
      'ends_on', v_payment.quote ->> 'ends_on',
      'package_name', coalesce(v_package_name, 'Membership'),
      'total_amount_inr', v_payment.total_amount_inr,
      'refund_status', case
        when v_payment.provider_payment_id is not null then 'pending_manual_refund'
        else 'not_required'
      end
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

  if v_payment.duration_days is null or v_payment.duration_days < 1 then
    raise exception 'PAYMENT_QUOTE_MISMATCH' using errcode = 'P0001';
  end if;

  update public.memberships
     set status = 'expired',
         updated_at = v_now
   where user_id = v_payment.user_id
     and status = 'active'
     and ends_on < v_today;

  select * into v_latest
    from public.memberships
   where user_id = v_payment.user_id
     and status <> 'cancelled'
   order by ends_on desc, starts_on desc
   limit 1;

  if v_latest.id is not null and v_latest.ends_on >= v_today then
    v_is_stacked := true;
    v_starts := v_latest.ends_on + 1;
  else
    v_starts := v_today;
  end if;

  v_ends := v_starts + (v_payment.duration_days - 1);

  if v_starts is null or v_ends is null or v_ends < v_starts then
    raise exception 'PAYMENT_QUOTE_MISMATCH' using errcode = 'P0001';
  end if;

  if exists (
    select 1
      from public.memberships m
     where m.user_id = v_payment.user_id
       and m.status <> 'cancelled'
       and daterange(m.starts_on, m.ends_on, '[]')
           && daterange(v_starts, v_ends, '[]')
  ) then
    raise exception 'MEMBERSHIP_PERIOD_OVERLAP' using errcode = 'P0001';
  end if;

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
         quote = v_quote || jsonb_build_object(
           'starts_on', v_starts,
           'ends_on', v_ends,
           'is_stacked', v_is_stacked,
           'current_ends_on', v_latest.ends_on
         ),
         failure_reason = null,
         review_note = v_note,
         reviewed_at = v_now,
         reviewed_by = auth.uid(),
         checkout_state = 'submitted',
         reconciliation_required = false,
         reconciliation_reason = null,
         refund_status = 'not_required',
         refund_note = null,
         refunded_at = null,
         refunded_by = null,
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

comment on function public.admin_review_payment(uuid, text, text) is
  'Approves or declines a submitted payment. Self-review is forbidden. '
  'Reconciliation rows require a note. Approval preserves a still-valid '
  'membership and queues the purchased plan after its expiry.';

-- ---------------------------------------------------------------------------
-- Manual refund tracking (admin only; no live refund API is called)
-- ---------------------------------------------------------------------------
create or replace function public.admin_mark_payment_refunded(
  p_payment_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
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

  if v_payment.status <> 'declined' then
    raise exception 'PAYMENT_NOT_DECLINED' using errcode = 'P0001';
  end if;

  if v_payment.provider_payment_id is null then
    raise exception 'PAYMENT_NOT_CAPTURED' using errcode = 'P0001';
  end if;

  if v_payment.refund_status <> 'pending_manual_refund' then
    raise exception 'REFUND_NOT_PENDING' using errcode = 'P0001';
  end if;

  perform set_config('fitdesk.payment_write', 'on', true);

  update public.payments
     set refund_status = 'refunded',
         refund_note = coalesce(v_note, refund_note),
         refunded_at = now(),
         refunded_by = auth.uid(),
         updated_at = now()
   where id = v_payment.id;

  return jsonb_build_object(
    'status', 'refunded',
    'payment_id', v_payment.id,
    'refund_status', 'refunded'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants / RLS hardening
-- ---------------------------------------------------------------------------
revoke update on table public.payments from authenticated;
revoke update (
  status,
  reviewed_at,
  reviewed_by,
  review_note,
  failure_reason,
  refund_status,
  refund_note,
  refunded_at,
  refunded_by
) on public.payments from authenticated;

drop policy if exists "payments_update_admin" on public.payments;

revoke all on function public.guard_payment_review() from public, anon, authenticated;
revoke all on function public.submit_membership_payment(uuid, text, integer, text) from public, anon, authenticated;
revoke all on function public.reserve_renewal_checkout(uuid, integer) from public, anon, authenticated;
revoke all on function public.attach_checkout_order(uuid, text) from public, anon, authenticated;
revoke all on function public.abandon_checkout(uuid, text) from public, anon, authenticated;
revoke all on function public.begin_payment_verification(uuid) from public, anon, authenticated;
revoke all on function public.record_captured_payment(uuid, text, text, integer, text) from public, anon, authenticated;
revoke all on function public.flag_checkout_reconciliation(uuid, text, text) from public, anon, authenticated;
revoke all on function public.admin_list_pending_payments() from public, anon, authenticated;
revoke all on function public.admin_list_refund_payments() from public, anon, authenticated;
revoke all on function public.admin_review_payment(uuid, text, text) from public, anon, authenticated;
revoke all on function public.admin_mark_payment_refunded(uuid, text) from public, anon, authenticated;

grant execute on function public.reserve_renewal_checkout(uuid, integer) to authenticated;
grant execute on function public.admin_list_pending_payments() to authenticated;
grant execute on function public.admin_list_refund_payments() to authenticated;
grant execute on function public.admin_review_payment(uuid, text, text) to authenticated;
grant execute on function public.admin_mark_payment_refunded(uuid, text) to authenticated;

grant execute on function public.submit_membership_payment(uuid, text, integer, text) to service_role;
grant execute on function public.attach_checkout_order(uuid, text) to service_role;
grant execute on function public.abandon_checkout(uuid, text) to service_role;
grant execute on function public.begin_payment_verification(uuid) to service_role;
grant execute on function public.record_captured_payment(uuid, text, text, integer, text) to service_role;
grant execute on function public.flag_checkout_reconciliation(uuid, text, text) to service_role;
