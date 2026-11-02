CREATE OR REPLACE FUNCTION public.abandon_checkout(p_payment_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_assert()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select p.gym_id
    into v_gym_id
    from public.profiles p
   where p.id = auth.uid()
     and p.is_admin = true;

  if v_gym_id is null then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;

  return v_gym_id;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_cancel_membership(p_membership_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_membership public.memberships;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then
    raise exception 'REASON_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_membership
    from public.memberships
   where id = p_membership_id
     and gym_id = v_gym_id
   for update;

  if not found then
    raise exception 'MEMBERSHIP_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_membership.status = 'cancelled' then
    raise exception 'ALREADY_CANCELLED' using errcode = 'P0001';
  end if;

  -- Cannot cancel a paused membership without resuming? Allow cancel from any non-cancelled state.
  update public.memberships
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = auth.uid(),
         cancellation_reason = v_reason,
         updated_at = now()
   where id = p_membership_id;

  return jsonb_build_object(
    'membership_id', p_membership_id,
    'status', 'cancelled',
    'cancelled_at', now()
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_dashboard_stats()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    ),
    'active_members', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and m.status = 'active'
         and m.starts_on <= v_today
         and m.ends_on >= v_today
    ),
    'pending_approvals', (
      select count(*)::integer
        from public.payments pay
       where pay.gym_id = v_gym_id
         and pay.status = 'pending'
         and pay.provider_payment_id is not null
    ),
    'expiring_soon', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and m.status = 'active'
         and m.ends_on between v_today and v_today + 7
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_get_attendance_qr()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_result jsonb;
begin
  select jsonb_build_object(
    'qr', case
      when q.id is null then null
      else jsonb_build_object(
        'id', q.id,
        'label', q.label,
        'token', q.token_value,
        'created_at', q.created_at
      )
    end,
    'rotation_months', g.attendance_qr_months,
    'rotated_at', coalesce(q.created_at, g.attendance_qr_rotated_at),
    'next_rotation_at', case
      when coalesce(q.created_at, g.attendance_qr_rotated_at) is null then null
      else coalesce(q.created_at, g.attendance_qr_rotated_at)
           + (g.attendance_qr_months || ' months')::interval
    end
  )
    into v_result
    from public.gyms g
    left join lateral (
      select qr.*
        from public.gym_qr_codes qr
       where qr.gym_id = g.id
         and qr.is_active = true
         and qr.revoked_at is null
       order by qr.created_at desc
       limit 1
    ) q on true
   where g.id = v_gym_id;

  if v_result is null then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  return v_result;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_get_gym_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_row jsonb;
begin
  select jsonb_build_object(
    'gym_id', g.id,
    'slug', g.slug,
    'name', g.name,
    'upi_id', g.upi_id,
    'upi_payee_name', g.upi_payee_name,
    'payment_qr_path', g.payment_qr_path,
    'is_open', g.is_open,
    'shutter_changed_at', g.shutter_changed_at,
    'attendance_qr_months', g.attendance_qr_months,
    'attendance_qr_rotated_at', g.attendance_qr_rotated_at,
    'updated_at', g.updated_at
  )
    into v_row
    from public.gyms g
   where g.id = v_gym_id;

  if v_row is null then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  return v_row;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_get_payment_methods()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_closures(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(closure_date date, reason text, announcement_id uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_join_requests()
 RETURNS TABLE(id uuid, status text, requested_at timestamp with time zone, user_email text, member_name text, member_phone text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_gym_id uuid;
begin
  select profiles.gym_id
    into v_gym_id
    from public.profiles
   where profiles.id = auth.uid()
     and profiles.is_admin = true;

  if v_gym_id is null then
    return;
  end if;

  return query
  select r.id,
         r.status,
         r.requested_at,
         u.email::text,
         p.full_name,
         nullif(btrim(p.phone || ''), '')
    from public.gym_join_requests r
    join auth.users u on u.id = r.user_id
    left join public.profiles p on p.id = r.user_id
   where r.gym_id = v_gym_id
   order by r.status asc, r.requested_at desc;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_members(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text)
 RETURNS TABLE(user_id uuid, membership_id uuid, full_name text, email text, phone text, joined_at timestamp with time zone, plan_name text, membership_status membership_status, starts_on date, ends_on date, payment_status text, pending_payment_id uuid, pending_amount_inr integer, pending_reference text, pending_since timestamp with time zone, pending_plan_name text, activity_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_notifications(p_limit integer DEFAULT 50)
 RETURNS TABLE(id uuid, kind text, title text, body text, payload jsonb, user_id uuid, membership_id uuid, member_name text, member_phone text, is_read boolean, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
begin
  return query
  select n.id, n.kind, n.title, n.body, n.payload, n.user_id, n.membership_id,
         p.full_name, p.phone, n.is_read, n.created_at
    from public.admin_notifications n
    left join public.profiles p on p.id = n.user_id
   where n.gym_id = v_gym_id
   order by n.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_packages()
 RETURNS TABLE(id uuid, name text, description text, duration_months integer, duration_days integer, price_inr integer, is_active boolean, is_recommended boolean, sort_order integer, created_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
begin
  return query
  select
    pk.id,
    pk.name,
    pk.description,
    coalesce(pk.duration_months, greatest(1, round(pk.duration_days::numeric / 30)::integer)),
    pk.duration_days,
    pk.price_inr,
    pk.is_active,
    pk.is_recommended,
    pk.sort_order,
    pk.created_at,
    pk.updated_at
  from public.packages pk
  where pk.gym_id = v_gym_id
    and pk.pricing_mode = 'fixed'
  order by pk.is_active desc, pk.sort_order asc, pk.duration_days asc;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_pending_payments()
 RETURNS TABLE(payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text, package_name text, duration_days integer, base_amount_inr integer, fine_amount_inr integer, total_amount_inr integer, status payment_status, provider_order_id text, provider_payment_id text, failure_reason text, quote jsonb, created_at timestamp with time zone, paid_at timestamp with time zone, reviewed_at timestamp with time zone, reviewed_by uuid, checkout_state text, reconciliation_required boolean, reconciliation_reason text, legacy_status text, refund_status text, refund_note text, refunded_at timestamp with time zone, refunded_by uuid, screenshot_path text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_pending_payments_all_gyms()
 RETURNS TABLE(payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text, package_name text, duration_days integer, base_amount_inr integer, fine_amount_inr integer, total_amount_inr integer, status payment_status, provider_order_id text, provider_payment_id text, failure_reason text, quote jsonb, created_at timestamp with time zone, paid_at timestamp with time zone, reviewed_at timestamp with time zone, reviewed_by uuid, checkout_state text, reconciliation_required boolean, reconciliation_reason text, legacy_status text, refund_status text, refund_note text, refunded_at timestamp with time zone, refunded_by uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_refund_payments()
 RETURNS TABLE(payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text, package_name text, total_amount_inr integer, provider_payment_id text, review_note text, refund_status text, refund_note text, reviewed_at timestamp with time zone, refunded_at timestamp with time zone, refunded_by uuid, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_list_refund_payments_all_gyms()
 RETURNS TABLE(payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text, package_name text, total_amount_inr integer, provider_payment_id text, review_note text, refund_status text, refund_note text, reviewed_at timestamp with time zone, refunded_at timestamp with time zone, refunded_by uuid, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_mark_all_notifications_read()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_count integer;
begin
  update public.admin_notifications
     set is_read = true,
         read_at = now(),
         read_by = auth.uid()
   where gym_id = v_gym_id
     and is_read = false;
  get diagnostics v_count = row_count;
  return jsonb_build_object('marked', v_count);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_mark_notification_read(p_notification_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
begin
  update public.admin_notifications
     set is_read = true,
         read_at = now(),
         read_by = auth.uid()
   where id = p_notification_id
     and gym_id = v_gym_id;
  if not found then
    raise exception 'NOTIFICATION_NOT_FOUND' using errcode = 'P0001';
  end if;
  return jsonb_build_object('id', p_notification_id, 'is_read', true);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_mark_payment_refunded(p_payment_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_pause_membership(p_membership_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_membership public.memberships;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_reason is null then
    raise exception 'REASON_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_membership
    from public.memberships
   where id = p_membership_id
     and gym_id = v_gym_id
   for update;

  if not found then
    raise exception 'MEMBERSHIP_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_membership.status = 'cancelled' then
    raise exception 'CANCELLED_MEMBERSHIP' using errcode = 'P0001';
  end if;

  if v_membership.status = 'paused' then
    raise exception 'ALREADY_PAUSED' using errcode = 'P0001';
  end if;

  if v_membership.status <> 'active' then
    raise exception 'MEMBERSHIP_NOT_ACTIVE' using errcode = 'P0001';
  end if;

  -- If membership already expired, pausing is not meaningful.
  if v_membership.ends_on < v_today then
    raise exception 'MEMBERSHIP_EXPIRED' using errcode = 'P0001';
  end if;

  update public.memberships
     set status = 'paused',
         paused_at = now(),
         paused_by = auth.uid(),
         pause_reason = v_reason,
         paused_until = v_today,
         updated_at = now()
   where id = p_membership_id;

  insert into public.membership_pauses (membership_id, gym_id, paused_at, paused_by, reason)
  values (p_membership_id, v_gym_id, now(), auth.uid(), v_reason);

  return jsonb_build_object(
    'membership_id', p_membership_id,
    'status', 'paused',
    'paused_at', now(),
    'paused_from', v_today
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_resume_membership(p_membership_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_membership public.memberships;
  v_pause public.membership_pauses;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_paused_days integer;
  v_new_ends_on date;
begin
  select * into v_membership
    from public.memberships
   where id = p_membership_id
     and gym_id = v_gym_id
   for update;

  if not found then
    raise exception 'MEMBERSHIP_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_membership.status = 'cancelled' then
    raise exception 'CANCELLED_MEMBERSHIP' using errcode = 'P0001';
  end if;

  if v_membership.status <> 'paused' then
    raise exception 'NOT_PAUSED' using errcode = 'P0001';
  end if;

  -- Find the open pause row.
  select * into v_pause
    from public.membership_pauses
   where membership_id = p_membership_id
     and resumed_at is null
   order by paused_at desc
   limit 1
   for update;

  if not found then
    raise exception 'NO_OPEN_PAUSE' using errcode = 'P0001';
  end if;

  v_paused_days := greatest(1, (v_today - coalesce(v_membership.paused_until, v_today::date)) + 1);
  -- Ensure at least the days since paused_until; if resumed same day, 1 day.
  if v_paused_days < 1 then v_paused_days := 1; end if;

  v_new_ends_on := v_membership.ends_on + v_paused_days;

  update public.membership_pauses
     set resumed_at = now(),
         resumed_by = auth.uid(),
         paused_days = v_paused_days
   where id = v_pause.id;

  update public.memberships
     set status = 'active',
         ends_on = v_new_ends_on,
         total_paused_days = total_paused_days + v_paused_days,
         paused_at = null,
         paused_by = null,
         pause_reason = null,
         paused_until = null,
         resumed_at = now(),
         resumed_by = auth.uid(),
         updated_at = now()
   where id = p_membership_id;

  return jsonb_build_object(
    'membership_id', p_membership_id,
    'status', 'active',
    'paused_days', v_paused_days,
    'new_ends_on', v_new_ends_on
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_review_join_request(p_request_id uuid, p_approve boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_admin uuid := auth.uid();
  v_gym_id uuid;
  v_request public.gym_join_requests;
  v_member_name text;
begin
  if v_admin is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select gym_id into v_gym_id
    from public.profiles
   where id = v_admin
     and is_admin = true;

  if v_gym_id is null then
    raise exception 'ADMIN_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_request
    from public.gym_join_requests
   where id = p_request_id
     and gym_id = v_gym_id;

  if not found then
    raise exception 'JOIN_REQUEST_NOT_FOUND' using errcode = 'P0001';
  end if;

  if p_approve then
    if exists (select 1 from public.profiles where id = v_request.user_id and gym_id = v_gym_id) then
      -- Idempotent re-approve.
      update public.gym_join_requests
         set status = 'approved', decided_at = now(), decided_by = v_admin
       where id = p_request_id;
      return jsonb_build_object('status', 'approved', 'user_id', v_request.user_id, 'gym_id', v_gym_id);
    end if;

    if exists (select 1 from public.profiles where id = v_request.user_id and gym_id is not null) then
      raise exception 'MEMBER_ALREADY_IN_GYM' using errcode = 'P0001';
    end if;

    update public.gym_join_requests
       set status = 'approved', decided_at = now(), decided_by = v_admin
     where id = p_request_id;

    update public.profiles
       set gym_id = v_gym_id
     where id = v_request.user_id;

    select coalesce(full_name, 'Member') into v_member_name
      from public.profiles where id = v_request.user_id;

    insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id)
    values (
      v_gym_id,
      'member_joined',
      'New member approved ├óΓé¼ΓÇ¥ ' || v_member_name,
      v_member_name || ' was approved and can now see packages, renew and check in.',
      jsonb_build_object('user_id', v_request.user_id, 'approved_at', now()),
      v_request.user_id
    );

    return jsonb_build_object('status', 'approved', 'user_id', v_request.user_id, 'gym_id', v_gym_id);
  else
    update public.gym_join_requests
       set status = 'declined', decided_at = now(), decided_by = v_admin
     where id = p_request_id;

    return jsonb_build_object('status', 'declined', 'user_id', v_request.user_id, 'gym_id', v_gym_id);
  end if;
exception
  when unique_violation then
    raise exception 'PHONE_ALREADY_REGISTERED' using errcode = 'P0001';
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_review_payment(p_payment_id uuid, p_decision text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_review_payment_unscoped(p_payment_id uuid, p_decision text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_rotate_attendance_qr(p_label text DEFAULT 'Front desk'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_label text := coalesce(nullif(btrim(p_label), ''), 'Front desk');
  v_token text;
begin
  v_token := 'FITDESK-' || upper(encode(extensions.gen_random_bytes(24), 'hex'));

  update public.gym_qr_codes
     set is_active = false,
         revoked_at = now()
   where gym_id = v_gym_id
     and is_active = true;

  insert into public.gym_qr_codes (
    label,
    token_hash,
    token_value,
    is_active,
    created_by,
    gym_id
  )
  values (
    v_label,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    v_token,
    true,
    auth.uid(),
    v_gym_id
  );

  update public.gyms
     set attendance_qr_rotated_at = now(),
         updated_at = now()
   where id = v_gym_id;

  return public.admin_get_attendance_qr();
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_save_payment_method(p_method text, p_is_enabled boolean, p_upi_id text DEFAULT NULL::text, p_payee_name text DEFAULT NULL::text, p_qr_path text DEFAULT NULL::text, p_clear_qr boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_set_attendance_rotation(p_months integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
begin
  if p_months is null or p_months not in (1, 3, 6, 12) then
    raise exception 'INVALID_ROTATION_INTERVAL' using errcode = '22023';
  end if;

  update public.gyms
     set attendance_qr_months = p_months,
         updated_at = now()
   where id = v_gym_id;

  return public.admin_get_attendance_qr();
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_set_closure(p_date date, p_closed boolean, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_set_gym_open(p_open boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_changed timestamptz := now();
begin
  update public.gyms
     set is_open = p_open,
         shutter_changed_at = v_changed,
         updated_at = v_changed
   where id = v_gym_id;

  return jsonb_build_object(
    'is_open', p_open,
    'shutter_changed_at', v_changed
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_set_package_active(p_id uuid, p_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_row public.packages;
begin
  update public.packages
     set is_active = p_active,
         updated_at = now()
   where id = p_id
     and gym_id = v_gym_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'PACKAGE_NOT_FOUND' using errcode = 'P0001';
  end if;

  return jsonb_build_object('id', v_row.id, 'is_active', v_row.is_active);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_unread_notification_count()
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_count integer;
begin
  select count(*)::integer into v_count
    from public.admin_notifications
   where gym_id = v_gym_id
     and is_read = false;
  return coalesce(v_count, 0);
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_update_gym_name(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.admin_update_payment_settings(p_upi_id text, p_upi_payee_name text, p_qr_path text DEFAULT NULL::text, p_clear_qr boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_upi text := nullif(lower(btrim(coalesce(p_upi_id, ''))), '');
  v_payee text := nullif(btrim(coalesce(p_upi_payee_name, '')), '');
  v_qr text := nullif(btrim(coalesce(p_qr_path, '')), '');
begin
  if v_upi is not null
     and v_upi !~ '^[a-z0-9][a-z0-9._-]{1,60}@[a-z][a-z0-9]{1,40}$' then
    raise exception 'INVALID_UPI_ID' using errcode = '22023';
  end if;

  if v_qr is not null and v_qr not like v_gym_id::text || '/%' then
    raise exception 'QR_PATH_GYM_MISMATCH' using errcode = '22023';
  end if;

  update public.gyms
     set upi_id = v_upi,
         upi_payee_name = case when v_upi is null then null else coalesce(v_payee, name) end,
         payment_qr_path = case when p_clear_qr then null else coalesce(v_qr, payment_qr_path) end,
         updated_at = now()
   where id = v_gym_id;

  return public.admin_get_gym_settings();
end;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_upsert_package(p_months integer, p_price_inr integer, p_name text DEFAULT NULL::text, p_description text DEFAULT NULL::text, p_id uuid DEFAULT NULL::uuid, p_is_recommended boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gym_id uuid := public.admin_assert();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_description text := nullif(btrim(coalesce(p_description, '')), '');
  v_days integer;
  v_row public.packages;
begin
  if p_months is null or p_months < 1 or p_months > 24 then
    raise exception 'INVALID_PACKAGE_MONTHS' using errcode = '22023';
  end if;

  if p_price_inr is null or p_price_inr < 1 then
    raise exception 'INVALID_PACKAGE_PRICE' using errcode = '22023';
  end if;

  v_days := case p_months
    when 1 then 30
    when 3 then 90
    when 6 then 180
    when 12 then 365
    else p_months * 30
  end;

  if v_name is null then
    v_name := case p_months
      when 1 then 'Monthly'
      when 3 then 'Quarterly'
      when 6 then 'Half-yearly'
      when 12 then 'Annual'
      else p_months::text || ' Month Plan'
    end;
  end if;

  if p_id is null then
    insert into public.packages (
      name,
      description,
      duration_days,
      duration_months,
      price_inr,
      pricing_mode,
      is_active,
      is_recommended,
      sort_order,
      gym_id
    )
    values (
      v_name,
      v_description,
      v_days,
      p_months,
      p_price_inr,
      'fixed',
      true,
      p_is_recommended,
      p_months * 10,
      v_gym_id
    )
    returning * into v_row;
  else
    update public.packages
       set name = v_name,
           description = v_description,
           duration_days = v_days,
           duration_months = p_months,
           price_inr = p_price_inr,
           pricing_mode = 'fixed',
           min_days = null,
           max_days = null,
           is_recommended = p_is_recommended,
           sort_order = p_months * 10,
           updated_at = now()
     where id = p_id
       and gym_id = v_gym_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'PACKAGE_NOT_FOUND' using errcode = 'P0001';
    end if;
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'duration_months', v_row.duration_months,
    'duration_days', v_row.duration_days,
    'price_inr', v_row.price_inr,
    'is_active', v_row.is_active
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.attach_checkout_order(p_payment_id uuid, p_provider_order_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.begin_payment_verification(p_payment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.check_in_with_qr(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_qr public.gym_qr_codes;
  v_membership public.memberships;
  v_latest_membership public.memberships;
  v_attendance public.attendance;
  v_gym_name text;
  v_profile public.profiles;
  v_has_closure boolean := false;
  v_paid boolean := false;
  v_notify boolean := false;
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

  -- Active membership covering today.
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
    -- Expired-unpaid notification logic (past 3-day grace period).
    select * into v_latest_membership
      from public.memberships
     where user_id = v_user
       and gym_id = v_profile.gym_id
     order by ends_on desc
     limit 1;

    if found and v_latest_membership.ends_on is not null
       and v_today >= (v_latest_membership.ends_on + 4) then
      -- Check if paid: any approved payment created after expiry.
      select exists (
        select 1 from public.payments
         where user_id = v_user
           and gym_id = v_profile.gym_id
           and status = 'approved'
           and created_at::date > v_latest_membership.ends_on
      ) into v_paid;

      if not v_paid and v_latest_membership.status <> 'cancelled' and v_latest_membership.status <> 'paused' then
        v_notify := true;
      end if;
    end if;

    if v_notify then
      insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id, membership_id)
      values (
        v_profile.gym_id,
        'membership_expired_unpaid',
        'Membership Expired ΓÇö ' || coalesce(v_profile.full_name, 'Member'),
        coalesce(v_profile.full_name, 'Member') || ' scanned the gym attendance QR code, but their membership expired on ' ||
          to_char(v_latest_membership.ends_on, 'DD Mon YYYY') || ' and the outstanding payment is still unpaid.',
        jsonb_build_object(
          'member_name', v_profile.full_name,
          'phone', v_profile.phone,
          'package_id', v_latest_membership.package_id,
          'expiry_date', v_latest_membership.ends_on,
          'attempted_at', now()
        ),
        v_user,
        v_latest_membership.id
      )
      on conflict do nothing;

      return jsonb_build_object(
        'status', 'membership_inactive',
        'message', 'Your membership expired on ' || to_char(v_latest_membership.ends_on, 'DD Mon YYYY') || '. Please renew to continue.',
        'member_name', v_profile.full_name
      );
    end if;

    raise exception 'MEMBERSHIP_INACTIVE' using errcode = 'P0001';
  end if;

  select coalesce(name, 'FitDesk') into v_gym_name
    from public.gyms
   where id = v_profile.gym_id;

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
$function$
;
CREATE OR REPLACE FUNCTION public.create_gym_qr_code(p_label text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_label text := btrim(coalesce(p_label, ''));
  v_token text;
  v_qr public.gym_qr_codes;
begin
  if length(v_label) = 0 then
    raise exception 'LABEL_REQUIRED' using errcode = 'P0001';
  end if;

  v_token := 'FITDESK-' || upper(encode(extensions.gen_random_bytes(24), 'hex'));

  insert into public.gym_qr_codes (label, token_hash, created_by)
  values (
    v_label,
    encode(extensions.digest(v_token, 'sha256'), 'hex'),
    auth.uid()
  )
  returning * into v_qr;

  -- The raw token is intentionally returned only once. Print it, then discard.
  return jsonb_build_object(
    'id', v_qr.id,
    'label', v_qr.label,
    'token', v_token,
    'created_at', v_qr.created_at
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.ensure_my_profile()
 RETURNS profiles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_user uuid := auth.uid();
  v_phone text;
  v_profile public.profiles;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_profile from public.profiles where id = v_user;
  if found then
    return v_profile;
  end if;

  select phone into v_phone from auth.users where id = v_user;

  insert into public.profiles (id, phone)
  values (v_user, coalesce(v_phone, ''))
  on conflict (id) do nothing;

  select * into v_profile from public.profiles where id = v_user;
  if not found then
    raise exception 'PROFILE_CREATE_FAILED' using errcode = 'P0001';
  end if;

  return v_profile;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.fill_membership_gym()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.flag_checkout_reconciliation(p_payment_id uuid, p_provider_order_id text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.generate_gym_join_code()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
declare
  alphabet text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  a text := '';
  b text := '';
begin
  for i in 1..4 loop
    a := a || substr(alphabet, floor(random() * length(alphabet))::int + 1, 1);
    b := b || substr(alphabet, floor(random() * length(alphabet))::int + 1, 1);
  end loop;
  return 'FD-' || a || '-' || b;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.get_my_renewal_quote(p_package_id uuid, p_duration_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    v_fine_reason := '8 days past expiry - ├óΓÇÜ┬╣50 flat late fee';
  elsif v_days_past >= 9 then
    v_fine := 50 + 5 * (v_days_past - 8);
    v_fine_reason := v_days_past::text || ' days past expiry - ├óΓÇÜ┬╣50 + ├óΓÇÜ┬╣5/day after day 8';
  elsif v_days_past > 0 then
    v_fine_reason := v_days_past::text
      || case when v_days_past = 1 then ' day' else ' days' end
      || ' past expiry - inside the 7-day grace period';
  end if;

  v_base := case
    when v_pkg.pricing_mode = 'per_day' then v_pkg.price_inr * v_duration
    else v_pkg.price_inr
  end;

  v_starts := case when v_is_stacked then v_effective_end + 1 else v_today end;
  v_ends := v_starts + (v_duration - 1);

  v_breakdown := jsonb_build_array(
    jsonb_build_object(
      'label', v_pkg.name || ' ├é┬╖ ' || v_duration::text || ' days',
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
    'current_ends_on', v_effective_end,
    'is_stacked', v_is_stacked,
    'is_paused', v_is_paused,
    'fine_reason', v_fine_reason,
    'breakdown', v_breakdown
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.get_my_upi_payment(p_payment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    elsif v_payment.provider is not null and v_payment.provider <> 'upi' then
      -- Rail-aware payee from the gym's enabled payment methods.
      select pm.upi_id,
             coalesce(pm.payee_name, v_gym.name),
             pm.qr_path
        into v_upi_id, v_payee_name, v_qr_path
        from public.gym_payment_methods pm
       where pm.gym_id = v_payment.gym_id
         and pm.is_enabled
         and pm.method = v_payment.provider
       limit 1;

      if v_upi_id is null and v_qr_path is null then
        v_reason := 'NOT_CONFIGURED';
      else
        v_available := true;
        v_gym_name := v_gym.name;
      end if;
    elsif v_gym.upi_id is not null then
      v_upi_id := v_gym.upi_id;
      v_payee_name := coalesce(v_gym.upi_payee_name, v_gym.name);
      v_qr_path := v_gym.payment_qr_path;
      v_available := true;
      v_gym_name := v_gym.name;
    else
      v_reason := 'NOT_CONFIGURED';
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
$function$
;
CREATE OR REPLACE FUNCTION public.guard_membership_period()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.guard_payment_review()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.handle_gym_join_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if new.join_code is null or length(btrim(new.join_code)) = 0 then
    loop
      new.join_code := public.generate_gym_join_code();
      exit when not exists (select 1 from public.gyms where join_code = new.join_code);
    end loop;
  end if;
  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  insert into public.profiles (id, phone)
  values (new.id, coalesce(new.phone, ''))
  on conflict (id) do nothing;
  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.handle_user_phone_updated()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
begin
  update public.profiles
     set phone = coalesce(new.phone, '')
   where id = new.id;
  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  select coalesce(
    (select p.is_admin from public.profiles p where p.id = auth.uid()),
    false
  );
$function$
;
CREATE OR REPLACE FUNCTION public.member_payment_methods()
 RETURNS TABLE(method text, upi_id text, payee_name text, qr_path text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.my_join_requests()
 RETURNS TABLE(status text, gym_id uuid, gym_name text, requested_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    return;
  end if;

  return query
  select r.status, r.gym_id, g.name, r.requested_at
    from public.gym_join_requests r
    join public.gyms g on g.id = r.gym_id
   where r.user_id = v_user
   order by r.requested_at desc;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.normalize_gym_payment_method()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.normalize_gym_payment_settings()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.record_captured_payment(p_payment_id uuid, p_provider_payment_id text, p_provider_order_id text, p_paid_amount_inr integer, p_failure_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.register_gym_owner(p_gym_name text, p_full_name text, p_phone text DEFAULT NULL::text, p_slug text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.request_join_gym(p_join_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
declare
  v_user uuid := auth.uid();
  v_code text := upper(nullif(btrim(coalesce(p_join_code, '')), ''));
  v_gym public.gyms;
  v_profile public.profiles;
  v_request public.gym_join_requests;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if v_code is null then
    raise exception 'JOIN_CODE_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_profile from public.profiles where id = v_user;
  if not found then
    raise exception 'PROFILE_REQUIRED' using errcode = 'P0001';
  end if;

  -- Already an approved member of a gym.
  if v_profile.gym_id is not null then
    return jsonb_build_object(
      'status', 'already_member',
      'gym_id', v_profile.gym_id
    );
  end if;

  select * into v_gym
    from public.gyms
   where upper(join_code) = v_code
     and is_active;

  if not found then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  -- Insert or re-open (re-request after decline), never a second row.
  insert into public.gym_join_requests (gym_id, user_id, status)
  values (v_gym.id, v_user, 'pending')
  on conflict (gym_id, user_id) do update
    set status = 'pending',
        requested_at = now(),
        decided_at = null,
        decided_by = null
  where public.gym_join_requests.status <> 'pending';

  select * into v_request
    from public.gym_join_requests
   where gym_id = v_gym.id and user_id = v_user;

  return jsonb_build_object(
    'status', v_request.status,
    'requested_at', v_request.requested_at,
    'gym_id', v_gym.id,
    'gym_name', v_gym.name,
    'requires_approval', true
  );
end;
$function$
;
CREATE OR REPLACE FUNCTION public.reserve_renewal_checkout(p_package_id uuid, p_duration_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.reserve_upi_checkout(p_package_id uuid, p_duration_days integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.reserve_upi_checkout(p_package_id uuid, p_duration_days integer DEFAULT NULL::integer, p_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- Validate the requested rail against the gym's enabled methods.
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
    v_method,
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
    'method', v_method,
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
$function$
;
CREATE OR REPLACE FUNCTION public.revoke_gym_qr_code(p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  update public.gym_qr_codes
     set is_active = false,
         revoked_at = now()
   where id = p_id
     and revoked_at is null;

  return found;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.submit_membership_payment(p_payment_id uuid, p_provider_payment_id text, p_paid_amount_inr integer, p_provider_order_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.submit_payment_screenshot(p_payment_id uuid, p_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.submit_upi_payment_reference(p_payment_id uuid, p_reference text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
;
CREATE OR REPLACE FUNCTION public.touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  new.updated_at := now();
  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.validate_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'storage', 'pg_temp'
AS $function$
begin
  new.full_name := nullif(btrim(coalesce(new.full_name, '')), '');

  if new.date_of_birth is not null and new.date_of_birth > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'INVALID_DATE_OF_BIRTH' using errcode = 'P0001';
  end if;

  if new.legal_document_path is not null
     and length(btrim(new.legal_document_path)) > 0
     and split_part(new.legal_document_path, '/', 1) <> new.id::text then
    raise exception 'INVALID_DOCUMENT_PATH' using errcode = 'P0001';
  end if;

  new.legal_document_path := nullif(btrim(coalesce(new.legal_document_path, '')), '');
  new.legal_document_name := nullif(btrim(coalesce(new.legal_document_name, '')), '');

  -- A member cannot claim completion with a path that has no uploaded object.
  if new.legal_document_path is not null
     and not exists (
       select 1
         from storage.objects
        where bucket_id = 'legal-documents'
          and name = new.legal_document_path
     ) then
    raise exception 'DOCUMENT_NOT_UPLOADED' using errcode = 'P0001';
  end if;

  new.profile_completed :=
    new.full_name is not null
    and new.date_of_birth is not null
    and new.blood_group is not null
    and new.gender is not null
    and new.legal_document_path is not null;

  new.updated_at := now();
  return new;
end;
$function$
;
