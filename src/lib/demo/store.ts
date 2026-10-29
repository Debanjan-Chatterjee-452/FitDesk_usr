import type {
  Announcement,
  AttendanceRecord,
  GymPackage,
  GymSettings,
  Membership,
  Payment,
  Profile,
  RenewalQuote,
} from '@/types'
import { addDaysToDate, todayInKolkata } from '@/lib/kolkata'
import { calculateLateFee } from '@/lib/lateFee'

export const DEMO_STORE_KEY = 'fitdesk.demo.v1'
export const DEMO_SESSION_KEY = 'fitdesk.demo.session'
export const DEMO_GYM_TOKEN = 'FITDESK-DEMO-GYM'
export const DEMO_EMAIL = 'aarav@fitdesk.demo'
export const DEMO_PHONE = '9876543210'
export const DEMO_PASSWORD = 'fitdesk123'

export interface DemoUser {
  id: string
  email: string
  email_confirmed: boolean
  /** Optional contact number. Not used for sign-in. */
  phone: string
  password: string
  profile: Profile
  memberships: Membership[]
  attendance: AttendanceRecord[]
  payments: Payment[]
}

/**
 * Demo-only gym. The UPI handle `@demo` is not a real payment service
 * provider, so this address can never receive money. Production gyms get
 * their own row through the admin dashboard / SQL tooling.
 */
export const DEMO_GYM_ID = '7a1d0d7e-0000-4000-8000-0000000000d1'

export interface DemoGym {
  id: string
  name: string
  upi_id: string | null
  upi_payee_name: string | null
  payment_qr_path: string | null
  is_active: boolean
}

export interface DemoDatabase {
  version: 1
  users: DemoUser[]
  packages: GymPackage[]
  announcements: Announcement[]
  settings: GymSettings
  gyms?: DemoGym[]
}

const PACKAGE_IDS = {
  monthly: '11111111-1111-4111-8111-111111111111',
  quarterly: '22222222-2222-4222-8222-222222222222',
  halfYearly: '33333333-3333-4333-8333-333333333333',
  annual: '44444444-4444-4444-8444-444444444444',
  flex: '55555555-5555-4555-8555-555555555555',
} as const

export { PACKAGE_IDS }

const nowIso = () => new Date().toISOString()

function buildPackages(): GymPackage[] {
  const base = {
    is_active: true,
    min_days: null,
    max_days: null,
    pricing_mode: 'fixed' as const,
    created_at: nowIso(),
    updated_at: nowIso(),
  }
  return [
    {
      ...base,
      id: PACKAGE_IDS.monthly,
      name: 'Monthly',
      description: 'Full gym access for 30 days. Perfect for a focused reset.',
      duration_days: 30,
      price_inr: 1499,
      is_recommended: false,
      sort_order: 10,
    },
    {
      ...base,
      id: PACKAGE_IDS.quarterly,
      name: 'Quarterly',
      description: 'Three months of training, group classes, and locker access.',
      duration_days: 90,
      price_inr: 3999,
      is_recommended: true,
      sort_order: 20,
    },
    {
      ...base,
      id: PACKAGE_IDS.halfYearly,
      name: 'Half-yearly',
      description: 'Six months of uninterrupted access. Best value per month.',
      duration_days: 180,
      price_inr: 6999,
      is_recommended: false,
      sort_order: 30,
    },
    {
      ...base,
      id: PACKAGE_IDS.annual,
      name: 'Annual',
      description: 'A full year of training. Includes two guest passes.',
      duration_days: 365,
      price_inr: 11999,
      is_recommended: false,
      sort_order: 40,
    },
    {
      ...base,
      id: PACKAGE_IDS.flex,
      name: 'Flex',
      description: 'Pick any duration from 7 to 180 days. Pay only for the time you need.',
      duration_days: 30,
      price_inr: 79,
      pricing_mode: 'per_day',
      min_days: 7,
      max_days: 180,
      is_recommended: false,
      sort_order: 50,
    },
  ]
}

function buildSettings(): GymSettings {
  return {
    id: 1,
    name: 'FitDesk Performance Club',
    address: '12, 100 Feet Road, Indiranagar, Bengaluru 560038',
    open_time: '05:00',
    close_time: '23:00',
    closed_weekdays: [0],
    contact_phone: '+91 90000 00000',
    updated_at: nowIso(),
  }
}

