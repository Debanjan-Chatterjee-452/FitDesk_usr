-- Rollback for 07_join_polish.sql
-- Restores the migration-13 bodies of request_join_gym(),
-- admin_list_join_requests() and admin_review_join_request().
begin;

drop function if exists public.admin_pending_join_request_count();

-- Restore the migration-13 function bodies:
--   psql "$SUPABASE_DB_URL" -f rollback/00_functions_before.sql

commit;
