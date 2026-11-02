-- FitDesk Admin — control-panel schema and admin-only RPC surface
--
-- Design rules:
--   * The member app keeps its narrow RLS policies. The admin website never
--     receives broad table grants; every admin read/write goes through a
--     SECURITY DEFINER function that checks profiles.is_admin.
--   * Every mutable domain table carries updated_at (or a creation timestamp
--     for append-only QR rotations) so a future realtime/socket bridge can
--     invalidate exactly one domain.
--   * Attendance stays a single gym-wide QR. Regeneration revokes the old QR
--     and creates one replacement; check-in still writes one row per member
--     per IST day.
--   * Closures are stored in public.announcements as kind='closure', which is
--     already the source of truth used by the member app's QR check-in.

-- The core migration installed an announcements_touch_updated_at trigger but
-- the column was never created. Add it before the closure RPC writes it.
alter table public.announcements
  add column if not exists updated_at timestamptz not null default now();

comment on column public.announcements.updated_at is
  'Last edit timestamp used by the admin calendar and future realtime invalidation.';

-- ---------------------------------------------------------------------------
-- Gym operating state + attendance QR rotation policy
-- ---------------------------------------------------------------------------
alter table public.gyms
  add column if not exists is_open boolean not null default true,
  add column if not exists shutter_changed_at timestamptz,
  add column if not exists attendance_qr_months integer not null default 3,
  add column if not exists attendance_qr_rotated_at timestamptz;

alter table public.gyms
  drop constraint if exists gyms_attendance_qr_months_valid;
alter table public.gyms
  add constraint gyms_attendance_qr_months_valid
  check (attendance_qr_months in (1, 3, 6, 12));

comment on column public.gyms.is_open is
  'Manual shutter state controlled by the admin dashboard. Future member-app sync reads this value.';
comment on column public.gyms.attendance_qr_months is
  'Recommended attendance-QR rotation cadence in months. Rotation is never required daily.';

-- ---------------------------------------------------------------------------
-- Package duration in months (the member app continues to use duration_days)
-- ---------------------------------------------------------------------------
alter table public.packages
  add column if not exists duration_months integer;

update public.packages
   set duration_months = greatest(1, round(duration_days::numeric / 30)::integer)
 where duration_months is null;

alter table public.packages
  drop constraint if exists packages_duration_months_valid;
alter table public.packages
  add constraint packages_duration_months_valid
  check (duration_months is null or duration_months between 1 and 24);

comment on column public.packages.duration_months is
  'Admin-facing duration. duration_days remains the canonical value consumed by the member app.';

-- ---------------------------------------------------------------------------
-- Attendance QR: gym scope + the printable token
--
-- token_hash remains the lookup key used by check_in_with_qr(). token_value is
-- required so an admin can re-open, download, or print the same QR later. The
-- table has no grants for authenticated members; token_value is only exposed
-- by admin_get_attendance_qr().
-- ---------------------------------------------------------------------------
alter table public.gym_qr_codes
  add column if not exists gym_id uuid references public.gyms (id) on delete cascade,
  add column if not exists token_value text;

update public.gym_qr_codes
   set gym_id = (select id from public.gyms where slug = 'fitdesk')
 where gym_id is null;

create index if not exists gym_qr_codes_gym_active_idx
  on public.gym_qr_codes (gym_id, is_active, created_at desc);

comment on column public.gym_qr_codes.token_value is
  'Printable raw token for the active gym QR. Only exposed through the admin RPC, never to members.';

-- ---------------------------------------------------------------------------
-- One active closure announcement per calendar date
-- ---------------------------------------------------------------------------
create unique index if not exists announcements_one_active_closure_per_date
  on public.announcements (starts_on)
  where kind = 'closure' and is_active = true;

-- ---------------------------------------------------------------------------
-- Admin guard
-- ---------------------------------------------------------------------------
create or replace function public.admin_assert()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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

comment on function public.admin_assert() is
  'Returns the signed-in admin''s gym id or raises. Used only inside SECURITY DEFINER RPCs.';

-- ---------------------------------------------------------------------------
-- Gym settings
-- ---------------------------------------------------------------------------
create or replace function public.admin_get_gym_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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

