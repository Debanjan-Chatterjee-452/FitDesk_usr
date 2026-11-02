# Frontend Changes (revised after code review)

> These are proposals. Nothing has been changed in either app yet.
> Revised on 2026-11-02 after reading the actual frontend code and the tested
> draft SQL. The previous version had four inaccuracies; they are corrected
> below and listed in section 0.
>
> The existing dashboard layout, colours, navigation style and forms stay.

---

## 0. What the code review changed

| # | Previous claim | What the code actually needs |
|---|---|---|
| 1 | A3 "keep `GymOverview` shape, pages do not change" | False. `member_gym_overview()` returns `status`, `gym_name`, `is_open`, `gym_id` and a **subset** of settings. `GymOverview` must gain fields, and the member `GymSettings` type must gain `gym_id` and a nullable `id`. |
| 2 | A4 "change `Profile.gym_id` to nullable" | Already done: `Profile.gym_id?: string \| null` in `src/types/index.ts`. No profile type change is needed. |
| 3 | B5 "add Previous/Next and a total count" | Understated. `MembersPage` currently computes the four tab counts, search and filtering **client-side over the full list**. Moving to server paging needs a counts RPC (now added to draft 06), debounced search, offset reset, and mutation cache changes. |
| 4 | B6 "map `GYM_SUSPENDED` in error handling" | Not enough. `restoreAdminSession()` runs before any page and turns the error into a generic `bootError` screen. Suspension must be handled **inside the restore/sign-in path**. |

Two smaller corrections: B1 must read signup metadata directly (the current
`reset()` prefill is a race), and B2/B4 need extra fields on the admin
`GymSettings` type.

---

## A. Member app (`D:\Gym App`)

### A1. Route the existing join page

File: `src/App.tsx`

The current tree is:

```
RequireSession
  /onboarding
  RequireCompleteProfile
    AppShell
      /, /membership, /attendance, /profile, /scan, /admin/approvals
```

Change it to:

```
RequireSession
  /onboarding
  RequireCompleteProfile
    /join-gym              <- new, no AppShell
    RequireGym
      AppShell
        /, /membership, /attendance, /profile, /scan, /admin/approvals
```

- `/join-gym` renders the existing `JoinGymPage` unchanged.
- It is outside `AppShell`, so it has no bottom navigation.
- It is inside `RequireCompleteProfile`, so a member must finish their profile
  before choosing a gym.

### A2. Gym-assignment guard

File: `src/components/guards.tsx`

Add `RequireGym`:

- while `profileLoading && !profile`: show the existing `FullScreenLoader`;
- if `isDemo`: render `Outlet` (the demo profile has no real `gym_id`);
- if `profile?.gym_id` is `null`/missing: `<Navigate to="/join-gym" replace />`;
- otherwise render `Outlet`.

No existing member is affected because every existing profile already has a
gym. The legacy gym has no admin, but it does have members.

### A3. Read the member's own gym settings

File: `src/lib/api/gym.ts`

Replace the singleton read:

```ts
client.from('gym_settings').select('*').eq('id', 1).maybeSingle()
```

with one RPC call:

```ts
client.rpc('member_gym_overview')
```

The RPC returns:

```json
{
  "status": "active" | "suspended" | "no_gym",
  "gym_id": "uuid",
  "gym_name": "string",
  "is_open": true,
  "settings": {
    "id": 1,
    "gym_id": "uuid",
    "name": "string",
    "address": "string|null",
    "open_time": "05:00",
    "close_time": "23:00",
    "closed_weekdays": [0],
    "contact_phone": "string|null",
    "updated_at": "timestamp"
  },
  "announcements": []
}
```

Therefore `GymOverview` becomes:

```ts
export interface GymOverview {
  status: 'active' | 'suspended' | 'no_gym'
  gymId: string | null
  gymName: string | null
  isOpen: boolean
  settings: GymSettings | null
  announcements: Announcement[]
}
```

Notes:

- Only `settings.address`, `settings.open_time`, `settings.close_time`,
  `settings.closed_weekdays` and `settings.updated_at` are read today
  (`GymStatusCard` and `lib/gymStatus.ts`). The subset is sufficient.
- `upi_id`, `payment_qr_path` and `slug` are **not** read from the overview, so
  their absence does not break payments. Verified by search.
- Demo mode keeps using the local demo store, but must add `status: 'active'`,
  `gymName` and `isOpen` so the shape matches.

### A4. Types (corrected)

File: `src/types/index.ts`

