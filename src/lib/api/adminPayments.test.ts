import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type {
  MembershipStatus,
  Payment,
  RenewalQuote,
} from '@/types'
import { addDaysToDate, todayInKolkata } from '@/lib/kolkata'
import {
  PACKAGE_IDS,
  createSeedDatabase,
  loadDemoDatabase,
  migrateDemoDatabase,
  resetDemoDatabase,
  saveDemoDatabase,
  type DemoDatabase,
} from '@/lib/demo/store'

vi.mock('@/lib/env', () => ({
  isDemo: true,
  isDemoMode: true,
  isSupabaseConfigured: false,
  supabaseUrl: '',
  supabaseAnonKey: '',
  razorpayPublicKeyId: '',
  TIMEZONE: 'Asia/Kolkata',
  CURRENCY: 'INR',
  appConfig: {},
}))

const session = vi.hoisted(() => ({ userId: '' }))

vi.mock('./session', () => ({
  requireUserId: async () => session.userId,
}))

import {
  listPendingPayments,
  listRefundPayments,
  markPaymentRefunded,
  reviewPayment,
} from './adminPayments'
import {
  createRenewalOrder,
  getMyPayments,
  getMyPendingPayment,
  verifyRenewalPayment,
} from './payments'
import { getMyMembershipOverview } from './memberships'

function createStorage(): Storage {
  const data = new Map<string, string>()
  return {
    get length() {
      return data.size
    },
    clear() {
      data.clear()
    },
    getItem(key: string) {
      return data.get(key) ?? null
    },
    key(index: number) {
      return [...data.keys()][index] ?? null
    },
    removeItem(key: string) {
      data.delete(key)
    },
    setItem(key: string, value: string) {
      data.set(key, value)
    },
  }
}

function addReviewer(db: DemoDatabase): string {
  const id = crypto.randomUUID()
  const now = new Date().toISOString()
  const email = 'reviewer@fitdesk.demo'

  db.users.push({
    id,
    email,
    email_confirmed: true,
    phone: '9000000000',
    password: 'reviewer123',
    profile: {
      id,
      email,
      phone: '+919000000000',
      full_name: 'Review Admin',
      date_of_birth: null,
      blood_group: null,
      gender: null,
      legal_document_path: null,
      legal_document_name: null,
      legal_document_type: null,
      profile_completed: true,
      is_admin: true,
      created_at: now,
      updated_at: now,
    },
    memberships: [],
    attendance: [],
    payments: [],
  })

  return id
}

function seedMember(expiryOffset: number): {
  db: DemoDatabase
  userId: string
  reviewerId: string
  membershipId: string
  endsOn: string
} {
  const db = createSeedDatabase()
  const user = db.users[0]!
  const today = todayInKolkata()
  const membership = user.memberships[0]!
  const endsOn = addDaysToDate(today, expiryOffset)
  const status: MembershipStatus = expiryOffset < 0 ? 'expired' : 'active'

  user.memberships = [
    {
      ...membership,
      starts_on: addDaysToDate(today, expiryOffset - 29),
      ends_on: endsOn,
      status,
      fine_paid_inr: 25,
    },
  ]
  user.payments = []
  const reviewerId = addReviewer(db)
  saveDemoDatabase(db)
  session.userId = user.id

  return { db, userId: user.id, reviewerId, membershipId: membership.id, endsOn }
}

async function submitRenewal(packageId: string): Promise<{
  paymentId: string
  orderId: string
}> {
  const order = await createRenewalOrder(packageId)
  const verification = await verifyRenewalPayment({
    razorpay_order_id: order.order_id,
    razorpay_payment_id: `pay_test_${order.payment_id}`,
    razorpay_signature: 'test_signature',
  })
  expect(verification.status).toBe('pending_approval')
  return { paymentId: order.payment_id, orderId: order.order_id }
}

function demoUser() {
  return loadDemoDatabase().users[0]!
}