export function buildDemoGyms(): DemoGym[] {
  return [
    {
      id: DEMO_GYM_ID,
      name: 'FitDesk Performance Club',
      // Demo-only: `@demo` is not a real PSP handle, so nothing can be paid.
      upi_id: 'fitdesk@demo',
      upi_payee_name: 'FitDesk Performance Club (Demo)',
      payment_qr_path: null,
      is_active: true,
    },
  ]
}

function buildAnnouncements(): Announcement[] {
  const today = todayInKolkata()
  return [
    {
      id: 'a1111111-1111-4111-8111-111111111111',
      title: 'New functional training zone is open',
      body: 'Turf, sled track and rig are now open on the first floor. Ask the front desk for a walkthrough.',
      kind: 'info',
      starts_on: addDaysToDate(today, -14),
      ends_on: addDaysToDate(today, 21),
      is_active: true,
      created_at: nowIso(),
    },
    {
      id: 'a2222222-2222-4222-8222-222222222222',
      title: 'Sunday deep-clean closure',
      body: 'The gym stays closed on Sundays for maintenance and deep cleaning.',
      kind: 'closure',
      starts_on: addDaysToDate(today, 5),
      ends_on: addDaysToDate(today, 5),
      is_active: true,
      created_at: nowIso(),
    },
  ]
}

function buildDemoUser(): DemoUser {
  const id = '00000000-0000-4000-8000-000000000001'
  const today = todayInKolkata()
  const startsOn = addDaysToDate(today, -12)
  const endsOn = addDaysToDate(today, 18)
  const createdAt = new Date(`${startsOn}T06:30:00+05:30`).toISOString()
  const packageRef = buildPackages()[0]!

  const membership: Membership = {
    id: '90000000-0000-4000-8000-000000000001',
    user_id: id,
    package_id: PACKAGE_IDS.monthly,
    starts_on: startsOn,
    ends_on: endsOn,
    price_paid_inr: 1499,
    fine_paid_inr: 0,
    status: 'active',
    created_at: createdAt,
    updated_at: createdAt,
    package: packageRef,
  }

  const attendanceDays = [-1, -2, -4, -5, -8, -9, -11, -12, -15, -18]
  const attendance: AttendanceRecord[] = attendanceDays.map((offset, index) => {
    const date = addDaysToDate(today, offset)
    const hour = index % 2 === 0 ? '06' : '19'
    const minute = String(10 + ((index * 7) % 45)).padStart(2, '0')
    const at = new Date(`${date}T${hour}:${minute}:00+05:30`).toISOString()
    return {
      id: `attendance-${offset}`,
      user_id: id,
      check_in_at: at,
      check_in_date: date,
      source: 'qr',
      gym_qr_id: null,
      created_at: at,
    }
  })

  const payment: Payment = {
    id: '80000000-0000-4000-8000-000000000001',
    user_id: id,
    membership_id: membership.id,
    package_id: PACKAGE_IDS.monthly,
    duration_days: 30,
    base_amount_inr: 1499,
    fine_amount_inr: 0,
    total_amount_inr: 1499,
    status: 'approved',
    provider: 'razorpay',
    provider_order_id: 'order_demo_seed_001',
    provider_payment_id: 'pay_demo_seed_001',
    failure_reason: null,
    quote: null,
    paid_at: createdAt,
    reviewed_at: createdAt,
    reviewed_by: id,
    review_note: null,
    checkout_state: 'submitted',
    reconciliation_required: false,
    reconciliation_reason: null,
    legacy_status: null,
    refund_status: 'not_required',
    refund_note: null,
    refunded_at: null,
    refunded_by: null,
    created_at: createdAt,
    updated_at: createdAt,
    package: {
      id: PACKAGE_IDS.monthly,
      name: 'Monthly',
      duration_days: 30,
    },
  }

  return {
    id,
    email: DEMO_EMAIL,
    email_confirmed: true,
    phone: DEMO_PHONE,
    password: DEMO_PASSWORD,
    profile: {
      id,
      email: DEMO_EMAIL,
      phone: `+91${DEMO_PHONE}`,
      full_name: 'Aarav Mehta',
      date_of_birth: '1996-04-18',
      blood_group: 'O+',
      gender: 'male',
      legal_document_path: `${id}/demo-verification-document.pdf`,
      legal_document_name: 'aarav-id-verification.pdf',
      legal_document_type: 'application/pdf',
      profile_completed: true,
      is_admin: true,
      created_at: createdAt,
      updated_at: createdAt,
    },
    memberships: [membership],
    attendance,
    payments: [payment],
  }
}

