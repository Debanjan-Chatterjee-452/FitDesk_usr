-- ============================================================================
-- FitDesk multi-gym SaaS — draft migration 07
-- Join-flow polish and consistency with the new guards
--
-- STATUS: DRAFT — DO NOT APPLY TO PRODUCTION WITHOUT APPROVAL.
--
-- Depends on migration 13 (gym_join_requests + join RPCs). This migration:
--   * routes every admin join RPC through admin_assert(), so suspended gyms
--     are blocked in one place;
--   * makes approve/decline idempotent and reject stale decisions;
--   * returns the gym public id to the member;
--   * adds a pending-count RPC for the future navigation badge.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Member request: idempotent, returns public id
-- ---------------------------------------------------------------------------
create or replace function public.request_join_gym(p_join_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_code text := upper(nullif(btrim(coalesce(p_join_code, '')), ''));
  v_gym public.gyms;
  v_profile public.profiles;
  v_request public.gym_join_requests;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  if v_code is null then
    raise exception 'JOIN_CODE_REQUIRED' using errcode = 'P0001';
  end if;

  select * into v_profile from public.profiles where id = v_user;
  if not found then
    raise exception 'PROFILE_REQUIRED' using errcode = 'P0001';
  end if;

  if v_profile.gym_id is not null then
    return jsonb_build_object(
      'status', 'already_member',
      'gym_id', v_profile.gym_id
    );
  end if;

  select * into v_gym
    from public.gyms
   where upper(join_code) = v_code
     and is_active;

  if not found then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  insert into public.gym_join_requests (gym_id, user_id, status)
  values (v_gym.id, v_user, 'pending')
  on conflict (gym_id, user_id) do update
    set status = 'pending',
        requested_at = now(),
        decided_at = null,
        decided_by = null
  where public.gym_join_requests.status <> 'pending';

  select * into v_request
    from public.gym_join_requests
   where gym_id = v_gym.id and user_id = v_user;

  return jsonb_build_object(
    'status', v_request.status,
    'requested_at', v_request.requested_at,
    'gym_id', v_gym.id,
    'gym_name', v_gym.name,
    'gym_public_id', v_gym.public_id,
    'requires_approval', true
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Admin list: uses the shared guard (suspended gyms blocked)
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_join_requests()
returns table (
  id uuid,
  status text,
  requested_at timestamptz,
  user_email text,
  member_name text,
  member_phone text
)
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
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
         nullif(btrim(coalesce(p.phone, '')), '')
    from public.gym_join_requests r
    join auth.users u on u.id = r.user_id
    left join public.profiles p on p.id = r.user_id
   where r.gym_id = v_gym_id
   order by (r.status = 'pending') desc, r.requested_at desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Pending badge count
-- ---------------------------------------------------------------------------
create or replace function public.admin_pending_join_request_count()
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_count integer;
begin
  select count(*)::integer into v_count
    from public.gym_join_requests
   where gym_id = v_gym_id
     and status = 'pending';

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Admin decision: guard, idempotent approve, stale-decision check
-- ---------------------------------------------------------------------------
create or replace function public.admin_review_join_request(
  p_request_id uuid,
  p_approve boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := auth.uid();
  v_gym_id uuid := public.admin_assert();
  v_request public.gym_join_requests;
  v_member_name text;
begin
  select * into v_request
    from public.gym_join_requests
   where id = p_request_id
     and gym_id = v_gym_id
   for update;

  if not found then
    raise exception 'JOIN_REQUEST_NOT_FOUND' using errcode = 'P0001';
  end if;

  if p_approve then
    -- Re-approving an already approved request is safe and does nothing.
    if v_request.status = 'approved' then
      return jsonb_build_object(
        'status', 'approved',
        'user_id', v_request.user_id,
        'gym_id', v_gym_id,
        'already_approved', true
      );
    end if;

    if v_request.status <> 'pending' then
      raise exception 'JOIN_REQUEST_ALREADY_DECIDED' using errcode = 'P0001';
    end if;

    if exists (
      select 1 from public.profiles
       where id = v_request.user_id
         and gym_id = v_gym_id
    ) then
      update public.gym_join_requests
         set status = 'approved', decided_at = now(), decided_by = v_admin
       where id = p_request_id;

      return jsonb_build_object(
        'status', 'approved',
        'user_id', v_request.user_id,
        'gym_id', v_gym_id,
        'already_approved', true
      );
    end if;

    if exists (
      select 1 from public.profiles
       where id = v_request.user_id
         and gym_id is not null
    ) then
      raise exception 'MEMBER_ALREADY_IN_GYM' using errcode = 'P0001';
    end if;

    update public.gym_join_requests
       set status = 'approved', decided_at = now(), decided_by = v_admin
     where id = p_request_id;

    update public.profiles
       set gym_id = v_gym_id
     where id = v_request.user_id;

    select coalesce(full_name, 'Member') into v_member_name
      from public.profiles where id = v_request.user_id;

    insert into public.admin_notifications (gym_id, kind, title, body, payload, user_id)
    values (
      v_gym_id,
      'member_joined',
      'New member approved — ' || v_member_name,
      v_member_name || ' was approved and can now see packages, renew and check in.',
      jsonb_build_object('user_id', v_request.user_id, 'approved_at', now()),
      v_request.user_id
    );

    return jsonb_build_object(
      'status', 'approved',
      'user_id', v_request.user_id,
      'gym_id', v_gym_id,
      'already_approved', false
    );
  else
    if v_request.status = 'declined' then
      return jsonb_build_object(
        'status', 'declined',
        'user_id', v_request.user_id,
        'gym_id', v_gym_id,
        'already_declined', true
      );
    end if;

    if v_request.status = 'approved' then
      raise exception 'JOIN_REQUEST_ALREADY_DECIDED' using errcode = 'P0001';
    end if;

    update public.gym_join_requests
       set status = 'declined', decided_at = now(), decided_by = v_admin
     where id = p_request_id;

    return jsonb_build_object(
      'status', 'declined',
      'user_id', v_request.user_id,
      'gym_id', v_gym_id,
      'already_declined', false
    );
  end if;
exception
  when unique_violation then
    raise exception 'PHONE_ALREADY_REGISTERED' using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.request_join_gym(text) from public, anon, authenticated;
revoke all on function public.admin_list_join_requests() from public, anon, authenticated;
revoke all on function public.admin_review_join_request(uuid, boolean) from public, anon, authenticated;
revoke all on function public.admin_pending_join_request_count() from public, anon, authenticated;

grant execute on function public.request_join_gym(text) to authenticated;
grant execute on function public.admin_list_join_requests() to authenticated;
grant execute on function public.admin_review_join_request(uuid, boolean) to authenticated;
grant execute on function public.admin_pending_join_request_count() to authenticated;

commit;
