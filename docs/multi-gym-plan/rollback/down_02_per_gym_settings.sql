-- Rollback for 02_per_gym_settings.sql
-- Keeps the original FitDesk settings row and removes the extra per-gym rows.
-- Deletes settings rows for gyms other than the original 'fitdesk' gym.
begin;

delete from public.gym_settings
 where gym_id is distinct from '7a1d0d7e-0000-4000-8000-000000000001'::uuid;

update public.gym_settings
   set id = 1
 where gym_id = '7a1d0d7e-0000-4000-8000-000000000001'::uuid
   and id is null;

drop policy if exists "gym_settings_select_own_gym" on public.gym_settings;

create policy "gym_settings_select_authenticated"
  on public.gym_settings for select
  to authenticated
  using (true);

alter table public.gym_settings alter column id set default 1;
alter table public.gym_settings alter column id set not null;

alter table public.gym_settings
  add constraint gym_settings_pkey primary key (id);

alter table public.gym_settings
  add constraint gym_settings_singleton check (id = 1);

drop index if exists public.gym_settings_gym_id_unique;
alter table public.gym_settings drop column if exists gym_id;

revoke all on table public.gym_settings from anon, authenticated;
grant select on table public.gym_settings to authenticated;

drop function if exists public.member_gym_overview();

commit;
