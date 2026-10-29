import type {
  Payment,
  PaymentVerification,
  RenewalQuote,
  UpiCheckoutReservation,
  UpiPayee,
  UpiPaymentInstructions,
  UpiPaymentState,
} from '@/types'
import { isDemo } from '@/lib/env'
import { AppError, toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import {
  calculateDemoQuote,
  loadDemoDatabase,
  saveDemoDatabase,
  type DemoDatabase,
  type DemoGym,
} from '@/lib/demo/store'
import {
  isValidUpiReference,
  normalizeUpiReference,
  resolveUpiPayee,
  type ResolvedUpiPayee,
} from '@/lib/upi/upi'
import { requireUserId } from './session'

/**
 * Direct-UPI payment API.
 *
 * The browser only ever sends a package id, a duration, a payment id and the
 * transaction reference the member typed. Amounts, the recipient UPI ID and
 * the gym are resolved server-side by the `reserve_upi_checkout` and
 * `get_my_upi_payment` RPCs.
 */

function demoGym(db: DemoDatabase, gymId: string | null | undefined): DemoGym | null {
  const gyms = db.gyms ?? []
  return gyms.find((gym) => gym.id === gymId) ?? gyms.find((gym) => gym.is_active) ?? null
}

function demoState(payment: Payment): UpiPaymentState {
  if (payment.status === 'approved') return 'VERIFIED'
  if (payment.status === 'declined') return 'FAILED'
  if (payment.checkout_state === 'abandoned') return 'CANCELLED'
  if (payment.checkout_state === 'submitted' || payment.provider_payment_id) {
    return 'PENDING_VERIFICATION'
  }
  return 'NOT_STARTED'
}

/** Same derivation the database uses, so demo and production behave alike. */
export function buildUpiReference(paymentId: string): string {
  return `FD${paymentId.replace(/-/g, '').slice(0, 12).toUpperCase()}`
}

/**
 * Refuses to hand the UI a payee it cannot trust: a missing/invalid UPI ID or
 * an unusable amount makes the payee unavailable instead of being "fixed" by
 * substituting something else.
 */
function normalizePayee(raw: Partial<UpiPayee> | null | undefined, amountInr: number): UpiPayee {
  return resolveUpiPayee(raw, amountInr)
}

function normalizeInstructions(raw: Record<string, unknown>): UpiPaymentInstructions {
  const amount = Number(raw.amount_inr)
  const payee: ResolvedUpiPayee = resolveUpiPayee(
    raw.payee as Parameters<typeof resolveUpiPayee>[0],
    amount,
  )
  return {
    payment_id: String(raw.payment_id),
    payment_state: (raw.payment_state as UpiPaymentState) ?? 'NOT_STARTED',
    status: raw.status as Payment['status'],
    checkout_state: raw.checkout_state as Payment['checkout_state'],
    payment_method: String(raw.payment_method ?? 'upi'),
    amount_inr: Number.isFinite(amount) ? amount : 0,
    currency: 'INR',
    reference: String(raw.reference ?? ''),
    gym_id: (raw.gym_id as string | null) ?? null,
    gym_name: String(raw.gym_name ?? 'this gym'),
    package_name: String(raw.package_name ?? 'Membership'),
    duration_days: Number(raw.duration_days) || 0,
    starts_on: (raw.starts_on as string | null) ?? null,
    ends_on: (raw.ends_on as string | null) ?? null,
    upi_reference: (raw.upi_reference as string | null) ?? null,
    submitted_at: (raw.submitted_at as string | null) ?? null,
    payee,
  }
}

export async function reserveUpiCheckout(
  packageId: string,
  durationDays?: number | null,
): Promise<UpiCheckoutReservation> {
  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    const gym = demoGym(db, null)
    if (!gym) throw new AppError('GYM_NOT_CONFIGURED', 'Payment is not available for this gym yet.')

    const existing = user.payments.find(
      (item) => item.status === 'pending' && item.checkout_state !== 'abandoned',
    )

    if (existing) {
      if (existing.reconciliation_required) {
        return {
          status: 'reconciliation_required',
          payment_id: existing.id,
          quote: existing.quote,
          reconciliation_reason: existing.reconciliation_reason,
        }
      }
      if (existing.checkout_state === 'submitted' || existing.provider_payment_id) {
        return {
          status: 'already_pending',
          payment_id: existing.id,
          quote: existing.quote,
          upi_reference: existing.upi_reference ?? existing.provider_payment_id,
          amount_inr: existing.total_amount_inr,
        }
      }
      return {
        status: 'resume_checkout',
        payment_id: existing.id,
        quote: existing.quote,
        package_name: existing.quote?.package_name,
        amount_inr: existing.total_amount_inr,
        gym_id: existing.gym_id ?? gym.id,
      }
    }

    const quote = calculateDemoQuote(userId, packageId, durationDays ?? null, db)
    const pkg = db.packages.find((item) => item.id === packageId)
    const now = new Date().toISOString()
    const payment: Payment = {
      id: crypto.randomUUID(),
      user_id: userId,
      membership_id: null,
      package_id: packageId,
      duration_days: quote.duration_days,
      base_amount_inr: quote.base_amount,
      fine_amount_inr: quote.fine_amount,
      total_amount_inr: quote.total_amount,
      status: 'pending',
      provider: 'upi',
      provider_order_id: null,
      provider_payment_id: null,
      failure_reason: null,
      quote,
      paid_at: null,
      reviewed_at: null,
      reviewed_by: null,
      review_note: null,
      checkout_state: 'open',
      reconciliation_required: false,
      reconciliation_reason: null,
      legacy_status: null,
      refund_status: 'not_required',
      refund_note: null,
      refunded_at: null,
      refunded_by: null,
      gym_id: gym.id,
      upi_reference: null,
      upi_submitted_at: null,
      payee_upi_id: null,
      created_at: now,
      updated_at: now,
      package: pkg ? { id: pkg.id, name: pkg.name, duration_days: pkg.duration_days } : null,
    }
    user.payments.push(payment)
    saveDemoDatabase(db)

    return {
      status: 'reserved',
      payment_id: payment.id,
      quote,
      package_name: quote.package_name,
      amount_inr: payment.total_amount_inr,
      gym_id: gym.id,
      created_at: payment.created_at,
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('reserve_upi_checkout', {
      p_package_id: packageId,
      p_duration_days: durationDays ?? null,
    })
    if (error) throw error
    if (!data) throw new Error('PAYMENT_FAILED')

    const raw = data as Record<string, unknown>
    const status = raw.status as UpiCheckoutReservation['status']
    return {
      status,
      payment_id: String(raw.payment_id),
      quote: (raw.quote as RenewalQuote | null) ?? null,
      package_name: (raw.package_name as string | undefined) ?? undefined,
      amount_inr:
        raw.amount_inr === undefined || raw.amount_inr === null
          ? undefined
          : Number(raw.amount_inr),
      gym_id: (raw.gym_id as string | undefined) ?? undefined,
      upi_reference: (raw.upi_reference as string | null) ?? null,
      reconciliation_reason: (raw.reconciliation_reason as string | null) ?? null,
      created_at: (raw.created_at as string | undefined) ?? undefined,
    }
  } catch (error) {
    throw toAppError(error)
  }
}

export async function getUpiPaymentInstructions(
  paymentId: string,
): Promise<UpiPaymentInstructions> {
  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    const payment = user.payments.find((item) => item.id === paymentId)
    if (!payment) throw new AppError('PAYMENT_NOT_FOUND', 'We could not find that payment.')

    const gym = demoGym(db, payment.gym_id)
    const amount = payment.total_amount_inr
    const payee = normalizePayee(
      gym && gym.is_active
        ? {
            available: true,
            reason: null,
            upi_id: gym.upi_id,
            name: gym.upi_payee_name ?? gym.name,
            qr_path: gym.payment_qr_path,
            qr_bucket: 'gym-payment-qr',
          }
        : { available: false, reason: 'NOT_CONFIGURED' },
      amount,
    )

    return {
      payment_id: payment.id,
      payment_state: demoState(payment),
      status: payment.status,
      checkout_state: payment.checkout_state,
      payment_method: payment.provider,
      amount_inr: amount,
      currency: 'INR',
      reference: buildUpiReference(payment.id),
      gym_id: payment.gym_id ?? gym?.id ?? null,
      gym_name: gym?.name ?? 'this gym',
      package_name:
        payment.package?.name ?? db.packages.find((item) => item.id === payment.package_id)?.name ?? 'Membership',
      duration_days: payment.duration_days,
      starts_on: payment.quote?.starts_on ?? null,
      ends_on: payment.quote?.ends_on ?? null,
      upi_reference: payment.upi_reference ?? null,
      submitted_at: payment.upi_submitted_at ?? null,
      payee,
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('get_my_upi_payment', {
      p_payment_id: paymentId,
    })
    if (error) throw error
    if (!data) throw new Error('PAYMENT_NOT_FOUND')
    return normalizeInstructions(data as Record<string, unknown>)
  } catch (error) {
    throw toAppError(error)
  }
}

export async function submitUpiReference(
  paymentId: string,
  reference: string,
): Promise<PaymentVerification> {
  const normalized = normalizeUpiReference(reference)
  if (!isValidUpiReference(normalized)) {
    throw new AppError(
      'INVALID_UPI_REFERENCE',
      'Enter the 12-digit UPI reference (UTR) from your payment app. It is 6–40 letters or digits.',
    )
  }

  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    const payment = user.payments.find((item) => item.id === paymentId)
    if (!payment) throw new AppError('PAYMENT_NOT_FOUND', 'We could not find that payment.')

    const gym = demoGym(db, payment.gym_id)
    if (!gym || !gym.is_active || !gym.upi_id) {
      throw new AppError('PAYMENT_NOT_CONFIGURED', 'Payment is not available for this gym yet.')
    }

    if (payment.status === 'approved') {
      return {
        status: 'already_approved',
        payment_id: payment.id,
        membership_id: payment.membership_id,
        starts_on: payment.quote?.starts_on ?? null,
        ends_on: payment.quote?.ends_on ?? null,
        package_name: payment.package?.name ?? 'Membership',
        total_amount_inr: payment.total_amount_inr,
      }
    }
    if (payment.status === 'declined') {
      throw new AppError('PAYMENT_DECLINED', 'This payment was declined by the gym.')
    }

    if (payment.provider_payment_id) {
      if (payment.provider_payment_id === normalized) {
        return {
          status: 'already_pending',
          payment_id: payment.id,
          membership_id: null,
          starts_on: payment.quote?.starts_on ?? null,
          ends_on: payment.quote?.ends_on ?? null,
          package_name: payment.package?.name ?? 'Membership',
          total_amount_inr: payment.total_amount_inr,
        }
      }
      throw new AppError(
        'PAYMENT_ORDER_MISMATCH',
        'A different reference is already recorded for this payment. Contact the front desk.',
      )
    }

    const now = new Date().toISOString()
    payment.provider = 'upi'
    payment.provider_payment_id = normalized
    payment.upi_reference = normalized
    payment.upi_submitted_at = now
    payment.payee_upi_id = gym.upi_id
    payment.checkout_state = 'submitted'
    payment.updated_at = now
    saveDemoDatabase(db)

    return {
      status: 'pending_approval',
      payment_id: payment.id,
      membership_id: null,
      starts_on: payment.quote?.starts_on ?? null,
      ends_on: payment.quote?.ends_on ?? null,
      package_name: payment.package?.name ?? 'Membership',
      total_amount_inr: payment.total_amount_inr,
      provider_payment_id: normalized,
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('submit_upi_payment_reference', {
      p_payment_id: paymentId,
      p_reference: normalized,
    })
    if (error) throw error
    if (!data) throw new Error('PAYMENT_FAILED')
    return data as PaymentVerification
  } catch (error) {
    throw toAppError(error)
  }
}
