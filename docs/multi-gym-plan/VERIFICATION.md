# Read-Only Verification (canonical + legacy)

> **Status: BLOCKED until `supabase login` completes.**
> Nothing in this document has been run against production yet.
>
> All checks are `SELECT`-only. No migration, DDL, write, delete, auth change,
> storage change, or deploy is performed.

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
| A | Canonical project exists, ref matches, region/status, migration history | Pending |
| B | Legacy project exists, is reachable, and is only read | Pending |
| C1 | Auth users: count, confirmed count, distinct e-mails, e-mail hash | Pending |
| C2 | Tables and exact row counts (all schemas) | Pending |
| C3 | Storage buckets, public/private flag, object counts and bytes | Pending |
| C4 | Functions/RPCs: names, arguments, body hashes | Pending |
| C5 | Triggers: definitions | Pending |
| C6 | RLS policies and table grants | Pending |
| C7 | Migration history | Pending |
| C8 | Realtime publication tables | Pending |
| D | Backup / PITR window, retention, recoverability | Pending |
| E | Migration #13 applied or not (do not assume) | Pending |
| F | Documentation updated with actual results | Pending |

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
| Project ref/status | Pending | Pending | |
| Migration head | Pending | Pending | |
| Auth users count | Pending | Pending | |
| Public tables | Pending | Pending | |
| Storage buckets | Pending | Pending | |
| Storage objects | Pending | Pending | |
| RPC count | Pending | Pending | |
| Policy count | Pending | Pending | |
| Trigger count | Pending | Pending | |
| Realtime tables | Pending | Pending | |
| PITR window | Pending | n/a | |
| Migration #13 | Pending | n/a | |