function buildReconciliationPayment(
  userId: string,
  overrides: Partial<Payment> = {},
): Payment {
  const now = new Date().toISOString()
  return {
    id: crypto.randomUUID(),
    user_id: userId,
    membership_id: null,
    package_id: PACKAGE_IDS.monthly,
    duration_days: 30,
    base_amount_inr: 1499,
    fine_amount_inr: 0,
    total_amount_inr: 1499,
    status: 'pending',
    provider: 'razorpay',
    provider_order_id: 'order_reconciliation_test',
    provider_payment_id: null,
    failure_reason: 'Capture may have succeeded; manual reconciliation is required.',
    quote: null,
    paid_at: null,
    reviewed_at: null,
    reviewed_by: null,
    review_note: null,
    checkout_state: 'reconciliation_required',
    reconciliation_required: true,
    reconciliation_reason:
      'Razorpay reports this order as paid, but no payment was returned.',
    legacy_status: null,
    refund_status: 'not_required',
    refund_note: null,
    refunded_at: null,
    refunded_by: null,
    created_at: now,
    updated_at: now,
    ...overrides,
  }
}

describe('manual approval preserves the active membership', () => {
  beforeEach(() => {
    vi.stubGlobal('localStorage', createStorage())
    vi.stubGlobal('sessionStorage', createStorage())
    resetDemoDatabase()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('leaves the current plan untouched while a renewal is pending', async () => {
    const { membershipId, endsOn } = seedMember(18)
    const before = demoUser().memberships[0]!

    const { paymentId } = await submitRenewal(PACKAGE_IDS.quarterly)

    const user = demoUser()
    const payment = user.payments.find((item) => item.id === paymentId)!
    expect(payment.status).toBe('pending')
    expect(payment.membership_id).toBeNull()

    expect(user.memberships).toHaveLength(1)
    const current = user.memberships[0]!
    expect(current.id).toBe(membershipId)
    expect(current.package_id).toBe(before.package_id)
    expect(current.starts_on).toBe(before.starts_on)
    expect(current.ends_on).toBe(endsOn)
    expect(current.status).toBe('active')
    expect(current.fine_paid_inr).toBe(25)

    const pending = await getMyPendingPayment()
    expect(pending?.id).toBe(paymentId)
    expect(pending?.package_id).toBe(PACKAGE_IDS.quarterly)

    const overview = await getMyMembershipOverview()
    expect(overview.current?.id).toBe(membershipId)
    expect(overview.current?.ends_on).toBe(endsOn)
    expect(overview.upcoming).toBeNull()
  })

  it('approves the purchased package after the current expiry without shortening access', async () => {
    const { endsOn, membershipId, reviewerId } = seedMember(18)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.quarterly)

    // A stale checkout quote must not be trusted at approval time.
    const staleDb = loadDemoDatabase()
    const stalePayment = staleDb.users[0]!.payments.find((item) => item.id === paymentId)!
    const today = todayInKolkata()
    stalePayment.quote = {
      ...(stalePayment.quote as RenewalQuote),
      starts_on: today,
      ends_on: addDaysToDate(today, 29),
      is_stacked: false,
      current_ends_on: null,
    }
    saveDemoDatabase(staleDb)

    session.userId = reviewerId
    const result = await reviewPayment(paymentId, 'approved')
    const expectedStart = addDaysToDate(endsOn, 1)
    const expectedEnd = addDaysToDate(expectedStart, 89)

    expect(result.status).toBe('approved')
    expect(result.package_name).toBe('Quarterly')
    expect(result.starts_on).toBe(expectedStart)
    expect(result.ends_on).toBe(expectedEnd)

    const user = demoUser()
    expect(user.memberships).toHaveLength(2)

    const current = user.memberships.find((item) => item.id === membershipId)!
    expect(current.ends_on).toBe(endsOn)
    expect(current.status).toBe('active')
    expect(current.fine_paid_inr).toBe(25)

    const renewal = user.memberships.find((item) => item.id === result.membership_id)!
    expect(renewal.package_id).toBe(PACKAGE_IDS.quarterly)
    expect(renewal.starts_on).toBe(expectedStart)
    expect(renewal.ends_on).toBe(expectedEnd)
    expect(renewal.price_paid_inr).toBe(3999)
    expect(renewal.fine_paid_inr).toBe(0)
    expect(renewal.status).toBe('active')

    const payment = user.payments.find((item) => item.id === paymentId)!
    expect(payment.status).toBe('approved')
    expect(payment.membership_id).toBe(renewal.id)
    expect(payment.quote?.starts_on).toBe(expectedStart)
    expect(payment.quote?.ends_on).toBe(expectedEnd)
    expect(payment.quote?.duration_days).toBe(90)
  })

  it('uses the membership state at approval time, not the checkout quote', async () => {
    const { membershipId, endsOn, reviewerId } = seedMember(18)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.monthly)

    const extendedEnd = addDaysToDate(endsOn, 10)
    const db = loadDemoDatabase()
    const current = db.users[0]!.memberships.find((item) => item.id === membershipId)!
    current.ends_on = extendedEnd
    saveDemoDatabase(db)

    session.userId = reviewerId
    const result = await reviewPayment(paymentId, 'approved')
    const expectedStart = addDaysToDate(extendedEnd, 1)

    expect(result.starts_on).toBe(expectedStart)
    expect(result.ends_on).toBe(addDaysToDate(expectedStart, 29))
    expect(demoUser().memberships.find((item) => item.id === membershipId)!.ends_on).toBe(
      extendedEnd,
    )
  })

  it('starts an expired renewal today using the purchased package', async () => {
    const { reviewerId } = seedMember(-5)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.monthly)
    const today = todayInKolkata()

    session.userId = reviewerId
    const result = await reviewPayment(paymentId, 'approved')

    expect(result.starts_on).toBe(today)
    expect(result.ends_on).toBe(addDaysToDate(today, 29))

    const user = demoUser()
    const renewal = user.memberships.find((item) => item.id === result.membership_id)!
    expect(renewal.package_id).toBe(PACKAGE_IDS.monthly)
    expect(renewal.status).toBe('active')
    expect(renewal.starts_on).toBe(today)
  })

  it('declining leaves the existing membership and fines unchanged', async () => {
    const { membershipId, endsOn, reviewerId } = seedMember(18)
    const before = structuredClone(demoUser().memberships)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.quarterly)

    session.userId = reviewerId
    const result = await reviewPayment(paymentId, 'declined', 'Could not verify at the desk')

    expect(result.status).toBe('declined')
    expect(result.membership_id).toBeNull()
    expect(result.refund_status).toBe('pending_manual_refund')

    const user = demoUser()
    expect(user.memberships).toEqual(before)
    expect(user.memberships).toHaveLength(1)
    expect(user.memberships[0]!.id).toBe(membershipId)
    expect(user.memberships[0]!.ends_on).toBe(endsOn)
    expect(user.memberships[0]!.fine_paid_inr).toBe(25)

    const payment = user.payments.find((item) => item.id === paymentId)!
    expect(payment.status).toBe('declined')
    expect(payment.membership_id).toBeNull()
    expect(payment.review_note).toBe('Could not verify at the desk')
    expect(payment.refund_status).toBe('pending_manual_refund')
  })

  it('rejects a repeated approval without activating a second plan', async () => {
    const { reviewerId } = seedMember(18)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.quarterly)

    session.userId = reviewerId
    await reviewPayment(paymentId, 'approved')
    expect(demoUser().memberships).toHaveLength(2)

    await expect(reviewPayment(paymentId, 'approved')).rejects.toMatchObject({
      code: 'PAYMENT_ALREADY_REVIEWED',
    })
    expect(demoUser().memberships).toHaveLength(2)
  })

  it('serializes two concurrent approvals so only one wins', async () => {
    const { reviewerId } = seedMember(18)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.quarterly)

    session.userId = reviewerId
    const results = await Promise.allSettled([
      reviewPayment(paymentId, 'approved'),
      reviewPayment(paymentId, 'approved'),
    ])

    expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1)
    const rejected = results.find((result) => result.status === 'rejected')
    expect(rejected).toBeDefined()
    expect((rejected as PromiseRejectedResult).reason).toMatchObject({
      code: 'PAYMENT_ALREADY_REVIEWED',
    })
    expect(demoUser().memberships).toHaveLength(2)
  })
})

