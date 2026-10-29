import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AppError } from '@/lib/errors'
import {
  DEMO_GYM_ID,
  PACKAGE_IDS,
  createSeedDatabase,
  loadDemoDatabase,
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
  getUpiPaymentInstructions,
  reserveUpiCheckout,
  submitUpiReference,
} from './upi'

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

function seed(): DemoDatabase {
  const db = createSeedDatabase()
  db.users[0]!.payments = []
  saveDemoDatabase(db)
  session.userId = db.users[0]!.id
  return db
}

async function expectAppError(promise: Promise<unknown>, code: string) {
  await expect(promise).rejects.toBeInstanceOf(AppError)
  await expect(promise).rejects.toMatchObject({ code })
}

describe('demo direct-UPI flow', () => {
  beforeEach(() => {
    vi.stubGlobal('localStorage', createStorage())
    vi.stubGlobal('sessionStorage', createStorage())
    resetDemoDatabase()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('reserves from the server-side quote and never from the browser', async () => {
    seed()

    const reservation = await reserveUpiCheckout(PACKAGE_IDS.monthly)
    expect(reservation.status).toBe('reserved')
    expect(reservation.amount_inr).toBe(1499)
    expect(reservation.gym_id).toBe(DEMO_GYM_ID)

    // A second attempt resumes the same row instead of creating another one.
    const again = await reserveUpiCheckout(PACKAGE_IDS.quarterly)
    expect(again.status).toBe('resume_checkout')
    expect(again.payment_id).toBe(reservation.payment_id)
    expect(again.amount_inr).toBe(1499)

    expect(loadDemoDatabase().users[0]!.payments).toHaveLength(1)
  })

  it('exposes the demo gym payee without a real PSP handle', async () => {
    seed()
    const { payment_id } = await reserveUpiCheckout(PACKAGE_IDS.monthly)

    const instructions = await getUpiPaymentInstructions(payment_id)
    expect(instructions.amount_inr).toBe(1499)
    expect(instructions.payee).toMatchObject({
      available: true,
      upi_id: 'fitdesk@demo',
      reason: null,
    })
    expect(instructions.payment_state).toBe('NOT_STARTED')
    expect(instructions.reference).toMatch(/^FD[A-Z0-9]{12}$/)
  })

  it('blocks payment when the gym has no UPI ID yet', async () => {
    const db = seed()
    db.gyms = db.gyms!.map((gym) => ({ ...gym, upi_id: null }))
    saveDemoDatabase(db)

    const { payment_id } = await reserveUpiCheckout(PACKAGE_IDS.monthly)
    const instructions = await getUpiPaymentInstructions(payment_id)

    expect(instructions.payee).toEqual({
      available: false,
      reason: 'NOT_CONFIGURED',
      upi_id: null,
      name: null,
      qr_path: null,
      qr_bucket: null,
    })

    await expectAppError(
      submitUpiReference(payment_id, '123456789012'),
      'PAYMENT_NOT_CONFIGURED',
    )
  })

  it('records the claimed reference but leaves the payment pending', async () => {
    seed()
    const { payment_id } = await reserveUpiCheckout(PACKAGE_IDS.monthly)

    const result = await submitUpiReference(payment_id, ' utr-1234 5678 ')
    expect(result.status).toBe('pending_approval')
    expect(result.total_amount_inr).toBe(1499)

    const payment = loadDemoDatabase().users[0]!.payments[0]!
    expect(payment.status).toBe('pending')
    expect(payment.checkout_state).toBe('submitted')
    expect(payment.provider).toBe('upi')
    expect(payment.provider_payment_id).toBe('UTR12345678')
    expect(payment.upi_reference).toBe('UTR12345678')
    expect(payment.payee_upi_id).toBe('fitdesk@demo')
    expect(payment.paid_at).toBeNull()

    const after = await getUpiPaymentInstructions(payment_id)
    expect(after.payment_state).toBe('PENDING_VERIFICATION')
    expect(after.upi_reference).toBe('UTR12345678')
  })

  it('is idempotent for the same reference and refuses a different one', async () => {
    seed()
    const { payment_id } = await reserveUpiCheckout(PACKAGE_IDS.monthly)
    await submitUpiReference(payment_id, 'UTR12345678')

    expect((await submitUpiReference(payment_id, 'UTR12345678')).status).toBe('already_pending')

    await expectAppError(
      submitUpiReference(payment_id, '999999999999'),
      'PAYMENT_ORDER_MISMATCH',
    )
  })

  it('validates the reference before touching the store', async () => {
    seed()
    const { payment_id } = await reserveUpiCheckout(PACKAGE_IDS.monthly)

    await expectAppError(submitUpiReference(payment_id, 'abc'), 'INVALID_UPI_REFERENCE')
    await expectAppError(
      submitUpiReference(payment_id, '1234/5678'),
      'INVALID_UPI_REFERENCE',
    )

    expect(loadDemoDatabase().users[0]!.payments[0]!.provider_payment_id).toBeNull()
  })

  it("cannot read another member's payment", async () => {
    const db = seed()
    const { payment_id } = await reserveUpiCheckout(PACKAGE_IDS.monthly)

    const owner = db.users[0]!
    const outsiderId = crypto.randomUUID()
    db.users.push({
      ...owner,
      id: outsiderId,
      email: 'outsider@fitdesk.demo',
      profile: { ...owner.profile, id: outsiderId, email: 'outsider@fitdesk.demo' },
      memberships: [],
      attendance: [],
      payments: [],
    })
    saveDemoDatabase(db)

    session.userId = outsiderId
    await expectAppError(getUpiPaymentInstructions(payment_id), 'PAYMENT_NOT_FOUND')
    await expectAppError(
      submitUpiReference(payment_id, '123456789012'),
      'PAYMENT_NOT_FOUND',
    )
  })

  it('reports a submitted checkout as already pending when the flow reopens', async () => {
    seed()
    const { payment_id } = await reserveUpiCheckout(PACKAGE_IDS.monthly)
    await submitUpiReference(payment_id, 'UTR12345678')

    const again = await reserveUpiCheckout(PACKAGE_IDS.monthly)
    expect(again.status).toBe('already_pending')
    expect(again.payment_id).toBe(payment_id)
    expect(again.amount_inr).toBe(1499)
  })

  it('keeps a submitted payment out of the create path even if the plan changes', async () => {
    seed()
    const { payment_id } = await reserveUpiCheckout(PACKAGE_IDS.monthly)
    await submitUpiReference(payment_id, 'UTR12345678')

    const other = await reserveUpiCheckout(PACKAGE_IDS.annual)
    expect(other.status).toBe('already_pending')
    expect(other.payment_id).toBe(payment_id)
    expect(loadDemoDatabase().users[0]!.payments).toHaveLength(1)
  })
})
