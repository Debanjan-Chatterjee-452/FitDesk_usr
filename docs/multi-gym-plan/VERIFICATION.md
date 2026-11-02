# Read-Only Verification (canonical + legacy)

> **Status: VERIFIED (read-only) on 2026-11-02.**
> Canonical and legacy projects were inspected with authenticated CLI access.
> No production data was changed by the verification itself. Migrations were
> applied afterwards with the user's explicit authorization.

## 0. Why this exists

The plan is approved, but the production database, legacy project and backups
have not yet been verified with real credentials. This document is the
checklist for items A–F in the user's instruction and records the evidence.

The Supabase CLI can run read-only SQL through the Management API, so no
database password and no service-role key are needed:

```powershell
npx.cmd --yes supabase db query --project-ref <ref> --file <file> --output csv
npx.cmd --yes supabase backups list --project-ref <ref> --output json
```

`npx.cmd` is used because PowerShell script execution is disabled on this
machine. The access token is read by the CLI from `%USERPROFILE%\.supabase` and
is never printed or committed.

---

## 1. Login check

Run once, in the user's own terminal:

```powershell
npx.cmd --yes supabase login
```

Then:

```powershell
npx.cmd --yes supabase projects list
```

Expected: both projects are listed.

| Project | Ref | Role | Status |
|---|---|---|---|
| FitDesk production | `psgepyvdwvunjkbacsxe` | canonical | pending login |
| FitDesk legacy | `ocycaiomiiovnsjeivvd` | read-only inspection | pending login |

If the CLI reports a missing `database_read` scope, the fallback is a
user-provided read-only connection string in an environment variable. Do not
paste a password or service-role key into chat.

---

## 2. Verification commands

Outputs are written outside the repository, under
`C:\Users\Lenovo\AppData\Local\Temp\opencode\fitdesk-verify\`.
They contain counts and hashes only, not e-mails or member data.

```powershell
$out = "C:\Users\Lenovo\AppData\Local\Temp\opencode\fitdesk-verify"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$plan = "D:\Gym App\docs\multi-gym-plan"

foreach ($ref in @("psgepyvdwvunjkbacsxe", "ocycaiomiiovnsjeivvd")) {
  npx.cmd --yes supabase db query --project-ref $ref `
    --file "$plan\sql\verify_readonly_structure.sql" --output csv `
    > "$out\$ref-structure.csv"

  npx.cmd --yes supabase db query --project-ref $ref `
    --file "$plan\sql\verify_readonly_hashes.sql" --output csv `
    > "$out\$ref-hashes.csv"
}

npx.cmd --yes supabase backups list --project-ref psgepyvdwvunjkbacsxe --output json `
  > "$out\canonical-backups.json"
npx.cmd --yes supabase backups list --project-ref ocycaiomiiovnsjeivvd --output json `
  > "$out\legacy-backups.json"
```

Do not run these with `--linked`; `--project-ref` avoids creating or changing
local link metadata.

---

## 3. A–F checklist and evidence

| Item | What is checked | Result |
|---|---|---|
| A | Canonical project exists, ref matches, region/status, migration history | **Verified** — `psgepyvdwvunjkbacsxe`, "FitDesk-admin", region `ap-southeast-1`, status `ACTIVE_HEALTHY`, Postgres 17.11 |
| B | Legacy project exists, is reachable, and is only read | **Verified** — `ocycaiomiiovnsjeivvd`, "FitDesk", same region, `ACTIVE_HEALTHY`. Read-only queries only. |
| C1 | Auth users: count, confirmed count, distinct e-mails, e-mail hash | **Verified** — canonical 2 users (2 confirmed, 2 distinct); legacy 2 users (2 confirmed, 2 distinct). One shared e-mail hash; one unique to each project. |
| C2 | Tables and exact row counts (all schemas) | **Verified** — see `*-hashes.csv`. Canonical: gyms 3, profiles 2, memberships 0, payments 1, attendance 0, packages 7, gym_settings 3, announcements 0, gym_join_requests 0 (before #13; now present), auth_users 2, storage_objects 1. Legacy: gyms 1, profiles 2, memberships 0, payments 0, attendance 0, packages 5, gym_settings 1, announcements 1, auth_users 2, storage_objects 4. |
| C3 | Storage buckets, public/private flag, object counts and bytes | **Verified** — canonical: `gym-payment-qr` (public), `legal-documents` (private, 1 object, 1,973,575 bytes), `payment-proofs` (private). Legacy: `gym-payment-qr` (public), `legal-document` (private), `legal-documents` (private, 4 objects, 1,545,815 bytes). |
| C4 | Functions/RPCs: names, arguments, body hashes | **Verified** — canonical 96 functions, legacy 79. Canonical has the newer admin/platform/join RPCs. |
| C5 | Triggers: definitions | **Verified** — canonical 18, legacy 16. |
| C6 | RLS policies and table grants | **Verified** — canonical 22 policies, legacy 16. |
| C7 | Migration history | **Not tracked in DB** — no `supabase_migrations` schema in either project. Object presence used instead (see E). |
| C8 | Realtime publication tables | **Verified** — `supabase_realtime` publication exists in both but has **no published tables**. Canonical also has `supabase_realtime_messages_publication` with daily message tables. |
| D | Backup / PITR window, retention, recoverability | **Verified** — `pitr_enabled: false`, `backups: null` in both projects. No managed PITR. A fresh logical dump (schema + data) was taken for canonical before migration and stored locally. |
| E | Migration #13 applied or not (do not assume) | **Verified before migration: NOT applied** (join table and RPCs absent). **Now applied** as part of the production migration run, along with drafts 01–07. |
| F | Documentation updated with actual results | **Done** — this file. |

### E. Migration #13 (explicit check)

```sql
select version, name, inserted_at
  from supabase_migrations.schema_migrations
 where version like '20261104000100%';

