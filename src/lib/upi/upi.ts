/**
 * Direct-UPI helpers.
 *
 * Everything here is pure so it can be unit tested without a browser. The
 * rules mirror the database (`public.gyms` trigger and the UPI RPCs):
 *   * a UPI ID is `<handle>@<psp>`, lowercase;
 *   * an amount is always a positive number of rupees;
 *   * a transaction reference is 6–40 letters/digits.
 */

export type QrVerification =
  | { status: 'verified'; parsed: ParsedUpiUri }
  | { status: 'not_upi' }
  | { status: 'missing_amount' }
  | { status: 'payee_mismatch'; foundUpiId: string }
  | { status: 'amount_mismatch'; foundAmount: number }

export interface ParsedUpiUri {
  upiId: string
  payeeName: string | null
  amountInr: number | null
  reference: string | null
  note: string | null
}

export interface UpiUriInput {
  upiId: string
  payeeName?: string | null
  amountInr: number
  reference?: string | null
  note?: string | null
}

/** Same shape the database trigger accepts. */
const UPI_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{1,60}@[a-z][a-z0-9]{1,40}$/
/** NPCI caps the transaction note at 50 characters. */
const MAX_NOTE_LENGTH = 50
/** NPCI caps the transaction reference at 35 characters. */
const MAX_REFERENCE_LENGTH = 35
const MAX_PAYEE_NAME_LENGTH = 99

export function normalizeUpiId(value: string | null | undefined): string {
  return (value ?? '').trim().toLowerCase()
}

export function isValidUpiId(value: string | null | undefined): boolean {
  return UPI_ID_PATTERN.test(normalizeUpiId(value))
}

export function normalizeUpiReference(value: string | null | undefined): string {
  return (value ?? '').replace(/[\s-]+/g, '').toUpperCase()
}

export function isValidUpiReference(value: string | null | undefined): boolean {
  const normalized = normalizeUpiReference(value)
  return /^[A-Z0-9]{6,40}$/.test(normalized)
}

/** UPI apps expect a decimal amount with at most two places. */
export function formatUpiAmount(amountInr: number): string {
  return amountInr.toFixed(2)
}

export function isValidUpiAmount(amountInr: number | null | undefined): boolean {
  return (
    typeof amountInr === 'number' &&
    Number.isFinite(amountInr) &&
    amountInr > 0 &&
    // Sub-paise amounts cannot be paid.
    Math.abs(Math.round(amountInr * 100) - amountInr * 100) < 1e-6
  )
}

/**
 * Builds a `upi://pay` intent. Every value is percent-encoded with
 * encodeURIComponent (never `+` for spaces) because several UPI apps show the
 * raw value when they cannot decode a form-encoded plus sign.
 *
 * @throws when the recipient or amount is not valid. Callers must not fall
 * back to a different recipient.
 */
export function buildUpiUri(input: UpiUriInput): string {
  const upiId = normalizeUpiId(input.upiId)
  if (!isValidUpiId(upiId)) {
    throw new Error('INVALID_UPI_ID')
  }
  if (!isValidUpiAmount(input.amountInr)) {
    throw new Error('INVALID_UPI_AMOUNT')
  }

  const params: string[] = [`pa=${encodeURIComponent(upiId)}`]

  const payeeName = (input.payeeName ?? '').trim().slice(0, MAX_PAYEE_NAME_LENGTH)
  if (payeeName) {
    params.push(`pn=${encodeURIComponent(payeeName)}`)
  }

  params.push(`am=${formatUpiAmount(input.amountInr)}`)
  params.push('cu=INR')

  const reference = (input.reference ?? '').trim().slice(0, MAX_REFERENCE_LENGTH)
  if (reference) {
    params.push(`tr=${encodeURIComponent(reference)}`)
  }

  const note = (input.note ?? '').trim().slice(0, MAX_NOTE_LENGTH)
  if (note) {
    params.push(`tn=${encodeURIComponent(note)}`)
  }

  return `upi://pay?${params.join('&')}`
}

function parseAmount(value: string | null): number | null {
  if (value === null || value.trim() === '') return null
  const amount = Number(value)
  return Number.isFinite(amount) && amount > 0 ? amount : null
}

