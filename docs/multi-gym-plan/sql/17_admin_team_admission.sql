-- 17_admin_team_admission.sql
-- Admin team management (create/edit/remove a second gym admin) and
-- admission-fee exposure to the member app.
--
-- Invariants:
--   * Every RPC is gym-scoped through public.admin_assert().
--   * The two-admin limit is serialised with a per-gym advisory lock and is
--     also enforced by the enforce_two_admins_per_gym trigger.
--   * The gym owner can never be revoked by another admin.
--   * Existing member accounts may be promoted, never moved across gyms.

begin;

-- ---------------------------------------------------------------------------
-- List admins for the signed-in admin's gym.
-- ---------------------------------------------------------------------------
create or replace function public.admin_list_gym_admins()
returns jsonb
language plpgsql
stable
security definer
set search_path to public, auth, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
begin
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'user_id', p.id,
               'email', u.email,
               'full_name', p.full_name,
               'phone', p.phone,
               'avatar_path', p.avatar_path,
               'is_owner', (g.owner_id = p.id),
               'is_self', (p.id = auth.uid()),
               'created_at', p.created_at
             )
             order by (g.owner_id = p.id) desc, p.created_at asc
           )
      from public.profiles p
      join auth.users u on u.id = p.id
      join public.gyms g on g.id = p.gym_id
     where p.gym_id = v_gym_id
       and p.is_admin = true
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Create (or promote) a second gym admin with a usable password.
-- ---------------------------------------------------------------------------
create or replace function public.admin_create_gym_admin(
  p_full_name text,
  p_email text,
  p_password text,
  p_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path to public, auth, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_name text := nullif(btrim(coalesce(p_full_name, '')), '');
  v_email text := lower(nullif(btrim(coalesce(p_email, '')), ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_user_id uuid;
  v_profile public.profiles;
  v_count integer;
begin
  if v_name is null or length(v_name) < 2 then
    raise exception 'FULL_NAME_REQUIRED' using errcode = '22023';
  end if;

  if v_email is null
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'INVALID_EMAIL' using errcode = '22023';
  end if;

  if p_password is null or length(p_password) < 8 then
    raise exception 'PASSWORD_TOO_SHORT' using errcode = '22023';
  end if;

  -- Serialise admin creation per gym so two concurrent requests cannot both
  -- observe a free slot.
  perform pg_advisory_xact_lock(hashtext('gym_admin:' || v_gym_id::text));

  select id into v_user_id
    from auth.users
   where lower(email) = v_email
   limit 1;

  if v_user_id is not null then
    select * into v_profile
      from public.profiles
     where id = v_user_id;

    if not found then
      insert into public.profiles (id, phone)
      values (v_user_id, coalesce(v_phone, ''))
      on conflict (id) do nothing;
    end if;

    if v_profile.gym_id is not null and v_profile.gym_id <> v_gym_id then
      raise exception 'ADMIN_IN_OTHER_GYM' using errcode = 'P0001';
    end if;

    if not (v_profile.is_admin is true and v_profile.gym_id = v_gym_id) then
      select count(*) into v_count
        from public.profiles
       where gym_id = v_gym_id
         and is_admin is true;

      if v_count >= 2 then
        raise exception 'GYM_ADMIN_LIMIT_REACHED' using errcode = '22023';
      end if;
    end if;

    update auth.users
       set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()),
           updated_at = now()
     where id = v_user_id;

    update public.profiles
       set full_name = v_name,
           phone = coalesce(v_phone, phone),
           is_admin = true,
           gym_id = v_gym_id,
           is_deactivated = false,
           deactivated_at = null,
           deactivated_by = null,
           profile_completed = true,
           updated_at = now()
     where id = v_user_id;

    return jsonb_build_object(
      'status', 'added',
      'user_id', v_user_id,
      'existing_user', true
    );
  end if;

  select count(*) into v_count
    from public.profiles
   where gym_id = v_gym_id
     and is_admin is true;

  if v_count >= 2 then
    raise exception 'GYM_ADMIN_LIMIT_REACHED' using errcode = '22023';
  end if;

  v_user_id := gen_random_uuid();

  begin
    insert into auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      created_at,
      updated_at,
      raw_app_meta_data,
      raw_user_meta_data,
      confirmation_token,
      recovery_token,
      email_change_token_new,
      email_change
    ) values (
      '00000000-0000-0000-0000-000000000000',
      v_user_id,
      'authenticated',
      'authenticated',
      v_email,
      extensions.crypt(p_password, extensions.gen_salt('bf')),
      now(),
      now(),
      now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('full_name', v_name, 'phone', coalesce(v_phone, '')),
      '',
      '',
      '',
      ''
    );
  exception when unique_violation then
    raise exception 'EMAIL_ALREADY_REGISTERED' using errcode = 'P0001';
  end;

  begin
    insert into auth.identities (
      provider_id,
      user_id,
      identity_data,
      provider,
      last_sign_in_at,
      created_at,
      updated_at
    ) values (
      v_user_id::text,
      v_user_id,
      jsonb_build_object(
        'sub', v_user_id::text,
        'email', v_email,
        'email_verified', true,
        'phone_verified', false
      ),
      'email',
      now(),
      now(),
      now()
    );
  exception when unique_violation then
    null;
  end;

  update public.profiles
     set full_name = v_name,
         phone = coalesce(v_phone, ''),
         is_admin = true,
         gym_id = v_gym_id,
         profile_completed = true,
         updated_at = now()
   where id = v_user_id;

  return jsonb_build_object(
    'status', 'created',
    'user_id', v_user_id,
    'existing_user', false
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Edit an admin's display details and (optionally) reset their password.
-- ---------------------------------------------------------------------------
create or replace function public.admin_update_gym_admin(
  p_user_id uuid,
  p_full_name text,
  p_phone text default null,
  p_password text default null
)
returns jsonb
language plpgsql
security definer
set search_path to public, auth, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_name text := nullif(btrim(coalesce(p_full_name, '')), '');
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
begin
  if p_user_id is null then
    raise exception 'ADMIN_NOT_FOUND' using errcode = 'P0001';
  end if;

  if not exists (
    select 1
      from public.profiles
     where id = p_user_id
       and gym_id = v_gym_id
       and is_admin is true
  ) then
    raise exception 'ADMIN_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_name is not null and length(v_name) < 2 then
    raise exception 'FULL_NAME_REQUIRED' using errcode = '22023';
  end if;

  update public.profiles
     set full_name = coalesce(v_name, full_name),
         phone = coalesce(v_phone, phone),
         updated_at = now()
   where id = p_user_id;

  if p_password is not null and length(p_password) > 0 then
    if length(p_password) < 8 then
      raise exception 'PASSWORD_TOO_SHORT' using errcode = '22023';
    end if;

    update auth.users
       set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
           updated_at = now()
     where id = p_user_id;
  end if;

  return jsonb_build_object('status', 'updated', 'user_id', p_user_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Revoke admin access. Replaces the earlier version with owner protection
-- and the same per-gym lock.
-- ---------------------------------------------------------------------------
create or replace function public.admin_remove_gym_admin(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to public, auth, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_count integer;
begin
  if p_user_id = auth.uid() then
    raise exception 'CANNOT_REMOVE_SELF' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtext('gym_admin:' || v_gym_id::text));

  if exists (
    select 1 from public.gyms
     where id = v_gym_id
       and owner_id = p_user_id
  ) then
    raise exception 'GYM_OWNER_CANNOT_BE_REMOVED' using errcode = '22023';
  end if;

  if not exists (
    select 1
      from public.profiles
     where id = p_user_id
       and gym_id = v_gym_id
       and is_admin is true
  ) then
    raise exception 'ADMIN_NOT_FOUND' using errcode = 'P0001';
  end if;

  select count(*) into v_count
    from public.profiles
   where gym_id = v_gym_id
     and is_admin is true;

  if v_count <= 1 then
    raise exception 'LAST_ADMIN_CANNOT_BE_REMOVED' using errcode = '22023';
  end if;

  update public.profiles
     set is_admin = false,
         updated_at = now()
   where id = p_user_id
     and gym_id = v_gym_id;

  return jsonb_build_object('status', 'removed', 'user_id', p_user_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Keep the legacy email-only promote path behind the same lock.
-- ---------------------------------------------------------------------------
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

  perform pg_advisory_xact_lock(hashtext('gym_admin:' || v_gym_id::text));

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
   where gym_id = v_gym_id
     and is_admin is true;

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

-- ---------------------------------------------------------------------------
-- Admission fee: normalise negative/null input to 0 (fee disabled).
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_admission_fee(p_amount integer)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_amount integer := greatest(coalesce(p_amount, 0), 0);
begin
  update public.gyms
     set admission_fee_inr = v_amount,
         updated_at = now()
   where id = v_gym_id;

  return jsonb_build_object('gym_id', v_gym_id, 'admission_fee_inr', v_amount);
end;
$$;

-- ---------------------------------------------------------------------------
-- Expose the live admission fee to the member app.
-- ---------------------------------------------------------------------------
create or replace function public.member_gym_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path to public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_gym_id uuid;
  v_gym public.gyms;
  v_settings public.gym_settings;
  v_announcements jsonb;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED' using errcode = 'P0001';
  end if;

  select gym_id into v_gym_id
    from public.profiles
   where id = v_user;

  if v_gym_id is null then
    return jsonb_build_object('status', 'no_gym');
  end if;

  select * into v_gym
    from public.gyms
   where id = v_gym_id;

  if not found then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  select * into v_settings
    from public.gym_settings
   where gym_id = v_gym_id;

  select coalesce(
           jsonb_agg(to_jsonb(a) order by a.created_at desc),
           '[]'::jsonb
         )
    into v_announcements
    from public.announcements a
   where a.gym_id = v_gym_id
     and a.is_active = true
     and a.starts_on <= v_today
     and (a.ends_on is null or a.ends_on >= v_today);

  return jsonb_build_object(
    'status', case when v_gym.is_active then 'active' else 'suspended' end,
    'gym_id', v_gym.id,
    'gym_name', v_gym.name,
    'is_open', v_gym.is_open,
    'settings', case
      when v_settings.gym_id is null then null
      else jsonb_build_object(
        'id', v_settings.id,
        'gym_id', v_settings.gym_id,
        'name', v_gym.name,
        'address', v_settings.address,
        'open_time', v_settings.open_time,
        'close_time', v_settings.close_time,
        'closed_weekdays', v_settings.closed_weekdays,
        'contact_phone', v_settings.contact_phone,
        'admission_fee_inr', coalesce(v_gym.admission_fee_inr, 0),
        'updated_at', v_settings.updated_at
      )
    end,
    'announcements', v_announcements
  );
end;
$$;

-- The quote RPCs read gyms/packages/memberships directly. Members have no
-- table grants, so these must run as the definer (they are already scoped to
-- auth.uid()). Both overloads are required by the member app.
alter function public.get_my_renewal_quote(uuid, integer) security definer;
alter function public.get_my_renewal_quote(uuid, integer, boolean) security definer;
alter function public.get_my_renewal_quote(uuid, integer) set search_path = public, pg_temp;
alter function public.get_my_renewal_quote(uuid, integer, boolean) set search_path = public, pg_temp;

revoke all on function public.get_my_renewal_quote(uuid, integer) from public, anon;
revoke all on function public.get_my_renewal_quote(uuid, integer, boolean) from public, anon;
grant execute on function public.get_my_renewal_quote(uuid, integer) to authenticated;
grant execute on function public.get_my_renewal_quote(uuid, integer, boolean) to authenticated;

revoke all on function public.admin_list_gym_admins() from public, anon, authenticated;
revoke all on function public.admin_create_gym_admin(text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_update_gym_admin(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_remove_gym_admin(uuid) from public, anon, authenticated;
revoke all on function public.admin_add_gym_admin(text) from public, anon, authenticated;
revoke all on function public.admin_set_admission_fee(integer) from public, anon, authenticated;
revoke all on function public.member_gym_overview() from public, anon, authenticated;

grant execute on function public.admin_list_gym_admins() to authenticated;
grant execute on function public.admin_create_gym_admin(text, text, text, text) to authenticated;
grant execute on function public.admin_update_gym_admin(uuid, text, text, text) to authenticated;
grant execute on function public.admin_remove_gym_admin(uuid) to authenticated;
grant execute on function public.admin_add_gym_admin(text) to authenticated;
grant execute on function public.admin_set_admission_fee(integer) to authenticated;
grant execute on function public.member_gym_overview() to authenticated;

notify pgrst, 'reload schema';

commit;