create or replace function public.admin_update_payment_settings(
  p_upi_id text,
  p_upi_payee_name text,
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
$$;

create or replace function public.admin_set_gym_open(p_open boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

-- ---------------------------------------------------------------------------
-- Dashboard metrics
-- ---------------------------------------------------------------------------
create or replace function public.admin_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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

-- ---------------------------------------------------------------------------
-- Packages
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_packages()
returns table (
  id uuid,
  name text,
  description text,
  duration_months integer,
  duration_days integer,
  price_inr integer,
  is_active boolean,
  is_recommended boolean,
  sort_order integer,
  created_at timestamptz,
  updated_at timestamptz
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

create or replace function public.admin_upsert_package(
  p_months integer,
  p_price_inr integer,
  p_name text default null,
  p_description text default null,
  p_id uuid default null,
  p_is_recommended boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

create or replace function public.admin_set_package_active(
  p_id uuid,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

-- ---------------------------------------------------------------------------
-- Members: one row per auth user, never one row per session/login
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Closure calendar (uses announcements, the member app's existing source)
-- ---------------------------------------------------------------------------
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
  perform v_gym_id;

  return query
  select a.starts_on,
         coalesce(nullif(btrim(a.body), ''), a.title),
         a.id
    from public.announcements a
   where a.kind = 'closure'
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
  perform v_gym_id;

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
     where kind = 'closure'
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
   where a.kind = 'closure'
     and a.starts_on = p_date
     and a.is_active = true
   order by a.created_at desc
   limit 1;

  if v_id is null then
    insert into public.announcements (title, body, kind, starts_on, ends_on, is_active)
    values (
      'Gym closed',
      coalesce(v_reason, 'Closed by the gym team.'),
      'closure',
      p_date,
      p_date,
      true
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

-- ---------------------------------------------------------------------------
-- Attendance QR: one active code for the whole gym
-- ---------------------------------------------------------------------------
create or replace function public.admin_get_attendance_qr()
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

create or replace function public.admin_rotate_attendance_qr(
  p_label text default 'Front desk'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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

create or replace function public.admin_set_attendance_rotation(
  p_months integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

-- ---------------------------------------------------------------------------
-- Storage: an admin may upload/replace only inside their own gym's folder.
-- The bucket itself remains public-read because members need to scan/download
-- the payment QR; no member write policy exists.
-- ---------------------------------------------------------------------------
drop policy if exists "gym_payment_qr_admin_select" on storage.objects;
drop policy if exists "gym_payment_qr_admin_insert" on storage.objects;
drop policy if exists "gym_payment_qr_admin_update" on storage.objects;
drop policy if exists "gym_payment_qr_admin_delete" on storage.objects;

create policy "gym_payment_qr_admin_select"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'gym-payment-qr'
    and (select public.is_admin())
  );

create policy "gym_payment_qr_admin_insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'gym-payment-qr'
    and (select public.is_admin())
    and (storage.foldername(name))[1] = (
      select p.gym_id::text from public.profiles p where p.id = (select auth.uid())
    )
  );

create policy "gym_payment_qr_admin_update"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'gym-payment-qr'
    and (select public.is_admin())
    and (storage.foldername(name))[1] = (
      select p.gym_id::text from public.profiles p where p.id = (select auth.uid())
    )
  )
  with check (
    bucket_id = 'gym-payment-qr'
    and (select public.is_admin())
    and (storage.foldername(name))[1] = (
      select p.gym_id::text from public.profiles p where p.id = (select auth.uid())
    )
  );

create policy "gym_payment_qr_admin_delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'gym-payment-qr'
    and (select public.is_admin())
    and (storage.foldername(name))[1] = (
      select p.gym_id::text from public.profiles p where p.id = (select auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- Grants: admin RPCs are executable by authenticated users and enforce the
-- admin check internally. The helper is not callable from the API.
-- ---------------------------------------------------------------------------
revoke all on function public.admin_assert() from public, anon, authenticated;
revoke all on function public.admin_get_gym_settings() from public, anon, authenticated;
revoke all on function public.admin_update_payment_settings(text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.admin_set_gym_open(boolean) from public, anon, authenticated;
revoke all on function public.admin_dashboard_stats() from public, anon, authenticated;
revoke all on function public.admin_list_packages() from public, anon, authenticated;
revoke all on function public.admin_upsert_package(integer, integer, text, text, uuid, boolean) from public, anon, authenticated;
revoke all on function public.admin_set_package_active(uuid, boolean) from public, anon, authenticated;
revoke all on function public.admin_list_members(text, text) from public, anon, authenticated;
revoke all on function public.admin_list_closures(date, date) from public, anon, authenticated;
revoke all on function public.admin_set_closure(date, boolean, text) from public, anon, authenticated;
revoke all on function public.admin_get_attendance_qr() from public, anon, authenticated;
revoke all on function public.admin_rotate_attendance_qr(text) from public, anon, authenticated;
revoke all on function public.admin_set_attendance_rotation(integer) from public, anon, authenticated;

grant execute on function public.admin_get_gym_settings() to authenticated;
grant execute on function public.admin_update_payment_settings(text, text, text, boolean) to authenticated;
grant execute on function public.admin_set_gym_open(boolean) to authenticated;
grant execute on function public.admin_dashboard_stats() to authenticated;
grant execute on function public.admin_list_packages() to authenticated;
grant execute on function public.admin_upsert_package(integer, integer, text, text, uuid, boolean) to authenticated;
grant execute on function public.admin_set_package_active(uuid, boolean) to authenticated;
grant execute on function public.admin_list_members(text, text) to authenticated;
grant execute on function public.admin_list_closures(date, date) to authenticated;
grant execute on function public.admin_set_closure(date, boolean, text) to authenticated;
grant execute on function public.admin_get_attendance_qr() to authenticated;
grant execute on function public.admin_rotate_attendance_qr(text) to authenticated;
grant execute on function public.admin_set_attendance_rotation(integer) to authenticated;

comment on function public.admin_list_members(text, text) is
  'One deduplicated row per auth user (not per login/session), with current plan and pending approval.';
comment on function public.admin_rotate_attendance_qr(text) is
  'Revokes the gym''s previous QR and returns a newly generated single attendance QR token.';
