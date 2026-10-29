-- ============================================================================
-- FitDesk - member access to public.profiles
-- Target:  FitDesk production project, ref ocycaiomiiovnsjeivvd
-- Status:  PREPARED, NOT APPLIED. Run manually in the Supabase SQL Editor.
--
-- Type:    transactional, rerunnable, additive.
--          No profile row, membership, payment, admin flag or document is
--          read, written or deleted.
--
-- WHY THIS IS NOT IN supabase/migrations/
--   Migrations 20261027000100 .. 20261028000200 have never been applied to
--   this project. `supabase db push` would queue all of them and rewrite the
--   whole production schema. This script is kept outside migrations/ so it can
--   only run when a human deliberately pastes it into the SQL Editor.
--
-- OBSERVED PRODUCTION STATE (verified against the live project)
--   * public.profiles: 12 columns. There is no is_admin column, so migration
--     004 was never applied and admin tooling is inert. Nothing here depends
--     on that column.
--   * RLS enabled, relforcerowsecurity = false, table owner = postgres.
--   * pg_policies for public.profiles: zero rows.
--   * Table ACL: anon, authenticated, postgres and service_role each hold ALL
--     (INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN).
--   * There are no separate column-level ACLs today. information_schema
--     reports per-column privileges by expanding the table-level grant, which
--     is why a column check appears to show grants "across 12 columns". So
--     has_column_privilege already returns true for every column, including
--     profile_completed and phone. That is what this script removes.
--
--   PostgreSQL revokes matching column privileges automatically when the table
--   privilege is revoked by the table owner, which is the role the SQL Editor
--   and this script run as. The explicit per-column pass below is therefore a
--   second, deliberate statement of intent rather than the mechanism, and
--   Section 3 verifies effective privileges per column with
--   has_column_privilege instead of trusting either revoke. That distinction
--   matters because a per-column revoke is a no-op while a table-level grant
--   still exists, and because a grant made by a different grantor is not
--   removable by a non-owner.
--
-- INTENDED MODEL
--   authenticated : SELECT on the table, UPDATE on 7 columns, 2 own-row
--                   policies. No INSERT, DELETE, TRUNCATE, REFERENCES, TRIGGER.
--   anon          : nothing on public.profiles.
--   owner/migrations/service_role : untouched.
--
-- ONLY SECTION 2 IS EXECUTABLE IN THIS FILE. Run Section 1 first, one query at
-- a time, and read the output before running Section 2.
-- ============================================================================


