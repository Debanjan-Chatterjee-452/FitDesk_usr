-- 20261124000700_fitdesk_realtime_shutter_closures.sql
-- Cross-app state sync for the gym shutter and the closure calendar.
--   * gyms must be published for Realtime so an admin shutter toggle can
--     reach already-open member apps.
--   * members need a gym-scoped closure feed (admin_list_closures is admin-only
--     and member_gym_overview only returned today's announcements).

-- 1. Publish gyms. This is what lets postgres_changes on public.gyms fire.
do $$
begin
  if not exists (
    select 1
      from pg_publication_tables
     where pubname = 'supabase_realtime' and tablename = 'gyms'
  ) then
    alter publication supabase_realtime add table public.gyms;
  end if;
end $$;

-- 2. Allow RLS-protected reads of the member's own gym. Realtime checks RLS
--    before delivering an event, so without a policy/GRANT no events arrive.
drop policy if exists gyms_select_member on public.gyms;
create policy gyms_select_member on public.gyms
for select to authenticated
using (
  exists (
    select 1 from public.profiles p
     where p.id = auth.uid()
       and p.gym_id = public.gyms.id
  )
);

grant select on public.gyms to authenticated;

-- 3. Member-facing closure feed for the Activity calendar. Returns every
--    active closure/holiday in the requested window for the caller's gym only.
drop function if exists public.member_gym_closures(date, date);

create or replace function public.member_gym_closures(
  p_from date default null,
  p_to date default null
)
returns table (
  closure_date date,
  title text,
  reason text,
  kind text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_gym_id uuid;
  v_from date;
  v_to date;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select p.gym_id into v_gym_id
    from public.profiles p
   where p.id = v_user;

  if v_gym_id is null then
    return;
  end if;

  v_from := case
    when p_from is not null then p_from
    else (now() at time zone 'Asia/Kolkata')::date
  end;
  v_to := case
    when p_to is not null then p_to
    else v_from + interval '12 months'
  end;

  return query
  select a.starts_on,
         a.title,
         coalesce(nullif(btrim(coalesce(a.body, '')), ''), a.title),
         a.kind::text
    from public.announcements a
   where a.gym_id = v_gym_id
     and a.is_active = true
     and a.kind in ('closure', 'holiday')
     and a.starts_on >= v_from
     and a.starts_on <= v_to
   order by a.starts_on;
end;
$$;

revoke all on function public.member_gym_closures(date, date) from public, anon;
grant execute on function public.member_gym_closures(date, date) to authenticated;

notify pgrst, 'reload schema';
