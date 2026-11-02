-- ============================================================================
-- FitDesk multi-gym SaaS — draft migration 05
-- Atomic, idempotent gym-owner registration
--
-- STATUS: DRAFT — DO NOT APPLY TO PRODUCTION WITHOUT APPROVAL.
--
-- After an owner confirms their email and signs in for the first time, the
-- admin app calls register_gym_owner(). This version:
--   * takes a per-user advisory lock, so a double-click or double-login
--     cannot create two gyms;
--   * returns the existing gym if the caller is already set up (idempotent);
--   * sets gyms.owner_id to the caller;
--   * creates the per-gym settings row;
--   * creates a 14-day trial subscription row;
--   * keeps the four payment rails;
--   * never deletes or moves another member's profile.
-- ============================================================================

begin;

create or replace function public.register_gym_owner(
  p_gym_name text,
  p_full_name text,
  p_phone text default null,
  p_slug text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_profile public.profiles;
  v_meta jsonb := '{}'::jsonb;
  v_gym public.gyms;
  v_gym_name text;
  v_full_name text;
  v_phone text;
  v_base text;
  v_slug text;
  v_counter integer := 1;
  v_gym_id uuid;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  -- Serialise concurrent calls for this account (double click / two tabs).
  perform pg_advisory_xact_lock(hashtextextended('fitdesk:register_gym_owner:' || v_user::text, 0));

  select raw_user_meta_data into v_meta
    from auth.users
   where id = v_user;

  select * into v_profile
    from public.profiles
   where id = v_user
   for update;

  if not found then
    raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0001';
  end if;

  -- -------------------------------------------------------------------------
  -- Already registered: return the same gym, never create a second one.
  -- -------------------------------------------------------------------------
  if v_profile.is_admin then
    if v_profile.gym_id is null then
      raise exception 'ADMIN_WITHOUT_GYM' using errcode = 'P0001';
    end if;

    select * into v_gym from public.gyms where id = v_profile.gym_id;
    if not found then
      raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
    end if;

    -- Complete any missing side rows without duplicating them.
    insert into public.gym_settings
      (gym_id, name, open_time, close_time, closed_weekdays)
    values
      (v_gym.id, v_gym.name, '05:00'::time, '23:00'::time, '{0}'::smallint[])
    on conflict (gym_id) do nothing;

    insert into public.gym_payment_methods (gym_id, method)
    select v_gym.id, m.method
      from (values ('google_pay'), ('phonepe'), ('paytm'), ('upi')) as m(method)
    on conflict (gym_id, method) do nothing;

    insert into public.gym_subscriptions (gym_id, plan, status, trial_ends_on)
    select v_gym.id, 'trial', 'trialing', (now() at time zone 'Asia/Kolkata')::date + 14
    where not exists (
      select 1 from public.gym_subscriptions s where s.gym_id = v_gym.id
    );

    return jsonb_build_object(
      'gym_id', v_gym.id,
      'public_id', v_gym.public_id,
      'join_code', v_gym.join_code,
      'slug', v_gym.slug,
      'name', v_gym.name,
      'is_admin', true,
      'already_registered', true
    );
  end if;

  -- -------------------------------------------------------------------------
  -- New owner. Fall back to the signup metadata when arguments are omitted.
  -- -------------------------------------------------------------------------
  v_gym_name := nullif(btrim(coalesce(p_gym_name, v_meta ->> 'gym_name', '')), '');
  v_full_name := nullif(btrim(coalesce(p_full_name, v_meta ->> 'full_name', '')), '');
  v_phone := nullif(btrim(coalesce(p_phone, v_meta ->> 'phone', '')), '');

  -- A member who already belongs to a gym must not silently take it over.
  -- Owner signups always carry a gym_name in auth metadata, which lets a
  -- pending owner created before the gym-less profile change finish setup.
  if v_profile.gym_id is not null
     and nullif(btrim(coalesce(v_meta ->> 'gym_name', '')), '') is null then
    raise exception 'MEMBER_ALREADY_IN_GYM' using errcode = '42501';
  end if;

  if v_gym_name is null or length(v_gym_name) < 2 then
    raise exception 'GYM_NAME_REQUIRED' using errcode = '22023';
  end if;

  if length(v_gym_name) > 80 then
    raise exception 'GYM_NAME_TOO_LONG' using errcode = '22023';
  end if;

  v_base := btrim(lower(regexp_replace(v_gym_name, '[^a-zA-Z0-9]+', '-', 'g')), '-');
  if v_base = '' then
    v_base := 'gym';
  end if;
  v_base := left(v_base, 40);

  v_slug := btrim(lower(coalesce(p_slug, '')), '-');
  if v_slug = '' or v_slug !~ '^[a-z0-9][a-z0-9-]{1,48}$' then
    v_slug := v_base;
  end if;

  while exists (select 1 from public.gyms g where g.slug = v_slug) loop
    v_counter := v_counter + 1;
    v_slug := v_base || '-' || v_counter;
  end loop;

  insert into public.gyms (slug, name, owner_id)
  values (v_slug, v_gym_name, v_user)
  returning id into v_gym_id;

  -- Per-gym settings (public_id and join_code are set by their triggers).
  insert into public.gym_settings
    (gym_id, name, open_time, close_time, closed_weekdays)
  values
    (v_gym_id, v_gym_name, '05:00'::time, '23:00'::time, '{0}'::smallint[])
  on conflict (gym_id) do nothing;

  -- Four payment rails, disabled until the owner enters UPI details.
  insert into public.gym_payment_methods (gym_id, method)
  select v_gym_id, m.method
    from (values ('google_pay'), ('phonepe'), ('paytm'), ('upi')) as m(method)
  on conflict (gym_id, method) do nothing;

  -- Manual subscription tracking (no gateway): start on a trial.
  insert into public.gym_subscriptions (gym_id, plan, status, trial_ends_on)
  values (v_gym_id, 'trial', 'trialing', (now() at time zone 'Asia/Kolkata')::date + 14);

  update public.profiles
     set is_admin = true,
         gym_id = v_gym_id,
         full_name = coalesce(v_full_name, full_name),
         phone = coalesce(v_phone, phone),
         updated_at = now()
   where id = v_user;

  select * into v_gym from public.gyms where id = v_gym_id;

  return jsonb_build_object(
    'gym_id', v_gym.id,
    'public_id', v_gym.public_id,
    'join_code', v_gym.join_code,
    'slug', v_gym.slug,
    'name', v_gym.name,
    'is_admin', true,
    'already_registered', false
  );
end;
$$;

revoke all on function public.register_gym_owner(text, text, text, text) from public, anon, authenticated;
grant execute on function public.register_gym_owner(text, text, text, text) to authenticated;

comment on function public.register_gym_owner(text, text, text, text) is
  'Creates the caller''s gym exactly once. Safe to call again after every login; returns the existing gym instead of duplicating it.';

commit;
