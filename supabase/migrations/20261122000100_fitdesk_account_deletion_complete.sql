-- 20261122000100_fitdesk_account_deletion_complete.sql
-- Replaces delete_my_account to remove ALL member-owned data, including
-- cash OTPs and storage objects (avatars + legal documents).

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

  -- Remove member-owned rows (gym-scoped data is keyed by user_id).
  delete from public.cash_payment_otps where user_id = v_user;
  delete from public.attendance where user_id = v_user;
  delete from public.payments where user_id = v_user;
  delete from public.memberships where user_id = v_user;
  delete from public.gym_join_requests where user_id = v_user;
  delete from public.profiles where id = v_user;

  -- Remove the auth user so they can re-register.
  delete from auth.users where id = v_user;

  return jsonb_build_object('deleted', true, 'user_id', v_user);
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
