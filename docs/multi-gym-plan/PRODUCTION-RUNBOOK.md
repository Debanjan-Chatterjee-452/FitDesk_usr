# Production Runbook

> **Do not start this until the user gives explicit written approval and the
> pre-flight checklist in [`BACKUP-AND-ROLLBACK.md`](BACKUP-AND-ROLLBACK.md)
> is complete.**

Production project: `psgepyvdwvunjkbacsxe`
Current migration level: **#12**
Prerequisite: migration **#13**

Use the **admin repository** (`D:\Gym Admin Website`) for migrations. Do not
run `supabase db push` from `D:\Gym App`: its CLI metadata still points at the
legacy project.

---

## 0. Pre-flight (no writes)

- [ ] Backup / PITR verified and recorded.
- [ ] Logical dump created, restored, and row counts matched.
- [ ] Function snapshot regenerated from production.
- [ ] Row counts recorded.
- [ ] Owner report reviewed.
- [ ] Attendance ambiguity report reviewed (before 04).
- [ ] Production clone passed the test matrix.
- [ ] Platform-owner e-mail confirmed.
- [ ] Frontend changes approved.
- [ ] Written approval received.

During the window:

- Do not suspend a gym.
- Do not run a second migration tool.
- Keep the terminal output for every step.

---

## 1. Authenticate and link (user does this on their own machine)

```powershell
cd "D:\Gym Admin Website"
npx supabase login
npx supabase link --project-ref psgepyvdwvunjkbacsxe
```

No token is pasted into chat or committed.

The CLI may ask for the database password while linking. Enter it directly in
the terminal; never in chat, a file, or a Vercel variable.

Confirm the link:

```powershell
npx supabase migration list
```

Expected: remote versions through `20261103000100` (the 13th slot is empty).

---

## 2. Migration file naming and helper

Apply the drafts **one at a time**, so each step can be verified before the
next one starts. The target filenames are:

| Draft | New filename |
|---|---|
| `01_gym_identity_ownership.sql` | `20261105000100_fitdesk_gym_identity_ownership.sql` |
| `02_per_gym_settings.sql` | `20261105000200_fitdesk_per_gym_settings.sql` |
| `03_platform_owner.sql` | `20261105000300_fitdesk_platform_owner.sql` |
| `04_isolation_hardening.sql` | `20261105000400_fitdesk_isolation_hardening.sql` |
| `05_registration_atomic.sql` | `20261105000500_fitdesk_registration_atomic.sql` |
| `06_admin_pagination.sql` | `20261105000600_fitdesk_admin_pagination.sql` |
| `07_join_polish.sql` | `20261105000700_fitdesk_join_polish.sql` |

The drafts contain explicit `begin;` / `commit;` because they are tested with
`psql`. `supabase db push` already wraps each migration in a transaction, so
the outer `begin;` and `commit;` must be removed from the copied file to avoid
committing the CLI's transaction early.

Define this helper once in the PowerShell session:

```powershell
function Install-Draft {
  param([string]$Source, [string]$Target)
  $text = Get-Content -Raw $Source
  $text = $text -replace '(?im)^[ \t]*begin;[ \t]*$', ''
  $text = $text -replace '(?im)^[ \t]*commit;[ \t]*$', ''
  Set-Content -Path $Target -Value $text -Encoding utf8
}
```

Example for step 01:

```powershell
Install-Draft `
  "D:\Gym App\docs\multi-gym-plan\sql\01_gym_identity_ownership.sql" `
  "D:\Gym Admin Website\supabase\migrations\20261105000100_fitdesk_gym_identity_ownership.sql"
```

Validate that the copied file has no outer transaction lines:

```powershell
Select-String -Path "D:\Gym Admin Website\supabase\migrations\20261105000100_*.sql" -Pattern '^\s*(begin|commit);'
```

Expected: no matches.

Commit each migration file to git **before** pushing it, so every applied
version has a matching file in the repository.

---

## 3. Apply migration #13

Do this **before** copying any draft file, so the dry run shows only #13.

```powershell
cd "D:\Gym Admin Website"
npx supabase db push --dry-run
```

Check that only `20261104000100_fitdesk_member_join_realtime.sql` is pending.

```powershell
npx supabase db push
```

Verify:

```sql
select version from supabase_migrations.schema_migrations order by version;
-- 20261104000100 must be present

select count(*) from public.gym_join_requests;          -- 0
select count(*) from public.profiles where gym_id is null; -- existing members: 0
```

Check the app still loads. Existing members keep their gym; new signups are no
longer auto-assigned to the legacy gym until approved.

