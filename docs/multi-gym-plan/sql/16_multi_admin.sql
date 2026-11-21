begin;
create or replace function public.admin_add_gym_admin(p_email text)
returns jsonb
language plpgsql
security definer
set search_path to public, auth, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_user_id uuid;
  v_profile public.profiles;
  v_count integer;
begin
  if p_email is null or btrim(p_email) = '' then
    raise exception 'EMAIL_REQUIRED' using errcode = '22023';
  end if;

  select id into v_user_id
    from auth.users
   where lower(email) = lower(btrim(p_email))
   limit 1;

  if v_user_id is null then
    raise exception 'USER_NOT_FOUND' using errcode = 'P0001';
  end if;

  select * into v_profile from public.profiles where id = v_user_id;

  if v_profile.gym_id is not null and v_profile.gym_id <> v_gym_id then
    raise exception 'ADMIN_IN_OTHER_GYM' using errcode = 'P0001';
  end if;

  if v_profile.is_admin is true and v_profile.gym_id = v_gym_id then
    return jsonb_build_object('status', 'already_admin', 'user_id', v_user_id);
  end if;

  select count(*) into v_count
    from public.profiles
   where gym_id = v_gym_id and is_admin is true;

  if v_count >= 2 then
    raise exception 'GYM_ADMIN_LIMIT_REACHED' using errcode = '22023';
  end if;

  update public.profiles
     set is_admin = true,
         gym_id = v_gym_id,
         updated_at = now()
   where id = v_user_id;

  return jsonb_build_object('status', 'added', 'user_id', v_user_id);
end;
$$;

create or replace function public.admin_remove_gym_admin(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_count integer;
begin
  if p_user_id = auth.uid() then
    raise exception 'CANNOT_REMOVE_SELF' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.profiles
     where id = p_user_id and gym_id = v_gym_id and is_admin is true
  ) then
    raise exception 'ADMIN_NOT_FOUND' using errcode = 'P0001';
  end if;

  select count(*) into v_count
    from public.profiles
   where gym_id = v_gym_id and is_admin is true;

  if v_count <= 1 then
    raise exception 'LAST_ADMIN_CANNOT_BE_REMOVED' using errcode = '22023';
  end if;

  update public.profiles
     set is_admin = false,
         updated_at = now()
   where id = p_user_id and gym_id = v_gym_id;

  return jsonb_build_object('status', 'removed', 'user_id', p_user_id);
end;
$$;

revoke all on function public.admin_add_gym_admin(text) from public, anon, authenticated;
grant execute on function public.admin_add_gym_admin(text) to authenticated;

revoke all on function public.admin_remove_gym_admin(uuid) from public, anon, authenticated;
grant execute on function public.admin_remove_gym_admin(uuid) to authenticated;

commit;