import {
  assertRazorpayConfigured,
  captureRazorpayPayment,
  createRazorpayOrder,
  getRazorpayOrder,
  getRazorpayPayment,
  listRazorpayOrderPayments,
  razorpayKeyId,
  type RazorpayOrder,
  type RazorpayPayment,
} from '../_shared/razorpay.ts'
import {
  handleError,
  HttpError,
  json,
  readJson,
  requirePost,
} from '../_shared/http.ts'
import { requireUser, supabaseAdmin } from '../_shared/supabase.ts'

interface CreateOrderBody {
  package_id?: string
  duration_days?: number | null
}

interface RenewalQuote {
  package_id: string
  package_name: string
  description: string | null
  pricing_mode: 'fixed' | 'per_day'
  duration_days: number
  base_amount: number
  fine_amount: number
  total_amount: number
  days_past_expiry: number
  grace_days: number
  starts_on: string
  ends_on: string
  current_ends_on: string | null
  is_stacked: boolean
  fine_reason: string | null
  breakdown: Array<{ label: string; amount: number }>
}

interface CheckoutReservation {
  status:
    | 'reserved'
    | 'resume_checkout'
    | 'already_pending'
    | 'reconciliation_required'
  payment_id: string
  order_id?: string | null
  quote?: RenewalQuote | null
  package_name?: string | null
  created_at?: string | null
  reconciliation_reason?: string | null
}

interface ProfileRow {
  full_name: string | null
  phone: string | null
  profile_completed: boolean
}

interface CheckoutContext {
  admin: ReturnType<typeof supabaseAdmin>
  client: Awaited<ReturnType<typeof requireUser>>['client']
  userId: string
  phone: string | null
  profile: ProfileRow
  packageId: string
  durationDays: number | null
}

/** An unpaid checkout older than this is safe to abandon after inspection. */
const STALE_CHECKOUT_MS = 30 * 60 * 1000

function mapQuoteError(message: string): never {
  if (message.includes('PACKAGE_NOT_FOUND')) {
    throw new HttpError(
      400,
      'PACKAGE_NOT_FOUND',
      'This plan is no longer available. Pick another plan to continue.',
    )
  }
  if (message.includes('AUTH_REQUIRED')) {
    throw new HttpError(401, 'AUTH_REQUIRED', 'Please sign in again to continue.')
  }
  throw new HttpError(
    500,
    'QUOTE_FAILED',
    'We could not calculate this renewal. Please try again.',
  )
}

function pendingApprovalError(paymentId: string): never {
  throw new HttpError(
    409,
    'RENEWAL_ALREADY_PENDING',
    'You already have a payment waiting for gym approval. Wait for that review before starting another renewal.',
    { payment_id: paymentId },
  )
}

function reconciliationError(
  paymentId: string,
  reason: string,
  extra: Record<string, unknown> = {},
): never {
  throw new HttpError(
    409,
    'PAYMENT_RECONCILIATION_REQUIRED',
    'A previous payment may already have been captured. The gym must reconcile it before you can start another renewal. Please contact the front desk.',
    { payment_id: paymentId, reason, ...extra },
  )
}

function amountFor(reservation: CheckoutReservation): number {
  const amount = Number(reservation.quote?.total_amount)
  if (!Number.isInteger(amount) || amount <= 0) {
    throw new HttpError(
      500,
      'PAYMENT_AMOUNT_INVALID',
      'This renewal has an invalid amount. Please contact the front desk.',
      { payment_id: reservation.payment_id },
    )
  }
  return amount
}

function paymentOrderResponse(
  reservation: CheckoutReservation,
  orderId: string,
  profile: ProfileRow,
  phone: string | null,
) {
  const quote = reservation.quote
  if (!quote) {
    throw new HttpError(
      500,
      'PAYMENT_QUOTE_MISSING',
      'This checkout is missing its quote. Please contact the front desk.',
      { payment_id: reservation.payment_id },
    )
  }

  return {
    payment_id: reservation.payment_id,
    order_id: orderId,
    amount: Number(quote.total_amount),
    currency: 'INR',
    key_id: razorpayKeyId(),
    quote,
    prefill: {
      name: profile.full_name ?? '',
      contact: profile.phone ?? phone ?? '',
    },
  }
}

async function reserveCheckout(
  context: CheckoutContext,
): Promise<CheckoutReservation> {
  const { data, error } = await context.client.rpc('reserve_renewal_checkout', {
    p_package_id: context.packageId,
    p_duration_days: context.durationDays,
  })

  if (error) {
    console.error('[fitdesk] checkout reservation failed', error)
    mapQuoteError(error.message ?? '')
  }
  if (!data) {
    throw new HttpError(
      500,
      'QUOTE_FAILED',
      'We could not calculate this renewal. Please try again.',
    )
  }

  return data as CheckoutReservation
}

