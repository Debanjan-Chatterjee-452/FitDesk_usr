# FitDesk — Member App

A production-ready, mobile-first gym membership PWA for **FitDesk Performance Club**.
Members sign in with an email address, finish a verified profile, scan the front-desk QR to
check in, track their plan, and renew by paying the gym **directly over UPI** — no payment
gateway and no card details.

The member app ships with a focused **payment approval queue** for Admin-role users.
Other staff operations are still performed through SQL / Supabase tooling, documented below.

---

## What is included

- Email + password authentication, persistent-session toggle, email confirmation and recovery links
- Mandatory profile completion (name, DOB, gender, blood group, legal document upload)
- Dashboard with live plan validity, IST countdown, gym open/closed/holiday status
- Camera QR check-in with duplicate protection per **Asia/Kolkata** calendar day
- Membership plans, stacked renewals, strict late-fee calculation
- Direct UPI renewal: the gym's own UPI ID/QR, Google Pay / PhonePe / Paytm / any UPI app
- QR verification — the gym's uploaded QR is decoded and must match the server's payee and
  amount, otherwise a QR is generated from the verified UPI ID and labelled as such
- Member submits the UTR / UPI reference; **nothing activates until a human verifies it**
- Manual admin approval for every purchase/renewal: `pending → approved | declined`
- Member “Payment pending verification” state, renewal locking, and decline notices
- Pending renewals never interrupt the current plan; approval preserves remaining paid days
- Admin approval queue with irreversible Approve/Decline confirmation modals
- Attendance calendar, streak, session history, payment receipts
- Light/dark premium teal design, PWA install, offline shell
- Multi-gym aware schema: payments, plans and payees are scoped per gym
- Supabase Postgres schema, RLS, private document bucket, SECURITY DEFINER functions
- Legacy Razorpay Edge Functions retained but unused by the member flow
- Explicit local demo mode for design review without a backend

---

## Stack

| Layer | Choice |
| --- | --- |
| UI | React 19, TypeScript 6, Tailwind CSS 3.4, Framer Motion |
| App | Vite 8, React Router 7, TanStack Query 5, React Hook Form + Zod |
| Backend | Supabase Postgres, Auth, Storage, Edge Functions (Deno) |
| Payments | Direct UPI `upi://pay` intent + client-side QR generation (`qrcode`), manual verification |
| Scanning | `@zxing/browser` (gym check-in QR and payment QR decoding) |
| Time / money | `date-fns-tz`, `Asia/Kolkata`, INR / ₹ |
| PWA | `vite-plugin-pwa` (Workbox) |
| Tests | Vitest (unit tests for IST dates, gym status, QR parsing, renewal pricing) |

---

## Quick start — local demo

The demo is fully client-side and clearly labelled. It never touches Supabase or a payment
network. The demo payee is `fitdesk@demo`, which is not a real PSP handle, so no money can move.

Requires Node `^20.19` or `>=22.12` (Vite 8) and npm 10+.

```powershell
npm.cmd install
npm.cmd run dev:demo
```

Open `http://localhost:5173`. `dev:demo` loads the committed `.env.demo`
(`VITE_DEMO_MODE=true`), so no Supabase project or local `.env.local` is needed.
A normal `npm.cmd run build` compiles demo mode out of the active flow — the demo
branches remain inert dead code and are never enabled at runtime.
Use `npm.cmd run dev` for the normal production build, or copy `.env.example` to
`.env.local` if you prefer to enable demo through that file.

With no Supabase variables and demo mode off, the app shows the in-app setup screen instead
of starting — that is the expected production default until a backend is connected.

| Demo value | Value |
| --- | --- |
| Email | `aarav@fitdesk.demo` |
| Password | `fitdesk123` |
| Gym QR token | `FITDESK-DEMO-GYM` |

Demo registration uses email + password too. Because demo mode does not send email, the
**Check your inbox** screen exposes a “Confirm email (demo)” button. No real email is sent.

Scanner tips: use **Enter code manually**, or open `/scan?gym=FITDESK-DEMO-GYM`.
The demo database can be reset from **Profile → Demo workspace → Reset demo data**.

---

## Production setup

