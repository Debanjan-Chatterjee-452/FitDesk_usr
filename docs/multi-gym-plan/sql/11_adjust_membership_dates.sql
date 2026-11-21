begin;
create or replace function public.admin_adjust_membership_dates(
  p_membership_id uuid,
  p_starts_on date
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_membership public.memberships;
  v_days integer;
  v_ends date;
begin
  if p_starts_on is null then
    raise exception 'START_DATE_REQUIRED' using errcode = '22023';
  end if;

  select m.* into v_membership
    from public.memberships m
   where m.id = p_membership_id
     and m.gym_id = v_gym_id;

  if not found then
    raise exception 'MEMBERSHIP_NOT_FOUND' using errcode = 'P0001';
  end if;

  select duration_days into v_days
    from public.packages
   where id = v_membership.package_id;

  if v_days is null or v_days < 1 then
    raise exception 'INVALID_PACKAGE_DURATION' using errcode = 'P0001';
  end if;

  v_ends := p_starts_on + (v_days - 1);

  update public.memberships
     set starts_on = p_starts_on,
         ends_on = v_ends,
         updated_at = now()
   where id = p_membership_id
     and gym_id = v_gym_id;

  insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id, membership_id)
  values (
    v_gym_id,
    'membership_adjusted',
    'Membership dates updated',
    'Membership ' || p_membership_id::text || ' start set to ' || p_starts_on::text || ', end ' || v_ends::text,
    jsonb_build_object('membership_id', p_membership_id, 'starts_on', p_starts_on, 'ends_on', v_ends, 'adjusted_by', auth.uid()),
    v_membership.user_id,
    p_membership_id
  );

  return jsonb_build_object(
    'membership_id', p_membership_id,
    'starts_on', p_starts_on,
    'ends_on', v_ends,
    'duration_days', v_days
  );
end;
$$;

revoke all on function public.admin_adjust_membership_dates(uuid, date) from public, anon, authenticated;
grant execute on function public.admin_adjust_membership_dates(uuid, date) to authenticated;

commit;