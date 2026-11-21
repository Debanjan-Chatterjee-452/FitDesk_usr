begin;
drop function if exists public.admin_list_join_requests();
create or replace function public.admin_list_join_requests()
returns table (
  id uuid,
  status text,
  requested_at timestamptz,
  user_email text,
  member_name text,
  member_phone text,
  member_document_path text,
  member_document_name text
)
language plpgsql
stable
security definer
set search_path to public, auth, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
begin
  return query
  select r.id,
         r.status,
         r.requested_at,
         u.email::text,
         p.full_name,
         nullif(btrim(coalesce(p.phone, '')), ''),
         p.legal_document_path,
         p.legal_document_name
    from public.gym_join_requests r
    join auth.users u on u.id = r.user_id
    left join public.profiles p on p.id = r.user_id
   where r.gym_id = v_gym_id
   order by (r.status = 'pending') desc, r.requested_at desc;
end;
$$;

revoke all on function public.admin_list_join_requests() from public, anon, authenticated;
grant execute on function public.admin_list_join_requests() to authenticated;

commit;