**Stop if:** any existing profile lost its `gym_id`, or login fails.

---

## 4. Apply step 01 — identity and ownership

```powershell
Install-Draft `
  "D:\Gym App\docs\multi-gym-plan\sql\01_gym_identity_ownership.sql" `
  "D:\Gym Admin Website\supabase\migrations\20261105000100_fitdesk_gym_identity_ownership.sql"

cd "D:\Gym Admin Website"
npx supabase db push --dry-run   # must show only 20261105000100
npx supabase db push
```

Verify:

```sql
select count(*) filter (where public_id is null) as missing_public_id from public.gyms; -- 0
select count(*) filter (where owner_id is null) as missing_owner from public.gyms;
select slug, public_id, owner_id from public.gyms order by public_id;

-- Gyms that need a manual ownership decision:
select g.id, g.slug, count(p.id) filter (where p.is_admin) as admin_count
  from public.gyms g
  left join public.profiles p on p.gym_id = g.id
 group by g.id, g.slug
having count(p.id) filter (where p.is_admin) <> 1;
```

Expected:

- Every gym has a public ID.
- Gyms with exactly one admin got `owner_id`.
- Gyms with 0 or 2+ admins stay `NULL` and appear in this list. **Report them;
  do not guess.**
- The legacy `fitdesk` gym is expected to have 0 admins locally.

**Stop if:** any existing gym lost data or a public ID collides.

---

## 5. Apply step 02 — per-gym settings

```powershell
Install-Draft `
  "D:\Gym App\docs\multi-gym-plan\sql\02_per_gym_settings.sql" `
  "D:\Gym Admin Website\supabase\migrations\20261105000200_fitdesk_per_gym_settings.sql"

cd "D:\Gym Admin Website"
npx supabase db push --dry-run   # must show only 20261105000200
npx supabase db push
```

Verify:

```sql
select count(*) from public.gyms;              -- N
select count(*) from public.gym_settings;      -- must equal N
select count(*) from public.gym_settings where gym_id is null; -- 0

select g.slug, s.name, s.open_time, s.close_time, s.closed_weekdays
  from public.gyms g
  left join public.gym_settings s on s.gym_id = g.id
 order by g.public_id;
```

- The original FitDesk gym keeps the original name/hours.
- Other gyms get the documented defaults (`05:00`–`23:00`, Sunday closed).
- Admins can still save payment settings.

Temporarily, the member app still reads `gym_settings` id 1, so every member
sees the original gym's hours until the frontend step ships. This is expected
and lasts only until the member deploy.

**Stop if:** the settings count does not equal the gym count.

---

## 6. Apply step 03 — platform owner backend

```powershell
Install-Draft `
  "D:\Gym App\docs\multi-gym-plan\sql\03_platform_owner.sql" `
  "D:\Gym Admin Website\supabase\migrations\20261105000300_fitdesk_platform_owner.sql"

cd "D:\Gym Admin Website"
npx supabase db push --dry-run   # must show only 20261105000300
npx supabase db push
```

Verify:

```sql
select to_regclass('public.platform_admins'),
       to_regclass('public.gym_subscriptions'),
       to_regclass('public.platform_audit_log');

select count(*) from public.platform_admins; -- 0
```

No platform account is created. No gym admin is promoted.

---

## 7. Apply step 04 — isolation hardening

Before pushing, run the attendance report to know what to expect:

```sql
select count(*) from public.attendance;
```

Then:

```powershell
Install-Draft `
  "D:\Gym App\docs\multi-gym-plan\sql\04_isolation_hardening.sql" `
  "D:\Gym Admin Website\supabase\migrations\20261105000400_fitdesk_isolation_hardening.sql"

cd "D:\Gym Admin Website"
npx supabase db push --dry-run   # must show only 20261105000400
npx supabase db push
```

Verify:

```sql
select count(*) as total,
       count(*) filter (where gym_id is null) as needs_review
  from public.attendance;

-- The review list from TEST-MATRIX.md section E.
```

- Every assigned row came from the QR, a single covering membership, or a
  single-gym history.
- Remaining rows are listed for the user. Do not edit them without approval.
- No gym should be suspended during this step.
- Storage listing still works for the admin's own QR.

**Stop if:** a member can no longer check in, or an admin sees `GYM_SUSPENDED`
while their gym is active.

---

## 8. Apply step 05 — registration

```powershell
Install-Draft `
  "D:\Gym App\docs\multi-gym-plan\sql\05_registration_atomic.sql" `
  "D:\Gym Admin Website\supabase\migrations\20261105000500_fitdesk_registration_atomic.sql"

cd "D:\Gym Admin Website"
npx supabase db push --dry-run   # must show only 20261105000500
npx supabase db push
```

