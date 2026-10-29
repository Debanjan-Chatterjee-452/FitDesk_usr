-- ============================================================================
-- FitDesk - late renewal fine: ₹5 per day after day 8
-- Target:  FitDesk production project, ref ocycaiomiiovnsjeivvd
--
-- Policy (Asia/Kolkata calendar days past the latest plan's end date):
--   • 0-7 days ................... ₹0 (grace)
--   • exactly day 8 .............. ₹50 flat
--   • day 9 and beyond ........... ₹50 + ₹5 for each day after day 8
--
-- The frontend mirrors this exact schedule in src/lib/lateFee.ts, and the
-- demo quote calls the same helper, so the banner, the renewal sheet and the
-- server can never disagree.
--
-- This function must be replaced in place: `submit_membership_payment` and
-- `reserve_upi_checkout` both re-quote through it, so no other SQL changes.
-- Grants are preserved by `create or replace`.
-- ============================================================================

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
