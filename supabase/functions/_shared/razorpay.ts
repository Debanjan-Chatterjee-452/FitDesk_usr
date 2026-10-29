import { HttpError } from './http.ts'
import { requireEnv } from './supabase.ts'

const RAZORPAY_API = 'https://api.razorpay.com/v1'

export interface RazorpayOrder {
  id: string
  amount: number
  currency: string
  status: string
  receipt?: string | null
}

export interface RazorpayPayment {
  id: string
  order_id: string | null
  amount: number
  currency: string
  status: string
  captured: boolean
  method?: string | null
  email?: string | null
  contact?: string | null
}

export interface RazorpayOrderPaymentCollection {
  entity: string
  count: number
  items: RazorpayPayment[]
}

export function razorpayKeyId(): string {
  return requireEnv('RAZORPAY_KEY_ID')
}

function razorpayKeySecret(): string {
  return requireEnv('RAZORPAY_KEY_SECRET')
}

export function isRazorpayConfigured(): boolean {
  return Boolean(
    Deno.env.get('RAZORPAY_KEY_ID')?.trim() &&
      Deno.env.get('RAZORPAY_KEY_SECRET')?.trim(),
  )
}

export function assertRazorpayConfigured(): void {
  if (!isRazorpayConfigured()) {
    throw new HttpError(
      503,
      'PAYMENT_GATEWAY_NOT_CONFIGURED',
      'Online payments are not enabled yet. Please renew at the front desk.',
    )
  }
}

async function razorpayRequest<T>(
  path: string,
  init: { method?: string; body?: unknown } = {},
): Promise<T> {
  const credentials = btoa(`${razorpayKeyId()}:${razorpayKeySecret()}`)
  let response: Response

  try {
    response = await fetch(`${RAZORPAY_API}${path}`, {
      method: init.method ?? 'GET',
      headers: {
        Authorization: `Basic ${credentials}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    })
  } catch (error) {
    console.error('[fitdesk] Razorpay network failure', error)
    throw new HttpError(
      502,
      'PAYMENT_GATEWAY_UNAVAILABLE',
      'We could not reach the payment gateway. Please try again.',
    )
  }

  const payload = await response.json().catch(() => null)
  if (!response.ok) {
    console.error('[fitdesk] Razorpay API error', response.status, payload)
    if (response.status === 404) {
      throw new HttpError(
        404,
        'PAYMENT_GATEWAY_NOT_FOUND',
        'The payment gateway could not find that record.',
        { provider: 'razorpay', status: response.status },
      )
    }
    throw new HttpError(
      502,
      'PAYMENT_GATEWAY_ERROR',
      'The payment gateway rejected the request. Please try again.',
      { provider: 'razorpay', status: response.status },
    )
  }

  return payload as T
}

export function createRazorpayOrder(input: {
  amountInr: number
  receipt: string
  notes: Record<string, string>
}): Promise<RazorpayOrder> {
  return razorpayRequest<RazorpayOrder>('/orders', {
    method: 'POST',
    body: {
      amount: input.amountInr * 100,
      currency: 'INR',
      receipt: input.receipt,
      notes: input.notes,
      payment_capture: 1,
    },
  })
}

export function getRazorpayPayment(paymentId: string): Promise<RazorpayPayment> {
  return razorpayRequest<RazorpayPayment>(`/payments/${encodeURIComponent(paymentId)}`)
}

/** Used only to decide whether an old checkout is safe to abandon. */
export function getRazorpayOrder(orderId: string): Promise<RazorpayOrder> {
  return razorpayRequest<RazorpayOrder>(`/orders/${encodeURIComponent(orderId)}`)
}

/** Used only to detect a payment that the browser never reported back. */
export function listRazorpayOrderPayments(
  orderId: string,
): Promise<RazorpayOrderPaymentCollection> {
  return razorpayRequest<RazorpayOrderPaymentCollection>(
    `/orders/${encodeURIComponent(orderId)}/payments`,
  )
}

export function captureRazorpayPayment(input: {
  paymentId: string
  amountInr: number
}): Promise<RazorpayPayment> {
  return razorpayRequest<RazorpayPayment>(
    `/payments/${encodeURIComponent(input.paymentId)}/capture`,
    {
      method: 'POST',
      body: {
        amount: input.amountInr * 100,
        currency: 'INR',
      },
    },
  )
}

/**
 * Verifies Razorpay's `order_id|payment_id` HMAC using the key secret. This is
 * the only place a browser-supplied signature is trusted, and only after the
 * server-generated order is located for the signed-in user.
 */
export async function verifyRazorpaySignature(input: {
  orderId: string
  paymentId: string
  signature: string
}): Promise<boolean> {
  const secret = razorpayKeySecret()
  const signature = input.signature.trim().toLowerCase()
  if (!/^[a-f0-9]{64}$/.test(signature)) return false

  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const digest = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(`${input.orderId}|${input.paymentId}`),
  )
  const expected = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')

  // Constant-time comparison.
  let difference = expected.length ^ signature.length
  for (let index = 0; index < expected.length; index += 1) {
    difference |= expected.charCodeAt(index) ^ signature.charCodeAt(index)
  }
  return difference === 0
}
