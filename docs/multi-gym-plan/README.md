# FitDesk Multi-Gym SaaS — Plan and Draft Migrations

> **Status: DRAFT — NOT APPLIED TO PRODUCTION.**
> Nothing has been deployed, migrated, or deleted. This folder is planning and
> local-test material only.

This folder contains the complete plan the user asked for, in plain language,
plus the exact SQL, rollback scripts, test matrix, and runbook.

## Read these in order

| File | What it answers |
|---|---|
| [`FINAL-PLAN.md`](FINAL-PLAN.md) | The whole plan in simple language, plus the approval checklist. Start here. |
| [`AUDIT-FINDINGS.md`](AUDIT-FINDINGS.md) | What the read-only audit found, including the gap list and the blocked legacy project. |
| [`FRONTEND-CHANGES.md`](FRONTEND-CHANGES.md) | Every UI change, why it is needed, and what does **not** change. |
| [`VERIFICATION.md`](VERIFICATION.md) | Read-only A–F verification checklist for canonical, legacy, backups, and migration #13. |
| [`TEST-MATRIX.md`](TEST-MATRIX.md) | Gym A / Gym B isolation tests (46 checks) and the local results already obtained. |
| [`BACKUP-AND-ROLLBACK.md`](BACKUP-AND-ROLLBACK.md) | Verified-backup checklist, PITR steps, rollback order, and snapshots. |
| [`PRODUCTION-RUNBOOK.md`](PRODUCTION-RUNBOOK.md) | Exact step-by-step production sequence with stop conditions. |

## SQL drafts (apply in numeric order, after migration 13)

| Draft | Purpose | Local test |
|---|---|---|
| [`sql/01_gym_identity_ownership.sql`](sql/01_gym_identity_ownership.sql) | `owner_id`, permanent `public_id`, suspension fields, admin settings payload | Passed |
| [`sql/02_per_gym_settings.sql`](sql/02_per_gym_settings.sql) | One `gym_settings` row per gym, own-gym RLS, `member_gym_overview()` | Passed |
| [`sql/03_platform_owner.sql`](sql/03_platform_owner.sql) | Separate `platform_admins`, subscriptions, audit log, platform RPCs | Passed |
| [`sql/04_isolation_hardening.sql`](sql/04_isolation_hardening.sql) | `attendance.gym_id` + safe backfill, suspended-gym guards, refund and storage scoping, QR check-in gym guard | Passed |
| [`sql/05_registration_atomic.sql`](sql/05_registration_atomic.sql) | Idempotent owner registration with ownership, settings, rails and trial | Passed |
| [`sql/06_admin_pagination.sql`](sql/06_admin_pagination.sql) | Additive paged member list with `total_count` and the four status-tab counts | Passed |
| [`sql/07_join_polish.sql`](sql/07_join_polish.sql) | Join RPCs through `admin_assert()`, idempotent decisions, pending badge count | Passed |

`sql/_test_*.sql` are local-only test scripts. They are not migrations.

`rollback/00_functions_before.sql` and `rollback/00_public_schema_before.sql`
are pre-draft snapshots taken from the local database. Regenerate them from
production immediately before applying anything.

## Canonical database

- **Canonical:** `psgepyvdwvunjkbacsxe`
- **Legacy:** `ocycaiomiiovnsjeivvd` — alive, not used by either app; read-only
  inspection still pending Supabase CLI login on this machine.
- No third project, no database-per-gym.

## Local verification already completed

- Drafts 01–07 applied cleanly to a clone of the local FitDesk database.
- Owner registration created exactly one gym, one settings row, four rails and
  one trial subscription; a second call returned the same gym.
- `member_gym_overview()` returned the correct gym for a member.
- Paged member list returned only the admin's gym and a correct `total_count`.
- Cross-gym refund returned `PAYMENT_NOT_FOUND`.
- Cross-gym QR check-in returned `QR_GYM_MISMATCH`.
- Suspended gym returned `GYM_SUSPENDED` for admin RPCs and check-in.
- Join request created one row, duplicate request made no second row, approval
  assigned the member, and a repeated approval was a no-op.
- All rollback scripts reverted the schema to the pre-draft state on a second
  clone.

## Still blocked

1. Legacy project inspection: needs `npx supabase login` (or a user-scoped
   `SUPABASE_ACCESS_TOKEN`) done by the user. Never paste a token in chat.
2. Production backup/PITR confirmation: needs dashboard access or a locally
   set `SUPABASE_DB_URL`.
3. Platform-owner email: must be confirmed by the user.
4. Explicit production approval.
