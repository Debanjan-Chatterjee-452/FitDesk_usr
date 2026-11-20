-- 20261120000200_fitdesk_document_id_number.sql
-- Stores the legal document ID number entered by the member during
-- onboarding/verification, so it can be validated against the uploaded doc.

alter table public.profiles
  add column if not exists legal_document_id_number text;

comment on column public.profiles.legal_document_id_number is
  'The ID number printed on the uploaded legal document (Aadhaar/PAN/etc).';

-- Allow members to write this column (it is part of profile completion).
-- (No RLS change needed beyond the existing profiles update policy.)