```ts
export interface GymSettings {
  id: number | null        // draft 02 drops NOT NULL
  gym_id: string           // new tenant key
  name: string
  address: string | null
  open_time: string
  close_time: string
  closed_weekdays: number[]
  contact_phone: string | null
  updated_at: string
}
```

No change to `Profile.gym_id`; it is already `string | null`.

### A5. Suspended / missing gym message

`RequireGym` should also use `useGymOverview()` (React Query dedupes it with
the home query):

- `status === 'suspended'`: show a full-screen card,
  "This gym is temporarily unavailable. Please contact your gym.", with a
  **Sign out** button. Do not render the app shell.
- `status === 'no_gym'`: redirect to `/join-gym` (same as missing `gym_id`).
- overview request fails: show the existing `ErrorState` with retry, not a
  redirect. A network error must not look like "no gym".

This is a guard-level screen, not only a home-screen card, because membership,
payment and attendance RPCs will reject a suspended gym after draft 04.

### A6. Not changing in the member app

- Login, signup, password reset, profile setup.
- Home layout, cards, colours, navigation.
- Membership, payment, UPI, attendance and scan screens.
- No new dependency.

**Member-app work:** one route nesting change, one guard, one API function, two
type fields, one message screen.

---

## B. Admin website (`D:\Gym Admin Website`)

### B1. Auto-complete owner setup after first login

File: `src/pages/OnboardingPage.tsx`

Current code fills the form through `reset()` inside a `useEffect`. Reading
`getValues()` afterwards is a race and can submit an empty gym name.

Revised behaviour:

1. On mount, call `readPendingOwnerDetails()` directly.
2. If a gym name exists, call `completeOwnerOnboarding({ gymName, fullName, phone })`
   immediately with those values — not with form state.
3. Guard with `useRef` so React Strict Mode cannot call it twice.
4. Show "Setting up your gym…" while it runs.
5. On success: `await reload()` then `navigate('/dashboard', { replace: true })`.
6. On failure: reveal the existing manual form, prefilled, with the error.
7. If no gym name in metadata: show the manual form (existing behaviour).

The database function is idempotent, so a retry is safe. Do not auto-run when
the signed-in account is already an admin (`isAdmin === true`).

### B2. Real gym name and IDs in the session

Files: `src/lib/api/auth.ts`, `src/context/AuthContext.tsx`,
`src/components/layout/SidebarContent.tsx`, `src/types/index.ts`

- After `is_admin()` returns true, call `admin_get_gym_settings()`.
- Extend `AdminSession` with:

  ```ts
  gymId: string | null
  gymName: string | null
  gymPublicId: string | null
  gymJoinCode: string | null
  gymSuspended: boolean
  ```

- Sidebar line ~56: replace the hardcoded `FitDesk Performance Club` with
  `session.gymName ?? 'FitDesk'`.
- Extend the admin `GymSettings` type with the fields the RPC already returns:
  `public_id`, `join_code`, `owner_id`, `is_active`, `suspended_at`,
  `suspension_reason`, `created_at`.

No layout change.

### B3. Join requests screen

New file: `src/lib/api/joinRequests.ts`

Exact RPC signatures from draft 07:

```ts
admin_list_join_requests()                       // jsonb/table
admin_review_join_request(p_request_id, p_approve)
admin_pending_join_request_count()               // integer
```

New page: `src/pages/JoinRequestsPage.tsx`

- pending first, then decided;
- member name, e-mail, phone, requested date;
- Approve / Decline buttons with a confirm step for Decline;
- refresh after a decision and on window focus (no new Realtime dependency);
- empty state and error state reuse existing components.

Add route `/join-requests` and one sidebar item with a pending badge.

On approve, the database assigns `profiles.gym_id`; the member app's
`RequireGym` then lets them in on their next refresh.

### B4. Show Gym ID and join code

Files: `src/lib/api/dashboard.ts` (type only), settings page.

`admin_get_gym_settings()` already returns `public_id` and `join_code` after
draft 01. Show both with copy buttons next to the gym name.

### B5. Pagination for the member list (full redesign)

Files: `src/lib/api/members.ts`, `src/pages/MembersPage.tsx`

`admin_list_members_page(p_search, p_status, p_limit, p_offset)` already
returns the member columns plus `total_count`.

The current page does the following **in the browser**:

- `counts` for all four tabs (`all`, `pending`, `paid`, `not_paid`);
- `filtered` by search across name, e-mail, phone, plan and reference;
- `dedupeByKey` over the full list;
- mutations that update the cached array in place.

