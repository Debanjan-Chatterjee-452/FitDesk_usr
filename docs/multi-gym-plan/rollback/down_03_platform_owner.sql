-- Rollback for 03_platform_owner.sql
-- Drops the platform-owner tables and RPCs. No gym/admin data is touched.
begin;

drop function if exists public.platform_upsert_subscription(uuid, text, text, date, date, integer, text);
drop function if exists public.platform_set_gym_active(uuid, boolean, text);
drop function if exists public.platform_gym_detail(uuid);
drop function if exists public.platform_dashboard_totals();
drop function if exists public.platform_list_gyms(text, text, integer, integer);
drop function if exists public.platform_me();
drop function if exists public.platform_assert();

drop table if exists public.platform_audit_log;
drop table if exists public.gym_subscriptions;
drop table if exists public.platform_admins;

commit;
