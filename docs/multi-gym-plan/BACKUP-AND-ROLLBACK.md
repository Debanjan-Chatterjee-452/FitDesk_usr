# Backup, Verification, and Rollback

> Production is **not** authorized yet. This document is the safety gate that
> must be completed first.

---

## 1. Two independent safety nets

1. **Supabase backup / PITR** — the guaranteed restore path.
2. **A fresh logical dump** stored on the user's computer — independent of
   Supabase.

Both are required before the first production migration.

---

## 2. Verify the Supabase backup (dashboard)

In the Supabase dashboard for `psgepyvdwvunjkbacsxe`:

1. Open **Database → Backups**.
2. Confirm the most recent automated backup is **today or yesterday** and its
   status is successful.
3. If the project is on a plan with **Point-in-Time Recovery**, open the PITR
   panel and confirm:
   - PITR is enabled,
   - the earliest restorable point is older than the migration window,
   - the retention window is at least 7 days.
4. Record:
   - backup timestamp,
   - PITR earliest restorable timestamp,
   - retention window,
   - plan name.

If the project has **no PITR**, do not proceed on backups alone. The logical
dump in section 3 is then the only rollback path, and the migration must run
in a low-traffic window.

---

## 3. Take a logical dump

The database URL contains a password. Do **not** paste it in chat, a file, a
commit, or Vercel. Set it only in the current PowerShell session:

```powershell
$env:SUPABASE_DB_URL = (Read-Host "Paste the production connection string" -MaskInput)
```

Then:

```powershell
pg_dump "$env:SUPABASE_DB_URL" `
  --format=custom `
  --no-owner `
  --no-privileges `
  --file="D:\Gym App\backups\fitdesk_before_multigym.dump"
```

Also take a schema-only copy:

```powershell
pg_dump "$env:SUPABASE_DB_URL" `
  --schema-only `
  --schema=public `
  --no-owner `
  --no-privileges `
  --file="D:\Gym App\backups\fitdesk_before_multigym_schema.sql"
```

Then clear the variable:

```powershell
Remove-Item Env:\SUPABASE_DB_URL
```

`D:\Gym App\backups\` is ignored by git (add it to `.gitignore` if it is not
already). A dump must never be committed.

If `pg_dump` is not installed, install the PostgreSQL client tools, or use the
Supabase dashboard backup download. Do not use a web-based SQL console for a
full dump.

---

## 4. Verify the dump

Restore it into a **scratch local database** and compare counts:

```powershell
# Local Supabase container is fine for this.
docker exec supabase_db_fitdesk-local dropdb -U postgres --if-exists fitdesk_backup_check
docker exec supabase_db_fitdesk-local createdb -U postgres fitdesk_backup_check
docker cp "D:\Gym App\backups\fitdesk_before_multigym.dump" supabase_db_fitdesk-local:/tmp/before.dump
docker exec supabase_db_fitdesk-local pg_restore -U postgres -d fitdesk_backup_check --no-owner --no-privileges /tmp/before.dump
```

Compare these tables in production and in the restored copy:

```sql
select 'gyms' as t, count(*) from public.gyms
union all select 'profiles', count(*) from public.profiles
union all select 'packages', count(*) from public.packages
union all select 'memberships', count(*) from public.memberships
union all select 'payments', count(*) from public.payments
union all select 'attendance', count(*) from public.attendance
union all select 'announcements', count(*) from public.announcements
union all select 'gym_qr_codes', count(*) from public.gym_qr_codes
union all select 'gym_payment_methods', count(*) from public.gym_payment_methods
union all select 'auth_users', count(*) from auth.users;
```

The counts must match. If they do not, the dump is not a valid rollback and
production must not proceed.

---

## 5. Capture function and schema snapshots

Immediately before production changes (after migration #13 is applied),
regenerate:

```powershell
$env:SUPABASE_DB_URL = (Read-Host "Connection string" -MaskInput)

psql "$env:SUPABASE_DB_URL" -At -c "
  select pg_get_functiondef(p.oid) || ';'
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
   order by p.proname, pg_get_function_identity_arguments(p.oid);
" | Set-Content -Encoding utf8 "D:\Gym App\docs\multi-gym-plan\rollback\00_functions_before.sql"

Remove-Item Env:\SUPABASE_DB_URL
```

This snapshot is how replaced function bodies are restored without guessing.

The local copies already in `rollback/` are from the local database and must
**not** be used for production rollback.

---

## 6. Rollback order

If a step fails or data looks wrong:

1. **Stop.** Do not run the next step.
2. Restore function bodies:
   ```powershell
   psql "$env:SUPABASE_DB_URL" -f "D:\Gym App\docs\multi-gym-plan\rollback\00_functions_before.sql"
   ```
3. Run down scripts in reverse order:
   ```
   rollback\down_07_join_polish.sql
   rollback\down_06_pagination.sql
   rollback\down_05_registration.sql
   rollback\down_04_isolation.sql
   rollback\down_03_platform_owner.sql
   rollback\down_02_per_gym_settings.sql
   rollback\down_01_gym_identity.sql
   ```
4. Re-check the app.
5. If anything is still unclear, restore the verified dump or PITR point.

### What each down script does

| Script | Reverts |
|---|---|
| `down_07` | Drops the pending-count RPC; restores migration-13 join RPCs from the snapshot |
| `down_06` | Drops the paged member RPC and its index |
| `down_05` | Restores the old registration function; keeps gyms already created |
| `down_04` | Drops `attendance.gym_id`, its trigger/index; restores old guards and storage policy |
| `down_03` | Drops platform tables and RPCs |
| `down_02` | Restores the settings singleton and legacy policy; removes extra settings rows |
| `down_01` | Drops `owner_id`, `public_id`, suspension fields, sequence and trigger |

### Data that a down script intentionally keeps

- Gyms created while the new code was live.
- Members approved into those gyms.
- Payments and attendance created during the window.

Deleting those would be more dangerous than leaving them. If they must be
removed, restore from the verified backup instead.

### Tested

The down scripts were run in reverse order on a second clone. Afterwards:

- `owner_id`, `public_id`, `suspended_at`, `suspension_reason`: absent,
- `attendance.gym_id`: absent,
- `gym_settings.gym_id`: absent,
- platform tables: absent,
- new functions: absent,
- settings singleton (`id = 1`): restored.

---

## 7. Point of no return

There is no destructive operation in the plan:

- no `drop table` of business data,
- no `truncate`,
- no column rewrite of amounts or dates,
- no member reassignment,
- no auth change.

The only irreversible parts are the **new** values written to new columns
(`owner_id`, `public_id`, `attendance.gym_id`) and any gyms/members created
during the window. Those are all recoverable only by restoring the backup,
which is why the backup is mandatory.

---

## 8. Production pre-flight checklist

- [ ] Supabase backup confirmed and timestamp recorded.
- [ ] PITR confirmed, or accepted that the logical dump is the only rollback.
- [ ] Logical dump created and stored outside the repo.
- [ ] Dump restored into a scratch database; row counts match.
- [ ] Function/schema snapshot recreated from production.
- [ ] `auth.users` count recorded.
- [ ] Row counts for gyms, profiles, packages, memberships, payments,
      attendance, announcements, QR codes, payment methods recorded.
- [ ] `select gym_id, count(*) from profiles group by 1` recorded.
- [ ] Gym owner report reviewed (gyms with 0 or 2+ admins).
- [ ] Attendance ambiguity report reviewed.
- [ ] Production clone passes the Gym A / Gym B matrix.
- [ ] Platform-owner e-mail confirmed.
- [ ] Frontend changes approved.
- [ ] Explicit written approval received.