-- ============================================================================
-- SECTION 1 - PREFLIGHT (read-only; run these individually first)
-- ============================================================================
--
-- 1.1 Table shape and the 7 editable columns. Every row must be present.
--
--   select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--   where table_schema = 'public' and table_name = 'profiles'
--   order by ordinal_position;
--
--   select expected.column_name,
--          (c.column_name is not null) as present
--   from (values
--           ('full_name'), ('date_of_birth'), ('blood_group'), ('gender'),
--           ('legal_document_path'), ('legal_document_name'),
--           ('legal_document_type')
--        ) as expected(column_name)
--   left join information_schema.columns c
--     on c.table_schema = 'public'
--    and c.table_name   = 'profiles'
--    and c.column_name  = expected.column_name;
--
-- 1.2 RLS state. rls_enabled must be true, rls_forced must be false.
--
--   select relname, relrowsecurity as rls_enabled,
--          relforcerowsecurity as rls_forced,
--          pg_get_userbyid(relowner) as table_owner
--   from pg_class where oid = 'public.profiles'::regclass;
--
-- 1.3 Existing policies. Expected today: zero rows.
--
--   select policyname, permissive, roles, cmd, qual, with_check
--   from pg_policies
--   where schemaname = 'public' and tablename = 'profiles'
--   order by policyname;
--
-- 1.4 Raw table ACL - shows the real grantee list, including PUBLIC.
--
--   select coalesce(g.rolname, 'PUBLIC') as grantee,
--          a.privilege_type, a.is_grantable
--   from pg_class c
--   cross join lateral aclexplode(c.relacl) a
--   left join pg_roles g on g.oid = a.grantee
--   where c.oid = 'public.profiles'::regclass
--   order by 1, 2;
--
-- 1.5 Raw column ACL - this is where the surviving UPDATE grants live.
--     Expect INSERT/REFERENCES/SELECT/UPDATE for anon and authenticated
--     across every column. That is what Section 2 removes.
--
--   select att.attname as column_name,
--          coalesce(g.rolname, 'PUBLIC') as grantee,
--          a.privilege_type, a.is_grantable
--   from pg_attribute att
--   cross join lateral aclexplode(att.attacl) a
--   left join pg_roles g on g.oid = a.grantee
--   where att.attrelid = 'public.profiles'::regclass
--     and att.attnum > 0 and not att.attisdropped
--   order by 1, 2, 3;
--
-- 1.6 Effective privileges, as PostgreSQL itself evaluates them.
--     has_column_privilege is authoritative for UPDATE because it counts a
--     table-level grant as applying to every column.
--
--   select r.role, p.privilege,
--          has_table_privilege(r.role, 'public.profiles', p.privilege) as allowed
--   from (values ('anon'), ('authenticated'), ('service_role')) as r(role)
--   cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),
--                       ('TRUNCATE'),('REFERENCES'),('TRIGGER')) as p(privilege)
--   order by 1, 2;
--
-- 1.7 Role inheritance. A grant to a role that anon/authenticated inherits
--     from would survive a direct revoke. Expect zero rows.
--
--   select r.rolname as member, g.rolname as inherits_from, m.admin_option
--   from pg_auth_members m
--   join pg_roles r on r.oid = m.member
--   join pg_roles g on g.oid = m.roleid
--   where r.rolname in ('anon','authenticated','service_role')
--      or g.rolname in ('anon','authenticated','service_role')
--   order by 1, 2;
--
-- 1.8 Default privileges. If something re-creates the table, these decide
--     what the new table starts with. Informational; this script does not
--     change them.
--
--   select pg_get_userbyid(defaclrole) as owner_role,
--          defaclnamespace::regnamespace as schema,
--          defaclobjtype as object_type,
--          defaclacl
--   from pg_default_acl;
--
-- 1.9 The helpers the app depends on. All three must be SECURITY DEFINER and
--     owned by the same role that owns the table.
--
--   select p.proname,
--          pg_get_userbyid(p.proowner) as function_owner,
--          p.prosecdef as security_definer,
--          p.proconfig as settings
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public'
--     and p.proname in ('ensure_my_profile','validate_profile',
--                       'handle_new_user','is_admin')
--   order by p.proname;
--
-- 1.10 Triggers. profiles_validate must exist: it derives profile_completed
--      and updated_at for every insert and update.
--
--   select tgname, tgtype, pg_get_triggerdef(oid) as definition
--   from pg_trigger
--   where tgrelid = 'public.profiles'::regclass and not tgisinternal
--   order by tgname;
--
-- 1.11 Storage, informational only - this script never touches it.
--
--   select id, public, file_size_limit, allowed_mime_types
--   from storage.buckets where id = 'legal-documents';
--
--   select policyname, cmd, roles
--   from pg_policies
--   where schemaname = 'storage' and tablename = 'objects'
--     and policyname like 'legal_documents%'
--   order by cmd;
--
-- STOP CONDITIONS - do not run Section 2 if any of these is true:
--   * Any of the 7 columns from 1.1 is missing.
--   * profile_completed is missing, or profiles_validate is missing from 1.10.
--     Without them profile_completed never becomes true and the app will
--     report "Some required details are still missing" after a good save.
--   * ensure_my_profile is missing, is not SECURITY DEFINER, or its owner
--     differs from the table owner (1.2 vs 1.9).
--   * rls_forced = true.
--   * 1.3 returns a policy that is not named profiles_select_own or
--     profiles_update_own, or a same-named policy whose cmd is not SELECT /
--     UPDATE, or any RESTRICTIVE policy. Section 2 raises instead of
--     overwriting; send the output and I will adapt the script.
--   * 1.7 returns any row - an inherited grant would survive a direct revoke.