A paged list changes all of that:

1. Replace `listMembers()` with `listMembersPage({ search, status, limit, offset })`.
2. Debounce search by ~300 ms; reset `offset` to `0` whenever search or status
   changes.
3. Keep page size 50 (RPC caps at 200).
4. Previous / Next buttons disabled at the edges; show "Showing X–Y of total".
5. Counts: call the new `admin_member_status_counts()` once per list refresh.
   It returns `{ all, pending, paid, not_paid }` for the admin's gym and
   intentionally ignores search, matching today's tab badges. Draft 06 now
   contains this function; no four-query workaround is needed.
6. Mutations (`cancel`, `pause`, `resume`, `reviewPayment`) must
   `invalidateQueries` for the member list instead of editing one array.
7. Keep `listMembers()` exported until the paged UI is deployed.

Search and filter UI stay visually the same.

### B6. Suspended gym (restore path, not just error text)

Files: `src/lib/errors.ts`, `src/lib/api/auth.ts`, `src/context/AuthContext.tsx`,
`src/App.tsx`

`admin_assert()` raises `GYM_SUSPENDED` after draft 04. `is_admin()` is
role-only and does **not** raise it, so a suspended admin can sign in and then
see generic failures. Fix both paths:

1. Add `GYM_SUSPENDED` to `FRIENDLY_MESSAGES` in `src/lib/errors.ts`:
   "This gym is suspended. Contact FitDesk support."
2. During `restoreAdminSession()` and `signInAdmin()`, after `is_admin()` is
   true, call `admin_get_gym_settings()` and catch `GYM_SUSPENDED`.
3. Return a session with `gymSuspended: true` (plus whatever profile data is
   already loaded) instead of throwing.
4. `AuthContext` keeps that session and does **not** set `bootError`.
5. In `App.tsx`, before the normal routes, render a dedicated full-screen
   suspended card with **Sign out** and **Retry**. Do not show the dashboard
   or the generic boot-error screen.
6. A non-admin account still goes to `/onboarding`; suspension only applies to
   gym admins.

### B7. Platform-owner detection (no UI yet)

- Add `isPlatformOwner` to the session by calling `platform_me()`.
- `platform_me()` returns `{ is_platform_owner: false }` for normal users, so it
  is safe for every signed-in account.
- Do **not** add a `/platform` route, page or navigation item yet.
- This only prepares the backend-to-frontend contract.

### B8. Not changing in the admin app

- Login, signup, password reset, owner signup form.
- Dashboard cards, QR/UPI screens, payment approval flow, receipts.
- Closures, attendance, packages, announcements.
- Existing navigation layout (one new item only).
- No new dependency, no new Vercel project.

---

## C. Deployment order (corrected)

1. Apply migration #13, then drafts 01–07.
2. Deploy the **admin** site:
   - real gym name and IDs,
   - suspended-gym screen,
   - auto-complete onboarding,
   - join requests page.
3. Deploy the **member** app:
   - join route + guard,
   - own-gym overview RPC,
   - type fields,
   - suspended gate.
4. Deploy pagination only with the counts RPC approved.

Why the order matters:

- Drafts are additive and do not break the current frontend.
- The member app keeps reading `gym_settings` id 1 until step 3. After draft 02
  that read is RLS-scoped, so it still works for the original gym but returns
  `null` for any new gym. **Ship step 3 before a second gym gets its first
  member.**
- The admin app keeps using `admin_list_members` until step 4.
- Owner registration (draft 05) can run before step 3 only while new gyms have
  no members. Safer: deploy the member app first if new owners will sign up
  immediately.

No UI change is required for the migrations to be safe.

---

## D. Accepted risks / deliberately not changing

- The `gym-payment-qr` bucket stays public because the member app uses
  `getPublicUrl`. Making it private needs a signed-URL change and is deferred.
- No `/platform` dashboard yet.
- No payment gateway.
- No change to the deployed URLs or Vercel projects.
- No visual redesign.

---

## E. Approval checklist (frontend only)

Please confirm, item by item:

1. Member app: nested route + `RequireGym` + overview RPC + suspended gate (A1–A5).
2. Admin app: auto-complete onboarding, real gym name/IDs, join requests,
   suspended screen (B1–B4, B6).
3. Member-list paging (B5) — **only if** the counts RPC is added to draft 06.
4. `isPlatformOwner` detection without any UI (B7).

Until items 1–4 are approved, no frontend file is edited.
