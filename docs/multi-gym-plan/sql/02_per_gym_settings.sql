-- ============================================================================
-- FitDesk multi-gym SaaS — draft migration 02
-- One settings row per gym + member overview RPC
--
-- STATUS: DRAFT — DO NOT APPLY TO PRODUCTION WITHOUT APPROVAL.
-- ============================================================================

begin;

lock table public.gym_settings in share row exclusive mode;

-- ---------------------------------------------------------------------------
-- 1. Turn the singleton into one row per gym
-- ---------------------------------------------------------------------------
alter table public.gym_settings
  add column if not exists gym_id uuid references public.gyms (id) on delete cascade;

comment on column public.gym_settings.gym_id is
  'Gym this settings row belongs to. One row per gym.';

-- The old singleton row belongs to the original FitDesk gym.
update public.gym_settings
   set gym_id = '7a1d0d7e-0000-4000-8000-000000000001'::uuid
 where gym_id is null
   and id = 1;

-- Stop rather than guess if any other legacy row has no gym.
do $$
declare
  v_count integer;
begin
  select count(*) into v_count
    from public.gym_settings
   where gym_id is null;

  if v_count > 0 then
    raise exception
      'GYM_SETTINGS_AMBIGUOUS: % row(s) have no gym_id; resolve them manually before retrying',
      v_count;
  end if;
end;
$$;

-- The old surrogate id is no longer the tenant key. Keep the column for
-- compatibility but stop requiring it.
alter table public.gym_settings drop constraint if exists gym_settings_pkey;
alter table public.gym_settings alter column id drop default;
alter table public.gym_settings alter column id drop not null;
alter table public.gym_settings drop constraint if exists gym_settings_singleton;

create unique index if not exists gym_settings_gym_id_unique
  on public.gym_settings (gym_id);

alter table public.gym_settings alter column gym_id set not null;

-- Create independent defaults for every gym that does not have settings yet.
insert into public.gym_settings
  (gym_id, name, address, open_time, close_time, closed_weekdays, contact_phone)
select
  g.id,
  g.name,
  null,
  '05:00'::time,
  '23:00'::time,
  '{0}'::smallint[],
  null
from public.gyms g
where not exists (
  select 1 from public.gym_settings s where s.gym_id = g.id
);

-- ---------------------------------------------------------------------------
-- 2. RLS: a member can only read their own gym's settings
-- ---------------------------------------------------------------------------
drop policy if exists "gym_settings_select_authenticated" on public.gym_settings;
drop policy if exists "gym_settings_select_own_gym" on public.gym_settings;

create policy "gym_settings_select_own_gym"
  on public.gym_settings for select
  to authenticated
  using (
    gym_id = (
      select p.gym_id
        from public.profiles p
       where p.id = (select auth.uid())
    )
  );

revoke all on table public.gym_settings from anon, authenticated;
grant select on table public.gym_settings to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Member overview RPC
--    Returns the gym, its hours, and active announcements in one call.
--    SECURITY DEFINER because members cannot read public.gyms directly.
-- ---------------------------------------------------------------------------
create or replace function public.member_gym_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_gym_id uuid;
  v_gym public.gyms;
  v_settings public.gym_settings;
  v_announcements jsonb;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select gym_id into v_gym_id
    from public.profiles
   where id = v_user;

  if v_gym_id is null then
    return jsonb_build_object('status', 'no_gym');
  end if;

  select * into v_gym
    from public.gyms
   where id = v_gym_id;

  if not found then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  select * into v_settings
    from public.gym_settings
   where gym_id = v_gym_id;

  select coalesce(
           jsonb_agg(to_jsonb(a) order by a.created_at desc),
           '[]'::jsonb
         )
    into v_announcements
    from public.announcements a
   where a.gym_id = v_gym_id
     and a.is_active = true
     and a.starts_on <= v_today
     and (a.ends_on is null or a.ends_on >= v_today);

  return jsonb_build_object(
    'status', case when v_gym.is_active then 'active' else 'suspended' end,
    'gym_id', v_gym.id,
    'gym_name', v_gym.name,
    'is_open', v_gym.is_open,
    'settings', case
      when v_settings.gym_id is null then null
      else jsonb_build_object(
        'id', v_settings.id,
        'gym_id', v_settings.gym_id,
        'name', v_gym.name,
        'address', v_settings.address,
        'open_time', v_settings.open_time,
        'close_time', v_settings.close_time,
        'closed_weekdays', v_settings.closed_weekdays,
        'contact_phone', v_settings.contact_phone,
        'updated_at', v_settings.updated_at
      )
    end,
    'announcements', v_announcements
  );
end;
$$;

revoke all on function public.member_gym_overview() from public, anon, authenticated;
grant execute on function public.member_gym_overview() to authenticated;

commit;
