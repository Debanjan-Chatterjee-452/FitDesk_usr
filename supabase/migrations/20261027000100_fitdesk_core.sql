-- FitDesk member app — core schema
-- Timezone rule: every calendar decision is made in Asia/Kolkata.
-- Money is stored as whole Indian rupees (INR) in integer columns.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.gender as enum ('male', 'female', 'other', 'prefer_not_to_say');
create type public.blood_group as enum ('A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-');
create type public.membership_status as enum ('pending', 'active', 'expired', 'cancelled');
create type public.payment_status as enum ('created', 'pending', 'paid', 'failed', 'refunded', 'cancelled');
create type public.pricing_mode as enum ('fixed', 'per_day');
create type public.announcement_kind as enum ('info', 'holiday', 'closure');
create type public.attendance_source as enum ('qr', 'manual', 'admin');

-- ---------------------------------------------------------------------------
-- Profiles (1:1 with auth.users)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  phone text not null default '',
  full_name text,
  date_of_birth date,
  blood_group public.blood_group,
  gender public.gender,
  legal_document_path text,
  legal_document_name text,
  legal_document_type text,
  profile_completed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Member profile. Rows are created by the auth trigger and can only be read/updated by their owner.';
comment on column public.profiles.legal_document_path is
  'Private object path inside the legal-documents bucket: <user-id>/<file-name>.';
comment on column public.profiles.profile_completed is
  'Derived by trigger from the mandatory profile fields. Clients cannot set this directly.';

create unique index profiles_phone_unique
  on public.profiles (phone)
  where phone <> '';

-- ---------------------------------------------------------------------------
-- Packages
-- ---------------------------------------------------------------------------
create table public.packages (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  duration_days integer not null,
  price_inr integer not null,
  pricing_mode public.pricing_mode not null default 'fixed',
  min_days integer,
  max_days integer,
  is_active boolean not null default true,
  is_recommended boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint packages_name_not_blank check (length(btrim(name)) > 0),
  constraint packages_duration_positive check (duration_days > 0),
  constraint packages_price_non_negative check (price_inr >= 0),
  constraint packages_per_day_bounds check (
    pricing_mode <> 'per_day'
    or (
      min_days is not null
      and max_days is not null
      and min_days > 0
      and max_days >= min_days
    )
  )
);

comment on column public.packages.price_inr is
  'Fixed plans: total price. Per-day plans: price for one day.';

create index packages_active_sort_idx
  on public.packages (is_active, sort_order, name);

-- ---------------------------------------------------------------------------
-- Memberships
-- ---------------------------------------------------------------------------
create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  package_id uuid not null references public.packages (id) on delete restrict,
  starts_on date not null,
  ends_on date not null,
  price_paid_inr integer not null default 0,
  fine_paid_inr integer not null default 0,
  status public.membership_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint memberships_dates_ordered check (ends_on >= starts_on),
  constraint memberships_amounts_non_negative check (price_paid_inr >= 0 and fine_paid_inr >= 0)
);

comment on table public.memberships is
  'Immutable member entitlements. Rows are written only by the payment activation function.';

create index memberships_user_ends_idx
  on public.memberships (user_id, ends_on desc);
create index memberships_active_idx
  on public.memberships (user_id, status, ends_on desc);

-- ---------------------------------------------------------------------------
-- Gym QR codes (only a SHA-256 hash is stored)
-- ---------------------------------------------------------------------------
create table public.gym_qr_codes (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  token_hash text not null unique,
  is_active boolean not null default true,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  constraint gym_qr_codes_label_not_blank check (length(btrim(label)) > 0)
);

comment on table public.gym_qr_codes is
  'Printed front-desk QR codes. The raw token is returned once by create_gym_qr_code(); only its hash is kept.';
comment on column public.gym_qr_codes.token_hash is
  'Lowercase hex SHA-256 of the raw QR token.';

-- ---------------------------------------------------------------------------
-- Attendance
-- ---------------------------------------------------------------------------
create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  check_in_at timestamptz not null default now(),
  check_in_date date generated always as
    ((check_in_at at time zone 'Asia/Kolkata')::date) stored,
  source public.attendance_source not null default 'qr',
  gym_qr_id uuid references public.gym_qr_codes (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint attendance_one_per_ist_day unique (user_id, check_in_date)
);

comment on column public.attendance.check_in_date is
  'Generated in Asia/Kolkata so "one check-in per day" is enforced on the gym calendar.';

create index attendance_user_time_idx
  on public.attendance (user_id, check_in_at desc);
create index attendance_date_idx
  on public.attendance (check_in_date);

