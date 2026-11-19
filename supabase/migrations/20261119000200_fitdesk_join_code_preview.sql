-- 20261119000200_fitdesk_join_code_preview.sql
-- Lets a member preview the gym name for a join code before submitting a
-- request. Read-only: no row is created and no gym data beyond the name is
-- exposed.

create or replace function public.preview_gym_by_join_code(p_join_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_code text := upper(nullif(btrim(coalesce(p_join_code, '')), ''));
  v_gym public.gyms;
begin
  if v_code is null then
    return jsonb_build_object('status', 'empty');
  end if;

  select * into v_gym
    from public.gyms
   where upper(join_code) = v_code
     and is_active = true;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  return jsonb_build_object(
    'status', 'found',
    'gym_id', v_gym.id,
    'gym_name', v_gym.name
  );
end;
$$;

revoke all on function public.preview_gym_by_join_code(text) from public, anon;
grant execute on function public.preview_gym_by_join_code(text) to authenticated;
grant execute on function public.preview_gym_by_join_code(text) to service_role;
