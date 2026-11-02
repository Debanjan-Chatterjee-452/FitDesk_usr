-- ============================================================================
-- FitDesk read-only verification — record fingerprints
--
-- SAFE: every statement is a SELECT. No writes, no DDL.
--
-- Purpose: compare row counts and stable ID sets between canonical and legacy
-- without exporting personal data. If counts or fingerprints differ, run the
-- deeper per-table comparison described in VERIFICATION.md.
--
-- Usage:
--   npx.cmd --yes supabase db query --project-ref <ref> \
--     --file docs/multi-gym-plan/sql/verify_readonly_hashes.sql \
--     --output csv > verification/<ref>-hashes.csv
-- ============================================================================

with
gyms as (
  select 'gyms' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.gyms$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text, ',' order by id)) as h from public.gyms$q$,
      false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.gyms') is not null
),
profiles as (
  select 'profiles' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.profiles$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text || ':' || coalesce(gym_id::text, '-'), ',' order by id)) as h
          from public.profiles$q$, false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.profiles') is not null
),
memberships as (
  select 'memberships' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.memberships$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text, ',' order by id)) as h from public.memberships$q$,
      false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.memberships') is not null
),
payments as (
  select 'payments' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.payments$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text, ',' order by id)) as h from public.payments$q$,
      false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.payments') is not null
),
attendance as (
  select 'attendance' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.attendance$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text, ',' order by id)) as h from public.attendance$q$,
      false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.attendance') is not null
),
packages as (
  select 'packages' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.packages$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text, ',' order by id)) as h from public.packages$q$,
      false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.packages') is not null
),
settings as (
  select 'gym_settings' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.gym_settings$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(coalesce(id::text, '-'), ',' order by id)) as h
          from public.gym_settings$q$, false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.gym_settings') is not null
),
announcements as (
  select 'announcements' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.announcements$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text, ',' order by id)) as h from public.announcements$q$,
      false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.announcements') is not null
),
join_requests as (
  select 'gym_join_requests' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from public.gym_join_requests$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text, ',' order by id)) as h from public.gym_join_requests$q$,
      false, false, '')))[1]::text as id_fingerprint
  where to_regclass('public.gym_join_requests') is not null
),
auth_users as (
  select 'auth_users' as section,
    (select count(*)::text from auth.users) as row_count,
    (select md5(string_agg(id::text, ',' order by id)) from auth.users) as id_fingerprint
),
auth_identities as (
  select 'auth_identities' as section,
    (select count(*)::text from auth.identities) as row_count,
    (select md5(string_agg(id::text, ',' order by id)) from auth.identities) as id_fingerprint
),
storage_objects as (
  select 'storage_objects' as section,
    (xpath('/table/row/c/text()', query_to_xml(
      $q$select count(*) as c from storage.objects$q$, false, false, '')))[1]::text as row_count,
    (xpath('/table/row/h/text()', query_to_xml(
      $q$select md5(string_agg(id::text, ',' order by id)) as h from storage.objects$q$,
      false, false, '')))[1]::text as id_fingerprint
)

select section, row_count, id_fingerprint from gyms
union all select section, row_count, id_fingerprint from profiles
union all select section, row_count, id_fingerprint from memberships
union all select section, row_count, id_fingerprint from payments
union all select section, row_count, id_fingerprint from attendance
union all select section, row_count, id_fingerprint from packages
union all select section, row_count, id_fingerprint from settings
union all select section, row_count, id_fingerprint from announcements
union all select section, row_count, id_fingerprint from join_requests
union all select section, row_count, id_fingerprint from auth_users
union all select section, row_count, id_fingerprint from auth_identities
union all select section, row_count, id_fingerprint from storage_objects
order by section;
