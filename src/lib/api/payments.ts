import type {
  GymPackage,
  Payment,
  PaymentOrder,
  PaymentVerification,
} from '@/types'
import { isDemo } from '@/lib/env'
import { AppError, toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import {
  calculateDemoQuote,
  loadDemoDatabase,
  saveDemoDatabase,
  type DemoUser,
} from '@/lib/demo/store'
import { requireUserId } from './session'

interface RazorpayVerifyPayload {
  razorpay_order_id: string
  razorpay_payment_id: string
  razorpay_signature: string
}

/**
 * Open checkouts (no provider payment id) are not receipts and stay hidden.
 * A row flagged for reconciliation is always visible: it may already have been
 * captured, and hiding it would lose the member's money trail.
 */
function isVisibleReceipt(payment: Payment): boolean {
  if (payment.status !== 'pending') return true
  return Boolean(
    payment.provider_payment_id ||
      payment.reconciliation_required ||
      payment.checkout_state === 'reconciliation_required',
  )
}

function newestFirst(a: Payment, b: Payment): number {
  return a.created_at < b.created_at ? 1 : -1
}

/** The member's active checkout or submitted payment, if any. */
function findActiveCheckout(payments: Payment[]): Payment | null {
  return (
    [...payments]
      .filter(
        (payment) =>
          payment.status === 'pending' && payment.checkout_state !== 'abandoned',
      )
      .sort(
        (a, b) =>
          Number(Boolean(b.reconciliation_required)) -
            Number(Boolean(a.reconciliation_required)) || newestFirst(a, b),
      )[0] ?? null
  )
}

export async function getMyPayments(): Promise<Payment[]> {
  if (isDemo) {
    const userId = await requireUserId()
    const user = loadDemoDatabase().users.find((item) => item.id === userId)
    if (!user) return []
    return user.payments.filter(isVisibleReceipt).sort(newestFirst)
  }

  try {
    const userId = await requireUserId()
    const { data, error } = await getSupabase()
      .from('payments')
      .select('*, package:packages(id,name,duration_days)')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(25)
    if (error) throw error
    return ((data ?? []) as Payment[]).filter(isVisibleReceipt)
  } catch (error) {
    throw toAppError(error)
  }
}

/** The submitted payment or reconciliation row that needs attention, if any. */
export async function getMyPendingPayment(): Promise<Payment | null> {
  if (isDemo) {
    const userId = await requireUserId()
    const user = loadDemoDatabase().users.find((item) => item.id === userId)
    if (!user) return null
    return (
      [...user.payments]
        .filter(
          (item) =>
            item.status === 'pending' &&
            (item.provider_payment_id ||
              item.reconciliation_required ||
              item.checkout_state === 'reconciliation_required'),
        )
        .sort(newestFirst)[0] ?? null
    )
  }

  try {
    const userId = await requireUserId()
    const { data, error } = await getSupabase()
      .from('payments')
      .select('*, package:packages(id,name,duration_days)')
      .eq('user_id', userId)
      .eq('status', 'pending')
      .or('provider_payment_id.not.is.null,reconciliation_required.eq.true')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle()
    if (error) throw error
    return (data as Payment | null) ?? null
  } catch (error) {
    throw toAppError(error)
  }
}

async function invokeFunction<T>(name: string, body: Record<string, unknown>): Promise<T> {
  const { data, error } = await getSupabase().functions.invoke(name, { body })
  if (error) {
    let payload: { error?: string; message?: string } | null = null
    const context = (error as { context?: unknown }).context
    if (context instanceof Response) {
      try {
        payload = (await context.clone().json()) as { error?: string; message?: string }
      } catch {
        payload = null
      }
    }
    if (payload?.error) {
      throw toAppError({
        code: payload.error,
        message: payload.message ?? payload.error,
      })
    }
    throw toAppError(payload?.message ? new Error(payload.message) : error)
  }
  if (!data) {
    throw new AppError('UNKNOWN', 'The payment service returned an empty response.')
  }
  return data as T
}

export async function createRenewalOrder(
  packageId: string,
  durationDays?: number | null,
): Promise<PaymentOrder> {
  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    const now = new Date()
    const nowIso = now.toISOString()
    const existing = findActiveCheckout(user.payments)

    if (existing) {
      if (
        existing.reconciliation_required ||
        existing.checkout_state === 'reconciliation_required'
      ) {
        throw new AppError(
          'PAYMENT_RECONCILIATION_REQUIRED',
          'A previous payment may already have been captured. The gym must reconcile it before you can start another renewal.',
        )
      }

      if (existing.provider_payment_id || existing.checkout_state === 'submitted') {
        throw new AppError(
          'RENEWAL_ALREADY_PENDING',
          'You already have a payment waiting for gym approval. Wait for that review before starting another renewal.',
        )
      }

      const samePackage = existing.package_id === packageId
      const sameDuration =
        durationDays === null ||
        durationDays === undefined ||
        existing.duration_days === durationDays
      const stale =
        now.getTime() - new Date(existing.created_at).getTime() > 30 * 60 * 1000

      if (existing.provider_order_id && !stale && samePackage && sameDuration) {
        return demoOrderFromPayment(existing, user)
      }

      if (existing.provider_order_id) {
        // No provider payment id exists, so this demo checkout was never
        // captured. Preserve the row for history instead of deleting it.
        existing.checkout_state = 'abandoned'
        existing.failure_reason = stale
          ? 'Checkout expired before any payment was attempted.'
          : 'Member chose a different plan before paying.'
        existing.updated_at = nowIso
      } else {
        // Reuse the reserved row so repeated requests never create a second
        // payment record.
        if (!samePackage || !sameDuration || !existing.quote) {
          const quote = calculateDemoQuote(userId, packageId, durationDays ?? null, db)
          const pkg = db.packages.find((item) => item.id === quote.package_id)
          existing.package_id = quote.package_id
          existing.duration_days = quote.duration_days
          existing.base_amount_inr = quote.base_amount
          existing.fine_amount_inr = quote.fine_amount
          existing.total_amount_inr = quote.total_amount
          existing.quote = quote
          existing.package = pkg
            ? { id: pkg.id, name: pkg.name, duration_days: pkg.duration_days }
            : null
        }
        existing.provider_order_id = `order_demo_${Date.now()}_${crypto
          .randomUUID()
          .slice(0, 8)}`
        existing.checkout_state = 'open'
        existing.updated_at = nowIso
        saveDemoDatabase(db)
        return demoOrderFromPayment(existing, user)
      }
    }

    const quote = calculateDemoQuote(userId, packageId, durationDays ?? null, db)
    const pkg = db.packages.find((item) => item.id === packageId) as GymPackage | undefined
    const orderId = `order_demo_${Date.now()}_${crypto.randomUUID().slice(0, 8)}`
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
      provider: 'razorpay',
      provider_order_id: orderId,
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
      created_at: nowIso,
      updated_at: nowIso,
      package: pkg
        ? { id: pkg.id, name: pkg.name, duration_days: pkg.duration_days }
        : null,
    }
    user.payments.push(payment)
    saveDemoDatabase(db)
    return demoOrderFromPayment(payment, user)
  }

  return invokeFunction<PaymentOrder>('create-renewal-order', {
    package_id: packageId,
    duration_days: durationDays ?? null,
  })
}

