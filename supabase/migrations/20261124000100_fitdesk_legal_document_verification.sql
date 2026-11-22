-- 20261124000100_fitdesk_legal_document_verification.sql
-- Legal document verification flow: store the document kind (Aadhaar/PAN/...)
-- and the typed document number separately from the file's MIME type.
--
-- The pre-existing `legal_document_type` column actually held the uploaded
-- file's MIME type, so it is renamed to `legal_document_mime_type` and a new
-- `legal_document_type` column is added for the human-readable kind.
-- `legal_document_id_number` is renamed to the shorter `legal_document_number`.

-- ---------------------------------------------------------------------------
-- 1. Column renames (idempotent)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'legal_document_type'
  ) and not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'legal_document_mime_type'
  ) then
    alter table public.profiles
      rename column legal_document_type to legal_document_mime_type;
  end if;

  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'legal_document_id_number'
  ) and not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'legal_document_number'
  ) then
    alter table public.profiles
      rename column legal_document_id_number to legal_document_number;
  end if;
end $$;

alter table public.profiles
  add column if not exists legal_document_mime_type text;
alter table public.profiles
  add column if not exists legal_document_type text;
alter table public.profiles
  add column if not exists legal_document_number text;

comment on column public.profiles.legal_document_mime_type is
  'MIME type of the uploaded identity document (image/jpeg, application/pdf, ...).';
comment on column public.profiles.legal_document_type is
  'Kind of identity document: Aadhaar Card, PAN Card, Driving Licence, Passport or Voter ID.';
comment on column public.profiles.legal_document_number is
  'The ID number printed on the uploaded identity document.';

-- Only the five supported document kinds are accepted.
alter table public.profiles
  drop constraint if exists profiles_legal_document_type_check;
alter table public.profiles
  add constraint profiles_legal_document_type_check
  check (
    legal_document_type is null
    or legal_document_type in (
      'Aadhaar Card', 'PAN Card', 'Driving Licence', 'Passport', 'Voter ID'
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Column grants (profiles uses column-level UPDATE grants)
-- ---------------------------------------------------------------------------
grant select (
  legal_document_mime_type,
  legal_document_type,
  legal_document_number
) on public.profiles to authenticated;

grant update (
  legal_document_mime_type,
  legal_document_type,
  legal_document_number,
  avatar_path
) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Admin inspection view: expose the typed kind + number with the file
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_join_requests();

create or replace function public.admin_list_join_requests()
returns table (
  id uuid,
  status text,
  requested_at timestamptz,
  user_email text,
  member_name text,
  member_phone text,
  member_document_path text,
  member_document_name text,
  member_document_type text,
  member_document_number text
)
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_gym_id uuid;
begin
  select profiles.gym_id
    into v_gym_id
    from public.profiles
   where profiles.id = auth.uid()
     and profiles.is_admin = true;

  if v_gym_id is null then
    return;
  end if;

  return query
  select r.id,
         r.status,
         r.requested_at,
         u.email::text,
         p.full_name,
         nullif(btrim(coalesce(p.phone, '')), ''),
         p.legal_document_path,
         p.legal_document_name,
         p.legal_document_type,
         p.legal_document_number
    from public.gym_join_requests r
    join auth.users u on u.id = r.user_id
    left join public.profiles p on p.id = r.user_id
   where r.gym_id = v_gym_id
   order by (r.status = 'pending') desc, r.requested_at desc;
end;
$$;

revoke all on function public.admin_list_join_requests() from public, anon;
grant execute on function public.admin_list_join_requests() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Renewal quote: confirm the exact 3-argument signature used by the app
-- ---------------------------------------------------------------------------
-- The app calls get_my_renewal_quote({ p_package_id, p_duration_days,
-- p_is_new_admission }). A stale 2-argument overload left over from the first
-- deployment caused PostgREST to miss the function until its schema cache was
-- refreshed.
do $$
begin
  if exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'get_my_renewal_quote'
       and p.pronargs = 3
  ) then
    grant execute on function public.get_my_renewal_quote(uuid, integer, boolean)
      to authenticated;
    grant execute on function public.get_my_renewal_quote(uuid, integer, boolean)
      to service_role;
  end if;
end $$;

notify pgrst, 'reload schema';
