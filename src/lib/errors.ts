export type ErrorCode =
  | 'AUTH_REQUIRED'
  | 'INVALID_CREDENTIALS'
  | 'EMAIL_NOT_CONFIRMED'
  | 'EMAIL_LINK_INVALID'
  | 'PHONE_NOT_CONFIRMED'
  | 'OTP_INVALID'
  | 'OTP_EXPIRED'
  | 'RATE_LIMITED'
  | 'USER_EXISTS'
  | 'WEAK_PASSWORD'
  | 'NETWORK'
  | 'DUPLICATE_CHECKIN'
  | 'INVALID_QR'
  | 'MEMBERSHIP_INACTIVE'
  | 'GYM_CLOSED'
  | 'PACKAGE_NOT_FOUND'
  | 'PAYMENT_NOT_FOUND'
  | 'PAYMENT_NOT_CONFIGURED'
  | 'GYM_NOT_CONFIGURED'
  | 'INVALID_UPI_REFERENCE'
  | 'REFERENCE_ALREADY_USED'
  | 'PAYMENT_FAILED'
  | 'PAYMENT_CANCELLED'
  | 'PAYMENT_DECLINED'
  | 'PAYMENT_NOT_SUBMITTED'
  | 'PAYMENT_ALREADY_REVIEWED'
  | 'RENEWAL_ALREADY_PENDING'
  | 'PAYMENT_ORDER_MISMATCH'
  | 'PAYMENT_QUOTE_MISMATCH'
  | 'PAYMENT_AMOUNT_MISMATCH'
  | 'PAYMENT_QUOTE_MISSING'
  | 'PAYMENT_RECONCILIATION_REQUIRED'
  | 'PAYMENT_RECONCILIATION_FAILED'
  | 'ADMIN_REQUIRED'
  | 'SELF_REVIEW_FORBIDDEN'
  | 'INVALID_REVIEW_DECISION'
  | 'RECONCILIATION_NOTE_REQUIRED'
  | 'PAYMENT_NOT_DECLINED'
  | 'PAYMENT_NOT_CAPTURED'
  | 'REFUND_NOT_PENDING'
  | 'PROFILE_INCOMPLETE'
  | 'PROFILE_FIELD_NOT_EDITABLE'
  | 'PROFILE_SAVE_BLOCKED'
  | 'STORAGE_BLOCKED'
  | 'UNKNOWN'

export class AppError extends Error {
  code: ErrorCode
  details?: unknown

  constructor(code: ErrorCode, message: string, details?: unknown) {
    super(message)
    this.name = 'AppError'
    this.code = code
    this.details = details
  }
}

