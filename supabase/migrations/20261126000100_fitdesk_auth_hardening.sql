-- ============================================================================
-- Auth hardening: a single SECURITY DEFINER profile lookup for the admin app.
--
-- Reading profiles directly immediately after signInWithPassword can fail on
-- a fresh device while RLS/session state settles. This RPC always resolves
-- the caller from auth.uid() and is safe to call right after sign-in.
-- ============================================================================

create or replace function public.admin_get_my_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_profile jsonb;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select to_jsonb(p) into v_profile
    from public.profiles p
   where p.id = auth.uid();

  if v_profile is null then
    raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001';
  end if;

  return v_profile;
end;
$function$;

grant execute on function public.admin_get_my_profile() to authenticated;

notify pgrst, 'reload schema';
