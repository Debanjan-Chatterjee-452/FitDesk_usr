-- 20261124000600_fitdesk_pending_join_document_access.sql
-- Pending join requesters deliberately have profiles.gym_id = NULL until an
-- admin approves them, so the gym-membership check added in 00500 could not
-- open their uploaded identity document. Extend the SECURITY DEFINER helper to
-- also allow documents belonging to anyone with a join request for the admin's
-- gym (any status, so historical requests remain reviewable).

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
     where a.id = auth.uid()
       and a.is_admin is true
       and (
         -- Existing members of this admin's gym.
         exists (
           select 1
             from public.profiles m
            where m.id = v_member_id
              and m.gym_id is not null
              and m.gym_id = a.gym_id
         )
         -- Applicants to this admin's gym. Their profile gym_id is still NULL
         -- while the request is pending, so the join request is the only link.
         or exists (
           select 1
             from public.gym_join_requests r
            where r.user_id = v_member_id
              and r.gym_id = a.gym_id
         )
       )
  );
end;
$$;

revoke all on function public.admin_can_view_member_path(text) from public, anon;
grant execute on function public.admin_can_view_member_path(text) to authenticated;

notify pgrst, 'reload schema';