/** Parses a scanned/decoded UPI payload. Returns null for anything else. */
export function parseUpiUri(value: string | null | undefined): ParsedUpiUri | null {
  const raw = (value ?? '').trim()
  if (!/^upi:\/\//i.test(raw)) return null

  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return null
  }

  const upiId = normalizeUpiId(url.searchParams.get('pa'))
  // A malformed `pa` is not a usable UPI intent: treating it as one would put
  // an unverifiable recipient in front of the member.
  if (!isValidUpiId(upiId)) return null

  const decoded = (key: string) => {
    const value = url.searchParams.get(key)
    return value === null || value.trim() === '' ? null : value
  }

  return {
    upiId,
    payeeName: decoded('pn'),
    amountInr: parseAmount(url.searchParams.get('am')),
    reference: decoded('tr'),
    note: decoded('tn'),
  }
}

/**
 * Decides whether a gym-uploaded QR image may be shown as-is.
 *
 * - `verified`: it is a UPI intent for the gym's configured UPI ID.
 * - `payee_mismatch` / `amount_mismatch`: it points somewhere else. Never show
 *   it; generate a QR from the verified UPI ID instead.
 * - `not_upi`: not a UPI QR at all (could be any URL).
 */
export function interpretUpiQrPayload(
  payload: string | null | undefined,
  expected: { upiId: string; amountInr?: number | null },
): QrVerification {
  const parsed = parseUpiUri(payload)
  if (!parsed) return { status: 'not_upi' }

  if (parsed.upiId !== normalizeUpiId(expected.upiId)) {
    return { status: 'payee_mismatch', foundUpiId: parsed.upiId }
  }

  const expectedAmount = expected.amountInr
  if (typeof expectedAmount === 'number' && isValidUpiAmount(expectedAmount)) {
    // A static QR carries no amount: it is not wrong, but it cannot be shown
    // as "ready for this exact amount" either.
    if (parsed.amountInr === null) return { status: 'missing_amount' }
    if (Math.abs(parsed.amountInr - expectedAmount) >= 0.005) {
      return { status: 'amount_mismatch', foundAmount: parsed.amountInr }
    }
  }

  return { status: 'verified', parsed }
}

export const UPI_STATE_LABELS = {
  NOT_STARTED: 'Awaiting payment',
  PENDING_VERIFICATION: 'Pending verification',
  VERIFIED: 'Verified',
  FAILED: 'Failed',
  CANCELLED: 'Cancelled',
} as const

/** A paid attempt is only "done" once a human verifies it. */
export function isPaymentSettled(state: string): boolean {
  return state === 'VERIFIED' || state === 'FAILED' || state === 'CANCELLED'
}

export interface RawUpiPayee {
  available?: boolean | null
  reason?: string | null
  upi_id?: string | null
  name?: string | null
  qr_path?: string | null
  qr_bucket?: string | null
}

export interface ResolvedUpiPayee {
  available: boolean
  reason: 'NOT_CONFIGURED' | 'AMOUNT_INVALID' | 'INVALID_UPI_ID' | null
  upi_id: string | null
  name: string | null
  qr_path: string | null
  qr_bucket: string | null
}

function unavailable(reason: ResolvedUpiPayee['reason']): ResolvedUpiPayee {
  return {
    available: false,
    reason,
    upi_id: null,
    name: null,
    qr_path: null,
    qr_bucket: null,
  }
}

/**
 * Turns whatever the server returned into a payee the UI may render.
 *
 * A payee is only usable when the server says it is available, the UPI ID is
 * well-formed, and there is a payable amount. Anything else becomes
 * "unavailable" — we never repair a recipient by substituting another one.
 */
export function resolveUpiPayee(
  raw: RawUpiPayee | null | undefined,
  amountInr: number,
): ResolvedUpiPayee {
  const upiId = normalizeUpiId(raw?.upi_id)

  if (!raw || raw.available !== true || !upiId) {
    return unavailable(
      normalizePayeeReason(raw?.reason) ?? 'NOT_CONFIGURED',
    )
  }
  if (!isValidUpiId(upiId)) {
    return unavailable('INVALID_UPI_ID')
  }
  if (!isValidUpiAmount(amountInr)) {
    return unavailable('AMOUNT_INVALID')
  }

  return {
    available: true,
    reason: null,
    upi_id: upiId,
    name: raw.name ?? null,
    qr_path: raw.qr_path ?? null,
    qr_bucket: raw.qr_bucket ?? 'gym-payment-qr',
  }
}

function normalizePayeeReason(reason: string | null | undefined): ResolvedUpiPayee['reason'] {
  if (reason === 'AMOUNT_INVALID' || reason === 'INVALID_UPI_ID' || reason === 'NOT_CONFIGURED') {
    return reason
  }
  return null
}