const RPC_MESSAGES: Record<string, { code: ErrorCode; message: string }> = {
  DUPLICATE_CHECKIN: {
    code: 'DUPLICATE_CHECKIN',
    message: 'You have already checked in today. One scan per day is enough.',
  },
  INVALID_QR: {
    code: 'INVALID_QR',
    message: "That doesn't look like a FitDesk gym code. Try scanning the code at the front desk.",
  },
  MEMBERSHIP_INACTIVE: {
    code: 'MEMBERSHIP_INACTIVE',
    message: 'Your membership is not active. Renew your plan to check in.',
  },
  GYM_CLOSED: {
    code: 'GYM_CLOSED',
    message: 'The gym is closed today. Check the home screen for announcements.',
  },
  AUTH_REQUIRED: {
    code: 'AUTH_REQUIRED',
    message: 'Please sign in again to continue.',
  },
  PACKAGE_NOT_FOUND: {
    code: 'PACKAGE_NOT_FOUND',
    message: 'This plan is no longer available. Pick another plan to continue.',
  },
  PAYMENT_NOT_FOUND: {
    code: 'PAYMENT_NOT_FOUND',
    message: 'We could not find that payment. Please start the renewal again.',
  },
  PAYMENT_NOT_CONFIGURED: {
    code: 'PAYMENT_NOT_CONFIGURED',
    message: 'Payment is not available for this gym yet. Please pay at the front desk.',
  },
  GYM_NOT_CONFIGURED: {
    code: 'GYM_NOT_CONFIGURED',
    message: 'Payment is not available for this gym yet. Please pay at the front desk.',
  },
  INVALID_UPI_REFERENCE: {
    code: 'INVALID_UPI_REFERENCE',
    message:
      'Enter the UPI reference (UTR) from your payment app. It is 6–40 letters or digits.',
  },
  REFERENCE_ALREADY_USED: {
    code: 'REFERENCE_ALREADY_USED',
    message:
      'That UPI reference is already recorded against another payment. Check the reference and try again, or contact the front desk.',
  },
  PAYMENT_DECLINED: {
    code: 'PAYMENT_DECLINED',
    message: 'This payment was declined by the gym. Please contact the front desk.',
  },
  PAYMENT_NOT_SUBMITTED: {
    code: 'PAYMENT_NOT_SUBMITTED',
    message: 'This payment has not been submitted yet. Complete the checkout first.',
  },
  PAYMENT_ALREADY_REVIEWED: {
    code: 'PAYMENT_ALREADY_REVIEWED',
    message: 'This payment has already been reviewed. This action cannot be undone.',
  },
  RENEWAL_ALREADY_PENDING: {
    code: 'RENEWAL_ALREADY_PENDING',
    message:
      'You already have a payment waiting for gym approval. Wait for that review before starting another renewal.',
  },
  PAYMENT_RECONCILIATION_REQUIRED: {
    code: 'PAYMENT_RECONCILIATION_REQUIRED',
    message:
      'A previous payment may already have been captured. The gym must reconcile it before you can start another renewal. Please contact the front desk.',
  },
  PAYMENT_RECONCILIATION_FAILED: {
    code: 'PAYMENT_RECONCILIATION_FAILED',
    message:
      'The payment was captured but the reconciliation record could not be saved. Contact the front desk with your Razorpay payment id.',
  },
  ADMIN_REQUIRED: {
    code: 'ADMIN_REQUIRED',
    message: 'You do not have permission to review payments.',
  },
  SELF_REVIEW_FORBIDDEN: {
    code: 'SELF_REVIEW_FORBIDDEN',
    message:
      'You cannot approve or decline your own payment. Ask another admin to review it.',
  },
  INVALID_REVIEW_DECISION: {
    code: 'INVALID_REVIEW_DECISION',
    message: 'Choose either Approve or Decline for this payment.',
  },
  RECONCILIATION_NOTE_REQUIRED: {
    code: 'RECONCILIATION_NOTE_REQUIRED',
    message:
      'Add a note explaining the Razorpay reconciliation before reviewing this payment.',
  },
  PAYMENT_NOT_DECLINED: {
    code: 'PAYMENT_NOT_DECLINED',
    message: 'Only a declined payment can be marked as refunded.',
  },
  PAYMENT_NOT_CAPTURED: {
    code: 'PAYMENT_NOT_CAPTURED',
    message:
      'No captured gateway payment is recorded for this row. Verify it in Razorpay before tracking a refund.',
  },
  REFUND_NOT_PENDING: {
    code: 'REFUND_NOT_PENDING',
    message: 'This payment is not waiting for a manual refund.',
  },
  REVIEW_VIA_RPC_ONLY: {
    code: 'ADMIN_REQUIRED',
    message: 'Payments must be reviewed through the approval queue.',
  },
  PAYMENT_WRITE_VIA_RPC_ONLY: {
    code: 'ADMIN_REQUIRED',
    message: 'Payments must be reviewed through the approval queue.',
  },
  PAYMENT_NOT_PAYABLE: {
    code: 'PAYMENT_FAILED',
    message: 'This payment can no longer be completed. Please start a new renewal.',
  },
  PAYMENT_GATEWAY_NOT_CONFIGURED: {
    code: 'PAYMENT_NOT_CONFIGURED',
    message: 'Online payments are not enabled yet. Please renew at the front desk.',
  },
  PAYMENT_GATEWAY_UNAVAILABLE: {
    code: 'NETWORK',
    message: 'We could not reach the payment gateway. Check your connection and try again.',
  },
  PAYMENT_GATEWAY_ERROR: {
    code: 'PAYMENT_FAILED',
    message: 'The payment gateway rejected the request. Please try again.',
  },
  PAYMENT_SIGNATURE_INVALID: {
    code: 'PAYMENT_FAILED',
    message: "We could not verify this payment's signature. No plan was activated.",
  },
  PAYMENT_AMOUNT_MISMATCH: {
    code: 'PAYMENT_AMOUNT_MISMATCH',
    message:
      'The amount on this payment does not match the renewal total. Nothing was charged against it — please contact the front desk.',
  },
  PAYMENT_AMOUNT_INVALID: {
    code: 'PAYMENT_FAILED',
    message: 'This renewal has an invalid amount. Please contact the front desk.',
  },
  PAYMENT_ORDER_MISMATCH: {
    code: 'PAYMENT_ORDER_MISMATCH',
    message:
      'A different UPI reference is already recorded for this payment. Check the reference, or contact the front desk.',
  },
  PAYMENT_QUOTE_MISMATCH: {
    code: 'PAYMENT_FAILED',
    message: 'The renewal quote changed before activation. Please contact the front desk.',
  },
  PAYMENT_QUOTE_MISSING: {
    code: 'PAYMENT_FAILED',
    message: 'This payment record is incomplete. Please contact the front desk.',
  },
  PAYMENT_INCONSISTENT: {
    code: 'PAYMENT_FAILED',
    message: 'This payment record is incomplete. Please contact the front desk.',
  },
  MEMBERSHIP_PERIOD_OVERLAP: {
    code: 'PAYMENT_FAILED',
    message:
      "This approval would overlap an existing membership. Check the member's plans before retrying.",
  },
  PAYMENT_CREATE_FAILED: {
    code: 'PAYMENT_FAILED',
    message: 'We could not start this payment. Please try again.',
  },
  QUOTE_FAILED: {
    code: 'PAYMENT_FAILED',
    message: 'We could not calculate this renewal. Please try again.',
  },
  PROFILE_INCOMPLETE: {
    code: 'PROFILE_INCOMPLETE',
    message: 'Finish your member profile before continuing.',
  },
  SERVER_MISCONFIGURED: {
    code: 'UNKNOWN',
    message: 'The service is not configured yet. Please contact the gym.',
  },
}