async function recordReconciliation(
  context: CheckoutContext,
  paymentId: string,
  orderId: string,
  amountInr: number,
  providerPaymentId: string,
  reason: string,
): Promise<void> {
  try {
    const { error } = await context.admin.rpc('record_captured_payment', {
      p_payment_id: paymentId,
      p_provider_payment_id: providerPaymentId,
      p_provider_order_id: orderId,
      p_paid_amount_inr: amountInr,
      p_failure_reason: reason,
    })
    if (error) {
      console.error('[fitdesk] reconciliation recording failed', error)
    }
  } catch (error) {
    console.error('[fitdesk] reconciliation recording threw', error)
  }
}

async function flagReconciliation(
  context: CheckoutContext,
  paymentId: string,
  orderId: string,
  reason: string,
): Promise<never> {
  try {
    const { error } = await context.admin.rpc('flag_checkout_reconciliation', {
      p_payment_id: paymentId,
      p_provider_order_id: orderId,
      p_reason: reason,
    })
    if (error) {
      console.error('[fitdesk] reconciliation flag failed', error)
    }
  } catch (error) {
    console.error('[fitdesk] reconciliation flag threw', error)
  }

  reconciliationError(paymentId, reason, { provider_order_id: orderId })
}

async function abandonCheckout(
  context: CheckoutContext,
  paymentId: string,
  reason: string,
): Promise<void> {
  const { error } = await context.admin.rpc('abandon_checkout', {
    p_payment_id: paymentId,
    p_reason: reason,
  })
  if (error) {
    console.error('[fitdesk] safe checkout abandonment failed', error)
    throw new HttpError(
      503,
      'PAYMENT_GATEWAY_UNAVAILABLE',
      'We could not safely restart this checkout. Please try again in a moment.',
      { payment_id: paymentId },
    )
  }
}

async function submitCapturedPayment(
  context: CheckoutContext,
  paymentId: string,
  orderId: string,
  amountInr: number,
  providerPaymentId: string,
): Promise<never> {
  const { data: submission, error } = await context.admin.rpc(
    'submit_membership_payment',
    {
      p_payment_id: paymentId,
      p_provider_payment_id: providerPaymentId,
      p_paid_amount_inr: amountInr,
      p_provider_order_id: orderId,
    },
  )

  if (!error && submission) {
    pendingApprovalError(paymentId)
  }

  const message = error?.message ?? 'Payment submission failed.'
  if (message.includes('PAYMENT_DECLINED')) {
    throw new HttpError(
      409,
      'PAYMENT_DECLINED',
      'This payment was declined by the gym. Please contact the front desk.',
      { payment_id: paymentId },
    )
  }

  await recordReconciliation(
    context,
    paymentId,
    orderId,
    amountInr,
    providerPaymentId,
    `The gateway payment was captured but the database submission failed: ${message}`,
  )
  reconciliationError(paymentId, message, {
    provider_payment_id: providerPaymentId,
    provider_order_id: orderId,
  })
}

