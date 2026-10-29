-- FitDesk — preserve the existing active membership on approval
--
-- Additive follow-up to 20261027000400_fitdesk_manual_payment_approval.sql.
--
-- A pending purchase/renewal must never disturb the plan a member is using
-- today. Approval therefore ignores the checkout quote's dates and recalculates
-- the applied period from the member's latest non-cancelled membership:
--
--   * still valid (ends_on >= today) -> start the day after its ends_on, so
--     every remaining day is preserved;
--   * lapsed                        -> start today.
--
-- The purchased package, duration, base amount, and fine stay exactly as paid.
-- Approval is serialized per member and can only run once per payment.

-- ---------------------------------------------------------------------------
-- One non-cancelled membership may cover a given calendar day
--
-- This is defence in depth on top of the period calculation below. It blocks a
-- direct insert/update that would overlap an existing entitlement, while still
-- allowing contiguous stacked plans and status-only updates (for example
-- marking a lapsed plan expired).
-- ---------------------------------------------------------------------------
create or replace function public.guard_membership_period()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status = 'cancelled' then
    return new;
  end if;

  if exists (
    select 1
      from public.memberships m
     where m.user_id = new.user_id
       and m.id <> new.id
       and m.status <> 'cancelled'
       and daterange(m.starts_on, m.ends_on, '[]')
           && daterange(new.starts_on, new.ends_on, '[]')
  ) then
    raise exception 'MEMBERSHIP_PERIOD_OVERLAP' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

comment on function public.guard_membership_period() is
  'Rejects overlapping non-cancelled memberships. A member may hold a current '
  'plan plus contiguous future plans, but never two plans covering the same day.';

drop trigger if exists memberships_guard_period on public.memberships;
create trigger memberships_guard_period
  before insert or update of user_id, starts_on, ends_on
  on public.memberships
  for each row
  execute function public.guard_membership_period();

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

  -- Serialize every review for this member. A second approval (same payment or
  -- a duplicate) waits here, then re-reads the committed row and is rejected.
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

  -- Price, package, and duration are immutable facts of the purchase. The
  -- dates are intentionally not trusted: they are recalculated below.
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

  -- Mark only already-lapsed plans as expired. A plan that still covers today
  -- is left exactly as it is, including its package and expiry date.
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

  -- Fail loudly if any legacy row would still overlap the recalculated period.
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

  -- Store the period that was actually applied so receipts and the member's
  -- history match the membership row. Price and duration stay untouched.
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
  'Approves or declines a submitted payment. Approval preserves a still-valid '
  'membership and queues the purchased plan after its expiry; it never shortens '
  'the member''s paid access. Reviews are serialized per member.';

-- ---------------------------------------------------------------------------
-- Grants (CREATE OR REPLACE keeps existing grants, but restate them so this
-- migration is safe to apply on its own)
-- ---------------------------------------------------------------------------
revoke all on function public.guard_membership_period() from public, anon, authenticated;
revoke all on function public.admin_review_payment(uuid, text, text) from public, anon, authenticated;
grant execute on function public.admin_review_payment(uuid, text, text) to authenticated;
