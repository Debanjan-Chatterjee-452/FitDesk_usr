# Read-Only Audit Findings

> No production data was changed. Every database query in this phase was a
> `select`. No migration, deploy, archive, reset, or delete was run.

## 1. Which project is actually in use

| Check | Result |
|---|---|
| Member app production bundle | points to `https://psgepyvdwvunjkbacsxe.supabase.co` |
| Admin website production bundle | points to `https://psgepyvdwvunjkbacsxe.supabase.co` |
| Member app local build | same project |
| Admin website local build | same project |
| Android / Capacitor assets | same project |
| Old project reference | only in stale CLI link metadata and old manual SQL files |

**Conclusion:** `psgepyvdwvunjkbacsxe` is the canonical database. The two
projects are separate Supabase projects; they do not share a database.

The legacy project `ocycaiomiiovnsjeivvd` is alive but is not used by the
current member app or admin website.

## 2. Migration state

- Production has migrations through **#12**.
- Migration **#13** (`20261104000100_fitdesk_member_join_realtime.sql`) is
  present in the admin repository but **not applied** to production.
  - `gym_join_requests` is absent (PostgREST `PGRST205`).
  - Join RPCs are absent (PostgREST `PGRST202`).
- The member repository only carries migrations #1–#10. This does not matter
  for production because the admin repository has the full set, but the two
  repositories should be kept in sync going forward.

**Consequence:** the plan applies #13 first, then drafts 01–07.

## 3. Confirmed gaps and how the plan fixes them

| # | Gap found | Risk | Fix |
|---|---|---|---|
| 1 | `admin_mark_payment_refunded()` only checks `is_admin()`, not the gym | An admin could refund another gym's payment row if they knew the UUID | Draft 04 scopes the lookup by `admin_assert()` |
| 2 | `gym-payment-qr` admin SELECT policy allows any admin to list any gym's files | Cross-gym file listing | Draft 04 narrows SELECT to the admin's own folder |
| 3 | `admin_assert()` does not check `gyms.is_active` | A suspended gym keeps full admin access | Draft 04 blocks suspended gyms with `GYM_SUSPENDED` |
| 4 | `gym_settings` is a singleton (`id = 1`) | Every gym shows the original FitDesk hours/address; admins edit the same row | Draft 02 creates one row per gym with own-gym RLS |
| 5 | Member app reads `gym_settings` with `.eq('id', 1)` | All members see the legacy gym's hours | Draft 02 adds `member_gym_overview()`; frontend switches to it |
| 6 | `register_gym_owner()` creates a gym but no `owner_id`, no settings, no subscription | No verified owner link; no independent settings; no trial tracking | Draft 05 adds all three atomically |
| 7 | `register_gym_owner()` raises `ALREADY_AN_ADMIN` on repeat | A retry or second login can fail and confuse the owner | Draft 05 returns the existing gym idempotently |
| 8 | `attendance` has no `gym_id` | Historical check-ins cannot be attributed to a gym reliably | Draft 04 adds and safely backfills it |
| 9 | `check_in_with_qr()` does not check `gyms.is_active` or a missing gym | Suspended/gym-less members could still check in | Draft 04 blocks both |
| 10 | `admin_list_members()` has no paging or total count | Large gyms load every member at once | Draft 06 adds an additive paged RPC |
| 11 | Admin sidebar shows a hardcoded gym name | Wrong name for every gym except the first | Frontend change (proposed, not approved) |
| 12 | `/join-gym` page exists in the member app but has no route | Members cannot request to join a gym | Frontend change (proposed, not approved) |
| 13 | No gym-assignment guard in the member app | A gym-less member sees an empty/broken home | Frontend change (proposed, not approved) |
| 14 | Admin website has no join-request screen | Approved join flow has no UI | Frontend change (proposed, not approved) |
| 15 | `admin_list_join_requests()` and `admin_review_join_request()` check admin manually | Suspended-gym check would be missed | Draft 07 routes them through `admin_assert()` |
| 16 | Approve/decline is not idempotent for stale decisions | Double click can flip a decision | Draft 07 makes decisions idempotent and rejects stale ones |

## 4. Things that were checked and are already correct

- Payment queues and the refund list are gym-scoped by migration #11.
- `admin_list_members`, dashboard stats, packages, closures, QR codes and
  payment settings are gym-scoped.
- `payment-proofs` storage policies are gym-scoped and private.
- `legal-documents` is private and owner-only.
- Member Realtime subscriptions are filtered by `user_id` and protected by RLS.
- `attendance` RLS only exposes a member's own rows.
- `gym_qr_codes` has RLS enabled with no policies, so members cannot read
  tokens.
- Existing profiles keep their `gym_id`; no migration moves or deletes them.

## 5. Legacy project `ocycaiomiiovnsjeivvd`

**Read-only inspection is still blocked on this machine.** The Supabase CLI is
installed but not authenticated:

```
AccessTokenRequiredError: Access token not provided.
```

No `SUPABASE_ACCESS_TOKEN` exists in the user, machine, or process environment,
and the local `.supabase` folder only contains telemetry. No legacy anon key
was found in either repository.

When the user signs in locally (`npx supabase login`), the inspection will
run in a **temporary folder** (not `D:\Gym App`, whose `.temp` still points at
the legacy project) and will only run these read-only checks:

1. `select` from `supabase_migrations.schema_migrations`.
2. Row counts per public table.
3. List of functions, triggers, policies and storage buckets.
4. Schema diff against canonical.
5. Count of auth users, and whether any user e-mail is missing from canonical.
6. Whether any payments, memberships or attendance rows are unique to legacy.

Possible outcomes:

| Finding | Recommendation |
|---|---|
| No unique data | Keep as an archive. Retire only with explicit approval, much later. |
| Unique data exists | Produce an export/merge proposal. Do not merge automatically. |
| Ambiguous | Leave untouched and ask. |

No archive, delete, reset, or migration of the legacy project will happen
without a separate written approval.

## 6. Deployment state

| Item | State |
|---|---|
| `fitdesk-usr` Vercel project | GitHub-linked to `FitDesk_usr`, branch `main`, Node 24.x |
| `fitdesk-admin` Vercel project | **not** GitHub-linked, Node 26.x |
| Unused Vercel project | `fitdesk` / `fitdesk-one.vercel.app` — leave alone |

The admin site can keep deploying with the Vercel CLI. If automatic deploys
are wanted, connect the existing `fitdesk-admin` project to its GitHub repo
without creating a new project. That is a separate, low-risk step and needs
approval.

## 7. Credentials handled in this phase

- No service-role key, database password, or personal access token was read,
  printed, committed, or placed in any Vercel environment variable.
- No credential is present in this plan folder.
- Nothing in the plan requires a secret in frontend code.

## 8. Frontend review additions (2026-11-02)

Two non-database gaps were found while reading the frontend code. They are not
security holes, but they would make the new features look broken:

| # | Gap | Effect if ignored | Fix |
|---|---|---|---|
| 17 | Admin member page computes the four status-tab counts in the browser | After server paging, badges show only the current page or disappear | Draft 06 now adds `admin_member_status_counts()`; tested against the paged RPC for every local gym |
| 18 | Admin session restore runs before any page and converts every error to `bootError` | A suspended gym admin sees "something went wrong" instead of "gym suspended" | Catch `GYM_SUSPENDED` inside `restoreAdminSession()` and keep a flagged session |

The earlier plan also incorrectly said `GymOverview` would not change and that
`Profile.gym_id` needed a type change. Both are corrected in
[`FRONTEND-CHANGES.md`](FRONTEND-CHANGES.md) section 0.

