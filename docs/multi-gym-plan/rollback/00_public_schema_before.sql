--
-- PostgreSQL database dump
--

\restrict QebnYjJYMZVnpnYDB8KEhEaBscj1lsxbGuHbOGaiXpbke4hkcKYUtez8eRjFhIo

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: announcement_kind; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.announcement_kind AS ENUM (
    'info',
    'holiday',
    'closure'
);


--
-- Name: attendance_source; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.attendance_source AS ENUM (
    'qr',
    'manual',
    'admin'
);


--
-- Name: blood_group; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.blood_group AS ENUM (
    'A+',
    'A-',
    'B+',
    'B-',
    'AB+',
    'AB-',
    'O+',
    'O-'
);


--
-- Name: gender; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.gender AS ENUM (
    'male',
    'female',
    'other',
    'prefer_not_to_say'
);


--
-- Name: membership_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.membership_status AS ENUM (
    'pending',
    'active',
    'expired',
    'cancelled',
    'paused'
);


--
-- Name: payment_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.payment_status AS ENUM (
    'pending',
    'approved',
    'declined'
);


--
-- Name: pricing_mode; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.pricing_mode AS ENUM (
    'fixed',
    'per_day'
);


--
-- Name: abandon_checkout(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.abandon_checkout(p_payment_id uuid, p_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_assert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_assert() RETURNS uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: FUNCTION admin_assert(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.admin_assert() IS 'Returns the signed-in admin''s gym id or raises. Used only inside SECURITY DEFINER RPCs.';


--
-- Name: admin_cancel_membership(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_cancel_membership(p_membership_id uuid, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_dashboard_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_dashboard_stats() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_get_attendance_qr(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_attendance_qr() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_get_gym_settings(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_gym_settings() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_get_payment_methods(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_payment_methods() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_list_closures(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_closures(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date) RETURNS TABLE(closure_date date, reason text, announcement_id uuid)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_list_join_requests(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_join_requests() RETURNS TABLE(id uuid, status text, requested_at timestamp with time zone, user_email text, member_name text, member_phone text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_list_members(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_members(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text) RETURNS TABLE(user_id uuid, membership_id uuid, full_name text, email text, phone text, joined_at timestamp with time zone, plan_name text, membership_status public.membership_status, starts_on date, ends_on date, payment_status text, pending_payment_id uuid, pending_amount_inr integer, pending_reference text, pending_since timestamp with time zone, pending_plan_name text, activity_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_list_notifications(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_notifications(p_limit integer DEFAULT 50) RETURNS TABLE(id uuid, kind text, title text, body text, payload jsonb, user_id uuid, membership_id uuid, member_name text, member_phone text, is_read boolean, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_list_packages(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_packages() RETURNS TABLE(id uuid, name text, description text, duration_months integer, duration_days integer, price_inr integer, is_active boolean, is_recommended boolean, sort_order integer, created_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_list_pending_payments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_pending_payments() RETURNS TABLE(payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text, package_name text, duration_days integer, base_amount_inr integer, fine_amount_inr integer, total_amount_inr integer, status public.payment_status, provider_order_id text, provider_payment_id text, failure_reason text, quote jsonb, created_at timestamp with time zone, paid_at timestamp with time zone, reviewed_at timestamp with time zone, reviewed_by uuid, checkout_state text, reconciliation_required boolean, reconciliation_reason text, legacy_status text, refund_status text, refund_note text, refunded_at timestamp with time zone, refunded_by uuid, screenshot_path text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_list_pending_payments_all_gyms(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_pending_payments_all_gyms() RETURNS TABLE(payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text, package_name text, duration_days integer, base_amount_inr integer, fine_amount_inr integer, total_amount_inr integer, status public.payment_status, provider_order_id text, provider_payment_id text, failure_reason text, quote jsonb, created_at timestamp with time zone, paid_at timestamp with time zone, reviewed_at timestamp with time zone, reviewed_by uuid, checkout_state text, reconciliation_required boolean, reconciliation_reason text, legacy_status text, refund_status text, refund_note text, refunded_at timestamp with time zone, refunded_by uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
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


--
-- Name: admin_list_refund_payments(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_refund_payments() RETURNS TABLE(payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text, package_name text, total_amount_inr integer, provider_payment_id text, review_note text, refund_status text, refund_note text, reviewed_at timestamp with time zone, refunded_at timestamp with time zone, refunded_by uuid, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_list_refund_payments_all_gyms(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_refund_payments_all_gyms() RETURNS TABLE(payment_id uuid, user_id uuid, member_name text, member_email text, member_phone text, package_name text, total_amount_inr integer, provider_payment_id text, review_note text, refund_status text, refund_note text, reviewed_at timestamp with time zone, refunded_at timestamp with time zone, refunded_by uuid, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
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


--
-- Name: admin_mark_all_notifications_read(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_mark_all_notifications_read() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_mark_notification_read(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_mark_notification_read(p_notification_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_mark_payment_refunded(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_mark_payment_refunded(p_payment_id uuid, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_pause_membership(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_pause_membership(p_membership_id uuid, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_resume_membership(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_resume_membership(p_membership_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_review_join_request(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_review_join_request(p_request_id uuid, p_approve boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
      'New member approved â€” ' || v_member_name,
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
$$;


--
-- Name: admin_review_payment(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_review_payment(p_payment_id uuid, p_decision text, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_review_payment_unscoped(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_review_payment_unscoped(p_payment_id uuid, p_decision text, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: FUNCTION admin_review_payment_unscoped(p_payment_id uuid, p_decision text, p_note text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.admin_review_payment_unscoped(p_payment_id uuid, p_decision text, p_note text) IS 'Approves or declines a submitted payment. Self-review is forbidden. Reconciliation rows require a note. Approval preserves a still-valid membership and queues the purchased plan after its expiry.';


--
-- Name: admin_rotate_attendance_qr(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_rotate_attendance_qr(p_label text DEFAULT 'Front desk'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
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
$$;


--
-- Name: FUNCTION admin_rotate_attendance_qr(p_label text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.admin_rotate_attendance_qr(p_label text) IS 'Revokes the gym''s previous QR and returns a newly generated single attendance QR token.';


--
-- Name: admin_save_payment_method(text, boolean, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_save_payment_method(p_method text, p_is_enabled boolean, p_upi_id text DEFAULT NULL::text, p_payee_name text DEFAULT NULL::text, p_qr_path text DEFAULT NULL::text, p_clear_qr boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: admin_set_attendance_rotation(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_attendance_rotation(p_months integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_set_closure(date, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_closure(p_date date, p_closed boolean, p_reason text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_set_gym_open(boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_gym_open(p_open boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_set_package_active(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_set_package_active(p_id uuid, p_active boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_unread_notification_count(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_unread_notification_count() RETURNS integer
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_update_gym_name(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_update_gym_name(p_name text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: admin_update_payment_settings(text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_update_payment_settings(p_upi_id text, p_upi_payee_name text, p_qr_path text DEFAULT NULL::text, p_clear_qr boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: admin_upsert_package(integer, integer, text, text, uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_upsert_package(p_months integer, p_price_inr integer, p_name text DEFAULT NULL::text, p_description text DEFAULT NULL::text, p_id uuid DEFAULT NULL::uuid, p_is_recommended boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: attach_checkout_order(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.attach_checkout_order(p_payment_id uuid, p_provider_order_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: begin_payment_verification(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.begin_payment_verification(p_payment_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: check_in_with_qr(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_in_with_qr(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
        'Membership Expired — ' || coalesce(v_profile.full_name, 'Member'),
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
$$;


--
-- Name: create_gym_qr_code(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_gym_qr_code(p_label text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions', 'pg_temp'
    AS $$
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
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    phone text DEFAULT ''::text NOT NULL,
    full_name text,
    date_of_birth date,
    blood_group public.blood_group,
    gender public.gender,
    legal_document_path text,
    legal_document_name text,
    legal_document_type text,
    profile_completed boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_admin boolean DEFAULT false NOT NULL,
    gym_id uuid
);


--
-- Name: TABLE profiles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.profiles IS 'Member profile. Rows are created by the auth trigger and can only be read/updated by their owner.';


--
-- Name: COLUMN profiles.legal_document_path; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.legal_document_path IS 'Private object path inside the legal-documents bucket: <user-id>/<file-name>.';


--
-- Name: COLUMN profiles.profile_completed; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.profile_completed IS 'Derived by trigger from the mandatory profile fields. Clients cannot set this directly.';


--
-- Name: COLUMN profiles.is_admin; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.is_admin IS 'Admin role flag. Only service-role/SQL tooling can set it; members have no column grant for it. Admin-role users may review pending payments.';


--
-- Name: COLUMN profiles.gym_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.gym_id IS 'Gym this account belongs to. NULL until a gym admin approves the member''s join request.';


--
-- Name: ensure_my_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_my_profile() RETURNS public.profiles
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
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
$$;


--
-- Name: fill_membership_gym(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fill_membership_gym() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: flag_checkout_reconciliation(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.flag_checkout_reconciliation(p_payment_id uuid, p_provider_order_id text, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: generate_gym_join_code(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_gym_join_code() RETURNS text
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: get_my_renewal_quote(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_renewal_quote(p_package_id uuid, p_duration_days integer DEFAULT NULL::integer) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
    v_fine_reason := '8 days past expiry - â‚¹50 flat late fee';
  elsif v_days_past >= 9 then
    v_fine := 50 + 5 * (v_days_past - 8);
    v_fine_reason := v_days_past::text || ' days past expiry - â‚¹50 + â‚¹5/day after day 8';
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
      'label', v_pkg.name || ' Â· ' || v_duration::text || ' days',
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
$$;


--
-- Name: get_my_upi_payment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_upi_payment(p_payment_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: FUNCTION get_my_upi_payment(p_payment_id uuid); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_my_upi_payment(p_payment_id uuid) IS 'Reads the member''s own payment instructions; the payee follows the rail chosen at reserve time when one was recorded.';


--
-- Name: guard_membership_period(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_membership_period() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: FUNCTION guard_membership_period(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.guard_membership_period() IS 'Rejects overlapping non-cancelled memberships. A member may hold a current plan plus contiguous future plans, but never two plans covering the same day.';


--
-- Name: guard_payment_review(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_payment_review() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: handle_gym_join_code(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_gym_join_code() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.join_code is null or length(btrim(new.join_code)) = 0 then
    loop
      new.join_code := public.generate_gym_join_code();
      exit when not exists (select 1 from public.gyms where join_code = new.join_code);
    end loop;
  end if;
  return new;
end;
$$;


--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
begin
  insert into public.profiles (id, phone)
  values (new.id, coalesce(new.phone, ''))
  on conflict (id) do nothing;
  return new;
end;
$$;


--
-- Name: handle_user_phone_updated(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_user_phone_updated() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
begin
  update public.profiles
     set phone = coalesce(new.phone, '')
   where id = new.id;
  return new;
end;
$$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
  select coalesce(
    (select p.is_admin from public.profiles p where p.id = auth.uid()),
    false
  );
$$;


--
-- Name: FUNCTION is_admin(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.is_admin() IS 'True when the signed-in user has the Admin role. Never trusts client input.';


--
-- Name: member_payment_methods(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.member_payment_methods() RETURNS TABLE(method text, upi_id text, payee_name text, qr_path text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: my_join_requests(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.my_join_requests() RETURNS TABLE(status text, gym_id uuid, gym_name text, requested_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: normalize_gym_payment_method(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_gym_payment_method() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: normalize_gym_payment_settings(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_gym_payment_settings() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: record_captured_payment(uuid, text, text, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_captured_payment(p_payment_id uuid, p_provider_payment_id text, p_provider_order_id text, p_paid_amount_inr integer, p_failure_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: register_gym_owner(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.register_gym_owner(p_gym_name text, p_full_name text, p_phone text DEFAULT NULL::text, p_slug text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: request_join_gym(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.request_join_gym(p_join_code text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
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
$$;


--
-- Name: FUNCTION request_join_gym(p_join_code text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.request_join_gym(p_join_code text) IS 'Member requests to join a gym by join code; the gym admin must approve. Approval stamps profiles.gym_id.';


--
-- Name: reserve_renewal_checkout(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserve_renewal_checkout(p_package_id uuid, p_duration_days integer DEFAULT NULL::integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: reserve_upi_checkout(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserve_upi_checkout(p_package_id uuid, p_duration_days integer DEFAULT NULL::integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: FUNCTION reserve_upi_checkout(p_package_id uuid, p_duration_days integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.reserve_upi_checkout(p_package_id uuid, p_duration_days integer) IS 'Creates the member''s pending UPI payment from the server-side quote. Amount and gym are never client-supplied.';


--
-- Name: reserve_upi_checkout(uuid, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserve_upi_checkout(p_package_id uuid, p_duration_days integer DEFAULT NULL::integer, p_method text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
$$;


--
-- Name: FUNCTION reserve_upi_checkout(p_package_id uuid, p_duration_days integer, p_method text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.reserve_upi_checkout(p_package_id uuid, p_duration_days integer, p_method text) IS 'Reserves a pending payment; the optional method picks one of the gym''s enabled UPI rails (google_pay/phonepe/paytm) or the legacy general UPI.';


--
-- Name: revoke_gym_qr_code(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revoke_gym_qr_code(p_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  update public.gym_qr_codes
     set is_active = false,
         revoked_at = now()
   where id = p_id
     and revoked_at is null;

  return found;
end;
$$;


--
-- Name: submit_membership_payment(uuid, text, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_membership_payment(p_payment_id uuid, p_provider_payment_id text, p_paid_amount_inr integer, p_provider_order_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: submit_payment_screenshot(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_payment_screenshot(p_payment_id uuid, p_path text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: submit_upi_payment_reference(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_upi_payment_reference(p_payment_id uuid, p_reference text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: FUNCTION submit_upi_payment_reference(p_payment_id uuid, p_reference text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.submit_upi_payment_reference(p_payment_id uuid, p_reference text) IS 'Records the member''s claimed UTR. Never approves the payment or activates a membership.';


--
-- Name: touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


--
-- Name: validate_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_profile() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'storage', 'pg_temp'
    AS $$
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
$$;


--
-- Name: admin_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    gym_id uuid NOT NULL,
    kind text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    user_id uuid,
    membership_id uuid,
    is_read boolean DEFAULT false NOT NULL,
    read_at timestamp with time zone,
    read_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: announcements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.announcements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    body text,
    kind public.announcement_kind DEFAULT 'info'::public.announcement_kind NOT NULL,
    starts_on date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date NOT NULL,
    ends_on date,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    gym_id uuid NOT NULL,
    CONSTRAINT announcements_dates_ordered CHECK (((ends_on IS NULL) OR (ends_on >= starts_on))),
    CONSTRAINT announcements_title_not_blank CHECK ((length(btrim(title)) > 0))
);


--
-- Name: COLUMN announcements.updated_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.announcements.updated_at IS 'Last edit timestamp used by the admin calendar and future realtime invalidation.';


--
-- Name: attendance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attendance (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    check_in_at timestamp with time zone DEFAULT now() NOT NULL,
    check_in_date date GENERATED ALWAYS AS (((check_in_at AT TIME ZONE 'Asia/Kolkata'::text))::date) STORED,
    source public.attendance_source DEFAULT 'qr'::public.attendance_source NOT NULL,
    gym_qr_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: COLUMN attendance.check_in_date; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.attendance.check_in_date IS 'Generated in Asia/Kolkata so "one check-in per day" is enforced on the gym calendar.';


--
-- Name: gym_join_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gym_join_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    gym_id uuid NOT NULL,
    user_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_at timestamp with time zone,
    decided_by uuid,
    CONSTRAINT gym_join_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'declined'::text])))
);


--
-- Name: gym_payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gym_payment_methods (
    gym_id uuid NOT NULL,
    method text NOT NULL,
    is_enabled boolean DEFAULT false NOT NULL,
    upi_id text,
    payee_name text,
    qr_path text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT gym_payment_methods_method_valid CHECK ((method = ANY (ARRAY['google_pay'::text, 'phonepe'::text, 'paytm'::text, 'upi'::text])))
);


--
-- Name: TABLE gym_payment_methods; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.gym_payment_methods IS 'One row per gym and payment rail. UPI ID and QR path are independent: either, both, or neither.';


--
-- Name: COLUMN gym_payment_methods.method; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gym_payment_methods.method IS 'google_pay | phonepe | paytm | upi (general UPI).';


--
-- Name: COLUMN gym_payment_methods.qr_path; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gym_payment_methods.qr_path IS 'Object path inside gym-payment-qr. Always prefixed with the owning gym id.';


--
-- Name: gym_qr_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gym_qr_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    label text NOT NULL,
    token_hash text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    gym_id uuid,
    token_value text,
    CONSTRAINT gym_qr_codes_label_not_blank CHECK ((length(btrim(label)) > 0))
);


--
-- Name: TABLE gym_qr_codes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.gym_qr_codes IS 'Printed front-desk QR codes. The raw token is returned once by create_gym_qr_code(); only its hash is kept.';


--
-- Name: COLUMN gym_qr_codes.token_hash; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gym_qr_codes.token_hash IS 'Lowercase hex SHA-256 of the raw QR token.';


--
-- Name: COLUMN gym_qr_codes.token_value; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gym_qr_codes.token_value IS 'Printable raw token for the active gym QR. Only exposed through the admin RPC, never to members.';


--
-- Name: gym_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gym_settings (
    id smallint DEFAULT 1 NOT NULL,
    name text DEFAULT 'FitDesk Performance Club'::text NOT NULL,
    address text,
    open_time time without time zone DEFAULT '05:00:00'::time without time zone NOT NULL,
    close_time time without time zone DEFAULT '23:00:00'::time without time zone NOT NULL,
    closed_weekdays smallint[] DEFAULT '{0}'::smallint[] NOT NULL,
    contact_phone text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT gym_settings_singleton CHECK ((id = 1)),
    CONSTRAINT gym_settings_weekdays_valid CHECK ((closed_weekdays <@ ARRAY[(0)::smallint, (1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint]))
);


--
-- Name: COLUMN gym_settings.closed_weekdays; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gym_settings.closed_weekdays IS '0 = Sunday … 6 = Saturday, in Asia/Kolkata.';


--
-- Name: gyms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gyms (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    slug text NOT NULL,
    name text NOT NULL,
    upi_id text,
    upi_payee_name text,
    payment_qr_path text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    is_open boolean DEFAULT true NOT NULL,
    shutter_changed_at timestamp with time zone,
    attendance_qr_months integer DEFAULT 3 NOT NULL,
    attendance_qr_rotated_at timestamp with time zone,
    join_code text,
    CONSTRAINT gyms_attendance_qr_months_valid CHECK ((attendance_qr_months = ANY (ARRAY[1, 3, 6, 12])))
);


--
-- Name: TABLE gyms; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.gyms IS 'One row per gym. Holds the gym-owned UPI recipient and QR used for direct payments.';


--
-- Name: COLUMN gyms.is_open; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gyms.is_open IS 'Manual shutter state controlled by the admin dashboard. Future member-app sync reads this value.';


--
-- Name: COLUMN gyms.attendance_qr_months; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.gyms.attendance_qr_months IS 'Recommended attendance-QR rotation cadence in months. Rotation is never required daily.';


--
-- Name: membership_pauses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.membership_pauses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    membership_id uuid NOT NULL,
    gym_id uuid NOT NULL,
    paused_at timestamp with time zone DEFAULT now() NOT NULL,
    paused_by uuid,
    reason text,
    resumed_at timestamp with time zone,
    resumed_by uuid,
    paused_days integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    package_id uuid NOT NULL,
    starts_on date NOT NULL,
    ends_on date NOT NULL,
    price_paid_inr integer DEFAULT 0 NOT NULL,
    fine_paid_inr integer DEFAULT 0 NOT NULL,
    status public.membership_status DEFAULT 'active'::public.membership_status NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    gym_id uuid NOT NULL,
    cancelled_at timestamp with time zone,
    cancelled_by uuid,
    cancellation_reason text,
    paused_at timestamp with time zone,
    paused_by uuid,
    pause_reason text,
    resumed_at timestamp with time zone,
    resumed_by uuid,
    total_paused_days integer DEFAULT 0 NOT NULL,
    paused_until date,
    CONSTRAINT memberships_amounts_non_negative CHECK (((price_paid_inr >= 0) AND (fine_paid_inr >= 0))),
    CONSTRAINT memberships_dates_ordered CHECK ((ends_on >= starts_on))
);


--
-- Name: TABLE memberships; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.memberships IS 'Immutable member entitlements. Rows are written only by the payment activation function.';


--
-- Name: COLUMN memberships.gym_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.memberships.gym_id IS 'Gym this membership belongs to. Derived from the package, never client input.';


--
-- Name: packages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.packages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    duration_days integer NOT NULL,
    price_inr integer NOT NULL,
    pricing_mode public.pricing_mode DEFAULT 'fixed'::public.pricing_mode NOT NULL,
    min_days integer,
    max_days integer,
    is_active boolean DEFAULT true NOT NULL,
    is_recommended boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    gym_id uuid DEFAULT '7a1d0d7e-0000-4000-8000-000000000001'::uuid NOT NULL,
    duration_months integer,
    CONSTRAINT packages_duration_months_valid CHECK (((duration_months IS NULL) OR ((duration_months >= 1) AND (duration_months <= 24)))),
    CONSTRAINT packages_duration_positive CHECK ((duration_days > 0)),
    CONSTRAINT packages_name_not_blank CHECK ((length(btrim(name)) > 0)),
    CONSTRAINT packages_per_day_bounds CHECK (((pricing_mode <> 'per_day'::public.pricing_mode) OR ((min_days IS NOT NULL) AND (max_days IS NOT NULL) AND (min_days > 0) AND (max_days >= min_days)))),
    CONSTRAINT packages_price_non_negative CHECK ((price_inr >= 0))
);


--
-- Name: COLUMN packages.price_inr; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.packages.price_inr IS 'Fixed plans: total price. Per-day plans: price for one day.';


--
-- Name: COLUMN packages.duration_months; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.packages.duration_months IS 'Admin-facing duration. duration_days remains the canonical value consumed by the member app.';


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    membership_id uuid,
    package_id uuid NOT NULL,
    duration_days integer NOT NULL,
    base_amount_inr integer NOT NULL,
    fine_amount_inr integer DEFAULT 0 NOT NULL,
    total_amount_inr integer NOT NULL,
    status public.payment_status DEFAULT 'pending'::public.payment_status NOT NULL,
    provider text DEFAULT 'upi'::text NOT NULL,
    provider_order_id text,
    provider_payment_id text,
    failure_reason text,
    quote jsonb,
    paid_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    legacy_status text,
    reconciliation_required boolean DEFAULT false NOT NULL,
    reconciliation_reason text,
    reviewed_at timestamp with time zone,
    reviewed_by uuid,
    review_note text,
    checkout_state text DEFAULT 'open'::text NOT NULL,
    refund_status text DEFAULT 'not_required'::text NOT NULL,
    refund_note text,
    refunded_at timestamp with time zone,
    refunded_by uuid,
    gym_id uuid NOT NULL,
    upi_reference text,
    upi_submitted_at timestamp with time zone,
    payee_upi_id text,
    screenshot_path text,
    CONSTRAINT payments_amounts_valid CHECK (((base_amount_inr >= 0) AND (fine_amount_inr >= 0) AND (total_amount_inr = (base_amount_inr + fine_amount_inr)))),
    CONSTRAINT payments_checkout_state_valid CHECK ((checkout_state = ANY (ARRAY['open'::text, 'verifying'::text, 'submitted'::text, 'reconciliation_required'::text, 'abandoned'::text]))),
    CONSTRAINT payments_duration_positive CHECK ((duration_days > 0)),
    CONSTRAINT payments_refund_status_valid CHECK ((refund_status = ANY (ARRAY['not_required'::text, 'pending_manual_refund'::text, 'refunded'::text]))),
    CONSTRAINT payments_upi_reference_format CHECK (((upi_reference IS NULL) OR (upi_reference ~ '^[A-Z0-9]{6,40}$'::text)))
);


--
-- Name: TABLE payments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.payments IS 'Server-created renewal orders. The browser can read its own receipts but can never insert or update a payment.';


--
-- Name: COLUMN payments.status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.status IS 'Manual review state: pending until an Admin-role user approves or declines. Only the admin_review_payment() function may change it.';


--
-- Name: COLUMN payments.paid_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.paid_at IS 'When the gateway captured the payment. It does not grant membership access.';


--
-- Name: COLUMN payments.legacy_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.legacy_status IS 'Original status from the pre-approval enum. Preserves failed/refunded/cancelled history.';


--
-- Name: COLUMN payments.reconciliation_required; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.reconciliation_required IS 'True when a payment may have been captured but cannot be safely approved or declined without manual Razorpay reconciliation.';


--
-- Name: COLUMN payments.reviewed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.reviewed_at IS 'When an Admin-role user approved or declined this payment.';


--
-- Name: COLUMN payments.checkout_state; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.checkout_state IS 'Checkout lifecycle: open -> verifying -> submitted, or reconciliation_required / abandoned.';


--
-- Name: COLUMN payments.refund_status; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.refund_status IS 'Manual refund tracking. FitDesk never calls a live refund API.';


--
-- Name: COLUMN payments.gym_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.gym_id IS 'Gym the money is owed to. Set server-side from the member profile.';


--
-- Name: COLUMN payments.upi_reference; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.upi_reference IS 'UTR / transaction reference claimed by the member. NOT proof of payment.';


--
-- Name: COLUMN payments.payee_upi_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.payee_upi_id IS 'UPI ID recorded when the member submitted the reference, for manual verification.';


--
-- Name: COLUMN payments.screenshot_path; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.payments.screenshot_path IS 'Optional member-uploaded proof in the private payment-proofs bucket. NOT proof of payment.';


--
-- Name: admin_notifications admin_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_notifications
    ADD CONSTRAINT admin_notifications_pkey PRIMARY KEY (id);


--
-- Name: announcements announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_pkey PRIMARY KEY (id);


--
-- Name: attendance attendance_one_per_ist_day; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_one_per_ist_day UNIQUE (user_id, check_in_date);


--
-- Name: attendance attendance_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_pkey PRIMARY KEY (id);


--
-- Name: gym_join_requests gym_join_requests_gym_id_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_join_requests
    ADD CONSTRAINT gym_join_requests_gym_id_user_id_key UNIQUE (gym_id, user_id);


--
-- Name: gym_join_requests gym_join_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_join_requests
    ADD CONSTRAINT gym_join_requests_pkey PRIMARY KEY (id);


--
-- Name: gym_payment_methods gym_payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_payment_methods
    ADD CONSTRAINT gym_payment_methods_pkey PRIMARY KEY (gym_id, method);


--
-- Name: gym_qr_codes gym_qr_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_qr_codes
    ADD CONSTRAINT gym_qr_codes_pkey PRIMARY KEY (id);


--
-- Name: gym_qr_codes gym_qr_codes_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_qr_codes
    ADD CONSTRAINT gym_qr_codes_token_hash_key UNIQUE (token_hash);


--
-- Name: gym_settings gym_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_settings
    ADD CONSTRAINT gym_settings_pkey PRIMARY KEY (id);


--
-- Name: gyms gyms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gyms
    ADD CONSTRAINT gyms_pkey PRIMARY KEY (id);


--
-- Name: gyms gyms_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gyms
    ADD CONSTRAINT gyms_slug_key UNIQUE (slug);


--
-- Name: membership_pauses membership_pauses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_pauses
    ADD CONSTRAINT membership_pauses_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: packages packages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: admin_notifications_expired_unpaid_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX admin_notifications_expired_unpaid_unique ON public.admin_notifications USING btree (gym_id, membership_id, kind, ((payload ->> 'expiry_date'::text))) WHERE (kind = 'membership_expired_unpaid'::text);


--
-- Name: admin_notifications_gym_read_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX admin_notifications_gym_read_idx ON public.admin_notifications USING btree (gym_id, is_read, created_at DESC);


--
-- Name: announcements_active_dates_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcements_active_dates_idx ON public.announcements USING btree (is_active, starts_on, ends_on);


--
-- Name: announcements_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcements_created_idx ON public.announcements USING btree (created_at DESC);


--
-- Name: announcements_gym_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX announcements_gym_active_idx ON public.announcements USING btree (gym_id, is_active, starts_on);


--
-- Name: announcements_one_active_closure_per_gym_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX announcements_one_active_closure_per_gym_date ON public.announcements USING btree (gym_id, starts_on) WHERE ((kind = 'closure'::public.announcement_kind) AND (is_active = true));


--
-- Name: attendance_date_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX attendance_date_idx ON public.attendance USING btree (check_in_date);


--
-- Name: attendance_user_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX attendance_user_time_idx ON public.attendance USING btree (user_id, check_in_at DESC);


--
-- Name: gym_join_requests_gym_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gym_join_requests_gym_status_idx ON public.gym_join_requests USING btree (gym_id, status, requested_at DESC);


--
-- Name: gym_join_requests_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gym_join_requests_user_idx ON public.gym_join_requests USING btree (user_id);


--
-- Name: gym_qr_codes_gym_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX gym_qr_codes_gym_active_idx ON public.gym_qr_codes USING btree (gym_id, is_active, created_at DESC);


--
-- Name: gyms_join_code_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX gyms_join_code_unique ON public.gyms USING btree (join_code);


--
-- Name: membership_pauses_gym_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX membership_pauses_gym_idx ON public.membership_pauses USING btree (gym_id);


--
-- Name: membership_pauses_membership_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX membership_pauses_membership_idx ON public.membership_pauses USING btree (membership_id, paused_at DESC);


--
-- Name: memberships_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memberships_active_idx ON public.memberships USING btree (user_id, status, ends_on DESC);


--
-- Name: memberships_gym_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memberships_gym_user_idx ON public.memberships USING btree (gym_id, user_id, ends_on DESC);


--
-- Name: memberships_user_ends_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memberships_user_ends_idx ON public.memberships USING btree (user_id, ends_on DESC);


--
-- Name: packages_active_sort_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX packages_active_sort_idx ON public.packages USING btree (is_active, sort_order, name);


--
-- Name: packages_gym_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX packages_gym_idx ON public.packages USING btree (gym_id, sort_order);


--
-- Name: payments_gym_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_gym_created_idx ON public.payments USING btree (gym_id, created_at DESC);


--
-- Name: payments_one_active_checkout_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX payments_one_active_checkout_per_user ON public.payments USING btree (user_id) WHERE ((status = 'pending'::public.payment_status) AND (checkout_state = ANY (ARRAY['open'::text, 'verifying'::text, 'submitted'::text])));


--
-- Name: payments_pending_queue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_pending_queue_idx ON public.payments USING btree (created_at) WHERE ((status = 'pending'::public.payment_status) AND (provider_payment_id IS NOT NULL));


--
-- Name: payments_provider_order_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX payments_provider_order_unique ON public.payments USING btree (provider_order_id) WHERE (provider_order_id IS NOT NULL);


--
-- Name: payments_provider_payment_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX payments_provider_payment_unique ON public.payments USING btree (provider_payment_id) WHERE (provider_payment_id IS NOT NULL);


--
-- Name: payments_reconciliation_queue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_reconciliation_queue_idx ON public.payments USING btree (created_at) WHERE (reconciliation_required = true);


--
-- Name: payments_refund_queue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_refund_queue_idx ON public.payments USING btree (created_at) WHERE (refund_status = 'pending_manual_refund'::text);


--
-- Name: payments_status_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_status_created_idx ON public.payments USING btree (status, created_at DESC);


--
-- Name: payments_user_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payments_user_created_idx ON public.payments USING btree (user_id, created_at DESC);


--
-- Name: profiles_gym_phone_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profiles_gym_phone_unique ON public.profiles USING btree (gym_id, phone) WHERE (phone <> ''::text);


--
-- Name: announcements announcements_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER announcements_touch_updated_at BEFORE UPDATE ON public.announcements FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: gym_payment_methods gym_payment_methods_normalize; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER gym_payment_methods_normalize BEFORE INSERT OR UPDATE ON public.gym_payment_methods FOR EACH ROW EXECUTE FUNCTION public.normalize_gym_payment_method();


--
-- Name: gym_settings gym_settings_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER gym_settings_touch_updated_at BEFORE UPDATE ON public.gym_settings FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: gyms gyms_join_code_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER gyms_join_code_trigger BEFORE INSERT OR UPDATE OF join_code ON public.gyms FOR EACH ROW EXECUTE FUNCTION public.handle_gym_join_code();


--
-- Name: gyms gyms_normalize_payment_settings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER gyms_normalize_payment_settings BEFORE INSERT OR UPDATE ON public.gyms FOR EACH ROW EXECUTE FUNCTION public.normalize_gym_payment_settings();


--
-- Name: memberships memberships_fill_gym; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memberships_fill_gym BEFORE INSERT OR UPDATE OF package_id ON public.memberships FOR EACH ROW EXECUTE FUNCTION public.fill_membership_gym();


--
-- Name: memberships memberships_guard_period; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memberships_guard_period BEFORE INSERT OR UPDATE OF user_id, starts_on, ends_on ON public.memberships FOR EACH ROW EXECUTE FUNCTION public.guard_membership_period();


--
-- Name: memberships memberships_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER memberships_touch_updated_at BEFORE UPDATE ON public.memberships FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: packages packages_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER packages_touch_updated_at BEFORE UPDATE ON public.packages FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: payments payments_guard_review; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payments_guard_review BEFORE UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.guard_payment_review();


--
-- Name: payments payments_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payments_touch_updated_at BEFORE UPDATE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();


--
-- Name: profiles profiles_validate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER profiles_validate BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.validate_profile();


--
-- Name: admin_notifications admin_notifications_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_notifications
    ADD CONSTRAINT admin_notifications_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE CASCADE;


--
-- Name: admin_notifications admin_notifications_membership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_notifications
    ADD CONSTRAINT admin_notifications_membership_id_fkey FOREIGN KEY (membership_id) REFERENCES public.memberships(id) ON DELETE SET NULL;


--
-- Name: admin_notifications admin_notifications_read_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_notifications
    ADD CONSTRAINT admin_notifications_read_by_fkey FOREIGN KEY (read_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: admin_notifications admin_notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_notifications
    ADD CONSTRAINT admin_notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: announcements announcements_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.announcements
    ADD CONSTRAINT announcements_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE CASCADE;


--
-- Name: attendance attendance_gym_qr_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_gym_qr_id_fkey FOREIGN KEY (gym_qr_id) REFERENCES public.gym_qr_codes(id) ON DELETE SET NULL;


--
-- Name: attendance attendance_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendance
    ADD CONSTRAINT attendance_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: gym_join_requests gym_join_requests_decided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_join_requests
    ADD CONSTRAINT gym_join_requests_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: gym_join_requests gym_join_requests_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_join_requests
    ADD CONSTRAINT gym_join_requests_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE CASCADE;


--
-- Name: gym_join_requests gym_join_requests_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_join_requests
    ADD CONSTRAINT gym_join_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: gym_payment_methods gym_payment_methods_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_payment_methods
    ADD CONSTRAINT gym_payment_methods_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE CASCADE;


--
-- Name: gym_qr_codes gym_qr_codes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_qr_codes
    ADD CONSTRAINT gym_qr_codes_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: gym_qr_codes gym_qr_codes_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gym_qr_codes
    ADD CONSTRAINT gym_qr_codes_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE CASCADE;


--
-- Name: membership_pauses membership_pauses_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_pauses
    ADD CONSTRAINT membership_pauses_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE CASCADE;


--
-- Name: membership_pauses membership_pauses_membership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_pauses
    ADD CONSTRAINT membership_pauses_membership_id_fkey FOREIGN KEY (membership_id) REFERENCES public.memberships(id) ON DELETE CASCADE;


--
-- Name: membership_pauses membership_pauses_paused_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_pauses
    ADD CONSTRAINT membership_pauses_paused_by_fkey FOREIGN KEY (paused_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: membership_pauses membership_pauses_resumed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_pauses
    ADD CONSTRAINT membership_pauses_resumed_by_fkey FOREIGN KEY (resumed_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: memberships memberships_cancelled_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_cancelled_by_fkey FOREIGN KEY (cancelled_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: memberships memberships_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE RESTRICT;


--
-- Name: memberships memberships_package_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_package_id_fkey FOREIGN KEY (package_id) REFERENCES public.packages(id) ON DELETE RESTRICT;


--
-- Name: memberships memberships_paused_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_paused_by_fkey FOREIGN KEY (paused_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: memberships memberships_resumed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_resumed_by_fkey FOREIGN KEY (resumed_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: memberships memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: packages packages_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packages
    ADD CONSTRAINT packages_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE RESTRICT;


--
-- Name: payments payments_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE RESTRICT;


--
-- Name: payments payments_membership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_membership_id_fkey FOREIGN KEY (membership_id) REFERENCES public.memberships(id) ON DELETE SET NULL;


--
-- Name: payments payments_package_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_package_id_fkey FOREIGN KEY (package_id) REFERENCES public.packages(id) ON DELETE RESTRICT;


--
-- Name: payments payments_refunded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_refunded_by_fkey FOREIGN KEY (refunded_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: payments payments_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: payments payments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_gym_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_gym_id_fkey FOREIGN KEY (gym_id) REFERENCES public.gyms(id) ON DELETE RESTRICT;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: admin_notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admin_notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_notifications admin_notifications_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admin_notifications_admin_all ON public.admin_notifications TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = auth.uid()) AND (p.is_admin = true) AND (p.gym_id = admin_notifications.gym_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = auth.uid()) AND (p.is_admin = true) AND (p.gym_id = admin_notifications.gym_id)))));


--
-- Name: announcements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;

--
-- Name: announcements announcements_select_published; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY announcements_select_published ON public.announcements FOR SELECT TO authenticated USING (((is_active = true) AND (starts_on <= ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date) AND (gym_id = ( SELECT p.gym_id
   FROM public.profiles p
  WHERE (p.id = ( SELECT auth.uid() AS uid))))));


--
-- Name: attendance; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attendance ENABLE ROW LEVEL SECURITY;

--
-- Name: attendance attendance_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY attendance_select_own ON public.attendance FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: gym_join_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gym_join_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: gym_join_requests gym_join_requests_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY gym_join_requests_select_own ON public.gym_join_requests FOR SELECT TO authenticated USING ((user_id = auth.uid()));


--
-- Name: gym_payment_methods; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gym_payment_methods ENABLE ROW LEVEL SECURITY;

--
-- Name: gym_qr_codes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gym_qr_codes ENABLE ROW LEVEL SECURITY;

--
-- Name: gym_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gym_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: gym_settings gym_settings_select_authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY gym_settings_select_authenticated ON public.gym_settings FOR SELECT TO authenticated USING (true);


--
-- Name: gyms; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.gyms ENABLE ROW LEVEL SECURITY;

--
-- Name: membership_pauses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.membership_pauses ENABLE ROW LEVEL SECURITY;

--
-- Name: membership_pauses membership_pauses_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY membership_pauses_admin_all ON public.membership_pauses TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = auth.uid()) AND (p.is_admin = true) AND (p.gym_id = membership_pauses.gym_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.profiles p
  WHERE ((p.id = auth.uid()) AND (p.is_admin = true) AND (p.gym_id = membership_pauses.gym_id)))));


--
-- Name: memberships; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: memberships memberships_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY memberships_select_own ON public.memberships FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: packages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.packages ENABLE ROW LEVEL SECURITY;

--
-- Name: packages packages_select_active; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packages_select_active ON public.packages FOR SELECT TO authenticated USING (((is_active = true) AND (gym_id = ( SELECT profiles.gym_id
   FROM public.profiles
  WHERE (profiles.id = ( SELECT auth.uid() AS uid))))));


--
-- Name: payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

--
-- Name: payments payments_select_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payments_select_admin ON public.payments FOR SELECT TO authenticated USING (( SELECT public.is_admin() AS is_admin));


--
-- Name: payments payments_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payments_select_own ON public.payments FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = user_id));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select_own ON public.profiles FOR SELECT TO authenticated USING ((( SELECT auth.uid() AS uid) = id));


--
-- Name: profiles profiles_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_update_own ON public.profiles FOR UPDATE TO authenticated USING ((( SELECT auth.uid() AS uid) = id)) WITH CHECK ((( SELECT auth.uid() AS uid) = id));


--
-- PostgreSQL database dump complete
--

\unrestrict QebnYjJYMZVnpnYDB8KEhEaBscj1lsxbGuHbOGaiXpbke4hkcKYUtez8eRjFhIo

