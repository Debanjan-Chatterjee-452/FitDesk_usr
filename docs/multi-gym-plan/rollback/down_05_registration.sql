-- Rollback for 05_registration_atomic.sql
-- Restores the pre-05 register_gym_owner() body (which does not set owner_id,
-- settings or subscriptions). Run rollback/00_functions_before.sql.
--
-- Gym rows already created while 05 was live are intentionally kept:
-- deleting a gym would delete its members' links and is far more dangerous
-- than leaving it in place.
begin;

-- No schema change. Function body is restored by:
--   psql "$SUPABASE_DB_URL" -f rollback/00_functions_before.sql
commit;