### 1. Create the Supabase project

Create a project at [supabase.com](https://supabase.com), then install/link the CLI:

```powershell
npm.cmd install -g supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

### 2. Apply the database

```powershell
supabase db push
```

This applies, in order:

| Migration | Contents |
| --- | --- |
| `20261027000100_fitdesk_core.sql` | Enums, tables, indexes, triggers, profile validation |
| `20261027000200_fitdesk_functions.sql` | Quote, QR check-in, payment activation, QR generation |
| `20261027000300_fitdesk_rls_storage_seed.sql` | RLS, grants, storage bucket/policies, default plans/settings |
| `20261027000400_fitdesk_manual_payment_approval.sql` | Admin role, pending/approved/declined statuses, review RPCs, approval RLS |
| `20261028000100_fitdesk_preserve_active_membership.sql` | Approval recalculates the applied period, serializes reviews per member, blocks overlapping memberships |
| `20261028000200_fitdesk_payment_safety.sql` | Payment guard triggers, review hardening |
| `20261029000100_fitdesk_upi_payments.sql` | Multi-gym `gyms` table + payee config, `gym_id` scoping, direct-UPI RPCs, `gym-payment-qr` bucket |

Alternatively paste each migration into the SQL editor in filename order.
`supabase/seed.sql` adds an optional local welcome announcement; migrations already seed
the five plans and gym settings.

### 3. Configure email auth

In **Authentication → Providers → Email**:

1. Enable the email provider and keep **Confirm email** on.
2. Set **Site URL** to your deployed app origin (for example `https://app.example.com`).
3. Add these **Redirect URLs**:
   - `https://app.example.com/confirm-email`
   - `https://app.example.com/reset-password`
   - `http://localhost:5173/confirm-email` and `http://localhost:5173/reset-password` for local development.
4. Configure custom SMTP before production; Supabase's built-in sender is rate-limited.
5. Review Auth rate limits and the confirmation/recovery email templates.

The app uses `signUp({ email, password })`, `signInWithPassword({ email, password })`,
`resetPasswordForEmail`, and `exchangeCodeForSession` for the PKCE email links. Phone
numbers remain optional profile/contact data and are never used for sign-in.

Existing phone-only members keep their profiles, memberships, payments, and attendance.
To let them sign in with email, add an email address to their Supabase auth user (Dashboard
or Admin API) and ask them to use **Forgot password** to set a password. No database
migration is required.

### 4. Storage

The migration creates the **private** `legal-documents` bucket with a 10 MB limit and
JPG/PNG/WEBP/HEIC/PDF MIME restrictions. Members can only read/write objects under
`<their-auth-uid>/...`. Document previews use short-lived signed URLs.

### 5. Environment

Copy `.env.example` to `.env.local` (or set the variables in your host):

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_ANON_OR_PUBLISHABLE_KEY
VITE_DEMO_MODE=false
```

Only the anon/publishable key is browser-visible. Never add a service-role key to a `VITE_*`
variable. There is no payment-gateway key in the browser: the member pays the gym's UPI ID
directly, and the UPI ID is served per payment by a SECURITY DEFINER function.

### 6. Edge Functions (legacy, optional)

The member flow no longer calls a payment gateway. The two Razorpay functions are kept for
historical reference and for any admin tooling that still expects them; they are not part of
renewal checkout and can be left undeployed.

```powershell
supabase functions deploy create-renewal-order
supabase functions deploy verify-payment
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically. Both functions require a valid member JWT (`verify_jwt = true`).

### 7. Configure the gym's UPI

Every gym row owns its payee. A member can only ever see the payee of the gym their payment
belongs to.

```sql
-- Required before any renewal can be paid online.
update public.gyms
   set upi_id         = 'gym-owner@okhdfcbank',   -- the gym owner's real UPI ID
       upi_payee_name = 'FitDesk Performance Club'
 where slug = 'fitdesk';

-- Optional: a QR image the gym already uses.
-- Upload to the public 'gym-payment-qr' bucket first; the path MUST start with the gym id.
update public.gyms
   set payment_qr_path = '<gym_id>/qr.png'
 where slug = 'fitdesk';
```

Until `upi_id` and `upi_payee_name` are set, the member sees **“Payment is not available for
this gym yet.”** — no QR, no UPI ID, no submit button, and the server refuses to accept a
reference. Nothing is ever invented or borrowed from another gym.

The uploaded QR is decoded in the browser and compared against the server's payee and amount.
If it points at a different UPI ID, carries a different amount, has no amount (static QR),
or cannot be decoded, it is **not** shown; the app generates a QR from the verified UPI ID and
says so in plain language.

### 8. Create the front-desk QR

Run this once in the SQL editor. It returns the raw token **once** and stores only its
SHA-256 hash:

```sql
select public.create_gym_qr_code('Front desk');
```

Copy the returned `token`, then generate a printable image:

```powershell
node scripts/generate-gym-qr.mjs "FITDESK-..." gym-qr.png
```

Place the image at the front desk. To rotate a lost/stolen code:

```sql
select public.revoke_gym_qr_code('QR_UUID');
select public.create_gym_qr_code('Front desk replacement');
```

Never commit a real gym token, and never hard-code a production token in the frontend.

### 9. Build and deploy the PWA

```powershell
npm.cmd run build
```

Upload `dist/` to any static host. Configure an SPA rewrite so every route falls back to
`index.html`, e.g. Netlify:

```toml
[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200
```

Serve over HTTPS — camera access and service workers require it (localhost is exempt).

---

## Renewal and late-fee rules

All calculations use `Asia/Kolkata` calendar dates and inclusive end dates.

| Days past expiry | Late fee |
| --- | --- |
| 0–7 | ₹0 |
| exactly 8 | ₹50 |
| 9 or more | ₹50 + ₹5 × (days − 8) |

Examples: day 8 = ₹50, day 9 = ₹55, day 12 = ₹70, day 30 = ₹160.

The member app shows this schedule as an in-app banner under the membership card on the
dashboard: a reminder at 3 days and 1 day before expiry, a warning on day 7 past expiry, and
an overdue notice from day 8 onwards. The banner is driven by the same IST calendar maths as
the server quote (`src/lib/lateFee.ts`), and disappears as soon as an approved renewal extends
or stacks the plan. A submitted-but-unverified payment does not hide it, because nothing has
changed yet.

- An **active** plan renews from the day after its current `ends_on` (stacking).
- A **lapsed** plan starts today.
- Approval applies the same rule at approval time using the member's latest plan, so a
  pending renewal never interrupts or shortens a still-valid membership.
- The dashboard shows the plan covering today and labels a stacked renewal as
  **queued**, so a future start date is never presented as already active.
- Per-day plans clamp the requested duration to `min_days … max_days`.
- The quote is generated by `get_my_renewal_quote()` on the server; the browser only
  displays it.
- The same quote is stored on the payment row. Approval re-checks the package, duration,
  and amounts, then recalculates the dates from the member's latest plan.

## Payment flow

Members pay the gym directly; FitDesk never touches the money and never sees a UPI PIN,
OTP, or banking credential.

1. The member taps **Renew**. The app calls `reserve_upi_checkout(package_id, duration_days)`.
2. That SECURITY DEFINER function asks Postgres for a fresh quote, refuses to create a second
   payment while a submitted one is awaiting review, and inserts a `payments` row with status
   `pending`, `provider = 'upi'`, and the quoted amount. An abandoned checkout for the same
   account is reused instead of duplicated.
3. `get_my_upi_payment(payment_id)` returns the amount, a reference, the payment state, and
   the payee — but only to the member who owns that row. The payee (UPI ID, name, QR path) is
   read from `public.gyms`, which members cannot query directly.
4. The pay screen shows the **server** amount (the browser never supplies it), the recipient
   UPI ID, the payee name, a verified-or-generated QR, and Copy buttons for the ID and amount.
5. **Pay using a UPI app** opens a correctly URL-encoded `upi://pay?pa=…&pn=…&am=…&cu=INR&tr=…`
   intent. If no app handles it, the QR and UPI ID stay on screen — the app never claims a
   payment started or succeeded.
6. The member pays in Google Pay / PhonePe / Paytm / any UPI app, then submits the UTR with
   `submit_upi_payment_reference(payment_id, reference)`.
7. Submission is idempotent and **does not activate a plan**. It stores the normalised
   reference (also in `provider_payment_id`, so the existing approval queue works unchanged),
   records `payee_upi_id` and `upi_submitted_at`, and leaves the payment `pending`. The
   member's expiry date and fines do not change yet.
8. The member dashboard shows **Payment pending verification**, and starting another renewal
   is blocked while the review is open.
9. An Admin-role user opens `/admin/approvals`, matches the UTR against the gym's bank
   statement, then chooses **Approve** or **Decline** and confirms the irreversible action.
10. **Approve** atomically recalculates the applied period from the member's latest
    non-cancelled plan. A still-valid plan is left exactly as it is and the purchased plan
    starts the day after its expiry; a lapsed plan starts today. The purchased package,
    duration, price, and fine are kept, and the payment becomes `approved`.
    **Decline** sets the payment to `declined` with a failure reason and creates no
    membership; the existing plan and fines are untouched, and the member is told to contact
    the gym for a manual refund.
11. A second decision is rejected with `PAYMENT_ALREADY_REVIEWED`. Reviews are serialized per
    member with an advisory lock, so concurrent approvals cannot activate a package twice.

Statuses are derived, never invented: `approved → VERIFIED`, `declined → FAILED`,
`abandoned → CANCELLED`, a submitted reference → `PENDING_VERIFICATION`, otherwise
`NOT_STARTED`. Scanning a QR, opening a UPI app, or returning to the tab proves nothing and
never activates a membership.

The dates stored on the checkout quote are only a request. Approval never trusts them, so a
stale quote cannot shorten the member's paid access. The database also rejects overlapping
non-cancelled memberships.

No browser value can set the recipient UPI ID, the amount, or a verified status.
`get_my_upi_payment`, `reserve_upi_checkout` and `submit_upi_payment_reference` are the only
member-executable functions and are all scoped to the caller's own payment; only the
admin-only `admin_review_payment()` RPC may change the review status.

---

## Security / RLS model

| Table | Member access |
| --- | --- |
| `profiles` | Select own; update only name, DOB, gender, blood group, document metadata. `profile_completed`, `phone`, and `is_admin` are protected. Email is read from the auth session. |
| `packages` | Select active plans for the member's own gym only. |
| `memberships` | Select own. No insert/update/delete. Created only by payment approval. |
| `attendance` | Select own. Writes only through `check_in_with_qr()`. |
| `payments` | Select own. Admin-role users can select the queue and update review fields; `status` changes only through `admin_review_payment()` plus the guard trigger. Includes `gym_id`, `upi_reference`, `upi_submitted_at`, `payee_upi_id`. |
| `announcements` | Select published, started announcements. |
| `gym_settings` | Select. |
| `gyms` | **No access.** Payment config (`upi_id`, `upi_payee_name`, `payment_qr_path`) is readable only through `get_my_upi_payment()` for the member's own payment. |
| `gym_qr_codes` | **No access.** Token hashes are service-role only. |
| `storage.objects` | Legal documents only under the member's own UID folder. `gym-payment-qr` is public by exact path with no member policies, and the path must be prefixed with the gym id (trigger-enforced). |

Members cannot change package prices, membership dates, payment status, fines, UPI payees,
or QR tokens. `submit_membership_payment`, `create_gym_qr_code`, and `revoke_gym_qr_code` are
service-role only. Only Admin-role users can call `admin_review_payment()`; the RLS
policies `payments_select_admin` / `payments_update_admin` and the
`payments_guard_review` trigger enforce the same rule at the table level.

Other protections:

- The amount is always the server's quote; the browser cannot submit one.
- `payments_provider_payment_unique` prevents the same UTR being claimed twice.
- A member's `gym_id` cannot be changed by the member.
- Profile completion is derived by a trigger, not trusted from the client.
- Attendance has a unique `(user_id, check_in_date)` constraint, so a race cannot produce
  two check-ins in one IST day.
- Documents are in a private bucket and served via 60-second signed URLs.
- Edge Functions validate the JWT and never return secrets.

---

## Staff / admin operations (SQL)

Payment approvals are handled in the in-app **Payment approvals** queue. Other staff
operations use the Supabase SQL editor.

```sql
-- Grant the Admin role. The user must sign in again (or refresh) to see the queue.
update public.profiles set is_admin = true where id = 'MEMBER_UUID';

-- Set the gym's payee (required before any online renewal works)
update public.gyms
   set upi_id = 'gym-owner@okhdfcbank', upi_payee_name = 'FitDesk Performance Club'
 where slug = 'fitdesk';

-- Change a plan price
update public.packages set price_inr = 1599 where id = '11111111-1111-4111-8111-111111111111';

-- Add a holiday / closure (blocks QR check-in for those dates)
insert into public.announcements (title, body, kind, starts_on, ends_on, is_active)
values ('Diwali holiday', 'The club is closed today.', 'holiday', '2026-11-08', '2026-11-08', true);

-- Update hours and weekly off (0 = Sunday)
update public.gym_settings
   set open_time = '05:30', close_time = '23:00', closed_weekdays = '{0}', updated_at = now()
 where id = 1;

-- Inspect today's check-ins
select p.full_name, a.check_in_at
  from public.attendance a
  join public.profiles p on p.id = a.user_id
 where a.check_in_date = (now() at time zone 'Asia/Kolkata')::date
 order by a.check_in_at;

-- Plans expiring in the next 7 days
select p.full_name, m.ends_on
  from public.memberships m
  join public.profiles p on p.id = m.user_id
 where m.status = 'active'
   and m.ends_on between (now() at time zone 'Asia/Kolkata')::date
                    and (now() at time zone 'Asia/Kolkata')::date + 7
 order by m.ends_on;

-- Payments waiting for an admin decision (same rows as the in-app queue)
select p.id, pr.full_name, p.total_amount_inr, p.status,
       p.provider_payment_id as upi_reference, p.payee_upi_id, p.upi_submitted_at
  from public.payments p
  left join public.profiles pr on pr.id = p.user_id
 where p.status = 'pending'
   and p.provider_payment_id is not null
 order by p.upi_submitted_at;
```

Do **not** set `payments.status` directly. Use **Approve** / **Decline** in the queue so the
stored quote, amount, membership, and review audit stay consistent. For a genuine
offline/cash renewal, insert the membership and payment in one controlled transaction with
a documented note.

---

## Project structure

```text
src/
  components/          UI primitives, layout, dashboard, membership, attendance
  context/             Auth + theme providers
  hooks/               TanStack Query hooks
  lib/
    api/               Supabase-facing data access (incl. upi.ts for the member UPI flow)
    demo/              Isolated local demo store
    upi/               UPI ID/URI/QR logic, QR image decode, clipboard
    ...                env, timezone, errors, QR parsing
  pages/               Auth, onboarding, dashboard, membership, attendance, scan, profile, admin
supabase/
  migrations/          Schema, functions, RLS, storage, reference data
  functions/           create-renewal-order, verify-payment (legacy, unused by the member flow)
  seed.sql             Optional local sample announcement
scripts/
  generate-gym-qr.mjs  Printable front-desk QR
  generate-icons.ps1   Regenerates PWA / Apple icons
```

---

## Available scripts

| Command | Purpose |
| --- | --- |
| `npm.cmd run dev` | Vite dev server (production config) |
| `npm.cmd run dev:demo` | Vite dev server with the isolated demo dataset |
| `npm.cmd run build` | Type-check and production build |
| `npm.cmd run build:demo` | Type-check and build the demo bundle |
| `npm.cmd run preview` | Preview the production build |
| `npm.cmd run lint` | Oxlint |
| `npm.cmd run test` | Run the Vitest unit suite once |
| `npm.cmd run test:watch` | Run the unit suite in watch mode |
| `node scripts/generate-gym-qr.mjs "TOKEN" out.png` | Generate a printable gym QR |
| `powershell -ExecutionPolicy Bypass -File scripts/generate-icons.ps1` | Regenerate PWA icons |

On Windows use `npm.cmd` / `npx.cmd` because PowerShell may block `npm.ps1`.

### Tests

`npm.cmd run test` runs the Vitest suite. It covers IST day boundaries, the gym
open/closed/holiday derivation, QR payload parsing, and the full renewal fine
schedule (7-day grace, day 8, day 9+ at ₹5/day) including stacked renewals and Flex
duration clamping. `src/lib/lateFee.test.ts` locks the schedule itself, and
`src/lib/expiryWarning.test.ts` locks the exact banner copy at 3 days, 1 day, day 7, day 8 and
day 9+ past expiry, including the IST midnight boundary.

The direct-UPI flow has its own suites: `src/lib/upi/upi.test.ts` (UPI ID and amount
validation, `upi://pay` encoding, QR payload interpretation including payee/amount mismatch and
static QRs, reference normalisation, payee resolution, state labels) and
`src/lib/api/upi.test.ts` (server-side quote, unconfigured gym, submit/idempotency/conflict,
cross-member isolation, already-pending behaviour), plus `src/lib/upi/clipboard.test.ts`.

The SQL function `get_my_renewal_quote()` mirrors the same fine
schedule and is the source of truth in production — update both when the policy
changes.

---

## Deployment checklist

- [ ] Migrations applied; five plans and gym settings visible
- [ ] Email auth tested end-to-end: registration → confirmation → login → recovery
- [ ] Site URL and `/confirm-email` + `/reset-password` redirect URLs allow-listed
- [ ] `legal-documents` bucket is private with MIME/size limits
- [ ] `gyms.upi_id` and `gyms.upi_payee_name` set to the gym owner's real UPI ID
- [ ] At least one staff profile has `is_admin = true`; the approval queue is reachable
- [ ] Approval RLS verified: a member account can read only its own payments and cannot review
- [ ] One real ₹1 UPI payment end-to-end: QR scans, UTR matches the bank statement, approval activates the plan
- [ ] Gym QR generated, printed, and token stored securely by staff
- [ ] `VITE_DEMO_MODE` is **not** `true` in production
- [ ] HTTPS + SPA rewrite configured
- [ ] Lighthouse / camera permission tested on iOS Safari and Android Chrome
- [ ] Backup and PITR policy enabled on the Supabase project
- [ ] Staff know how to publish holiday/closure announcements

---

## Troubleshooting

**“Supabase is not configured”** — set both `VITE_SUPABASE_URL` and
`VITE_SUPABASE_ANON_KEY`, then restart the dev server.

**No confirmation or reset email arrives** — check the Email provider, SMTP settings,
Redirect URLs, Auth logs, and rate limits. Also check spam/promotions.

**“Email link could not be completed”** — PKCE links must be opened in the same browser
that requested them. Request a fresh link from the same device, or update the email
templates to use the token-hash flow.

**Camera blocked** — browsers require HTTPS (or localhost) and explicit permission.
The scanner also supports manual code entry.

**Payment returns “not configured”** — the gym row has no `upi_id`/`upi_payee_name`, so the app
shows *“Payment is not available for this gym yet.”* Set them on `public.gyms` (see step 7).
The server also refuses to accept a UTR while the payee is unset.

**The uploaded QR is not shown** — the app decoded it and it did not match the server's payee
and amount, carried no amount, or could not be decoded. The generated QR below it points at
the verified UPI ID; fix the uploaded image if you want it to be used.

**Payment submitted but plan not active** — this is expected until an Admin-role user verifies
the UTR against the bank statement and approves the payment. Check `/admin/approvals`, or query
`payments` for a `pending` row with a `provider_payment_id`. Approval applies exactly once; a
second decision is rejected. Contact the member with the UPI reference if manual reconciliation
is needed.

**Approval fails with `MEMBERSHIP_PERIOD_OVERLAP`** — the member already has overlapping
non-cancelled membership rows, usually from legacy data. Correct those dates or statuses
first. Approval will not create another plan on top of an existing entitlement.

**Approval queue is empty or returns 403** — confirm the signed-in profile has
`is_admin = true` and refresh the session. The queue RPC and the `payments` RLS policies
both check the Admin role server-side.

**QR rejected** — confirm the printed token belongs to an active row in
`gym_qr_codes` (hash comparison is exact) and that no closure/holiday announcement covers
today.