async function handleCapturedGatewayPayment(
  context: CheckoutContext,
  paymentId: string,
  orderId: string,
  amountInr: number,
  payments: RazorpayPayment[],
): Promise<never> {
  const captured = payments.find(
    (payment) => payment.status === 'captured' || payment.captured,
  )
  const authorized = payments.find((payment) => payment.status === 'authorized')
  const candidate = captured ?? authorized

  if (!candidate) {
    // Callers only invoke this helper when a captured/authorized payment exists.
    throw new HttpError(
      409,
      'PAYMENT_NOT_CAPTURED',
      'The payment has not been captured yet. Please try again.',
      { payment_id: paymentId, provider_order_id: orderId },
    )
  }

  if (payments.length > 1) {
    await recordReconciliation(
      context,
      paymentId,
      orderId,
      amountInr,
      candidate.id,
      `Razorpay returned ${payments.length} payments for this order; the captured payment is ambiguous.`,
    )
    reconciliationError(paymentId, 'Multiple gateway payments exist for this order.', {
      provider_payment_id: candidate.id,
      provider_order_id: orderId,
    })
  }

  if (candidate.currency !== 'INR' || candidate.amount !== amountInr * 100) {
    await recordReconciliation(
      context,
      paymentId,
      orderId,
      amountInr,
      candidate.id,
      `The gateway amount (${candidate.amount} ${candidate.currency}) does not match the quoted total (${amountInr} INR).`,
    )
    reconciliationError(paymentId, 'Captured amount does not match the quote.', {
      provider_payment_id: candidate.id,
      provider_order_id: orderId,
    })
  }

  let finalPayment = candidate
  if (candidate.status === 'authorized') {
    try {
      finalPayment = await captureRazorpayPayment({
        paymentId: candidate.id,
        amountInr,
      })
    } catch (captureError) {
      console.error('[fitdesk] capture retry failed', captureError)
      // A concurrent request may have captured it. Re-read before flagging.
      try {
        const refreshed = await getRazorpayPayment(candidate.id)
        if (refreshed.status === 'captured') {
          finalPayment = refreshed
        } else {
          throw captureError
        }
      } catch {
        await recordReconciliation(
          context,
          paymentId,
          orderId,
          amountInr,
          candidate.id,
          'The gateway authorized the payment but the capture request failed.',
        )
        reconciliationError(paymentId, 'Capture request failed.', {
          provider_payment_id: candidate.id,
          provider_order_id: orderId,
        })
      }
    }
  }

  if (finalPayment.status !== 'captured') {
    await recordReconciliation(
      context,
      paymentId,
      orderId,
      amountInr,
      finalPayment.id,
      `The gateway payment status is ${finalPayment.status}, not captured.`,
    )
    reconciliationError(paymentId, 'Gateway payment is not captured.', {
      provider_payment_id: finalPayment.id,
      provider_order_id: orderId,
    })
  }

  await submitCapturedPayment(
    context,
    paymentId,
    orderId,
    amountInr,
    finalPayment.id,
  )
}

async function inspectOrder(
  orderId: string,
): Promise<{ order: RazorpayOrder; payments: RazorpayPayment[] } | 'missing'> {
  try {
    const order = await getRazorpayOrder(orderId)
    const collection = await listRazorpayOrderPayments(orderId)
    return { order, payments: collection.items ?? [] }
  } catch (error) {
    if (error instanceof HttpError && error.status === 404) {
      return 'missing'
    }
    throw error
  }
}

async function handleResumeCheckout(
  context: CheckoutContext,
  reservation: CheckoutReservation,
  allowStaleCleanup: boolean,
): Promise<Response> {
  const paymentId = reservation.payment_id
  const amountInr = amountFor(reservation)

  if (!reservation.order_id) {
    // The row was reserved but no gateway order was attached yet. Reuse the
    // same row so a repeated request cannot create a second payment record.
    return startCheckout(context, reservation)
  }

  let inspection: Awaited<ReturnType<typeof inspectOrder>>
  try {
    inspection = await inspectOrder(reservation.order_id)
  } catch (error) {
    console.error('[fitdesk] checkout inspection failed', error)
    throw new HttpError(
      503,
      'PAYMENT_GATEWAY_UNAVAILABLE',
      'We could not check the previous payment attempt. Please try again in a moment.',
      { payment_id: paymentId, provider_order_id: reservation.order_id },
    )
  }

  if (inspection === 'missing') {
    if (!allowStaleCleanup) {
      throw new HttpError(
        503,
        'PAYMENT_GATEWAY_UNAVAILABLE',
        'We could not check the previous payment attempt. Please try again in a moment.',
        { payment_id: paymentId, provider_order_id: reservation.order_id },
      )
    }
    await abandonCheckout(
      context,
      paymentId,
      'Razorpay no longer recognises this order; no payment can be attached to it.',
    )
    const fresh = await reserveCheckout(context)
    return handleReservation(context, fresh, false)
  }

  const hasCapturedOrAuthorized = inspection.payments.some(
    (payment) => payment.status === 'captured' || payment.captured || payment.status === 'authorized',
  )

  if (hasCapturedOrAuthorized) {
    return handleCapturedGatewayPayment(
      context,
      paymentId,
      reservation.order_id,
      amountInr,
      inspection.payments,
    )
  }

  if (inspection.order.status === 'paid') {
    // Razorpay says the order was paid but no payment is visible yet. Preserve
    // the order and require a manual check instead of deleting or declining it.
    return flagReconciliation(
      context,
      paymentId,
      reservation.order_id,
      'Razorpay reports this order as paid, but no payment was returned. The payment may not be visible yet.',
    )
  }

  const createdAt = reservation.created_at
    ? new Date(reservation.created_at).getTime()
    : 0
  const stale = createdAt > 0 && Date.now() - createdAt > STALE_CHECKOUT_MS

  if (
    allowStaleCleanup &&
    stale &&
    inspection.order.status === 'created'
  ) {
    await abandonCheckout(
      context,
      paymentId,
      'Checkout expired before any payment was attempted.',
    )
    const fresh = await reserveCheckout(context)
    return handleReservation(context, fresh, false)
  }

  // Resume the same gateway order. Returning the existing order is what makes
  // repeated checkout requests idempotent.
  return json(
    paymentOrderResponse(
      reservation,
      reservation.order_id,
      context.profile,
      context.phone,
    ),
  )
}

