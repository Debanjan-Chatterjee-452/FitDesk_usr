-- ============================================================================
-- FitDesk multi-gym SaaS — draft migration 04
-- Tenant isolation hardening
--
-- STATUS: DRAFT — DO NOT APPLY TO PRODUCTION WITHOUT APPROVAL.
-- Tested against a cloned local Supabase database.
--
-- What this does:
--   1. Adds attendance.gym_id and backfills only verifiable rows.
--   2. Auto-fills attendance.gym_id on every future insert.
--   3. Blocks suspended gyms from admin RPCs and member check-in.
--   4. Scopes manual refunds to the admin's own gym.
--   5. Scopes payment-QR storage reads to the admin's own gym folder.
--   6. Makes QR check-in refuse members with no gym.
--
-- Rows that cannot be attributed safely are left NULL on purpose. Run
-- _report_ambiguous_attendance.sql afterwards and review the list.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. attendance.gym_id
-- ---------------------------------------------------------------------------
alter table public.attendance
  add column if not exists gym_id uuid references public.gyms (id) on delete restrict;

comment on column public.attendance.gym_id is
  'Gym the member checked in at. Backfilled only where the relationship is unambiguous.';

-- 1a. Strongest evidence: the attendance QR code itself carries the gym.
update public.attendance a
   set gym_id = q.gym_id
  from public.gym_qr_codes q
 where a.gym_id is null
   and a.gym_qr_id = q.id
   and q.gym_id is not null;

-- 1b. Next: exactly one membership covering the check-in date.
with candidates as (
  select
    a.id,
    (array_agg(distinct m.gym_id))[1] as gym_id,
    count(distinct m.gym_id) as gym_count
  from public.attendance a
  join public.memberships m
    on m.user_id = a.user_id
   and m.starts_on <= a.check_in_date
   and m.ends_on >= a.check_in_date
  where a.gym_id is null
    and m.gym_id is not null
  group by a.id
)
update public.attendance a
   set gym_id = c.gym_id
  from candidates c
 where a.id = c.id
   and c.gym_count = 1;

-- 1c. Last safe fallback: the member's current profile gym, but only when the
--     member's whole membership + payment history points at one single gym.
with history as (
  select
    a.id,
    p.gym_id,
    (
      select count(distinct m.gym_id)
        from public.memberships m
       where m.user_id = a.user_id
         and m.gym_id is not null
    ) + (
      select count(distinct pay.gym_id)
        from public.payments pay
       where pay.user_id = a.user_id
         and pay.gym_id is not null
    ) as gym_count
  from public.attendance a
  join public.profiles p on p.id = a.user_id
  where a.gym_id is null
    and p.gym_id is not null
)
update public.attendance a
   set gym_id = h.gym_id
  from history h
 where a.id = h.id
   and h.gym_count = 1;

create index if not exists attendance_gym_date_idx
  on public.attendance (gym_id, check_in_date);

-- 1d. Every future insert gets a gym automatically, even if a new write path
--     forgets to pass it.
create or replace function public.fill_attendance_gym()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.gym_id is null and new.gym_qr_id is not null then
    select q.gym_id into new.gym_id
      from public.gym_qr_codes q
     where q.id = new.gym_qr_id;
  end if;

  if new.gym_id is null then
    select p.gym_id into new.gym_id
      from public.profiles p
     where p.id = new.user_id;
  end if;

  return new;
end;
$$;

drop trigger if exists attendance_fill_gym on public.attendance;
create trigger attendance_fill_gym
  before insert on public.attendance
  for each row
  execute function public.fill_attendance_gym();

revoke all on function public.fill_attendance_gym() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Admin guard: suspended gyms are locked out
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
  v_active boolean;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select p.gym_id, g.is_active
    into v_gym_id, v_active
    from public.profiles p
    join public.gyms g on g.id = p.gym_id
   where p.id = auth.uid()
     and p.is_admin = true;

  if v_gym_id is null then
    raise exception 'ADMIN_REQUIRED' using errcode = '42501';
  end if;

  if not v_active then
    raise exception 'GYM_SUSPENDED' using errcode = 'P0001';
  end if;

  return v_gym_id;
end;
$$;

comment on function public.admin_assert() is
  'Returns the signed-in admin''s gym id or raises. Blocks suspended gyms and non-admins.';

-- ---------------------------------------------------------------------------
-- 3. Manual refunds are gym-scoped
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
  v_gym_id uuid := public.admin_assert();
  v_payment public.payments;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  select * into v_payment
    from public.payments
   where id = p_payment_id
     and gym_id = v_gym_id
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

revoke all on function public.admin_mark_payment_refunded(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_mark_payment_refunded(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Payment-QR reads are scoped to the admin's own gym folder
--    (the bucket stays public for member rendering; that is unchanged)
-- ---------------------------------------------------------------------------
drop policy if exists "gym_payment_qr_admin_select" on storage.objects;

create policy "gym_payment_qr_admin_select"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'gym-payment-qr'
    and (select public.is_admin())
    and (storage.foldername(name))[1] = (
      select p.gym_id::text from public.profiles p where p.id = (select auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- 5. QR check-in: require a gym and require it to be active
-- ---------------------------------------------------------------------------
create or replace function public.check_in_with_qr(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_qr public.gym_qr_codes;
  v_gym public.gyms;
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

  if v_profile.gym_id is null then
    raise exception 'GYM_NOT_ASSIGNED' using errcode = 'P0001';
  end if;

  select * into v_gym
    from public.gyms
   where id = v_profile.gym_id;

  if not found then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  if not v_gym.is_active then
    raise exception 'GYM_SUSPENDED' using errcode = 'P0001';
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
    select * into v_latest_membership
      from public.memberships
     where user_id = v_user
       and gym_id = v_profile.gym_id
     order by ends_on desc
     limit 1;

    if found and v_latest_membership.ends_on is not null
       and v_today >= (v_latest_membership.ends_on + 4) then
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

  v_gym_name := coalesce(v_gym.name, 'FitDesk');

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

  insert into public.attendance (user_id, check_in_at, source, gym_qr_id, gym_id)
  values (v_user, now(), 'qr', v_qr.id, v_profile.gym_id)
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

revoke all on function public.check_in_with_qr(text) from public, anon, authenticated;
grant execute on function public.check_in_with_qr(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Report: rows that still have no safe gym
-- ---------------------------------------------------------------------------
do $$
declare
  v_total integer;
  v_unassigned integer;
begin
  select count(*) into v_total from public.attendance;
  select count(*) into v_unassigned from public.attendance where gym_id is null;

  raise notice 'attendance backfill: % of % rows assigned, % need review',
    v_total - v_unassigned, v_total, v_unassigned;
end;
$$;

commit;