-- ============================================================================
-- SECTION 2 - REPAIR (the only executable block in this file)
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 2.1 Refuse to touch a schema that does not match expectations.
-- ---------------------------------------------------------------------------
do $$
declare
  v_unexpected  text;
  v_wrong_cmd   text;
  v_restrictive text;
  v_forced      boolean;
begin
  select string_agg(policyname, ', ' order by policyname)
    into v_unexpected
    from pg_policies
   where schemaname = 'public'
     and tablename  = 'profiles'
     and policyname not in ('profiles_select_own', 'profiles_update_own');

  if v_unexpected is not null then
    raise exception 'Unexpected policy on public.profiles: %', v_unexpected
      using hint = 'Stop. Review pg_policies for public.profiles. Nothing was changed.';
  end if;

  select string_agg(policyname || ' (cmd=' || cmd || ')', ', ' order by policyname)
    into v_wrong_cmd
    from pg_policies
   where schemaname = 'public'
     and tablename  = 'profiles'
     and ((policyname = 'profiles_select_own' and cmd <> 'SELECT')
       or (policyname = 'profiles_update_own' and cmd <> 'UPDATE'));

  if v_wrong_cmd is not null then
    raise exception 'Policy with an unexpected command: %', v_wrong_cmd
      using hint = 'Stop. Nothing was changed.';
  end if;

  select string_agg(policyname, ', ' order by policyname)
    into v_restrictive
    from pg_policies
   where schemaname = 'public'
     and tablename  = 'profiles'
     and permissive = 'RESTRICTIVE';

  if v_restrictive is not null then
    raise exception 'Restrictive policy present on public.profiles: %', v_restrictive
      using hint = 'Stop. Recreating it as permissive could loosen access.';
  end if;

  select relforcerowsecurity into v_forced
    from pg_class where oid = 'public.profiles'::regclass;

  if v_forced then
    raise exception 'public.profiles has FORCE ROW LEVEL SECURITY enabled'
      using hint = 'FORCE would also subject the SECURITY DEFINER helpers to RLS. Stop.';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 2.2 RLS stays on. This is a no-op when it is already enabled.
--     ACCESS EXCLUSIVE is held for the rest of this short transaction.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;

-- ---------------------------------------------------------------------------
-- 2.3 Revoke, then re-grant. Nothing is left to inheritance.
-- ---------------------------------------------------------------------------

-- Table-level privileges, including any granted via PUBLIC. Revoking at table
-- level also clears the matching column privileges when issued by the owner.
revoke all on table public.profiles from public;
revoke all on table public.profiles from anon, authenticated;

-- Column-level pass, on every column that actually exists. This is a no-op
-- once the table-level revoke above has landed, but it keeps the intent
-- explicit and covers the case where a grant was recorded against a column by
-- a grantor the table-level statement could not reach. Enumerating the live
-- columns keeps it correct whether or not is_admin exists in this project.
do $$
declare
  v_column record;
begin
  for v_column in
    select a.attname
      from pg_attribute a
     where a.attrelid = 'public.profiles'::regclass
       and a.attnum > 0
       and not a.attisdropped
     order by a.attnum
  loop
    execute format(
      'revoke all (%I) on table public.profiles from public',
      v_column.attname
    );
    execute format(
      'revoke all (%I) on table public.profiles from anon, authenticated',
      v_column.attname
    );
  end loop;
end
$$;

-- Members read their own row. Table-level SELECT is required because the app
-- calls select('*') / .select('*'), which expands to every column including
-- profile_completed, is_admin and the timestamps. Row scoping comes from
-- profiles_select_own below, not from the column list.
grant select on table public.profiles to authenticated;

-- Members write exactly the seven form fields. Column-level UPDATE only; no
-- table-level UPDATE, so id, phone, profile_completed, is_admin, created_at
-- and updated_at stay unwritable from the API.
grant update (
  full_name,
  date_of_birth,
  blood_group,
  gender,
  legal_document_path,
  legal_document_name,
  legal_document_type
) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- 2.4 Own-row policies. Recreated inside this transaction, so there is never
--     a window in which the table is reachable without a policy.
-- ---------------------------------------------------------------------------
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles
  for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

