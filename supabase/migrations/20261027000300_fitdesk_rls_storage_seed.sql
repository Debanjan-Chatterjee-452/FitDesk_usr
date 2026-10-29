-- FitDesk member app — Row Level Security, grants, storage, reference data
-- Principle: members get SELECT on their own rows only. All mutations go
-- through SECURITY DEFINER functions or service-role Edge Functions.

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.packages enable row level security;
alter table public.memberships enable row level security;
alter table public.attendance enable row level security;
alter table public.payments enable row level security;
alter table public.announcements enable row level security;
alter table public.gym_settings enable row level security;
alter table public.gym_qr_codes enable row level security;

create policy "profiles_select_own"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create policy "packages_select_active"
  on public.packages for select
  to authenticated
  using (is_active = true);

create policy "memberships_select_own"
  on public.memberships for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "attendance_select_own"
  on public.attendance for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "payments_select_own"
  on public.payments for select
  to authenticated
  using ((select auth.uid()) = user_id);

create policy "announcements_select_published"
  on public.announcements for select
  to authenticated
  using (
    is_active = true
    and starts_on <= (now() at time zone 'Asia/Kolkata')::date
  );

create policy "gym_settings_select_authenticated"
  on public.gym_settings for select
  to authenticated
  using (true);

-- gym_qr_codes intentionally has RLS enabled and NO policies. Members can
-- never read tokens, hashes, or labels. Service role bypasses RLS.

-- ---------------------------------------------------------------------------
-- Table and column grants
-- ---------------------------------------------------------------------------
revoke all on table public.profiles from anon, authenticated;
revoke all on table public.packages from anon, authenticated;
revoke all on table public.memberships from anon, authenticated;
revoke all on table public.attendance from anon, authenticated;
revoke all on table public.payments from anon, authenticated;
revoke all on table public.announcements from anon, authenticated;
revoke all on table public.gym_settings from anon, authenticated;
revoke all on table public.gym_qr_codes from anon, authenticated;

grant select on table public.profiles to authenticated;
grant update (
  full_name,
  date_of_birth,
  blood_group,
  gender,
  legal_document_path,
  legal_document_name,
  legal_document_type
) on public.profiles to authenticated;

grant select on table public.packages to authenticated;
grant select on table public.memberships to authenticated;
grant select on table public.attendance to authenticated;
grant select on table public.payments to authenticated;
grant select on table public.announcements to authenticated;
grant select on table public.gym_settings to authenticated;

-- ---------------------------------------------------------------------------
-- Function execution grants
-- ---------------------------------------------------------------------------
revoke all on function public.ensure_my_profile() from public, anon, authenticated;
revoke all on function public.get_my_renewal_quote(uuid, integer) from public, anon, authenticated;
revoke all on function public.check_in_with_qr(text) from public, anon, authenticated;
revoke all on function public.complete_membership_payment(uuid, text, integer, text) from public, anon, authenticated;
revoke all on function public.create_gym_qr_code(text) from public, anon, authenticated;
revoke all on function public.revoke_gym_qr_code(uuid) from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.handle_user_phone_updated() from public, anon, authenticated;
revoke all on function public.touch_updated_at() from public, anon, authenticated;
revoke all on function public.validate_profile() from public, anon, authenticated;

grant execute on function public.ensure_my_profile() to authenticated;
grant execute on function public.get_my_renewal_quote(uuid, integer) to authenticated;
grant execute on function public.check_in_with_qr(text) to authenticated;

grant execute on function public.complete_membership_payment(uuid, text, integer, text) to service_role;
grant execute on function public.create_gym_qr_code(text) to service_role;
grant execute on function public.revoke_gym_qr_code(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Private storage bucket for identity/legal documents
-- ---------------------------------------------------------------------------
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'legal-documents',
  'legal-documents',
  false,
  10485760,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif',
    'application/pdf'
  ]
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "legal_documents_insert_own" on storage.objects;
drop policy if exists "legal_documents_select_own" on storage.objects;
drop policy if exists "legal_documents_delete_own" on storage.objects;

create policy "legal_documents_insert_own"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'legal-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "legal_documents_select_own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'legal-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "legal_documents_delete_own"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'legal-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- ---------------------------------------------------------------------------
-- Reference data
-- Prices are whole rupees. Edit these rows in the SQL editor or your admin
-- tooling; members can only read active packages.
-- ---------------------------------------------------------------------------
insert into public.packages (
  id, name, description, duration_days, price_inr, pricing_mode,
  min_days, max_days, is_active, is_recommended, sort_order
)
values
  (
    '11111111-1111-4111-8111-111111111111',
    'Monthly',
    'Full gym access for 30 days. Perfect for a focused reset.',
    30, 1499, 'fixed', null, null, true, false, 10
  ),
  (
    '22222222-2222-4222-8222-222222222222',
    'Quarterly',
    'Three months of training, group classes, and locker access.',
    90, 3999, 'fixed', null, null, true, true, 20
  ),
  (
    '33333333-3333-4333-8333-333333333333',
    'Half-yearly',
    'Six months of uninterrupted access. Best value per month.',
    180, 6999, 'fixed', null, null, true, false, 30
  ),
  (
    '44444444-4444-4444-8444-444444444444',
    'Annual',
    'A full year of training. Includes two guest passes.',
    365, 11999, 'fixed', null, null, true, false, 40
  ),
  (
    '55555555-5555-4555-8555-555555555555',
    'Flex',
    'Pick any duration from 7 to 180 days. Pay only for the time you need.',
    30, 79, 'per_day', 7, 180, true, false, 50
  )
on conflict (id) do nothing;

insert into public.gym_settings (
  id, name, address, open_time, close_time, closed_weekdays, contact_phone
)
values (
  1,
  'FitDesk Performance Club',
  '12, 100 Feet Road, Indiranagar, Bengaluru 560038',
  '05:00',
  '23:00',
  '{0}'::smallint[],
  '+91 90000 00000'
)
on conflict (id) do nothing;
