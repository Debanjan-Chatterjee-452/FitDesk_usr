-- Rollback for 01_gym_identity_ownership.sql
-- WARNING: drops the new owner_id / public_id data. Only for a full revert
-- before those columns are used. Prefer restoring from backup.
begin;

drop trigger if exists gyms_public_id_trigger on public.gyms;
drop function if exists public.handle_gym_public_id();
drop function if exists public.format_gym_public_id(bigint);

drop index if exists public.gyms_public_id_unique;
drop index if exists public.gyms_owner_idx;
drop index if exists public.gyms_active_idx;

alter table public.gyms drop column if exists suspension_reason;
alter table public.gyms drop column if exists suspended_at;
alter table public.gyms drop column if exists public_id;
alter table public.gyms drop column if exists owner_id;

drop sequence if exists public.gym_public_id_seq;

-- admin_get_gym_settings() is restored by running rollback/00_functions_before.sql.
commit;