select to_regclass('public.gym_join_requests') as join_table,
       to_regproc('public.request_join_gym') as request_rpc,
       to_regproc('public.admin_review_join_request') as review_rpc;
```

Expected if applied: one migration row, non-null `join_table`, both RPCs.
Earlier REST probes suggested #13 is **not** applied (`PGRST205`/`PGRST202`),
but this check is the authority.

### D. Backup / PITR

`supabase backups list` returns physical backups and PITR metadata. Record:

- earliest recoverable timestamp;
- latest recoverable timestamp;
- retention window in days;
- backup status (completed/failed);
- whether the window covers the planned migration and rollback window.

If the list is empty, the dashboard must be checked before planning a window.
An available PITR window is necessary but not sufficient: the plan also requires
a fresh logical dump restored into a scratch database with row counts checked.

---

## 4. How the two projects will be compared

1. `structure.csv`: compare `section,item,value` sets. Expected differences:
   canonical has the newer migrations/functions; legacy may have older ones.
   Anything unexpected is recorded, not fixed.
2. `hashes.csv`: compare counts and ID fingerprints per table. Equal counts +
   equal fingerprint means the same ID set. Different means a deeper diff is
   needed before claiming "no unique data".
3. Auth e-mails are compared as SHA/MD5 hashes only. No plaintext e-mail list is
   written to the repository or printed in chat.
4. If legacy holds rows absent from canonical, a separate export/merge proposal
   is written. Nothing is merged automatically.
5. If a comparison is ambiguous, it is reported as ambiguous and left alone.

---

## 5. Safety rules

- Only `verify_readonly_structure.sql` and `verify_readonly_hashes.sql` are run
  remotely; both contain only `SELECT`/CTE queries.
- No `supabase link`, `db push`, `db reset`, `migration`, `seed`, storage
  command, or auth command is run.
- No production migration, schema change, RLS change, storage change, deploy,
  branch push, or data change.
- The platform-owner account remains uncreated until the user supplies the
  confirmed e-mail.
- If any query fails, stop and report; do not retry with a write-capable
  workaround.

---

## 6. Results log

Filled in only after login. Until then every row stays "Pending".

| Check | Canonical | Legacy | Notes |
|---|---|---|---|
| Project ref/status | `psgepyvdwvunjkbacsxe`, ACTIVE_HEALTHY | `ocycaiomiiovnsjeivvd`, ACTIVE_HEALTHY | Same org and region |
| Migration head | No `supabase_migrations` schema; #13 absent before, now #13+01–07 applied | No `supabase_migrations` schema | Object-presence check used |
| Auth users count | 2 (2 confirmed) | 2 (2 confirmed) | One shared e-mail hash |
| Public tables | See hashes | See hashes | 3 gyms vs 1 gym; 1 vs 0 payments |
| Storage buckets | 3 buckets, 1 object | 3 buckets, 4 objects | Legacy has an extra `legal-document` bucket |
| RPC count | 96 | 79 | Canonical has newer admin/platform/join RPCs |
| Policy count | 22 | 16 | |
| Trigger count | 18 | 16 | |
| Realtime tables | None published in `supabase_realtime` | None published | Canonical has daily broadcast message tables |
| PITR window | Disabled | Disabled | Logical dump taken for canonical before migration |
| Migration #13 | Applied in production (verified) | n/a | |
