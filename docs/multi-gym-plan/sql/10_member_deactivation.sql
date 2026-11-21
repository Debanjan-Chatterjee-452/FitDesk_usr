begin;
alter table public.profiles add column if not exists is_deactivated boolean not null default false;
alter table public.profiles add column if not exists deactivated_at timestamptz;
alter table public.profiles add column if not exists deactivated_by uuid references auth.users(id);

create or replace function public.admin_set_member_active(
  p_user_id uuid,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_profile public.profiles;
begin
  select * into v_profile from public.profiles where id = p_user_id and gym_id = v_gym_id;
  if not found then
    raise exception 'MEMBER_NOT_FOUND' using errcode = 'P0001';
  end if;

  update public.profiles
     set is_deactivated = not p_active,
         deactivated_at = case when p_active then null else now() end,
         deactivated_by = case when p_active then null else auth.uid() end,
         updated_at = now()
   where id = p_user_id;

  if not p_active then
    update public.memberships
       set status = 'cancelled',
           updated_at = now()
     where user_id = p_user_id
       and gym_id = v_gym_id
       and status in ('active', 'paused');
  end if;

  return jsonb_build_object('user_id', p_user_id, 'active', p_active);
end;
$$;

revoke all on function public.admin_set_member_active(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_set_member_active(uuid, boolean) to authenticated;

commit;