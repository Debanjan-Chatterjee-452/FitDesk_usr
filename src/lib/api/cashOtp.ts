import type {
  CashPaymentInfo,
  CashPaymentRequestResult,
  CashPaymentState,
  Payment,
  PaymentVerification,
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
import { requireUserId } from './session'

/**
 * Cash payment flow.
 *
 * 1. The member requests cash. The server creates the pending payment and a
 *    6-digit one-time code that is valid for 300 seconds.
 * 2. The code is delivered to the gym only (admin panel + notification).
 *    The member never receives it from the app.
 * 3. After handing over the cash, the member types the code from the front
 *    desk. A valid code approves the payment, starts the plan and writes the
 *    receipt in one step.
 */

const DEMO_OTP_TTL_MS = 300_000

interface DemoOtp {
  code: string
  expiresAt: number
}

const demoOtps = new Map<string, DemoOtp>()

function demoGym(db: DemoDatabase, gymId: string | null | undefined): DemoGym | null {
  const gyms = db.gyms ?? []
  return gyms.find((gym) => gym.id === gymId) ?? gyms.find((gym) => gym.is_active) ?? null
}

function financeState(payment: Payment): CashPaymentState {
  if (payment.status === 'approved') return 'VERIFIED'
  if (payment.status === 'declined') return 'FAILED'
  if (payment.checkout_state === 'abandoned') return 'CANCELLED'
  if (payment.reconciliation_required) return 'RECONCILIATION'
  return 'AWAITING_CASH'
}

export async function requestCashPayment(
  packageId: string,
  durationDays?: number | null,
  isNewAdmission?: boolean,
): Promise<CashPaymentRequestResult> {
  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    const gym = demoGym(db, null)
    if (!gym) throw new AppError('GYM_NOT_CONFIGURED', 'Cash payment is not available for this gym.')

    let payment = user.payments.find(
      (item) => item.status === 'pending' && item.checkout_state !== 'abandoned',
    )

    if (payment && (payment.checkout_state === 'submitted' || payment.provider_payment_id)) {
      return {
        status: 'already_pending',
        payment_id: payment.id,
        amount_inr: payment.total_amount_inr,
        package_name: payment.package?.name ?? 'Membership',
        reason: 'PAYMENT_ALREADY_SUBMITTED',
      }
    }

    if (!payment) {
      const quote = calculateDemoQuote(userId, packageId, durationDays ?? null, db, isNewAdmission ?? false)
      const pkg = db.packages.find((item) => item.id === packageId)
      const now = new Date().toISOString()
      payment = {
        id: crypto.randomUUID(),
        user_id: userId,
        membership_id: null,
        package_id: packageId,
        duration_days: quote.duration_days,
        base_amount_inr: quote.base_amount,
        fine_amount_inr: quote.fine_amount,
        total_amount_inr: quote.total_amount,
        status: 'pending',
        provider: 'cash',
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
        is_new_admission: Boolean(isNewAdmission),
        created_at: now,
        updated_at: now,
        package: pkg ? { id: pkg.id, name: pkg.name, duration_days: pkg.duration_days } : null,
      }
      user.payments.push(payment)
    } else {
      payment.provider = 'cash'
      payment.payee_upi_id = null
      payment.updated_at = new Date().toISOString()
    }

    const live = demoOtps.get(payment.id)
    if (live && live.expiresAt > Date.now()) {
      saveDemoDatabase(db)
      return {
        status: 'otp_issued',
        payment_id: payment.id,
        amount_inr: payment.total_amount_inr,
        package_name: payment.package?.name ?? 'Membership',
        duration_days: payment.duration_days,
        gym_name: gym.name,
        expires_at: new Date(live.expiresAt).toISOString(),
        reused: true,
      }
    }

    const code = String(Math.floor(100000 + Math.random() * 900000))
    const expiresAt = Date.now() + DEMO_OTP_TTL_MS
    demoOtps.set(payment.id, { code, expiresAt })
    saveDemoDatabase(db)

    return {
      status: 'otp_issued',
      payment_id: payment.id,
      amount_inr: payment.total_amount_inr,
      package_name: payment.package?.name ?? 'Membership',
      duration_days: payment.duration_days,
      gym_name: gym.name,
      expires_at: new Date(expiresAt).toISOString(),
      reused: false,
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('member_request_cash_payment', {
      p_package_id: packageId,
      p_duration_days: durationDays ?? null,
      p_is_new_admission: isNewAdmission ?? false,
    })
    if (error) throw error
    if (!data) throw new Error('PAYMENT_FAILED')

    const raw = data as Record<string, unknown>
    return {
      status: (raw.status as CashPaymentRequestResult['status']) ?? 'otp_issued',
      payment_id: String(raw.payment_id),
      amount_inr: raw.amount_inr === undefined || raw.amount_inr === null ? undefined : Number(raw.amount_inr),
      package_name: (raw.package_name as string | undefined) ?? undefined,
      duration_days: raw.duration_days === undefined ? undefined : Number(raw.duration_days),
      gym_name: (raw.gym_name as string | null | undefined) ?? null,
      expires_at: (raw.expires_at as string | null | undefined) ?? null,
      reused: Boolean(raw.reused),
      reason: (raw.reason as string | null | undefined) ?? null,
    }
  } catch (error) {
    throw toAppError(error)
  }
}

export async function getCashPayment(paymentId: string): Promise<CashPaymentInfo> {
  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    const payment = user.payments.find((item) => item.id === paymentId)
    if (!payment) throw new AppError('PAYMENT_NOT_FOUND', 'We could not find that payment.')

    const gym = demoGym(db, payment.gym_id)
    const live = demoOtps.get(payment.id)
    const liveExpiry = live && live.expiresAt > Date.now() ? new Date(live.expiresAt).toISOString() : null

    return {
      payment_id: payment.id,
      payment_state: financeState(payment),
      status: payment.status,
      checkout_state: payment.checkout_state,
      payment_method: payment.provider,
      amount_inr: payment.total_amount_inr,
      package_name: payment.package?.name ?? 'Membership',
      duration_days: payment.duration_days,
      gym_name: gym?.name ?? null,
      requested_at: payment.created_at,
      otp_expires_at: liveExpiry,
      has_live_otp: Boolean(liveExpiry),
      can_rerequest_at: liveExpiry,
      starts_on: payment.quote?.starts_on ?? null,
      ends_on: payment.quote?.ends_on ?? null,
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('get_my_cash_payment', {
      p_payment_id: paymentId,
    })
    if (error) throw error
    if (!data) throw new Error('PAYMENT_NOT_FOUND')

    const raw = data as Record<string, unknown>
    return {
      payment_id: String(raw.payment_id),
      payment_state: (raw.payment_state as CashPaymentState) ?? 'AWAITING_CASH',
      status: raw.status as CashPaymentInfo['status'],
      checkout_state: raw.checkout_state as CashPaymentInfo['checkout_state'],
      payment_method: String(raw.payment_method ?? 'cash'),
      amount_inr: Number(raw.amount_inr) || 0,
      package_name: String(raw.package_name ?? 'Membership'),
      duration_days: Number(raw.duration_days) || 0,
      gym_name: (raw.gym_name as string | null) ?? null,
      requested_at: String(raw.requested_at ?? ''),
      otp_expires_at: (raw.otp_expires_at as string | null) ?? null,
      has_live_otp: Boolean(raw.has_live_otp),
      can_rerequest_at: (raw.can_rerequest_at as string | null) ?? null,
      starts_on: (raw.starts_on as string | null) ?? null,
      ends_on: (raw.ends_on as string | null) ?? null,
    }
  } catch (error) {
    throw toAppError(error)
  }
}

export async function verifyCashOtp(
  paymentId: string,
  otp: string,
): Promise<PaymentVerification> {
  const value = otp.replace(/\D/g, '').slice(0, 6)
  if (!/^\d{6}$/.test(value)) {
    throw new AppError('OTP_INVALID', 'Enter the 6-digit code from the front desk.')
  }

  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    const payment = user.payments.find((item) => item.id === paymentId)
    if (!payment) throw new AppError('PAYMENT_NOT_FOUND', 'We could not find that payment.')

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

    const live = demoOtps.get(payment.id)
    if (!live || live.code !== value) {
      throw new AppError('OTP_INVALID', 'That code is not right. Check the code from the gym and try again.')
    }
    if (live.expiresAt <= Date.now()) {
      demoOtps.delete(payment.id)
      throw new AppError('OTP_EXPIRED', 'That code has expired. Ask the gym for a new one.')
    }

    demoOtps.delete(payment.id)
    const now = new Date().toISOString()
    const startsOn = payment.quote?.starts_on ?? now.slice(0, 10)
    const endsOn = payment.quote?.ends_on ?? now.slice(0, 10)
    const membershipId = crypto.randomUUID()

    user.memberships.push({
      id: membershipId,
      user_id: userId,
      package_id: payment.package_id,
      gym_id: payment.gym_id ?? null,
      starts_on: startsOn,
      ends_on: endsOn,
      price_paid_inr: payment.base_amount_inr,
      fine_paid_inr: payment.fine_amount_inr,
      status: 'active',
      created_at: now,
      updated_at: now,
      package: payment.package ?? null,
    } as unknown as (typeof user.memberships)[number])

    payment.status = 'approved'
    payment.membership_id = membershipId
    payment.review_note = 'Verified via cash OTP.'
    payment.reviewed_at = now
    payment.updated_at = now
    saveDemoDatabase(db)

    return {
      status: 'pending_approval',
      payment_id: payment.id,
      membership_id: membershipId,
      starts_on: startsOn,
      ends_on: endsOn,
      package_name: payment.package?.name ?? 'Membership',
      total_amount_inr: payment.total_amount_inr,
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('verify_cash_otp', {
      p_payment_id: paymentId,
      p_otp: value,
    })
    if (error) throw error
    if (!data) throw new AppError('UNKNOWN', 'Verification failed.')
    return data as PaymentVerification
  } catch (error) {
    throw toAppError(error)
  }
}
