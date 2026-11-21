begin;
create or replace function public.admin_dashboard_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path to public, pg_temp
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
         and coalesce(p.is_deactivated, false) = false
    ),
    'deactivated_members', (
      select count(*)::integer
        from public.profiles p
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = true
    ),
    'active_members', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
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
    'expiring_1d', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.ends_on = v_today + 1
    ),
    'expiring_3d', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.ends_on between v_today + 1 and v_today + 3
    ),
    'expiring_7d', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.ends_on between v_today + 1 and v_today + 7
    ),
    'expired', (
      select count(distinct m.user_id)::integer
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where p.gym_id = v_gym_id
         and p.is_admin = false
         and coalesce(p.is_deactivated, false) = false
         and m.status = 'active'
         and m.ends_on < v_today
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

-- Idempotent expiry notification generator
create or replace function public.admin_generate_expiry_notifications()
returns integer
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_count integer := 0;
  r record;
begin
  for r in
    select m.user_id, m.ends_on, p.full_name
      from public.memberships m
      join public.profiles p on p.id = m.user_id
     where p.gym_id = v_gym_id
       and p.is_admin = false
       and coalesce(p.is_deactivated, false) = false
       and m.status = 'active'
       and m.ends_on between v_today and v_today + 7
  loop
    if not exists (
      select 1 from public.admin_notifications n
       where n.gym_id = v_gym_id
         and n.kind = 'membership_expiry'
         and n.user_id = r.user_id
         and (n.payload ->> 'ends_on')::date = r.ends_on
    ) then
      insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id)
      values (
        v_gym_id,
        'membership_expiry',
        'Membership expiring soon',
        coalesce(r.full_name, 'Member') || ' expires on ' || r.ends_on::text,
        jsonb_build_object('user_id', r.user_id, 'ends_on', r.ends_on, 'days_left', (r.ends_on - v_today)),
        r.user_id
      );
      v_count := v_count + 1;
    end if;
  end loop;

  -- expired notifications
  for r in
    select m.user_id, m.ends_on, p.full_name
      from public.memberships m
      join public.profiles p on p.id = m.user_id
     where p.gym_id = v_gym_id
       and p.is_admin = false
       and coalesce(p.is_deactivated, false) = false
       and m.status = 'active'
       and m.ends_on < v_today
  loop
    if not exists (
      select 1 from public.admin_notifications n
       where n.gym_id = v_gym_id
         and n.kind = 'membership_expired'
         and n.user_id = r.user_id
         and (n.payload ->> 'ends_on')::date = r.ends_on
    ) then
      insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id)
      values (
        v_gym_id,
        'membership_expired',
        'Membership expired',
        coalesce(r.full_name, 'Member') || ' expired on ' || r.ends_on::text,
        jsonb_build_object('user_id', r.user_id, 'ends_on', r.ends_on),
        r.user_id
      );
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.admin_generate_expiry_notifications() from public, anon, authenticated;
grant execute on function public.admin_generate_expiry_notifications() to authenticated;

commit;