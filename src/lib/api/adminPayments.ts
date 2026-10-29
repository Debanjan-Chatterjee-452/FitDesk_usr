import type {
  AdminPaymentRow,
  AdminRefundRow,
  Membership,
  Payment,
  PaymentReviewResult,
  RefundResult,
  RenewalQuote,
} from '@/types'
import { isDemo } from '@/lib/env'
import { AppError, toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { todayInKolkata } from '@/lib/kolkata'
import {
  resolveApprovedMembershipPeriod,
  type ApprovedMembershipPeriod,
} from '@/lib/membershipPeriod'
import { loadDemoDatabase, saveDemoDatabase } from '@/lib/demo/store'
import { requireUserId } from './session'

function findDemoPayment(
  payments: Array<{ payment: Payment; userId: string }>,
  paymentId: string,
): { payment: Payment; userId: string } | null {
  return payments.find((item) => item.payment.id === paymentId) ?? null
}

function flattenDemoPayments() {
  const db = loadDemoDatabase()
  return {
    db,
    payments: db.users.flatMap((user) =>
      user.payments.map((payment) => ({ payment, userId: user.id })),
    ),
  }
}

function asNumber(value: unknown): number {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

function quoteDates(quote: RenewalQuote | null): {
  starts_on: string | null
  ends_on: string | null
} {
  return {
    starts_on: quote?.starts_on ?? null,
    ends_on: quote?.ends_on ?? null,
  }
}

/**
 * Pending payments waiting for an Admin-role decision. The production query is
 * a SECURITY DEFINER RPC because payments reference auth.users, not profiles.
 */
export async function listPendingPayments(): Promise<AdminPaymentRow[]> {
  if (isDemo) {
    const userId = await requireUserId()
    const { db, payments } = flattenDemoPayments()
    const me = db.users.find((item) => item.id === userId)
    if (!me?.profile.is_admin) {
      throw new AppError('ADMIN_REQUIRED', 'You do not have permission to review payments.')
    }

    return payments
      .filter(
        ({ payment }) =>
          payment.status === 'pending' &&
          (Boolean(payment.provider_payment_id) ||
            payment.reconciliation_required ||
            payment.checkout_state === 'reconciliation_required'),
      )
      .map(({ payment, userId: memberId }) => {
        const member = db.users.find((item) => item.id === memberId)
        const pkg = db.packages.find((item) => item.id === payment.package_id)
        return {
          payment_id: payment.id,
          user_id: memberId,
          member_name: member?.profile.full_name ?? 'FitDesk member',
          member_email: member?.email ?? null,
          member_phone: member?.profile.phone || member?.phone || null,
          package_name: pkg?.name ?? payment.package?.name ?? 'Membership',
          duration_days: payment.duration_days,
          base_amount_inr: payment.base_amount_inr,
          fine_amount_inr: payment.fine_amount_inr,
          total_amount_inr: payment.total_amount_inr,
          status: payment.status,
          provider_order_id: payment.provider_order_id,
          provider_payment_id: payment.provider_payment_id,
          failure_reason: payment.failure_reason,
          quote: payment.quote,
          created_at: payment.created_at,
          paid_at: payment.paid_at,
          reviewed_at: payment.reviewed_at,
          reviewed_by: payment.reviewed_by,
          checkout_state: payment.checkout_state,
          reconciliation_required: payment.reconciliation_required,
          reconciliation_reason: payment.reconciliation_reason,
          legacy_status: payment.legacy_status,
          refund_status: payment.refund_status,
          refund_note: payment.refund_note,
          refunded_at: payment.refunded_at,
          refunded_by: payment.refunded_by,
        } satisfies AdminPaymentRow
      })
      .sort((a, b) =>
        (a.paid_at ?? a.created_at) < (b.paid_at ?? b.created_at) ? -1 : 1,
      )
  }

  try {
    const { data, error } = await getSupabase().rpc('admin_list_pending_payments')
    if (error) throw error
    return ((data ?? []) as AdminPaymentRow[]).map((row) => ({
      ...row,
      duration_days: asNumber(row.duration_days),
      base_amount_inr: asNumber(row.base_amount_inr),
      fine_amount_inr: asNumber(row.fine_amount_inr),
      total_amount_inr: asNumber(row.total_amount_inr),
      quote: (row.quote as RenewalQuote | null) ?? null,
    }))
  } catch (error) {
    throw toAppError(error)
  }
}

/** Approve or decline a pending payment. Decisions are irreversible. */
export async function reviewPayment(
  paymentId: string,
  decision: 'approved' | 'declined',
  note?: string | null,
): Promise<PaymentReviewResult> {
  if (isDemo) {
    const adminId = await requireUserId()
    const { db, payments } = flattenDemoPayments()
    const admin = db.users.find((item) => item.id === adminId)
    if (!admin?.profile.is_admin) {
      throw new AppError('ADMIN_REQUIRED', 'You do not have permission to review payments.')
    }

    const found = findDemoPayment(payments, paymentId)
    if (!found) {
      throw new AppError('PAYMENT_NOT_FOUND', 'We could not find that payment.')
    }

    const { payment } = found
    if (payment.status !== 'pending') {
      throw new AppError(
        'PAYMENT_ALREADY_REVIEWED',
        'This payment has already been reviewed. This action cannot be undone.',
      )
    }
    if (payment.membership_id) {
      throw new AppError(
        'PAYMENT_FAILED',
        'This payment record is inconsistent. Please contact the front desk.',
      )
    }
    if (payment.user_id === adminId) {
      throw new AppError(
        'SELF_REVIEW_FORBIDDEN',
        'You cannot approve or decline your own payment. Ask another admin to review it.',
      )
    }

    const trimmedNote = note?.trim() || null
    if (payment.reconciliation_required && !trimmedNote) {
      throw new AppError(
        'RECONCILIATION_NOTE_REQUIRED',
        'Add a note explaining the Razorpay reconciliation before reviewing this payment.',
      )
    }
    if (!payment.provider_payment_id) {
      throw new AppError(
        'PAYMENT_NOT_SUBMITTED',
        'This payment has not been submitted yet. Complete the checkout first.',
      )
    }

    const member = db.users.find((item) => item.id === payment.user_id)
    if (!member) {
      throw new AppError('PAYMENT_NOT_FOUND', 'We could not find the member for this payment.')
    }

    const pkg = db.packages.find((item) => item.id === payment.package_id)
    const now = new Date().toISOString()

    if (decision === 'declined') {
      payment.status = 'declined'
      payment.failure_reason = trimmedNote ?? 'Payment declined by the gym.'
      payment.review_note = trimmedNote
      payment.reviewed_at = now
      payment.reviewed_by = adminId
      payment.checkout_state = 'abandoned'
      payment.reconciliation_required = false
      payment.reconciliation_reason = null
      payment.refund_status = payment.provider_payment_id
        ? 'pending_manual_refund'
        : 'not_required'
      payment.refund_note = payment.provider_payment_id
        ? (trimmedNote ?? 'Captured payment declined. Manual refund required.')
        : null
      payment.refunded_at = null
      payment.refunded_by = null
      payment.updated_at = now
      saveDemoDatabase(db)

      return {
        status: 'declined',
        payment_id: payment.id,
        membership_id: null,
        ...quoteDates(payment.quote),
        package_name: pkg?.name ?? payment.package?.name ?? 'Membership',
        total_amount_inr: payment.total_amount_inr,
        refund_status: payment.refund_status,
      }
    }

    const quote = payment.quote
    if (!quote) {
      throw new AppError(
        'PAYMENT_FAILED',
        'This payment record is incomplete. Please contact the front desk.',
      )
    }

    if (
      quote.package_id !== payment.package_id ||
      quote.duration_days !== payment.duration_days ||
      quote.base_amount !== payment.base_amount_inr ||
      quote.fine_amount !== payment.fine_amount_inr ||
      quote.total_amount !== payment.total_amount_inr
    ) {
      throw new AppError(
        'PAYMENT_FAILED',
        'This payment does not match its quoted package. Please contact the front desk.',
      )
    }

    // The checkout quote's dates are only a request. Recalculate the applied
    // period from the member's latest plan so a still-valid membership keeps
    // every remaining day and is never shortened.
    let period: ApprovedMembershipPeriod
    try {
      period = resolveApprovedMembershipPeriod(member.memberships, payment.duration_days)
    } catch {
      throw new AppError(
        'PAYMENT_FAILED',
        'This payment has an invalid duration. Please contact the front desk.',
      )
    }

    const today = todayInKolkata()
    member.memberships = member.memberships.map((membership) =>
      membership.status === 'active' && membership.ends_on < today
        ? { ...membership, status: 'expired', updated_at: now }
        : membership,
    )

    const membership: Membership = {
      id: crypto.randomUUID(),
      user_id: member.id,
      package_id: payment.package_id,
      starts_on: period.starts_on,
      ends_on: period.ends_on,
      price_paid_inr: payment.base_amount_inr,
      fine_paid_inr: payment.fine_amount_inr,
      status: 'active',
      created_at: now,
      updated_at: now,
      package: pkg ?? null,
    }

    member.memberships.push(membership)
    payment.status = 'approved'
    payment.membership_id = membership.id
    payment.quote = {
      ...quote,
      starts_on: period.starts_on,
      ends_on: period.ends_on,
      is_stacked: period.is_stacked,
      current_ends_on: period.current_ends_on,
    }
    payment.failure_reason = null
    payment.review_note = trimmedNote
    payment.reviewed_at = now
    payment.reviewed_by = adminId
    payment.checkout_state = 'submitted'
    payment.reconciliation_required = false
    payment.reconciliation_reason = null
    payment.refund_status = 'not_required'
    payment.refund_note = null
    payment.refunded_at = null
    payment.refunded_by = null
    payment.updated_at = now
    saveDemoDatabase(db)

    return {
      status: 'approved',
      payment_id: payment.id,
      membership_id: membership.id,
      starts_on: membership.starts_on,
      ends_on: membership.ends_on,
      package_name: pkg?.name ?? payment.package?.name ?? 'Membership',
      total_amount_inr: payment.total_amount_inr,
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('admin_review_payment', {
      p_payment_id: paymentId,
      p_decision: decision,
      p_note: note ?? null,
    })
    if (error) throw error
    if (!data) {
      throw new AppError('PAYMENT_FAILED', 'The review did not return a result. Please retry.')
    }

    const row = data as Record<string, unknown>
    return {
      status: row.status === 'declined' ? 'declined' : 'approved',
      payment_id: String(row.payment_id ?? paymentId),
      membership_id: (row.membership_id as string | null) ?? null,
      starts_on: (row.starts_on as string | null) ?? null,
      ends_on: (row.ends_on as string | null) ?? null,
      package_name: String(row.package_name ?? 'Membership'),
      total_amount_inr: asNumber(row.total_amount_inr),
      refund_status:
        (row.refund_status as PaymentReviewResult['refund_status']) ?? null,
    }
  } catch (error) {
    throw toAppError(error)
  }
}

/**
 * Declined payments with a captured gateway payment id that still need a
 * manual refund. FitDesk never calls a live refund API.
 */
export async function listRefundPayments(): Promise<AdminRefundRow[]> {
  if (isDemo) {
    const userId = await requireUserId()
    const { db, payments } = flattenDemoPayments()
    const me = db.users.find((item) => item.id === userId)
    if (!me?.profile.is_admin) {
      throw new AppError('ADMIN_REQUIRED', 'You do not have permission to review payments.')
    }

    return payments
      .filter(
        ({ payment }) =>
          payment.status === 'declined' &&
          payment.refund_status === 'pending_manual_refund',
      )
      .map(({ payment, userId: memberId }) => {
        const member = db.users.find((item) => item.id === memberId)
        const pkg = db.packages.find((item) => item.id === payment.package_id)
        return {
          payment_id: payment.id,
          user_id: memberId,
          member_name: member?.profile.full_name ?? 'FitDesk member',
          member_email: member?.email ?? null,
          member_phone: member?.profile.phone || member?.phone || null,
          package_name: pkg?.name ?? payment.package?.name ?? 'Membership',
          total_amount_inr: payment.total_amount_inr,
          provider_payment_id: payment.provider_payment_id,
          review_note: payment.review_note ?? null,
          refund_status: payment.refund_status,
          refund_note: payment.refund_note,
          reviewed_at: payment.reviewed_at,
          refunded_at: payment.refunded_at,
          refunded_by: payment.refunded_by,
          created_at: payment.created_at,
        } satisfies AdminRefundRow
      })
      .sort((a, b) => (a.created_at < b.created_at ? -1 : 1))
  }

  try {
    const { data, error } = await getSupabase().rpc('admin_list_refund_payments')
    if (error) throw error
    return ((data ?? []) as AdminRefundRow[]).map((row) => ({
      ...row,
      total_amount_inr: asNumber(row.total_amount_inr),
    }))
  } catch (error) {
    throw toAppError(error)
  }
}

/** Records that the gym completed a refund outside FitDesk. */
export async function markPaymentRefunded(
  paymentId: string,
  note?: string | null,
): Promise<RefundResult> {
  if (isDemo) {
    const adminId = await requireUserId()
    const { db, payments } = flattenDemoPayments()
    const admin = db.users.find((item) => item.id === adminId)
    if (!admin?.profile.is_admin) {
      throw new AppError('ADMIN_REQUIRED', 'You do not have permission to track refunds.')
    }

    const found = findDemoPayment(payments, paymentId)
    if (!found) {
      throw new AppError('PAYMENT_NOT_FOUND', 'We could not find that payment.')
    }

    const { payment } = found
    if (payment.status !== 'declined') {
      throw new AppError(
        'PAYMENT_NOT_DECLINED',
        'Only a declined payment can be marked as refunded.',
      )
    }
    if (!payment.provider_payment_id) {
      throw new AppError(
        'PAYMENT_NOT_CAPTURED',
        'No captured gateway payment is recorded for this row. Verify it in Razorpay before tracking a refund.',
      )
    }
    if (payment.refund_status !== 'pending_manual_refund') {
      throw new AppError(
        'REFUND_NOT_PENDING',
        'This payment is not waiting for a manual refund.',
      )
    }

    const trimmedNote = note?.trim() || null
    const now = new Date().toISOString()
    payment.refund_status = 'refunded'
    payment.refund_note = trimmedNote ?? payment.refund_note ?? 'Manual refund recorded.'
    payment.refunded_at = now
    payment.refunded_by = adminId
    payment.updated_at = now
    saveDemoDatabase(db)

    return {
      status: 'refunded',
      payment_id: payment.id,
      refund_status: 'refunded',
    }
  }

  try {
    const { data, error } = await getSupabase().rpc(
      'admin_mark_payment_refunded',
      {
        p_payment_id: paymentId,
        p_note: note ?? null,
      },
    )
    if (error) throw error
    if (!data) {
      throw new AppError('PAYMENT_FAILED', 'The refund update returned no result. Please retry.')
    }

    const row = data as Record<string, unknown>
    return {
      status: 'refunded',
      payment_id: String(row.payment_id ?? paymentId),
      refund_status: (row.refund_status as RefundResult['refund_status']) ?? 'refunded',
    }
  } catch (error) {
    throw toAppError(error)
  }
}