async function startCheckout(
  context: CheckoutContext,
  reservation: CheckoutReservation,
): Promise<Response> {
  const amountInr = amountFor(reservation)
  const quote = reservation.quote
  if (!quote) {
    throw new HttpError(
      500,
      'PAYMENT_QUOTE_MISSING',
      'This checkout is missing its quote. Please contact the front desk.',
      { payment_id: reservation.payment_id },
    )
  }

  const receipt = `FD-${Date.now().toString(36).toUpperCase()}-${crypto
    .randomUUID()
    .slice(0, 8)
    .toUpperCase()}`

  const order = await createRazorpayOrder({
    amountInr,
    receipt,
    notes: {
      user_id: context.userId,
      package_id: quote.package_id,
      duration_days: String(quote.duration_days),
      source: 'fitdesk_member_app',
    },
  })

  const { error: attachError } = await context.admin.rpc('attach_checkout_order', {
    p_payment_id: reservation.payment_id,
    p_provider_order_id: order.id,
  })

  if (attachError) {
    console.error('[fitdesk] order attachment failed', attachError)

    // If a concurrent request attached a different order first, return that
    // order instead of handing out a second independently payable order.
    const { data: row } = await context.admin
      .from('payments')
      .select('id, status, checkout_state, provider_order_id, quote')
      .eq('id', reservation.payment_id)
      .maybeSingle()

    if (
      row?.provider_order_id &&
      row.status === 'pending' &&
      row.checkout_state === 'open'
    ) {
      return json(
        paymentOrderResponse(
          {
            ...reservation,
            order_id: row.provider_order_id,
            quote: (row.quote as RenewalQuote | null) ?? reservation.quote,
          },
          row.provider_order_id,
          context.profile,
          context.phone,
        ),
      )
    }

    throw new HttpError(
      500,
      'PAYMENT_CREATE_FAILED',
      'We could not start this payment. Please try again.',
      { payment_id: reservation.payment_id, provider_order_id: order.id },
    )
  }

  return json(
    paymentOrderResponse(reservation, order.id, context.profile, context.phone),
  )
}

async function handleReservation(
  context: CheckoutContext,
  reservation: CheckoutReservation,
  allowStaleCleanup: boolean,
): Promise<Response> {
  if (reservation.status === 'reconciliation_required') {
    reconciliationError(
      reservation.payment_id,
      reservation.reconciliation_reason ??
        'A previous payment may have been captured.',
      { provider_order_id: reservation.order_id ?? null },
    )
  }

  if (reservation.status === 'already_pending') {
    pendingApprovalError(reservation.payment_id)
  }

  if (reservation.status === 'resume_checkout') {
    return handleResumeCheckout(context, reservation, allowStaleCleanup)
  }

  return startCheckout(context, reservation)
}

Deno.serve(async (request) => {
  const early = requirePost(request)
  if (early) return early

  try {
    const { user, client } = await requireUser(request)
    const body = await readJson<CreateOrderBody>(request)

    if (!body.package_id || typeof body.package_id !== 'string') {
      throw new HttpError(400, 'INVALID_REQUEST', 'Choose a plan before paying.')
    }

    const durationDays =
      typeof body.duration_days === 'number' && Number.isFinite(body.duration_days)
        ? Math.trunc(body.duration_days)
        : null

    assertRazorpayConfigured()

    const admin = supabaseAdmin()

    const { data: profile, error: profileError } = await admin
      .from('profiles')
      .select('full_name, phone, profile_completed')
      .eq('id', user.id)
      .maybeSingle()

    if (profileError) {
      console.error('[fitdesk] profile lookup failed', profileError)
      throw new HttpError(500, 'PROFILE_LOOKUP_FAILED', 'We could not load your profile.')
    }
    if (!profile?.profile_completed) {
      throw new HttpError(
        403,
        'PROFILE_INCOMPLETE',
        'Finish your member profile before renewing.',
      )
    }

    const context: CheckoutContext = {
      admin,
      client,
      userId: user.id,
      phone: user.phone ?? null,
      profile: profile as ProfileRow,
      packageId: body.package_id,
      durationDays,
    }

    // Reservation is serialized per member inside Postgres. It returns the
    // member's existing active checkout instead of creating another one.
    const reservation = await reserveCheckout(context)
    return await handleReservation(context, reservation, true)
  } catch (error) {
    return handleError(error)
  }
})