function readField(error: unknown, field: string): string | undefined {
  if (error && typeof error === 'object' && field in error) {
    const value = (error as Record<string, unknown>)[field]
    if (typeof value === 'string') return value
  }
  return undefined
}

/** Convert Supabase / fetch / RPC errors into human-friendly AppErrors. */
export function toAppError(error: unknown): AppError {
  if (error instanceof AppError) return error

  const rawMessage = readField(error, 'message') ?? (typeof error === 'string' ? error : '')
  const rawCode = readField(error, 'code') ?? ''

  const rpcKey = Object.keys(RPC_MESSAGES).find(
    (key) => rawMessage.includes(key) || rawCode === key,
  )
  if (rpcKey) {
    const mapped = RPC_MESSAGES[rpcKey]!
    return new AppError(mapped.code, mapped.message, error)
  }

  const normalized = rawMessage.toLowerCase()
  const normalizedCode = rawCode.toLowerCase()

  if (normalizedCode === 'invalid_credentials' || normalized.includes('invalid login credentials')) {
    return new AppError(
      'INVALID_CREDENTIALS',
      "That email and password don't match. Please try again.",
      error,
    )
  }
  if (
    normalizedCode === 'email_not_confirmed' ||
    normalized.includes('email not confirmed') ||
    normalized.includes('email address not confirmed')
  ) {
    return new AppError(
      'EMAIL_NOT_CONFIRMED',
      'Confirm your email address before signing in. Check your inbox for the link.',
      error,
    )
  }
  if (normalizedCode === 'phone_not_confirmed' || normalized.includes('phone not confirmed')) {
    return new AppError(
      'PHONE_NOT_CONFIRMED',
      'Your mobile number is not verified yet. Verify it to sign in.',
      error,
    )
  }
  if (
    normalizedCode === 'user_already_exists' ||
    normalizedCode === 'email_exists' ||
    normalized.includes('already registered') ||
    normalized.includes('already been registered')
  ) {
    return new AppError(
      'USER_EXISTS',
      'An account already exists with this email. Try signing in instead.',
      error,
    )
  }
  if (
    normalizedCode === 'otp_expired' ||
    normalized.includes('token has expired') ||
    normalized.includes('otp has expired') ||
    normalized.includes('email link is invalid or has expired')
  ) {
    return new AppError(
      'EMAIL_LINK_INVALID',
      'That email link is invalid or has expired. Request a new one.',
      error,
    )
  }
  if (
    normalized.includes('invalid flow state') ||
    normalized.includes('code verifier') ||
    normalized.includes('invalid request: both auth code')
  ) {
    return new AppError(
      'EMAIL_LINK_INVALID',
      'This email link could not be completed. Open it on the same device where you requested it, or request a new link.',
      error,
    )
  }
  if (
    normalizedCode === 'otp_disabled' ||
    normalized.includes('invalid otp') ||
    normalized.includes('invalid token') ||
    normalized.includes('token is invalid')
  ) {
    return new AppError(
      'EMAIL_LINK_INVALID',
      'That link is invalid or has expired. Request a new one.',
      error,
    )
  }
  if (
    normalizedCode.includes('rate_limit') ||
    normalized.includes('rate limit') ||
    normalized.includes('too many requests') ||
    normalized.includes('security purposes')
  ) {
    return new AppError(
      'RATE_LIMITED',
      'Too many attempts. Please wait a minute and try again.',
      error,
    )
  }
  if (normalizedCode === 'weak_password' || normalized.includes('password should be at least')) {
    return new AppError(
      'WEAK_PASSWORD',
      'Choose a stronger password with at least 8 characters.',
      error,
    )
  }
  if (normalized.includes('failed to fetch') || normalized.includes('networkerror') || normalized.includes('load failed')) {
    return new AppError(
      'NETWORK',
      'We could not reach the server. Check your connection and try again.',
      error,
    )
  }
  if (normalizedCode === 'payments_not_configured') {
    return new AppError(
      'PAYMENT_NOT_CONFIGURED',
      'Online payments are not enabled yet. Please renew at the front desk.',
      error,
    )
  }

  return new AppError(
    'UNKNOWN',
    rawMessage || 'Something went wrong. Please try again.',
    error,
  )
}

export function isAppError(error: unknown): error is AppError {
  return error instanceof AppError
}