-- ---------------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------------
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  membership_id uuid references public.memberships (id) on delete set null,
  package_id uuid not null references public.packages (id) on delete restrict,
  duration_days integer not null,
  base_amount_inr integer not null,
  fine_amount_inr integer not null default 0,
  total_amount_inr integer not null,
  status public.payment_status not null default 'created',
  provider text not null default 'razorpay',
  provider_order_id text,
  provider_payment_id text,
  failure_reason text,
  quote jsonb,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payments_duration_positive check (duration_days > 0),
  constraint payments_amounts_valid check (
    base_amount_inr >= 0
    and fine_amount_inr >= 0
    and total_amount_inr = base_amount_inr + fine_amount_inr
  )
);

comment on table public.payments is
  'Server-created renewal orders. The browser can read its own receipts but can never insert or update a payment.';

create unique index payments_provider_order_unique
  on public.payments (provider_order_id)
  where provider_order_id is not null;
create unique index payments_provider_payment_unique
  on public.payments (provider_payment_id)
  where provider_payment_id is not null;
create index payments_user_created_idx
  on public.payments (user_id, created_at desc);
create index payments_status_created_idx
  on public.payments (status, created_at desc);

-- ---------------------------------------------------------------------------
-- Announcements and gym settings
-- ---------------------------------------------------------------------------
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  kind public.announcement_kind not null default 'info',
  starts_on date not null default ((now() at time zone 'Asia/Kolkata')::date),
  ends_on date,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint announcements_title_not_blank check (length(btrim(title)) > 0),
  constraint announcements_dates_ordered check (ends_on is null or ends_on >= starts_on)
);

create index announcements_active_dates_idx
  on public.announcements (is_active, starts_on, ends_on);
create index announcements_created_idx
  on public.announcements (created_at desc);

create table public.gym_settings (
  id smallint primary key default 1,
  name text not null default 'FitDesk Performance Club',
  address text,
  open_time time not null default '05:00',
  close_time time not null default '23:00',
  closed_weekdays smallint[] not null default '{0}'::smallint[],
  contact_phone text,
  updated_at timestamptz not null default now(),
  constraint gym_settings_singleton check (id = 1),
  constraint gym_settings_weekdays_valid check (
    closed_weekdays <@ array[0, 1, 2, 3, 4, 5, 6]::smallint[]
  )
);

comment on column public.gym_settings.closed_weekdays is
  '0 = Sunday … 6 = Saturday, in Asia/Kolkata.';

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger packages_touch_updated_at
  before update on public.packages
  for each row execute function public.touch_updated_at();

create trigger memberships_touch_updated_at
  before update on public.memberships
  for each row execute function public.touch_updated_at();

create trigger payments_touch_updated_at
  before update on public.payments
  for each row execute function public.touch_updated_at();

create trigger announcements_touch_updated_at
  before update on public.announcements
  for each row execute function public.touch_updated_at();

create trigger gym_settings_touch_updated_at
  before update on public.gym_settings
  for each row execute function public.touch_updated_at();

/**
 * Validates and normalises member-editable profile fields.
 * `profile_completed` is never trusted from the client.
 */
create or replace function public.validate_profile()
returns trigger
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
begin
  new.full_name := nullif(btrim(coalesce(new.full_name, '')), '');

  if new.date_of_birth is not null and new.date_of_birth > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'INVALID_DATE_OF_BIRTH' using errcode = 'P0001';
  end if;

  if new.legal_document_path is not null
     and length(btrim(new.legal_document_path)) > 0
     and split_part(new.legal_document_path, '/', 1) <> new.id::text then
    raise exception 'INVALID_DOCUMENT_PATH' using errcode = 'P0001';
  end if;

  new.legal_document_path := nullif(btrim(coalesce(new.legal_document_path, '')), '');
  new.legal_document_name := nullif(btrim(coalesce(new.legal_document_name, '')), '');

  -- A member cannot claim completion with a path that has no uploaded object.
  if new.legal_document_path is not null
     and not exists (
       select 1
         from storage.objects
        where bucket_id = 'legal-documents'
          and name = new.legal_document_path
     ) then
    raise exception 'DOCUMENT_NOT_UPLOADED' using errcode = 'P0001';
  end if;

  new.profile_completed :=
    new.full_name is not null
    and new.date_of_birth is not null
    and new.blood_group is not null
    and new.gender is not null
    and new.legal_document_path is not null;

  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_validate
  before insert or update on public.profiles
  for each row execute function public.validate_profile();

/** Creates a profile row for every new Supabase auth user. */
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  insert into public.profiles (id, phone)
  values (new.id, coalesce(new.phone, ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

/** Keeps the member-facing phone number in sync if auth changes it. */
create or replace function public.handle_user_phone_updated()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  update public.profiles
     set phone = coalesce(new.phone, '')
   where id = new.id;
  return new;
end;
$$;

create trigger on_auth_user_phone_updated
  after update of phone on auth.users
  for each row
  when (old.phone is distinct from new.phone)
  execute function public.handle_user_phone_updated();
