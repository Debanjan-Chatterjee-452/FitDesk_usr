-- Rollback for 04_isolation_hardening.sql
-- Restores the pre-04 function bodies by running rollback/00_functions_before.sql
-- afterwards. This script removes the added column and trigger.
begin;

drop trigger if exists attendance_fill_gym on public.attendance;
drop function if exists public.fill_attendance_gym();

drop index if exists public.attendance_gym_date_idx;
alter table public.attendance drop column if exists gym_id;

-- Restore old admin_assert(), admin_mark_payment_refunded() and
-- check_in_with_qr() bodies:
--   psql "$SUPABASE_DB_URL" -f rollback/00_functions_before.sql

-- Restore the old storage SELECT policy (any admin, any gym folder).
drop policy if exists "gym_payment_qr_admin_select" on storage.objects;
create policy "gym_payment_qr_admin_select"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'gym-payment-qr' and (select public.is_admin()));

commit;