Verify with a test owner on a staging account:

1. Sign up, confirm e-mail, first login.
2. Exactly one gym is created, with:
   - `owner_id`,
   - one settings row,
   - four payment rails,
   - one trial subscription,
   - a public ID and join code.
3. Sign out and in again: still exactly one gym.

**Stop if:** a second gym is created, or an existing admin is moved.

---

## 9. Apply step 06 — pagination

```powershell
Install-Draft `
  "D:\Gym App\docs\multi-gym-plan\sql\06_admin_pagination.sql" `
  "D:\Gym Admin Website\supabase\migrations\20261105000600_fitdesk_admin_pagination.sql"

cd "D:\Gym Admin Website"
npx supabase db push --dry-run   # must show only 20261105000600
npx supabase db push
```

Verify:

```sql
select proname, pg_get_function_identity_arguments(oid)
  from pg_proc
 where proname in ('admin_list_members', 'admin_list_members_page');
```

Both must exist. The old one keeps the live admin site working.

---

## 10. Apply step 07 — join polish

```powershell
Install-Draft `
  "D:\Gym App\docs\multi-gym-plan\sql\07_join_polish.sql" `
  "D:\Gym Admin Website\supabase\migrations\20261105000700_fitdesk_join_polish.sql"

cd "D:\Gym Admin Website"
npx supabase db push --dry-run   # must show only 20261105000700
npx supabase db push
```

Verify:

```sql
select proname
  from pg_proc
 where proname in ('request_join_gym',
                   'admin_list_join_requests',
                   'admin_review_join_request',
                   'admin_pending_join_request_count');
```

Then reload the API schema cache:

```sql
notify pgrst, 'reload schema';
```

---

## 11. Deploy the frontends (approved changes only)

### Admin first

```powershell
cd "D:\Gym Admin Website"
npx vercel --prod
```

Or connect the existing `fitdesk-admin` Vercel project to its GitHub repo (no
new project) and let it auto-deploy.

Smoke test:

- Login as Owner A.
- Sidebar shows the real gym name.
- Join Requests page opens and shows the correct gym only.
- Gym ID and join code are visible.
- Approve one test request.
- Settings, payments, packages, attendance QR still work.

### Member second

```powershell
cd "D:\Gym App"
npx vercel --prod
```

Smoke test:

- Login as Member A.
- Home shows Gym A's hours.
- `/join-gym` works for a gym-less test member.
- Scan Gym A's QR: success.
- Scan Gym B's QR: `QR_GYM_MISMATCH`.
- Attendance history still shows old rows.

---

## 12. Create the platform owner (manual, after e-mail confirmation)

Only after the user confirms the exact e-mail address:

1. Ask the user to sign up / sign in with that e-mail and confirm it.
2. Find the user id in **Authentication → Users** (read-only lookup).
3. In the SQL editor, run:

```sql
insert into public.platform_admins (user_id, role)
values ('<confirmed-user-uuid>', 'owner')
on conflict (user_id) do nothing;
```

4. Confirm with that account signed in:

```sql
select public.platform_me();
```

Expected: `{"is_platform_owner": true, "role": "owner"}`.

No gym admin is promoted. No e-mail is invented.

---

## 13. Final production verification

```sql
-- Counts must match the pre-flight baseline.
select 'gyms' as t, count(*) from public.gyms
union all select 'profiles', count(*) from public.profiles
union all select 'packages', count(*) from public.packages
union all select 'memberships', count(*) from public.memberships
union all select 'payments', count(*) from public.payments
union all select 'attendance', count(*) from public.attendance
union all select 'auth_users', count(*) from auth.users;

-- No existing member moved.
select count(*) from public.profiles where gym_id is null; -- only new gym-less signups

-- Settings coverage.
select count(*) from public.gym_settings; -- equals gym count

-- Platform.
select count(*) from public.platform_admins; -- 1 after step 12
```

Also run the full Gym A / Gym B matrix against production.

---

## 14. If something goes wrong

Follow [`BACKUP-AND-ROLLBACK.md`](BACKUP-AND-ROLLBACK.md) section 6.

Immediate rollback triggers:

- `auth.users` or `profiles` count changed unexpectedly.
- An existing member cannot log in.
- An existing member's `gym_id` changed.
- Any cross-gym data is visible.
- A member cannot check in at an active gym.
- An admin sees `GYM_SUSPENDED` while the gym is active.
- A second gym or duplicate admin appears.

Stop, snapshot the current state, then roll back or restore.
