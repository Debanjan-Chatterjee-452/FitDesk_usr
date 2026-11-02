# FitDesk Multi-Gym SaaS — Final Plan (Plain Language)

> **Nothing in this document has been applied to production.**
> It is the plan to approve before any real change is made.

---

## 0. Status (2026-11-02)

| Item | Status |
|---|---|
| Draft migrations 01–07 | Written, applied to a local test database, rollback scripts tested |
| Production database | Migration #13 + drafts 01–07 applied; verified (RPCs and tables present) |
| Backup / PITR check | Completed — PITR disabled; logical dump taken before migration |
| Legacy project inspection | **Done** — read-only counts/hashes/RPCs captured; one shared e-mail, one unique user each, legacy has an extra `legal-document` bucket and an announcement |
| Frontend review | Done; `FRONTEND-CHANGES.md` corrected (4 inaccuracies fixed) |
| Draft 06 counts RPC | Added and tested locally (`_test_status_counts.sql`) |
| Frontend approval | **Not given** — see `FRONTEND-CHANGES.md` section E |
| Production approval | **Not given** |

Two plan gaps were found during the frontend review:

1. **Member status counts — resolved.** Draft 06 now includes
   `admin_member_status_counts()`, which returns all four tab totals and is
   covered by local tests. Search intentionally does not change the badges,
   matching the current UI.
2. **Suspended-gym boot path.** `admin_assert()` raises `GYM_SUSPENDED`, but
   `is_admin()` does not. The admin app restores the session before any page,
   so suspension must be caught in `restoreAdminSession()`, not only mapped in
   a generic error handler. Details in `FRONTEND-CHANGES.md` B6.

---

## 1. The short version

FitDesk will keep **one shared database** for every gym.

- Each gym gets its own data, isolated by `gym_id`.
- Database rules (Row Level Security) and gym-scoped functions stop one gym
  from seeing another gym's members, payments or attendance.
- The member app and the admin website keep their current URLs and deploys.
- Existing accounts, passwords, memberships, payments and attendance stay.
- The second Supabase project is inspected read-only and left untouched.
- No third Supabase project and no database-per-gym.

