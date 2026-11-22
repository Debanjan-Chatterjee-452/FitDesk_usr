-- 20261124000500_fitdesk_admin_overview_join_review.sql
-- Restores the gym join code on the admin overview and gives gym admins full
-- visibility of a member's profile + identity document before they approve a
-- join request. All access is keyed on profiles.is_admin, never on owner_id,
-- so every administrator of the gym gets identical access.

-- ---------------------------------------------------------------------------
-- 1. Gym settings: return the join code / public id the overview already
--    expects. The live function had drifted and omitted these keys, which is
--    why the "Gym identity" card never rendered.
-- ---------------------------------------------------------------------------
create or replace function public.admin_get_gym_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_row jsonb;
begin
  select jsonb_build_object(
    'gym_id', g.id,
    'public_id', g.public_id,
    'join_code', g.join_code,
    'owner_id', g.owner_id,
    'slug', g.slug,
    'name', g.name,
    'upi_id', g.upi_id,
    'upi_payee_name', g.upi_payee_name,
    'payment_qr_path', g.payment_qr_path,
    'is_open', g.is_open,
    'shutter_changed_at', g.shutter_changed_at,
    'attendance_qr_months', g.attendance_qr_months,
    'attendance_qr_rotated_at', g.attendance_qr_rotated_at,
    'admission_fee_inr', g.admission_fee_inr,
    'is_active', g.is_active,
    'suspended_at', g.suspended_at,
    'suspension_reason', g.suspension_reason,
    'created_at', g.created_at,
    'updated_at', g.updated_at
  )
    into v_row
    from public.gyms g
   where g.id = v_gym_id;

  if v_row is null then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

revoke all on function public.admin_get_gym_settings() from public, anon;
grant execute on function public.admin_get_gym_settings() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Join requests: return the complete member profile needed to review an
--    applicant before approving them. Enum columns are cast to text so the
--    function works regardless of their underlying enum type.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_join_requests();

create or replace function public.admin_list_join_requests()
returns table (
  id uuid,
  status text,
  requested_at timestamptz,
  user_email text,
  member_user_id uuid,
  member_name text,
  member_phone text,
  member_date_of_birth text,
  member_gender text,
  member_blood_group text,
  member_avatar_path text,
  member_profile_completed boolean,
  member_document_path text,
  member_document_name text,
  member_document_mime_type text,
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
  -- Every admin of this gym resolves to the same gym id; owner_id is not
  -- consulted here so both administrators see exactly the same applicants.
  select profiles.gym_id
    into v_gym_id
    from public.profiles
   where profiles.id = auth.uid()
     and profiles.is_admin is true;

  if v_gym_id is null then
    return;
  end if;

  return query
  select r.id,
         r.status,
         r.requested_at,
         u.email::text,
         p.id,
         p.full_name,
         nullif(btrim(coalesce(p.phone, '')), ''),
         p.date_of_birth::text,
         p.gender::text,
         p.blood_group::text,
         p.avatar_path,
         coalesce(p.profile_completed, false),
         p.legal_document_path,
         p.legal_document_name,
         p.legal_document_mime_type,
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
-- 3. Document/avatar access: the buckets are private and their RLS policies
--    only allow the owning member. A gym admin must be able to open the
--    document of an applicant to their own gym (and only that gym) in order
--    to verify it before approving. Signed-URL creation uses these SELECT
--    policies, so no service key is ever exposed to the browser.
--    A SECURITY DEFINER helper is required because profiles has its own RLS
--    and an admin cannot otherwise select another member's profile row here.
-- ---------------------------------------------------------------------------
create or replace function public.admin_can_view_member_path(p_path text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member_id uuid;
begin
  if auth.uid() is null then
    return false;
  end if;

  begin
    v_member_id := (storage.foldername(p_path))[1]::uuid;
  exception when others then
    return false;
  end;

  return exists (
    select 1
      from public.profiles a
      join public.profiles m on m.gym_id = a.gym_id
     where a.id = auth.uid()
       and a.is_admin is true
       and m.id = v_member_id
       and m.gym_id is not null
  );
end;
$$;

revoke all on function public.admin_can_view_member_path(text) from public, anon;
grant execute on function public.admin_can_view_member_path(text) to authenticated;

drop policy if exists legal_documents_select_gym_admin on storage.objects;
create policy legal_documents_select_gym_admin on storage.objects
for select to authenticated
using (
  bucket_id = 'legal-documents'
  and public.admin_can_view_member_path(name)
);

drop policy if exists profile_avatars_select_gym_admin on storage.objects;
create policy profile_avatars_select_gym_admin on storage.objects
for select to authenticated
using (
  bucket_id = 'profile-avatars'
  and public.admin_can_view_member_path(name)
);

notify pgrst, 'reload schema';