export function createSeedDatabase(): DemoDatabase {
  return {
    version: 1,
    users: [buildDemoUser()],
    packages: buildPackages(),
    announcements: buildAnnouncements(),
    settings: buildSettings(),
    gyms: buildDemoGyms(),
  }
}

let memoryFallback: DemoDatabase | null = null

/**
 * Older demo databases stored only a phone number. Keep those users (and their
 * membership/payment history) but attach an email so email sign-in works.
 *
 * Payment migration is intentionally non-destructive: failed, refunded, and
 * cancelled rows keep their original status in `legacy_status` instead of
 * silently becoming plain declined receipts. No payment row is deleted.
 */
export function migrateDemoDatabase(db: DemoDatabase): boolean {
  let changed = false
  if (!Array.isArray(db.gyms) || db.gyms.length === 0) {
    db.gyms = buildDemoGyms()
    changed = true
  }
  for (const user of db.users) {
    if (!user.email) {
      user.email =
        user.phone === DEMO_PHONE
          ? DEMO_EMAIL
          : user.phone
            ? `${user.phone}@demo.fitdesk.local`
            : `member-${user.id.slice(0, 8)}@demo.fitdesk.local`
      changed = true
    }
    if (typeof user.email_confirmed !== 'boolean') {
      user.email_confirmed = true
      changed = true
    }
    if (!user.profile.email) {
      user.profile.email = user.email
      changed = true
    }

    if (typeof user.profile.is_admin !== 'boolean') {
      // The seeded demo identity is the gym's demo Admin so the approval queue
      // can be explored with the documented login. New sign-ups are members.
      user.profile.is_admin = user.email === DEMO_EMAIL
      changed = true
    }

    for (const payment of user.payments) {
      const legacy = payment.status as string
      const isCurrentStatus = ['pending', 'approved', 'declined'].includes(legacy)

      if (!isCurrentStatus) {
        if (legacy === 'paid') {
          payment.status = 'approved'
        } else if (legacy === 'created') {
          payment.status = 'pending'
        } else {
          // The review enum cannot represent these historical gateway states.
          // Keep the original value so the receipt is not misreported as a
          // plain decline.
          payment.status = 'declined'
          payment.legacy_status = payment.legacy_status ?? legacy
        }
        changed = true
      }

      if (payment.status === 'approved' && !payment.reviewed_at) {
        payment.reviewed_at = payment.paid_at ?? payment.updated_at
        changed = true
      }

      if (!payment.checkout_state) {
        payment.checkout_state =
          payment.status === 'approved'
            ? 'submitted'
            : payment.status === 'declined'
              ? 'abandoned'
              : payment.provider_payment_id
                ? 'submitted'
                : 'open'
        changed = true
      }
      if (typeof payment.reconciliation_required !== 'boolean') {
        payment.reconciliation_required = false
        changed = true
      }
      if (payment.reconciliation_reason === undefined) {
        payment.reconciliation_reason = null
        changed = true
      }
      if (payment.legacy_status === undefined) {
        payment.legacy_status = null
        changed = true
      }
      if (!payment.refund_status) {
        payment.refund_status =
          payment.legacy_status === 'refunded'
            ? 'refunded'
            : payment.status === 'declined' && payment.provider_payment_id
              ? 'pending_manual_refund'
              : 'not_required'
        changed = true
      }
      if (payment.refund_note === undefined) {
        payment.refund_note = null
        changed = true
      }
      if (payment.refunded_at === undefined) {
        payment.refunded_at =
          payment.legacy_status === 'refunded'
            ? (payment.reviewed_at ?? payment.paid_at ?? payment.updated_at)
            : null
        changed = true
      }
      if (payment.refunded_by === undefined) {
        payment.refunded_by = null
        changed = true
      }
      if (payment.reviewed_at === undefined) {
        payment.reviewed_at = payment.status === 'approved' ? payment.paid_at : null
        changed = true
      }
      if (payment.reviewed_by === undefined) {
        payment.reviewed_by = null
        changed = true
      }
    }
  }
  return changed
}

