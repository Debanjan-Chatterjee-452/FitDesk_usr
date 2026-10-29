/**
 * Runtime configuration.
 *
 * Only the Supabase URL, the anon/publishable key, and the Razorpay *public*
 * key id are ever exposed to the browser. Service-role keys and payment
 * secrets live exclusively in Supabase Edge Function secrets.
 */

const rawUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.trim()
const rawAnonKey = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim()
const rawRazorpayKeyId = (import.meta.env.VITE_RAZORPAY_KEY_ID as string | undefined)?.trim()

export const TIMEZONE = 'Asia/Kolkata'
export const CURRENCY = 'INR'

export const isDemoMode = import.meta.env.VITE_DEMO_MODE === 'true'

function looksLikeUrl(value: string | undefined): value is string {
  if (!value) return false
  try {
    const url = new URL(value)
    return url.protocol === 'https:' || url.protocol === 'http:'
  } catch {
    return false
  }
}

export const supabaseUrl = looksLikeUrl(rawUrl) ? rawUrl.replace(/\/$/, '') : ''
export const supabaseAnonKey = rawAnonKey ?? ''
export const razorpayPublicKeyId = rawRazorpayKeyId ?? ''

/** True when a real Supabase project is wired up. */
export const isSupabaseConfigured = Boolean(supabaseUrl && supabaseAnonKey)

/** Demo mode is explicit opt-in and never silently replaces production auth. */
export const isDemo = isDemoMode

export const appConfig = {
  name: 'FitDesk',
  version: '1.0.0',
  timezone: TIMEZONE,
  currency: CURRENCY,
  demo: isDemo,
  supportPhone: '+91 90000 00000',
} as const
