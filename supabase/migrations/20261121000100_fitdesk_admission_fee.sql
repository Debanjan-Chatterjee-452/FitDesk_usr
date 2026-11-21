-- 20261121000100_fitdesk_admission_fee.sql
-- Adds an optional, admin-configurable admission fee charged on new admissions.

alter table public.gyms
  add column if not exists admission_fee_inr integer not null default 0;

comment on column public.gyms.admission_fee_inr is
  'One-time admission fee charged when a member selects "New Admission". 0 = disabled.';

alter table public.payments
  add column if not exists is_new_admission boolean not null default false;

comment on column public.payments.is_new_admission is
  'Whether this payment included the gym admission fee.';
