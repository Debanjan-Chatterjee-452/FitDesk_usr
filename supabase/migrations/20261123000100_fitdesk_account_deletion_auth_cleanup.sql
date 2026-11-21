-- 20261123000100_fitdesk_account_deletion_auth_cleanup.sql
-- Replaces delete_my_account to also clean up all auth-schema tables
-- (identities, sessions, tokens, MFA, etc.) so re-registration with the
-- same email triggers a fresh confirmation email.

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

  -- Remove storage objects owned by this user (best-effort).
  delete from storage.objects
   where bucket_id in ('legal-documents', 'profile-avatars')
     and (storage.foldername(name))[1] = v_user::text;

  -- Remove member-owned public rows.
  delete from public.cash_payment_otps where user_id = v_user;
  delete from public.attendance where user_id = v_user;
  delete from public.payments where user_id = v_user;
  delete from public.memberships where user_id = v_user;
  delete from public.gym_join_requests where user_id = v_user;
  delete from public.profiles where id = v_user;

  -- Clean up auth-schema tables so re-registration is truly fresh.
  delete from auth.mfa_amr_claims where session_id in (select id from auth.sessions where user_id = v_user);
  delete from auth.mfa_challenges where factor_id in (select id from auth.mfa_factors where user_id = v_user);
  delete from auth.mfa_recovery_codes where factor_id in (select id from auth.mfa_factors where user_id = v_user);
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

  -- Remove the auth user so they can re-register.
  delete from auth.users where id = v_user;

  return jsonb_build_object('deleted', true, 'user_id', v_user);
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
