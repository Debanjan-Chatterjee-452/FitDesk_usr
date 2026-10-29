import {
  assertRazorpayConfigured,
  captureRazorpayPayment,
  getRazorpayPayment,
  verifyRazorpaySignature,
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

interface VerifyBody {
  razorpay_order_id?: string
  razorpay_payment_id?: string
  razorpay_signature?: string
}

interface PaymentRow {
  id: string
  user_id: string
  membership_id: string | null
  package_id: string
  duration_days: number
  total_amount_inr: number
  status: string
  provider_order_id: string | null
  provider_payment_id: string | null
  quote: { starts_on?: string | null; ends_on?: string | null } | null
  checkout_state: string | null
  reconciliation_required: boolean
  reconciliation_reason: string | null
}

interface SubmitResult {
  status: 'pending_approval' | 'already_pending' | 'already_approved'
  payment_id: string
  membership_id: string | null
  starts_on: string | null
  ends_on: string | null
  package_name: string
  total_amount_inr: number
}

interface VerificationResult extends SubmitResult {
  provider_payment_id?: string | null
  provider_order_id?: string | null
  reconciliation_reason?: string | null
}

interface BeginVerificationResult {
  status:
    | 'verifying'
    | 'already_submitted'
    | 'not_pending'
    | 'reconciliation_required'
  payment_id: string
  payment_status?: string
  provider_payment_id?: string | null
  reconciliation_reason?: string | null
}

async function packageName(
  admin: ReturnType<typeof supabaseAdmin>,
  packageId: string,
): Promise<string> {
  const { data } = await admin
    .from('packages')
    .select('name')
    .eq('id', packageId)
    .maybeSingle()
  return data?.name ?? 'Membership'
}

async function alreadyApprovedResult(
  admin: ReturnType<typeof supabaseAdmin>,
  payment: PaymentRow,
): Promise<SubmitResult> {
  if (!payment.membership_id) {
    throw new HttpError(
      409,
      'PAYMENT_INCONSISTENT',
      'This payment is marked approved but has no membership. Contact the front desk.',
    )
  }

  const [{ data: membership }, name] = await Promise.all([
    admin
      .from('memberships')
      .select('starts_on, ends_on')
      .eq('id', payment.membership_id)
      .maybeSingle(),
    packageName(admin, payment.package_id),
  ])

  if (!membership) {
    throw new HttpError(
      409,
      'PAYMENT_INCONSISTENT',
      'This payment is marked approved but its membership is missing. Contact the front desk.',
    )
  }

  return {
    status: 'already_approved',
    payment_id: payment.id,
    membership_id: payment.membership_id,
    starts_on: membership.starts_on,
    ends_on: membership.ends_on,
    package_name: name,
    total_amount_inr: payment.total_amount_inr,
  }
}

function mapSubmitError(message: string): never {
  if (message.includes('PAYMENT_NOT_FOUND')) {
    throw new HttpError(404, 'PAYMENT_NOT_FOUND', 'We could not find that payment.')
  }
  if (message.includes('PAYMENT_DECLINED')) {
    throw new HttpError(
      409,
      'PAYMENT_DECLINED',
      'This payment was declined by the gym. Please contact the front desk.',
    )
  }
  if (message.includes('PAYMENT_ALREADY_REVIEWED')) {
    throw new HttpError(
      409,
      'PAYMENT_ALREADY_REVIEWED',
      'This payment has already been reviewed. Refresh to see the latest status.',
    )
  }
  if (message.includes('PAYMENT_NOT_PAYABLE')) {
    throw new HttpError(
      409,
      'PAYMENT_NOT_PAYABLE',
      'This payment can no longer be submitted. Please start a new renewal.',
    )
  }
  if (message.includes('PAYMENT_QUOTE_MISMATCH')) {
    throw new HttpError(
      409,
      'PAYMENT_QUOTE_MISMATCH',
      'The renewal quote changed before submission. Please contact the front desk with your receipt.',
    )
  }
  if (message.includes('PAYMENT_AMOUNT_MISMATCH')) {
    throw new HttpError(
      409,
      'PAYMENT_AMOUNT_MISMATCH',
      'The captured amount did not match the renewal total. Please contact the front desk.',
    )
  }
  if (message.includes('PAYMENT_ORDER_MISMATCH')) {
    throw new HttpError(
      409,
      'PAYMENT_ORDER_MISMATCH',
      'The payment order did not match. Please contact the front desk.',
    )
  }
  if (message.includes('PAYMENT_QUOTE_MISSING') || message.includes('PAYMENT_INCONSISTENT')) {
    throw new HttpError(
      409,
      'PAYMENT_INCONSISTENT',
      'This payment record is incomplete. Please contact the front desk.',
    )
  }
  if (
    message.includes('payments_one_active_checkout_per_user') ||
    message.includes('payments_one_pending_review_per_user') ||
    message.includes('duplicate key value')
  ) {
    throw new HttpError(
      409,
      'RENEWAL_ALREADY_PENDING',
      'You already have a payment waiting for gym approval. Wait for that review before starting another renewal.',
    )
  }

  console.error('[fitdesk] payment submission failed', message)
  throw new HttpError(
    409,
    'PAYMENT_FAILED',
    'We verified the payment but could not submit it for approval. Please contact the front desk.',
  )
}

async function buildReconciliationResult(
  admin: ReturnType<typeof supabaseAdmin>,
  payment: PaymentRow,
  providerPaymentId: string | null,
  reason: string,
): Promise<VerificationResult> {
  return {
    status: 'reconciliation_required',
    payment_id: payment.id,
    membership_id: null,
    starts_on: payment.quote?.starts_on ?? null,
    ends_on: payment.quote?.ends_on ?? null,
    package_name: await packageName(admin, payment.package_id),
    total_amount_inr: payment.total_amount_inr,
    provider_payment_id: providerPaymentId ?? payment.provider_payment_id,
    provider_order_id: payment.provider_order_id,
    reconciliation_reason: reason,
  }
}

/**
 * Persist a captured/possibly-captured gateway payment before returning. If
 * the write fails, surface the provider ids in the error so they are not lost.
 */
async function recordReconciliationOrFail(
  admin: ReturnType<typeof supabaseAdmin>,
  payment: PaymentRow,
  providerPaymentId: string,
  reason: string,
): Promise<VerificationResult> {
  const { error } = await admin.rpc('record_captured_payment', {
    p_payment_id: payment.id,
    p_provider_payment_id: providerPaymentId,
    p_provider_order_id: payment.provider_order_id,
    p_paid_amount_inr: payment.total_amount_inr,
    p_failure_reason: reason,
  })

  if (error) {
    console.error('[fitdesk] captured payment recording failed', error)
    throw new HttpError(
      500,
      'PAYMENT_RECONCILIATION_FAILED',
      'The payment was captured but we could not save the reconciliation record. Contact the front desk with this payment id.',
      {
        payment_id: payment.id,
        provider_payment_id: providerPaymentId,
        provider_order_id: payment.provider_order_id,
        reason,
      },
    )
  }

  return buildReconciliationResult(admin, payment, providerPaymentId, reason)
}

async function loadPayment(
  admin: ReturnType<typeof supabaseAdmin>,
  paymentId: string,
): Promise<PaymentRow | null> {
  const { data } = await admin
    .from('payments')
    .select(
      'id, user_id, membership_id, package_id, duration_days, total_amount_inr, status, provider_order_id, provider_payment_id, quote, checkout_state, reconciliation_required, reconciliation_reason',
    )
    .eq('id', paymentId)
    .maybeSingle()
  return (data as PaymentRow | null) ?? null
}

Deno.serve(async (request) => {
  const early = requirePost(request)
  if (early) return early

  try {
    const { user } = await requireUser(request)
    const body = await readJson<VerifyBody>(request)

    const orderId = body.razorpay_order_id?.trim()
    const paymentId = body.razorpay_payment_id?.trim()
    const signature = body.razorpay_signature?.trim()

    if (!orderId || !paymentId || !signature) {
      throw new HttpError(
        400,
        'INVALID_REQUEST',
        'The payment response is incomplete. Please try again.',
      )
    }

    assertRazorpayConfigured()

    const admin = supabaseAdmin()
    const { data: paymentData, error: paymentError } = await admin
      .from('payments')
      .select(
        'id, user_id, membership_id, package_id, duration_days, total_amount_inr, status, provider_order_id, provider_payment_id, quote, checkout_state, reconciliation_required, reconciliation_reason',
      )
      .eq('provider_order_id', orderId)
      .eq('user_id', user.id)
      .maybeSingle()

    if (paymentError) {
      console.error('[fitdesk] payment lookup failed', paymentError)
      throw new HttpError(
        500,
        'PAYMENT_LOOKUP_FAILED',
        'We could not load that payment. Please try again.',
      )
    }
    if (!paymentData) {
      throw new HttpError(404, 'PAYMENT_NOT_FOUND', 'We could not find that payment.')
    }

    let payment = paymentData as PaymentRow

    if (payment.status === 'approved') {
      return json(await alreadyApprovedResult(admin, payment))
    }

    if (payment.status === 'declined') {
      throw new HttpError(
        409,
        'PAYMENT_DECLINED',
        'This payment was declined by the gym. Please contact the front desk.',
      )
    }

    if (payment.status !== 'pending') {
      throw new HttpError(
        409,
        'PAYMENT_NOT_PAYABLE',
        'This payment can no longer be submitted. Please start a new renewal.',
      )
    }

    if (payment.provider_order_id !== orderId) {
      throw new HttpError(
        400,
        'PAYMENT_ORDER_MISMATCH',
        'The payment order did not match. Please try again.',
      )
    }

    const signatureOk = await verifyRazorpaySignature({
      orderId,
      paymentId,
      signature,
    })
    if (!signatureOk) {
      throw new HttpError(
        400,
        'PAYMENT_SIGNATURE_INVALID',
        "We could not verify this payment's signature. No plan was activated.",
      )
    }

    // A reconciliation row may still be missing its provider payment id. The
    // signature is valid, so persist the id (and the reconciliation flag) rather
    // than losing the only reference to the member's money.
    if (payment.reconciliation_required) {
      return json(
        await recordReconciliationOrFail(
          admin,
          payment,
          paymentId,
          payment.reconciliation_reason ??
            'This payment may already have been captured and needs manual reconciliation.',
        ),
      )
    }

    // The checkout may have been closed (stale or superseded) before this signed
    // payment arrived. Record it for reconciliation instead of rejecting it.
    if (payment.checkout_state === 'abandoned') {
      return json(
        await recordReconciliationOrFail(
          admin,
          payment,
          paymentId,
          'This checkout was closed before the signed payment arrived. The member may have paid from another tab; verify the capture in Razorpay.',
        ),
      )
    }

    // Mark the checkout as verifying before any capture attempt. A crash after
    // this point leaves a visible in-progress record rather than hiding it.
    const { data: beginData, error: beginError } = await admin.rpc(
      'begin_payment_verification',
      { p_payment_id: payment.id },
    )
    if (beginError) {
      console.error('[fitdesk] verification start failed', beginError)

      if ((beginError.message ?? '').includes('PAYMENT_NOT_VERIFIABLE')) {
        // The row was closed between the read above and this call. The signed
        // payment is still real, so preserve it for manual reconciliation.
        return json(
          await recordReconciliationOrFail(
            admin,
            payment,
            paymentId,
            'This checkout was closed before verification completed. Verify the capture in Razorpay.',
          ),
        )
      }

      throw new HttpError(
        500,
        'PAYMENT_VERIFICATION_FAILED',
        'We could not start payment verification. Please try again.',
        { payment_id: payment.id, provider_order_id: orderId },
      )
    }

    const begin = beginData as BeginVerificationResult
    if (begin.status === 'reconciliation_required') {
      return json(
        await buildReconciliationResult(
          admin,
          payment,
          payment.provider_payment_id,
          begin.reconciliation_reason ??
            'This payment needs manual reconciliation before it can be reviewed.',
        ),
      )
    }
    if (begin.status === 'already_submitted') {
      const refreshed = await loadPayment(admin, payment.id)
      if (refreshed) payment = refreshed
    }
    if (begin.status === 'not_pending') {
      const refreshed = await loadPayment(admin, payment.id)
      if (!refreshed) {
        throw new HttpError(404, 'PAYMENT_NOT_FOUND', 'We could not find that payment.')
      }
      if (refreshed.status === 'approved') {
        return json(await alreadyApprovedResult(admin, refreshed))
      }
      if (refreshed.status === 'declined') {
        throw new HttpError(
          409,
          'PAYMENT_DECLINED',
          'This payment was declined by the gym. Please contact the front desk.',
        )
      }
    }

    let razorpayPayment: RazorpayPayment = await getRazorpayPayment(paymentId)

    if (
      razorpayPayment.order_id !== orderId ||
      razorpayPayment.currency !== 'INR' ||
      razorpayPayment.amount !== payment.total_amount_inr * 100
    ) {
      // The gateway record itself does not match the quote. Record it so the
      // ids survive even though this payment cannot be auto-submitted.
      return json(
        await recordReconciliationOrFail(
          admin,
          payment,
          razorpayPayment.id,
          `The gateway payment does not match this order or the quoted total. Status: ${razorpayPayment.status}.`,
        ),
      )
    }

    // Razorpay normally auto-captures (payment_capture: 1 on the order).
    // If the account is configured for manual capture, capture it now.
    if (razorpayPayment.status === 'authorized') {
      try {
        razorpayPayment = await captureRazorpayPayment({
          paymentId,
          amountInr: payment.total_amount_inr,
        })
      } catch (captureError) {
        console.error('[fitdesk] capture request failed', captureError)
        // A concurrent verification may have captured it. Re-read first.
        try {
          const refreshed = await getRazorpayPayment(paymentId)
          if (refreshed.status === 'captured') {
            razorpayPayment = refreshed
          } else {
            throw captureError
          }
        } catch {
          return json(
            await recordReconciliationOrFail(
              admin,
              payment,
              paymentId,
              'Razorpay authorized the payment but the capture request failed.',
            ),
          )
        }
      }
    }

    if (razorpayPayment.status !== 'captured') {
      if (razorpayPayment.status === 'authorized') {
        return json(
          await recordReconciliationOrFail(
            admin,
            payment,
            paymentId,
            'Razorpay authorized the payment but it is not captured.',
          ),
        )
      }

      throw new HttpError(
        409,
        'PAYMENT_NOT_CAPTURED',
        'The payment has not been captured yet. Please wait a moment and try again.',
        {
          payment_id: payment.id,
          provider_payment_id: paymentId,
          provider_order_id: orderId,
        },
      )
    }

    // The gateway payment is verified and captured. Record it as submitted for
    // manual admin review. Membership activation only happens in
    // admin_review_payment() after an Admin-role user approves it.
    const { data: submission, error: submissionError } = await admin.rpc(
      'submit_membership_payment',
      {
        p_payment_id: payment.id,
        p_provider_payment_id: paymentId,
        p_paid_amount_inr: payment.total_amount_inr,
        p_provider_order_id: orderId,
      },
    )

    if (submissionError) {
      const message = submissionError.message ?? ''

      if (message.includes('PAYMENT_DECLINED')) {
        mapSubmitError(message)
      }

      if (message.includes('PAYMENT_ALREADY_REVIEWED')) {
        const refreshed = await loadPayment(admin, payment.id)
        if (refreshed?.status === 'approved') {
          return json(await alreadyApprovedResult(admin, refreshed))
        }
        if (refreshed?.status === 'declined') {
          throw new HttpError(
            409,
            'PAYMENT_DECLINED',
            'This payment was declined by the gym. Please contact the front desk.',
          )
        }
      }

      // The capture succeeded, so never report this as a plain failure. Persist
      // the payment id and return a reconciliation result.
      return json(
        await recordReconciliationOrFail(
          admin,
          payment,
          paymentId,
          `The gateway payment was captured but the database submission failed: ${message}`,
        ),
      )
    }

    if (!submission) {
      return json(
        await recordReconciliationOrFail(
          admin,
          payment,
          paymentId,
          'The gateway payment was captured but the database submission returned no result.',
        ),
      )
    }

    return json(submission as SubmitResult)
  } catch (error) {
    return handleError(error)
  }
})