commit;


-- ============================================================================
-- SECTION 3 - POST-CHANGE VERIFICATION (read-only, run after the commit)
-- ============================================================================
--
-- 3.1 Expect exactly two policies, both PERMISSIVE, roles {authenticated},
--     predicates containing auth.uid() and id.
--
--   select policyname, permissive, roles, cmd, qual, with_check
--   from pg_policies
--   where schemaname = 'public' and tablename = 'profiles'
--   order by cmd;
--
-- 3.2 Effective table privileges (PostgreSQL 17 adds MAINTAIN).
--     Expect: authenticated SELECT = true, every write/DDL flag = false;
--             anon all false; service_role still able to read and write.
--
--   select r.role, p.privilege,
--          has_table_privilege(r.role, 'public.profiles', p.privilege) as allowed
--   from (values ('anon'), ('authenticated'), ('service_role')) as r(role)
--   cross join (values ('SELECT'),('INSERT'),('UPDATE'),('DELETE'),
--                       ('TRUNCATE'),('REFERENCES'),('TRIGGER'),
--                       ('MAINTAIN')) as p(privilege)
--   order by 1, 2;
--
-- 3.3 Effective per-column UPDATE. Expect true for authenticated on exactly
--     the 7 approved columns, false on id, phone, profile_completed,
--     is_admin (if present), created_at and updated_at. Expect false for anon
--     everywhere.
--
--   select c.column_name,
--          has_column_privilege('anon', 'public.profiles', c.column_name, 'UPDATE')
--            as anon_can_update,
--          has_column_privilege('authenticated', 'public.profiles', c.column_name, 'UPDATE')
--            as member_can_update
--   from information_schema.columns c
--   where c.table_schema = 'public' and c.table_name = 'profiles'
--   order by c.ordinal_position;
--
-- 3.4 Raw ACLs - no leftover grants. The column query should return exactly
--     seven UPDATE rows, all for authenticated.
--
--   select coalesce(g.rolname, 'PUBLIC') as grantee,
--          a.privilege_type, a.is_grantable
--   from pg_class c
--   cross join lateral aclexplode(c.relacl) a
--   left join pg_roles g on g.oid = a.grantee
--   where c.oid = 'public.profiles'::regclass
--   order by 1, 2;
--
--   select att.attname as column_name,
--          coalesce(g.rolname, 'PUBLIC') as grantee,
--          a.privilege_type
--   from pg_attribute att
--   cross join lateral aclexplode(att.attacl) a
--   left join pg_roles g on g.oid = a.grantee
--   where att.attrelid = 'public.profiles'::regclass
--     and att.attnum > 0 and not att.attisdropped
--   order by 1, 2;
--
-- 3.5 Optional functional check. Impersonates a signed-in member, then rolls
--     back. Replace the UUID with your own auth.users.id. Expect: your own row
--     only; a write to is_admin or phone fails; a write to full_name succeeds.
--
--   begin;
--   set local role authenticated;
--   set local request.jwt.claims =
--     '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}';
--   select id, full_name, profile_completed from public.profiles;
--   update public.profiles set full_name = full_name where id = auth.uid();
--   reset role;
--   rollback;


-- ============================================================================
-- SECTION 4 - ROLLBACK
-- ============================================================================
--
-- This restores the previous *intended* state: RLS enabled, no policies. It
-- deliberately does not restore the broad table-level and column-level write
-- grants that were removed, because those are the vulnerability this change
-- fixes. Nothing about the application depends on them: the only direct write
-- the app performs is the seven-column profile update, and every other
-- mutation goes through SECURITY DEFINER functions that run as the owner.
--
--   begin;
--   drop policy if exists "profiles_update_own" on public.profiles;
--   drop policy if exists "profiles_select_own" on public.profiles;
--   commit;
--
-- Full restoration of the old, over-privileged ACL is possible but is a
-- security regression and should be an explicit, separate decision:
--
--   -- NOT RECOMMENDED
--   -- begin;
--   -- grant select, insert, update, references
--   --   on table public.profiles to anon, authenticated;
--   -- commit;
-- ============================================================================