function demoOrderFromPayment(payment: Payment, user: DemoUser): PaymentOrder {
  const quote = payment.quote
  if (!quote || !payment.provider_order_id) {
    throw new AppError(
      'PAYMENT_FAILED',
      'This checkout is incomplete. Please start the renewal again.',
    )
  }

  return {
    payment_id: payment.id,
    order_id: payment.provider_order_id,
    amount: quote.total_amount,
    currency: 'INR',
    key_id: 'rzp_test_demo',
    quote,
    prefill: { name: user.profile.full_name ?? '', contact: user.phone },
  }
}

export async function verifyRenewalPayment(
  payload: RazorpayVerifyPayload,
): Promise<PaymentVerification> {
  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')
    const payment = user.payments.find(
      (item) => item.provider_order_id === payload.razorpay_order_id,
    )
    if (!payment) throw new AppError('PAYMENT_NOT_FOUND', 'We could not find that payment.')

    if (payment.status === 'approved' && payment.membership_id) {
      const membership = user.memberships.find((item) => item.id === payment.membership_id)
      return {
        status: 'already_approved',
        payment_id: payment.id,
        membership_id: payment.membership_id,
        starts_on: membership?.starts_on ?? null,
        ends_on: membership?.ends_on ?? null,
        package_name: payment.package?.name ?? 'Membership',
        total_amount_inr: payment.total_amount_inr,
      }
    }

    if (payment.status === 'declined') {
      throw new AppError(
        'PAYMENT_DECLINED',
        'This payment was declined by the gym. Please contact the front desk.',
      )
    }

    const quote = payment.quote
    if (!quote) throw new AppError('PAYMENT_FAILED', 'This payment has no quote.')

    const packageName =
      payment.package?.name ??
      db.packages.find((item) => item.id === payment.package_id)?.name ??
      'Membership'

    if (
      payment.reconciliation_required ||
      payment.checkout_state === 'reconciliation_required'
    ) {
      const now = new Date().toISOString()
      payment.provider_payment_id = payment.provider_payment_id ?? payload.razorpay_payment_id
      payment.paid_at = payment.paid_at ?? now
      payment.updated_at = now
      saveDemoDatabase(db)

      return {
        status: 'reconciliation_required',
        payment_id: payment.id,
        membership_id: null,
        starts_on: quote.starts_on,
        ends_on: quote.ends_on,
        package_name: packageName,
        total_amount_inr: payment.total_amount_inr,
        provider_payment_id: payment.provider_payment_id,
        provider_order_id: payment.provider_order_id,
        reconciliation_reason: payment.reconciliation_reason,
      }
    }

    if (payment.checkout_state === 'abandoned') {
      const now = new Date().toISOString()
      payment.provider_payment_id = payload.razorpay_payment_id
      payment.paid_at = now
      payment.checkout_state = 'reconciliation_required'
      payment.reconciliation_required = true
      payment.reconciliation_reason =
        'This checkout was closed before the demo payment arrived. Verify the capture before reviewing.'
      payment.updated_at = now
      saveDemoDatabase(db)

      return {
        status: 'reconciliation_required',
        payment_id: payment.id,
        membership_id: null,
        starts_on: quote.starts_on,
        ends_on: quote.ends_on,
        package_name: packageName,
        total_amount_inr: payment.total_amount_inr,
        provider_payment_id: payment.provider_payment_id,
        provider_order_id: payment.provider_order_id,
        reconciliation_reason: payment.reconciliation_reason,
      }
    }

    // Demo-only "server" step. The payment is submitted for admin review; no
    // membership is created and the expiry date does not move until approval.
    const wasSubmitted = Boolean(payment.provider_payment_id)
    if (!wasSubmitted) {
      const now = new Date().toISOString()
      payment.provider_payment_id = payload.razorpay_payment_id
      payment.paid_at = now
      payment.checkout_state = 'submitted'
      payment.reconciliation_required = false
      payment.reconciliation_reason = null
      payment.updated_at = now
      saveDemoDatabase(db)
    }

    return {
      status: wasSubmitted ? 'already_pending' : 'pending_approval',
      payment_id: payment.id,
      membership_id: null,
      starts_on: quote.starts_on,
      ends_on: quote.ends_on,
      package_name: packageName,
      total_amount_inr: payment.total_amount_inr,
    }
  }

  return invokeFunction<PaymentVerification>('verify-payment', { ...payload })
}
