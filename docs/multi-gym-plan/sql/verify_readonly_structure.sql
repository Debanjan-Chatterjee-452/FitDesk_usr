-- ============================================================================
-- FitDesk read-only verification — structure and catalog facts
--
-- SAFE: every statement is a SELECT. No INSERT, UPDATE, DELETE, DDL, or
-- function execution that writes. Run against canonical and legacy, save the
-- output, and compare.
--
-- Usage (after `supabase login`):
--   npx.cmd --yes supabase db query --project-ref <ref> \
--     --file docs/multi-gym-plan/sql/verify_readonly_structure.sql \
--     --output csv > verification/<ref>-structure.csv
-- ============================================================================

with
table_rows as (
  select
    'rows' as section,
    n.nspname || '.' || c.relname as item,
    coalesce(
      (xpath('/table/row/c/text()', query_to_xml(
        format('select count(*) as c from %I.%I', n.nspname, c.relname),
        false, false, ''
      )))[1]::text,
      '0'
    ) as value
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r', 'p')
    and n.nspname !~ '^pg_'
    and n.nspname <> 'information_schema'
),

functions as (
  select
    'function' as section,
    n.nspname || '.' || p.proname || '(' ||
      pg_get_function_identity_arguments(p.oid) || ')' as item,
    md5(pg_get_functiondef(p.oid)) as value
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where p.prokind in ('f', 'p')
    and n.nspname in ('public', 'storage', 'realtime')
),

policies as (
  select
    'policy' as section,
    schemaname || '.' || tablename || ' ' || policyname as item,
    cmd || ' | roles=' || array_to_string(roles, ',') as value
  from pg_policies
  where schemaname in ('public', 'storage')
),

triggers as (
  select
    'trigger' as section,
    n.nspname || '.' || c.relname || ' ' || t.tgname as item,
    pg_get_triggerdef(t.oid) as value
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where not t.tgisinternal
    and n.nspname in ('public', 'storage')
),

grants as (
  select
    'grant' as section,
    table_schema || '.' || table_name || ' ' || grantee || ' ' || privilege_type as item,
    'yes' as value
  from information_schema.role_table_grants
  where table_schema in ('public', 'storage')
    and grantee in ('anon', 'authenticated', 'service_role')
),

buckets as (
  select
    'bucket' as section,
    name as item,
    'public=' || public::text ||
      ' | limit=' || coalesce(file_size_limit::text, 'null') as value
  from storage.buckets
),

objects as (
  select
    'objects' as section,
    bucket_id as item,
    'count=' || count(*)::text ||
      ' | bytes=' || coalesce(sum((metadata->>'size')::bigint), 0)::text as value
  from storage.objects
  group by bucket_id
),

users as (
  select 'auth_users' as section, 'count' as item, count(*)::text as value
    from auth.users
  union all
  select 'auth_users', 'confirmed',
         count(*) filter (where email_confirmed_at is not null)::text
    from auth.users
  union all
  select 'auth_users', 'distinct_emails',
         count(distinct lower(email))::text
    from auth.users
  union all
  select 'auth_users', 'email_fingerprint',
         coalesce(md5(string_agg(lower(email), ',' order by lower(email))), 'empty')
    from auth.users
),

identities as (
  select 'auth_identity' as section, provider as item, count(*)::text as value
  from auth.identities
  group by provider
),

realtime as (
  select
    'realtime' as section,
    schemaname || '.' || tablename as item,
    'published' as value
  from pg_publication_tables
  where pubname = 'supabase_realtime'
),

extensions as (
  select 'extension' as section, extname as item, extversion as value
  from pg_extension
),

migrations as (
  select
    'migration' as section,
    version as item,
    name as value
  from (
    select
      unnest(xpath('/table/row/version/text()', m.xml))::text as version,
      unnest(xpath('/table/row/name/text()', m.xml))::text as name
    from (
      select case
        when to_regclass('supabase_migrations.schema_migrations') is null then null
        else query_to_xml(
          'select version, name from supabase_migrations.schema_migrations order by version',
          false, false, ''
        )
      end as xml
    ) m
  ) x
  where version is not null
)

select section, item, value from table_rows
union all select section, item, value from functions
union all select section, item, value from policies
union all select section, item, value from triggers
union all select section, item, value from grants
union all select section, item, value from buckets
union all select section, item, value from objects
union all select section, item, value from users
union all select section, item, value from identities
union all select section, item, value from realtime
union all select section, item, value from extensions
union all select section, item, value from migrations
order by section, item;
