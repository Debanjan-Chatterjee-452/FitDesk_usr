-- 20261120000100_fitdesk_account_deletion.sql
-- Allows a signed-in member to delete their own account and all associated
-- data, so they can re-register with the same email.

create or replace function public.delete_my_account()
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  -- Remove member-owned rows (gym-scoped data is keyed by user_id).
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
