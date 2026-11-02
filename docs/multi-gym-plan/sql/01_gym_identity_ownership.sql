-- ============================================================================
-- FitDesk multi-gym SaaS — draft migration 01
-- Gym identity and ownership
--
-- STATUS: DRAFT — DO NOT APPLY TO PRODUCTION WITHOUT APPROVAL.
-- Tested against a cloned local Supabase database.
-- ============================================================================

begin;

-- Prevent concurrent gym creation while IDs and ownership are backfilled.
lock table public.gyms in share row exclusive mode;

-- ---------------------------------------------------------------------------
-- 1. Ownership and permanent public Gym ID
-- ---------------------------------------------------------------------------
alter table public.gyms
  add column if not exists owner_id uuid references auth.users (id) on delete restrict,
  add column if not exists public_id text,
  add column if not exists suspended_at timestamptz,
  add column if not exists suspension_reason text;

comment on column public.gyms.owner_id is
  'Verified owner account. NULL when the existing gym has no unique admin or ownership is ambiguous.';
comment on column public.gyms.public_id is
  'Permanent human-readable Gym ID, for example FD-0001. Never reused.';
comment on column public.gyms.suspended_at is
  'Set by the platform owner when the gym is suspended.';
comment on column public.gyms.suspension_reason is
  'Platform-owner note explaining the suspension.';

-- Only backfill ownership where exactly one verified admin exists for the gym.
with admin_counts as (
  select
    p.gym_id,
    count(*)::integer as admin_count,
    (array_agg(p.id order by p.created_at, p.id))[1] as only_admin_id
  from public.profiles p
  where p.is_admin = true
    and p.gym_id is not null
  group by p.gym_id
)
update public.gyms g
   set owner_id = a.only_admin_id
  from admin_counts a
 where g.id = a.gym_id
   and a.admin_count = 1
   and g.owner_id is null;

-- ---------------------------------------------------------------------------
-- 2. Public ID sequence and formatter
-- ---------------------------------------------------------------------------
create sequence if not exists public.gym_public_id_seq;

create or replace function public.format_gym_public_id(p_seq bigint)
returns text
language sql
immutable
as $$
  select 'FD-' || case
    when p_seq < 10000 then lpad(p_seq::text, 4, '0')
    else p_seq::text
  end;
$$;

create or replace function public.handle_gym_public_id()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.public_id is null or btrim(new.public_id) = '' then
    new.public_id := public.format_gym_public_id(nextval('public.gym_public_id_seq'));
  end if;
  return new;
end;
$$;

drop trigger if exists gyms_public_id_trigger on public.gyms;
create trigger gyms_public_id_trigger
  before insert on public.gyms
  for each row
  execute function public.handle_gym_public_id();

-- Backfill in creation order. Existing public IDs are never changed.
do $$
declare
  r record;
begin
  for r in
    select id
      from public.gyms
     where public_id is null
     order by created_at, id
  loop
    update public.gyms
       set public_id = public.format_gym_public_id(nextval('public.gym_public_id_seq'))
     where id = r.id;
  end loop;
end;
$$;

create unique index if not exists gyms_public_id_unique
  on public.gyms (public_id);

alter table public.gyms alter column public_id set not null;

create index if not exists gyms_owner_idx on public.gyms (owner_id);
create index if not exists gyms_active_idx on public.gyms (is_active);

-- ---------------------------------------------------------------------------
-- 3. Admin settings now expose the permanent Gym ID and join code
-- ---------------------------------------------------------------------------
create or replace function public.admin_get_gym_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_row jsonb;
begin
  select jsonb_build_object(
    'gym_id', g.id,
    'public_id', g.public_id,
    'join_code', g.join_code,
    'owner_id', g.owner_id,
    'slug', g.slug,
    'name', g.name,
    'upi_id', g.upi_id,
    'upi_payee_name', g.upi_payee_name,
    'payment_qr_path', g.payment_qr_path,
    'is_open', g.is_open,
    'is_active', g.is_active,
    'suspended_at', g.suspended_at,
    'suspension_reason', g.suspension_reason,
    'shutter_changed_at', g.shutter_changed_at,
    'attendance_qr_months', g.attendance_qr_months,
    'attendance_qr_rotated_at', g.attendance_qr_rotated_at,
    'created_at', g.created_at,
    'updated_at', g.updated_at
  )
    into v_row
    from public.gyms g
   where g.id = v_gym_id;

  if v_row is null then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;

revoke all on function public.admin_get_gym_settings() from public, anon, authenticated;
grant execute on function public.admin_get_gym_settings() to authenticated;

commit;
