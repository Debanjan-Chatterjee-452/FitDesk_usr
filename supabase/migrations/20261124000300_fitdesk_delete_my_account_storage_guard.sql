-- 20261124000300_fitdesk_delete_my_account_storage_guard.sql
-- Supabase installs a guard trigger (storage.protect_delete) on storage.objects
-- that raises SQLSTATE 42501 for any direct DELETE unless the transaction-local
-- setting `storage.allow_delete_query` is 'true'. Account deletion runs as a
-- SECURITY DEFINER function, so it must set that flag itself before removing the
-- member's uploaded avatar and legal document.

create or replace function public.delete_my_account()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, storage, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  -- A gym owner must hand the gym over first; deleting the auth row would
  -- otherwise fail on the RESTRICT foreign key and leave a half-deleted user.
  if exists (select 1 from public.gyms where owner_id = v_user) then
    raise exception 'ACCOUNT_OWNS_GYM' using errcode = 'P0001';
  end if;

  -- Remove storage objects owned by this user. The guard trigger only permits
  -- this when the flag below is set for the current transaction.
  perform set_config('storage.allow_delete_query', 'true', true);
  delete from storage.objects
   where bucket_id in ('legal-documents', 'profile-avatars')
     and (storage.foldername(name))[1] = v_user::text;
  perform set_config('storage.allow_delete_query', 'false', true);

  -- Clear NO ACTION references before deleting the profile / auth rows.
  update public.profiles
     set deactivated_by = null
   where deactivated_by = v_user;
  update public.cash_payment_otps
     set created_by = null
   where created_by = v_user;

  -- Remove member-owned public rows.
  delete from public.cash_payment_otps where user_id = v_user;
  delete from public.attendance where user_id = v_user;
  delete from public.payments where user_id = v_user;
  delete from public.memberships where user_id = v_user;
  delete from public.gym_join_requests where user_id = v_user;
  delete from public.profiles where id = v_user;

  -- Clean up auth-schema tables so re-registration is truly fresh.
  delete from auth.mfa_amr_claims
   where session_id in (select id from auth.sessions where user_id = v_user);
  delete from auth.mfa_challenges
   where factor_id in (select id from auth.mfa_factors where user_id = v_user);
  delete from auth.mfa_recovery_codes
   where mfa_recovery_code_set_id in (
     select id from auth.mfa_recovery_code_sets where user_id = v_user
   );
  delete from auth.mfa_recovery_code_sets where user_id = v_user;
  delete from auth.mfa_factors where user_id = v_user;
  delete from auth.webauthn_credentials where user_id = v_user;
  delete from auth.webauthn_challenges where user_id = v_user;
  delete from auth.oauth_consents where user_id = v_user;
  delete from auth.oauth_authorizations where user_id = v_user;
  delete from auth.one_time_tokens where user_id = v_user;
  delete from auth.refresh_tokens where user_id = v_user;
  delete from auth.sessions where user_id = v_user;
  delete from auth.identities where user_id = v_user;
  delete from auth.flow_state where user_id = v_user;
  delete from auth.scim_users where user_id = v_user;

  -- Remove the auth user so they can re-register.
  delete from auth.users where id = v_user;

  return jsonb_build_object('deleted', true, 'user_id', v_user);
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

notify pgrst, 'reload schema';
