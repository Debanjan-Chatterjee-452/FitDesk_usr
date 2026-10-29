/**
 * Razorpay Checkout loader (browser only).
 * The public key id is safe to ship; the secret key never leaves the server.
 */

const CHECKOUT_SRC = 'https://checkout.razorpay.com/v1/checkout.js'

export interface RazorpaySuccessResponse {
  razorpay_order_id: string
  razorpay_payment_id: string
  razorpay_signature: string
}

export interface RazorpayCheckoutOptions {
  key: string
  amount: number
  currency: string
  name: string
  description: string
  order_id: string
  prefill?: { name?: string; contact?: string; email?: string }
  notes?: Record<string, string>
  theme?: { color?: string; backdrop_color?: string }
  modal?: {
    ondismiss?: () => void
    escape?: boolean
    confirm_close?: boolean
  }
  handler?: (response: RazorpaySuccessResponse) => void
}

interface RazorpayInstance {
  open: () => void
  on: (event: string, handler: (response: unknown) => void) => void
  close: () => void
}

declare global {
  interface Window {
    Razorpay?: new (options: RazorpayCheckoutOptions) => RazorpayInstance
  }
}

let loader: Promise<boolean> | null = null

export function loadRazorpay(): Promise<boolean> {
  if (typeof window === 'undefined') return Promise.resolve(false)
  if (window.Razorpay) return Promise.resolve(true)
  if (loader) return loader

  loader = new Promise<boolean>((resolve) => {
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${CHECKOUT_SRC}"]`)
    if (existing) {
      existing.addEventListener('load', () => resolve(Boolean(window.Razorpay)))
      existing.addEventListener('error', () => resolve(false))
      return
    }
    const script = document.createElement('script')
    script.src = CHECKOUT_SRC
    script.async = true
    script.onload = () => resolve(Boolean(window.Razorpay))
    script.onerror = () => {
      loader = null
      resolve(false)
    }
    document.body.appendChild(script)
  })

  return loader
}

export function openRazorpayCheckout(
  options: RazorpayCheckoutOptions,
): { instance: RazorpayInstance | null } {
  if (!window.Razorpay) return { instance: null }
  const instance = new window.Razorpay(options)
  instance.open()
  return { instance }
}
