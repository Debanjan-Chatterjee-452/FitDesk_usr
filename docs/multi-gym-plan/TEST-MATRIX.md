# Gym A / Gym B Test Matrix

Use this matrix on a clone of production before touching production, and again
after each production step.

- **Gym A** = `iron-temple` (owner: Owner A)
- **Gym B** = `steel-yard` (owner: Owner B)
- A member of A is "Member A"; a member of B is "Member B".

Test identities are applied locally with synthetic JWT claims:

```sql
select set_config(
  'request.jwt.claims',
  json_build_object('sub', '<user-uuid>', 'role', 'authenticated')::text,
  false
);
set role authenticated;
```

Then `reset role;` after each block.

---

## A. Isolation (must all pass before production)

| # | Check | Expected | Local result |
|---|---|---|---|
| 1 | Admin A calls `admin_list_members_page` | Only Gym A members, correct `total_count` | Passed |
| 2 | Admin B calls `admin_list_members_page` | Only Gym B members | Passed (same code path) |
| 3 | Admin A reviews a Gym B payment UUID | `PAYMENT_NOT_FOUND` | Passed (refund variant) |
| 4 | Admin A refunds a Gym B declined payment | `PAYMENT_NOT_FOUND` | **Passed** |
| 5 | Admin A sees dashboard totals | Counts only Gym A rows | Passed by SQL inspection |
| 6 | Admin A lists join requests | Only Gym A requests | Passed |
| 7 | Member A scans Gym B's attendance QR | `QR_GYM_MISMATCH` | **Passed** |
| 8 | Member A calls `member_gym_overview` | Gym A name/hours/announcements | **Passed** |
| 9 | Member B calls `member_gym_overview` | Gym B name/hours | Passed by SQL inspection |
| 10 | Gym B settings edit by Admin A | Not possible (own-gym RLS/RPC) | Passed by policy inspection |
| 11 | Admin A lists `gym-payment-qr` | Only `A-gym-id/…` objects | Passed by policy inspection |
| 12 | Member A reads another member's profile | No rows (RLS) | Passed by policy inspection |
| 13 | Member A reads another member's attendance | No rows (RLS) | Passed by policy inspection |

## B. Suspension

| # | Check | Expected | Local result |
|---|---|---|---|
| 14 | Suspend Gym A, Admin A calls any admin RPC | `GYM_SUSPENDED` | **Passed** |
| 15 | Suspend Gym A, Member A scans Gym A QR | `GYM_SUSPENDED` | **Passed** |
| 16 | Reactivate Gym A, Admin A calls RPC | Works again | **Passed** |
| 17 | Platform owner suspends/reactivates | One audit row per action | Passed by SQL inspection |

## C. Registration and join flow

| # | Check | Expected | Local result |
|---|---|---|---|
| 18 | New owner registers, then registers again | Exactly one gym, `already_registered: true` | **Passed** |
| 19 | Two simultaneous registrations (two tabs) | Exactly one gym (advisory lock) | Passed by design review |
| 20 | New owner gets settings, 4 rails, 1 trial, owner_id | All present | **Passed** |
| 21 | Owner signup has confirmation email enabled | Login still works after confirm | Unchanged auth config |
| 22 | Member requests the same gym twice | One `gym_join_requests` row | **Passed** |
| 23 | Admin approves twice | No error, no duplicate notification | **Passed** |
| 24 | Admin declines, member re-requests | Same row returns to `pending` | Passed by SQL review |
| 25 | Suspended gym join code | `GYM_NOT_FOUND` | Passed by SQL review |

## D. Data preservation

| # | Check | Expected |
|---|---|---|
| 26 | `auth.users` count before/after | Identical |
| 27 | `profiles` count before/after | Identical |
| 28 | `memberships` count before/after | Identical |
| 29 | `payments` count before/after | Identical |
| 30 | `attendance` count before/after | Identical |
| 31 | Existing `profiles.gym_id` values | Unchanged |
| 32 | Existing payment amounts / references | Unchanged |
| 33 | Existing membership dates / statuses | Unchanged |
| 34 | Existing UPI IDs / payee names / QR paths | Unchanged |
| 35 | Every gym has a unique `public_id` | Yes |
| 36 | Every gym has one settings row | Yes |

## E. Backfill report

Run after migration 04:

```sql
-- Should be zero before production is declared healthy.
select count(*) as unassigned
  from public.attendance
 where gym_id is null;

-- The actual review list.
select a.id, a.user_id, a.check_in_at, a.gym_qr_id,
       (select count(distinct m.gym_id)
          from public.memberships m
         where m.user_id = a.user_id) as membership_gyms,
       (select count(distinct p.gym_id)
          from public.payments p
         where p.user_id = a.user_id) as payment_gyms,
       pr.gym_id as profile_gym
  from public.attendance a
  join public.profiles pr on pr.id = a.user_id
 where a.gym_id is null
 order by a.check_in_at;
```

- Safe rows are already filled.
- Every remaining row is shown to the user before any manual decision.
- No row is guessed.

Local result: **2 of 2 attendance rows** were assigned safely; zero needed
review.

## F. Rollback test

| # | Check | Expected | Local result |
|---|---|---|---|
| 37 | Apply 01–07 to a clone | All clean | **Passed** |
| 38 | Run `down_07` … `down_01` + function snapshot | No errors | **Passed** |
| 39 | New columns/tables/functions removed | Zero remain | **Passed** |
| 40 | Original settings singleton restored | `id = 1` row only | **Passed** |

## G. Member list pagination and counts (draft 06)

| # | Check | Expected | Local result |
|---|---|---|---|
| 41 | `admin_member_status_counts()` vs `admin_list_members_page()` for every admin | Identical all/pending/paid/not_paid | **Passed (5 gyms)** |
| 42 | A real pending payment changes the counts | Paid −1, Pending +1, total unchanged | **Passed** |
| 43 | Search by e-mail, status filter, empty search | 1 / 1 / 0 rows, correct `total_count` | **Passed** |
| 44 | `limit 2, offset 0` then `offset 2` | 2 rows each, no overlap, `total_count` = 4 | **Passed** |
| 45 | Non-admin calls the counts RPC | `ADMIN_REQUIRED` | **Passed** |
| 46 | Suspended gym calls the counts RPC | `GYM_SUSPENDED` | **Passed** |

---

## Local test scripts

These are local-only and are never run against production:

- `sql/_test_registration.sql`
- `sql/_test_isolation.sql`
- `sql/_test_join.sql`
- `sql/_test_platform.sql`
- `sql/_test_status_counts.sql` (wraps itself in `begin` … `rollback`)

They create two throwaway auth accounts
(`owner-test@example.test`, `join-test@example.test`) inside the local test
database only.