The work is delivered as **one prerequisite (#13)** plus **seven small SQL
steps** and a short list of frontend changes. Every step can be rolled back.

---

## 2. Which database is canonical, and how the apps connect

**Canonical database:** `psgepyvdwvunjkbacsxe`
(`https://psgepyvdwvunjkbacsxe.supabase.co`)

Both deployed apps already point at it:

| App | Current config | Change needed |
|---|---|---|
| `fitdesk-usr.vercel.app` (members) | canonical URL + publishable key | none |
| `fitdesk-admin.vercel.app` (admins) | canonical URL + publishable key | none |

No connection setting is rewritten. No new project is created.

The legacy project `ocycaiomiiovnsjeivvd` is **not** used by either app. It
will be inspected read-only when Supabase CLI access is configured, and then
left exactly as it is.

---

## 3. What happens to existing data

### Canonical project

| Data | What happens |
|---|---|
| Gyms | Kept. Each gets a permanent human-readable ID (`FD-0001`…) and, where verifiable, a verified owner. |
| Admin accounts | Kept. `is_admin` is not changed for existing admins. |
| Member profiles | Kept. Existing `gym_id` is not changed, cleared, or reassigned. |
| Memberships | Kept. Amounts, dates and statuses are not rewritten. |
| Payments | Kept. Amounts, references and approval state are not rewritten. |
| Attendance | Kept. A new `gym_id` column is filled **only** where the gym is certain. |
| Packages, announcements, pauses, notifications | Kept. |
| UPI IDs, payee names, payment QR, attendance QR | Kept. Still separate per gym. |
| Settings | The original FitDesk settings stay on the original gym. Every other gym gets its own independent defaults. |

Ownership uses a `restrict` link to the auth account. Deleting an owner account
is therefore blocked until ownership is transferred first. That prevents a gym
from being left without an owner, but it is an operational rule to remember.

### Legacy project

- No write, no delete, no archive, no migration in this phase.
- After inspection, a short report will say whether it holds any unique data.
- If it has unique data, a separate merge proposal will be written.
- Retirement only with a separate written approval, later.

### Rows that cannot be verified

Nothing is guessed. If a record cannot be tied to one gym safely:

- it stays `NULL`,
- it appears in a report,
- the user is asked before it is changed.

Reports produced:

1. Gyms with no unique admin (so `owner_id` stays `NULL`).
2. Attendance rows that could not be attributed to one gym.
3. Any settings row that could not be tied to a gym (migration stops instead
   of guessing).

In the local test database, 4 of 5 gyms got a verified owner. The legacy
`fitdesk` gym has no admin, so its `owner_id` correctly stayed empty.

---

## 4. Authentication and passwords

- No migration touches `auth.users`, password hashes, sessions, JWT secrets or
  login providers.
- Existing users sign in with the same e-mail and password.
- Email confirmation stays **on**.
- The registration form and login form keep their current look.

### Owner registration timing

1. Owner signs up with e-mail, password, gym name and phone.
2. Supabase sends the confirmation e-mail (unchanged).
3. Owner confirms and signs in for the first time.
4. The admin app calls one database function, which:
   - creates the gym **only if it does not already exist**,
   - links `gyms.owner_id` to the owner,
   - creates the gym's own settings row,
   - creates the four payment rails,
   - starts a 14-day trial subscription,
   - makes the profile an admin of that gym.

**Idempotent:** the function takes a per-user lock and returns the existing gym
on every later call. A double click, a refresh, or a second login cannot create
a second gym or a second admin.

**Honest limitation:** the Supabase Auth account and the database rows cannot
share one transaction from a browser. The database part is one atomic
transaction: if it fails, no half-created gym remains, and the owner can retry.
This is the safest design Supabase supports without a server-side worker.

---

## 5. The exact changes, step by step

### Step 0 — apply the already-written migration #13

Source of truth: `D:\Gym Admin Website\supabase\migrations\20261104000100_fitdesk_member_join_realtime.sql`.

- It exists in the admin repo but is **untracked** in git.
- The member repo has migrations #1–#10 only, so #13 must be applied from the
  admin repo (or copied there) before drafts 06 and 07.
- Production is currently at #12; `gym_join_requests` and the join RPCs do not
  exist yet (confirmed by `PGRST205` / `PGRST202`).

It adds:

- gym join codes,
- the `gym_join_requests` table,
- join request/approve/decline functions,
- rail-aware UPI payments,
- pause-aware renewal quotes,
- Realtime entries for member/admin sync,
- nullable `profiles.gym_id` (existing values are kept).

This is a prerequisite for drafts 06 and 07.

### Step 1 — gym identity and ownership (`01`)

- Add `gyms.owner_id`, `gyms.public_id`, `gyms.suspended_at`,
  `gyms.suspension_reason`.
- Backfill `owner_id` only where exactly one verified admin exists.
- Generate permanent `FD-0001`, `FD-0002`, … in creation order.
- Add a trigger so every future gym gets an ID automatically.
- Return the Gym ID and join code in the admin settings payload.

### Step 2 — per-gym settings (`02`)

- Add `gym_settings.gym_id`, one row per gym.
- Keep the original row for the original FitDesk gym.
- Copy the original hours into that row; give other gyms independent defaults.
- Narrow settings reads to the member's own gym.
- Add `member_gym_overview()` so the member app gets its own gym's hours,
  status and announcements in one call.

### Step 3 — platform owner (`03`)

- Add `platform_admins` (separate from gym admins).
- Add `gym_subscriptions` for manual subscription tracking.
- Add `platform_audit_log` for every platform action.
- Add platform functions: totals, gym list, gym detail, suspend/activate,
  subscription editor.
- **No platform account is created by this migration.**
- **No gym admin is promoted automatically.**

### Step 4 — isolation hardening (`04`)

- Add `attendance.gym_id`; auto-fill it on every future check-in.
- Backfill it in this order, stopping at the first safe answer:
  1. the attendance QR code's gym,
  2. the only membership covering the check-in date,
  3. the profile gym **only if** the member's whole history is one gym.
- Leave anything else `NULL` and report it.
- Block suspended gyms in `admin_assert()` with `GYM_SUSPENDED`.
- Block check-in when the member has no gym or the gym is suspended.
- Scope manual refunds to the admin's own gym.
- Scope payment-QR storage listing to the admin's own gym folder.
- The `gym-payment-qr` bucket stays public for member rendering; it will not be
  made private in this phase (that would need a signed-URL frontend change).

### Step 5 — owner registration (`05`)

- One atomic, idempotent `register_gym_owner()`:

  - creates the gym with `owner_id`,
  - creates independent settings,
  - creates four payment rails,
  - creates a 14-day trial subscription,
  - makes the owner the gym admin,
  - returns the existing gym on repeat calls.

- It refuses to take over a gym for a normal member.
- It still works for an owner who signed up **before** step 0 and whose profile
  was auto-assigned to the legacy gym, because owner signups carry a gym name
  in their signup metadata.

### Step 6 — member list paging (`06`)

- Add `admin_list_members_page()` with `limit`, `offset` and `total_count`.
- Add `admin_member_status_counts()` for the four existing status tabs.
- Leave the existing `admin_list_members()` untouched, so the live admin site
  keeps working until its UI change is approved and deployed.

### Step 7 — join flow polish (`07`)

- Route admin join functions through the shared suspended-gym guard.
- Make approve/decline idempotent and reject stale decisions.
- Return the gym's public ID to the member.
- Add a pending-request count for the future navigation badge.

---

## 6. Security model after the change

| Area | Behaviour |
|---|---|
| Member data | RLS limits rows to the signed-in member. |
| Admin data | `SECURITY DEFINER` functions call `admin_assert()`, which returns the admin's own gym and rejects suspended gyms. |
| Platform data | `platform_assert()` checks `platform_admins`; a gym admin cannot call platform functions. |
| Storage | Payment proofs and legal documents stay private and gym-scoped. Payment-QR reads are gym-scoped; the public bucket read used by the member app is unchanged. |
| Realtime | Member channels stay filtered by `user_id` and protected by RLS. Join status uses lightweight polling, so no new table is published just for it. |
| Service role | Never used in the browser, never stored in a public Vercel variable, never committed. |

Existing RPC signatures are kept. Long replaced functions are captured in a
snapshot before the change, so a rollback can restore them without guessing.

---

## 7. What members and admins will notice

### Members

- Existing members: nothing changes on first deploy. Same login, same data.
- New members: a proper "join a gym" screen, then the gym's approval.
- Members see their **own** gym's hours, address and announcements.
- Gym-less members are guided to join a gym instead of seeing an empty home.
- If a gym is suspended, a clear "gym unavailable" message is shown.

### Gym admins

- Existing admins: same dashboard, same credentials.
- Sidebar shows the real gym name instead of a hardcoded one.
- Gym ID and join code are shown with copy buttons.
- A "Join requests" page with a pending count.
- Member list can page through large gyms.
- Suspended gym admins see a "gym suspended — contact FitDesk" screen.
- No redesign of the existing dashboard.

### Platform owner

- Separate role, separate dashboard later, at `/platform`.
- Can see all gyms, platform totals, suspend/activate a gym, and edit
  subscription status.
- Cannot be created by signing up. The account is created manually only after
  the user confirms the e-mail address.

---

## 8. Backup and rollback

### Before production

> Current blocker: the Supabase CLI has no stored access token, so neither the
> backup check nor the legacy inspection can run yet. The code must not be
> applied before both are done.

1. Confirm the Supabase dashboard shows a recent successful backup **or** an
   available PITR recovery point. Record the timestamp and retention window.
2. Take a fresh logical backup:
   `pg_dump "$SUPABASE_DB_URL" -Fc -f fitdesk_before_multigym.dump`
3. Restore that dump into a separate scratch database and verify row counts.
4. Capture a fresh function and schema snapshot from production.
5. Run the full Gym A / Gym B test matrix on a production clone.

### If something goes wrong

Rollback order (all scripts are in `rollback/`):

1. Restore function bodies from the pre-change snapshot.
2. Run down scripts in reverse order: `down_07` → `down_01`.
3. If anything is unclear or data looks wrong, **stop** and restore the
   verified backup / PITR point.

The rollback scripts were tested on a second clone and returned the schema to
its pre-draft state.

Down scripts only remove new objects where safe. They never delete members,
payments, memberships or attendance. Gyms created while the new code was live
are kept, because deleting a gym would cascade into its members' links.

---

## 9. Impact if we do nothing

The current app keeps working, but:

- every gym shares one settings row,
- any admin can list another gym's payment-QR files,
- a manual refund is not gym-scoped,
- attendance has no gym owner,
- suspended gyms are not actually locked out,
- new owners cannot safely retry registration,
- the member list has no paging.

None of these are solved by waiting. None of them are urgent enough to skip a
backup.

---

## 10. What I need from you before production

Please confirm each item:

1. **Approve the plan and the seven draft SQL files.**
2. **Configure Supabase CLI access on your computer securely** so the legacy
   project can be inspected and the production backup can be verified.
   Run this **in your own terminal**, not in the agent session:
   ```powershell
   npx --yes supabase login
   ```
   A browser page opens and shows an authorization code. Paste that code back
   into the terminal prompt. Do not paste the code or a token into chat.
   When it finishes, tell me "login done" — I will verify with
   `npx supabase projects list`.
3. **Confirm the platform-owner e-mail address.** No account will be created
   until you confirm it.
4. **Approve the short list of frontend changes** in
   [`FRONTEND-CHANGES.md`](FRONTEND-CHANGES.md). They are small, but they are
   visible UI changes.
5. **Choose the production window** and give explicit written approval to
   apply the migrations after the backup is verified.

After that, the runbook in [`PRODUCTION-RUNBOOK.md`](PRODUCTION-RUNBOOK.md) is
followed step by step, with a stop after each step to check row counts and
function behaviour.

---

## 11. Not doing in this phase

- No `/platform` dashboard UI. Backend first, then a separate UI proposal.
- No payment gateway. Direct UPI and manual verification stay.
- No automatic promotion of a gym admin to platform owner.
- No legacy project archive, delete, reset or migration.
- No new Supabase project.
- No database per gym.
- No change to the member app or admin app deploy URLs.
- No service-role key in the frontend, GitHub, logs, or public Vercel env.