export function loadDemoDatabase(): DemoDatabase {
  if (memoryFallback) return memoryFallback
  try {
    const raw = localStorage.getItem(DEMO_STORE_KEY)
    if (raw) {
      const parsed = JSON.parse(raw) as DemoDatabase
      if (parsed?.version === 1 && Array.isArray(parsed.users)) {
        if (migrateDemoDatabase(parsed)) saveDemoDatabase(parsed)
        memoryFallback = parsed
        return parsed
      }
    }
  } catch {
    // fall through to a fresh seed
  }
  const seed = createSeedDatabase()
  saveDemoDatabase(seed)
  return seed
}

export function saveDemoDatabase(db: DemoDatabase): void {
  memoryFallback = db
  try {
    localStorage.setItem(DEMO_STORE_KEY, JSON.stringify(db))
  } catch {
    // In-memory fallback keeps the demo usable if storage is unavailable.
  }
}

export function resetDemoDatabase(): void {
  memoryFallback = null
  try {
    localStorage.removeItem(DEMO_STORE_KEY)
    sessionStorage.removeItem(DEMO_SESSION_KEY)
    localStorage.removeItem(DEMO_SESSION_KEY)
  } catch {
    // no-op
  }
  loadDemoDatabase()
}

export function getDemoSessionUserId(): string | null {
  try {
    return (
      sessionStorage.getItem(DEMO_SESSION_KEY) ?? localStorage.getItem(DEMO_SESSION_KEY)
    )
  } catch {
    return null
  }
}

export function setDemoSessionUserId(userId: string, persist: boolean): void {
  try {
    const target = persist ? localStorage : sessionStorage
    target.setItem(DEMO_SESSION_KEY, userId)
    const other = persist ? sessionStorage : localStorage
    other.removeItem(DEMO_SESSION_KEY)
  } catch {
    // no-op
  }
}

export function clearDemoSession(): void {
  try {
    localStorage.removeItem(DEMO_SESSION_KEY)
    sessionStorage.removeItem(DEMO_SESSION_KEY)
  } catch {
    // no-op
  }
}

export function calculateDemoQuote(
  userId: string,
  packageId: string,
  durationDays: number | null,
  db: DemoDatabase = loadDemoDatabase(),
): RenewalQuote {
  const pkg = db.packages.find((item) => item.id === packageId && item.is_active)
  if (!pkg) throw new Error('PACKAGE_NOT_FOUND')
  const user = db.users.find((item) => item.id === userId)
  if (!user) throw new Error('AUTH_REQUIRED')

  const today = todayInKolkata()
  const nonCancelled = user.memberships
    .filter((membership) => membership.status !== 'cancelled')
    .sort((a, b) => (a.ends_on < b.ends_on ? 1 : -1))
  const latest = nonCancelled[0] ?? null
  const active = latest && latest.ends_on >= today ? latest : null
  const expired = !active && latest && latest.ends_on < today ? latest : null

  let duration = pkg.duration_days
  if (pkg.pricing_mode === 'per_day') {
    duration = durationDays ?? pkg.min_days ?? 30
    const min = pkg.min_days ?? 1
    const max = pkg.max_days ?? 365
    duration = Math.min(Math.max(duration, min), max)
  }

  const daysPastExpiry = expired
    ? Math.round(
        (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${expired.ends_on}T00:00:00Z`)) /
          86_400_000,
      )
    : 0

  const { amount: fineAmount, reason: fineReason } = calculateLateFee(daysPastExpiry)

  const baseAmount =
    pkg.pricing_mode === 'per_day' ? pkg.price_inr * duration : pkg.price_inr
  const startsOn = active ? addDaysToDate(active.ends_on, 1) : today
  const endsOn = addDaysToDate(startsOn, duration - 1)

  const breakdown: Array<{ label: string; amount: number }> = [
    { label: `${pkg.name} · ${duration} days`, amount: baseAmount },
  ]
  if (fineAmount > 0) {
    breakdown.push({ label: 'Late renewal fee', amount: fineAmount })
  }

  return {
    package_id: pkg.id,
    package_name: pkg.name,
    description: pkg.description,
    pricing_mode: pkg.pricing_mode,
    duration_days: duration,
    base_amount: baseAmount,
    fine_amount: fineAmount,
    total_amount: baseAmount + fineAmount,
    days_past_expiry: daysPastExpiry,
    grace_days: 7,
    starts_on: startsOn,
    ends_on: endsOn,
    current_ends_on: latest?.ends_on ?? null,
    is_stacked: Boolean(active),
    fine_reason: fineReason,
    breakdown,
  }
}
