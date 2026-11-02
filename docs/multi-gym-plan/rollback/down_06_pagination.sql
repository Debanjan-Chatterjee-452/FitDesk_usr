-- Rollback for 06_admin_pagination.sql
begin;

drop function if exists public.admin_member_status_counts();
drop function if exists public.admin_list_members_page(text, text, integer, integer);
drop index if exists public.profiles_gym_admin_idx;

commit;