describe('payment safety', () => {
  beforeEach(() => {
    vi.stubGlobal('localStorage', createStorage())
    vi.stubGlobal('sessionStorage', createStorage())
    resetDemoDatabase()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('returns the same payable order for repeated checkout requests', async () => {
    seedMember(18)

    const first = await createRenewalOrder(PACKAGE_IDS.quarterly)
    const second = await createRenewalOrder(PACKAGE_IDS.quarterly)

    expect(second.payment_id).toBe(first.payment_id)
    expect(second.order_id).toBe(first.order_id)
    expect(demoUser().payments).toHaveLength(1)
  })

  it('serializes concurrent checkout requests into one payment row', async () => {
    seedMember(18)

    const [first, second] = await Promise.all([
      createRenewalOrder(PACKAGE_IDS.quarterly),
      createRenewalOrder(PACKAGE_IDS.quarterly),
    ])

    expect(second.payment_id).toBe(first.payment_id)
    expect(second.order_id).toBe(first.order_id)
    expect(demoUser().payments).toHaveLength(1)
  })

  it('preserves a stale checkout instead of deleting it', async () => {
    seedMember(18)
    const first = await createRenewalOrder(PACKAGE_IDS.quarterly)

    const staleDb = loadDemoDatabase()
    const stale = staleDb.users[0]!.payments.find((item) => item.id === first.payment_id)!
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString()
    stale.created_at = twoHoursAgo
    stale.updated_at = twoHoursAgo
    saveDemoDatabase(staleDb)

    const second = await createRenewalOrder(PACKAGE_IDS.quarterly)

    expect(second.order_id).not.toBe(first.order_id)
    const payments = demoUser().payments
    expect(payments).toHaveLength(2)

    const preserved = payments.find((item) => item.id === first.payment_id)!
    expect(preserved.checkout_state).toBe('abandoned')
    expect(preserved.provider_payment_id).toBeNull()
    expect(preserved.failure_reason).toContain('expired')

    const fresh = payments.find((item) => item.id === second.payment_id)!
    expect(fresh.checkout_state).toBe('open')
  })

  it('keeps a reconciliation row visible to the member and admin queue', async () => {
    const { userId, reviewerId } = seedMember(18)
    const db = loadDemoDatabase()
    const reconciliation = buildReconciliationPayment(userId)
    db.users[0]!.payments.push(reconciliation)
    saveDemoDatabase(db)

    const payments = await getMyPayments()
    expect(payments.some((item) => item.id === reconciliation.id)).toBe(true)

    const pending = await getMyPendingPayment()
    expect(pending?.id).toBe(reconciliation.id)
    expect(pending?.reconciliation_required).toBe(true)

    await expect(createRenewalOrder(PACKAGE_IDS.monthly)).rejects.toMatchObject({
      code: 'PAYMENT_RECONCILIATION_REQUIRED',
    })

    session.userId = reviewerId
    const queue = await listPendingPayments()
    const row = queue.find((item) => item.payment_id === reconciliation.id)
    expect(row).toBeDefined()
    expect(row?.reconciliation_required).toBe(true)
    expect(row?.provider_payment_id).toBeNull()
  })

  it('forbids an admin from reviewing their own payment', async () => {
    const { reviewerId } = seedMember(18)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.monthly)

    await expect(reviewPayment(paymentId, 'approved')).rejects.toMatchObject({
      code: 'SELF_REVIEW_FORBIDDEN',
    })
    expect(demoUser().payments.find((item) => item.id === paymentId)!.status).toBe(
      'pending',
    )

    session.userId = reviewerId
    const result = await reviewPayment(paymentId, 'approved')
    expect(result.status).toBe('approved')
  })

  it('tracks a manual refund and rejects a repeated refund', async () => {
    const { reviewerId } = seedMember(18)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.quarterly)

    session.userId = reviewerId
    const declined = await reviewPayment(paymentId, 'declined', 'Duplicate charge')
    expect(declined.refund_status).toBe('pending_manual_refund')

    const queue = await listRefundPayments()
    expect(queue.map((item) => item.payment_id)).toContain(paymentId)

    const refunded = await markPaymentRefunded(paymentId, 'rfnd_test_001')
    expect(refunded.refund_status).toBe('refunded')

    const after = await listRefundPayments()
    expect(after.map((item) => item.payment_id)).not.toContain(paymentId)

    const payment = demoUser().payments.find((item) => item.id === paymentId)!
    expect(payment.refund_status).toBe('refunded')
    expect(payment.refund_note).toBe('rfnd_test_001')
    expect(payment.refunded_at).not.toBeNull()
    expect(payment.refunded_by).toBe(reviewerId)

    await expect(markPaymentRefunded(paymentId, 'again')).rejects.toMatchObject({
      code: 'REFUND_NOT_PENDING',
    })
  })

  it('requires a reconciliation note before reviewing a flagged payment', async () => {
    const { reviewerId } = seedMember(18)
    const { paymentId } = await submitRenewal(PACKAGE_IDS.monthly)

    const db = loadDemoDatabase()
    const payment = db.users[0]!.payments.find((item) => item.id === paymentId)!
    payment.reconciliation_required = true
    payment.checkout_state = 'reconciliation_required'
    payment.reconciliation_reason = 'Verified order paid but no payment id was returned.'
    saveDemoDatabase(db)

    session.userId = reviewerId
    await expect(reviewPayment(paymentId, 'approved')).rejects.toMatchObject({
      code: 'RECONCILIATION_NOTE_REQUIRED',
    })

    const result = await reviewPayment(
      paymentId,
      'approved',
      'Verified pay_test_123 in Razorpay.',
    )
    expect(result.status).toBe('approved')
  })

  it('preserves legacy failed, refunded, and cancelled history', () => {
    const db = createSeedDatabase()
    const user = db.users[0]!
    const base = user.payments[0]!

    function legacyPayment(id: string, status: string): Payment {
      const legacy = { ...base, id } as Record<string, unknown>
      legacy.status = status
      delete legacy.checkout_state
      delete legacy.reconciliation_required
      delete legacy.reconciliation_reason
      delete legacy.legacy_status
      delete legacy.refund_status
      delete legacy.refund_note
      delete legacy.refunded_at
      delete legacy.refunded_by
      return legacy as unknown as Payment
    }

    user.payments = [
      legacyPayment('legacy-failed', 'failed'),
      legacyPayment('legacy-refunded', 'refunded'),
      legacyPayment('legacy-cancelled', 'cancelled'),
    ]

    expect(migrateDemoDatabase(db)).toBe(true)

    const failed = user.payments.find((item) => item.id === 'legacy-failed')!
    expect(failed.status).toBe('declined')
    expect(failed.legacy_status).toBe('failed')

    const refunded = user.payments.find((item) => item.id === 'legacy-refunded')!
    expect(refunded.status).toBe('declined')
    expect(refunded.legacy_status).toBe('refunded')
    expect(refunded.refund_status).toBe('refunded')

    const cancelled = user.payments.find((item) => item.id === 'legacy-cancelled')!
    expect(cancelled.status).toBe('declined')
    expect(cancelled.legacy_status).toBe('cancelled')

    // The original status is never silently discarded.
    expect(
      user.payments.map((item) => item.legacy_status).filter(Boolean),
    ).toEqual(['failed', 'refunded', 'cancelled'])
  })

  it('maps legacy paid and created statuses without marking them as declines', () => {
    const db = createSeedDatabase()
    const user = db.users[0]!
    const base = user.payments[0]!

    const paid = { ...base, id: 'legacy-paid' } as Record<string, unknown>
    paid.status = 'paid'
    const created = { ...base, id: 'legacy-created' } as Record<string, unknown>
    created.status = 'created'
    delete created.provider_payment_id
    delete created.paid_at
    // A legacy row predates the checkout-state column entirely.
    delete created.checkout_state

    user.payments = [paid as unknown as Payment, created as unknown as Payment]

    migrateDemoDatabase(db)

    const migratedPaid = user.payments.find((item) => item.id === 'legacy-paid')!
    expect(migratedPaid.status).toBe('approved')
    expect(migratedPaid.legacy_status).toBeNull()

    const migratedCreated = user.payments.find((item) => item.id === 'legacy-created')!
    expect(migratedCreated.status).toBe('pending')
    expect(migratedCreated.legacy_status).toBeNull()
    expect(migratedCreated.checkout_state).toBe('open')
  })

  it('records a signed payment that arrives after the checkout was abandoned', async () => {
    seedMember(18)
    const order = await createRenewalOrder(PACKAGE_IDS.monthly)

    const abandonedDb = loadDemoDatabase()
    const row = abandonedDb.users[0]!.payments.find((item) => item.id === order.payment_id)!
    row.checkout_state = 'abandoned'
    row.failure_reason = 'Checkout expired before any payment was attempted.'
    saveDemoDatabase(abandonedDb)

    const verification = await verifyRenewalPayment({
      razorpay_order_id: order.order_id,
      razorpay_payment_id: 'pay_late_capture',
      razorpay_signature: 'test_signature',
    })

    expect(verification.status).toBe('reconciliation_required')
    expect(verification.provider_payment_id).toBe('pay_late_capture')

    const payment = demoUser().payments.find((item) => item.id === order.payment_id)!
    expect(payment.status).toBe('pending')
    expect(payment.checkout_state).toBe('reconciliation_required')
    expect(payment.reconciliation_required).toBe(true)
    expect(payment.provider_payment_id).toBe('pay_late_capture')
  })

  it('captures the provider payment id on an existing reconciliation row', async () => {
    seedMember(18)
    const order = await createRenewalOrder(PACKAGE_IDS.monthly)

    const db = loadDemoDatabase()
    const row = db.users[0]!.payments.find((item) => item.id === order.payment_id)!
    row.checkout_state = 'reconciliation_required'
    row.reconciliation_required = true
    row.reconciliation_reason = 'Razorpay reported the order as paid, but no payment was returned.'
    row.provider_payment_id = null
    saveDemoDatabase(db)

    const verification = await verifyRenewalPayment({
      razorpay_order_id: order.order_id,
      razorpay_payment_id: 'pay_reconciled',
      razorpay_signature: 'test_signature',
    })

    expect(verification.status).toBe('reconciliation_required')
    expect(verification.provider_payment_id).toBe('pay_reconciled')

    const payment = demoUser().payments.find((item) => item.id === order.payment_id)!
    expect(payment.reconciliation_required).toBe(true)
    expect(payment.provider_payment_id).toBe('pay_reconciled')
  })

  it('does not let a legacy pending row be silently deleted by a new checkout', async () => {
    const { userId } = seedMember(18)
    const db = loadDemoDatabase()
    const legacy = buildReconciliationPayment(userId, {
      id: 'legacy-pending-open',
      checkout_state: 'open',
      reconciliation_required: false,
      reconciliation_reason: null,
      provider_order_id: null,
      provider_payment_id: null,
      failure_reason: null,
    })
    db.users[0]!.payments.push(legacy)
    saveDemoDatabase(db)

    const order = await createRenewalOrder(PACKAGE_IDS.monthly)
    const payments = demoUser().payments

    expect(payments.some((item) => item.id === 'legacy-pending-open')).toBe(true)
    expect(payments.find((item) => item.id === order.payment_id)?.checkout_state).toBe(
      'open',
    )
  })
})
