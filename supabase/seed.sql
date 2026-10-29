-- Optional local-only seed data. Packages and gym settings are created by the
-- migrations so that a fresh production project is usable immediately.
-- Run this file with `supabase db reset` or paste it into the SQL editor.

insert into public.announcements (title, body, kind, starts_on, ends_on, is_active)
values (
  'Welcome to FitDesk',
  'Scan the QR at the front desk to check in. Your plan, receipts, and visit history live in this app.',
  'info',
  (now() at time zone 'Asia/Kolkata')::date,
  (now() at time zone 'Asia/Kolkata')::date + 30,
  true
)
on conflict do nothing;
