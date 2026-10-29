import { daysBetween, todayInKolkata } from './kolkata'

/**
 * Single source of truth for the late-renewal fine.
 *
 * This must stay byte-for-byte consistent with the SQL function
 * `public.get_my_renewal_quote()`, which is what a member is actually charged:
 *
 *   • 0–7 days past expiry ......... ₹0 (grace)
 *   • exactly day 8 ................ ₹50 flat
 *   • day 9 and beyond ............. ₹50 + ₹5 for each day after day 8
 *
 * If the policy changes, change it here, in
 * `supabase/migrations/*_fitdesk_late_fee_*.sql`, and in the demo quote.
 */

/** Days after expiry that still carry no fine. */
export const FINE_GRACE_DAYS = 7

/** Flat fine charged on the first day after the grace period. */
export const FINE_FLAT_AMOUNT = 50

/** Extra fine added for every day from day 9 onwards. */
export const FINE_DAILY_AMOUNT = 5

/** First day (days past expiry) that carries the flat fine. */
export const FINE_START_DAY = FINE_GRACE_DAYS + 1

export interface LateFee {
  /** Whole days since the plan ended. 0 while the plan is still valid. */
  daysPastExpiry: number
  amount: number
  /** Matches `fine_reason` from `get_my_renewal_quote()`. */
  reason: string | null
}

/**
 * Mirrors the SQL fine schedule exactly. Input is calendar days past expiry in
 * Asia/Kolkata, so callers must derive it with `daysBetween()` (never with
 * millisecond arithmetic).
 */
export function calculateLateFee(daysPastExpiry: number): LateFee {
  const days = Math.max(0, Math.floor(Number.isFinite(daysPastExpiry) ? daysPastExpiry : 0))

  if (days === 0) {
    return { daysPastExpiry: 0, amount: 0, reason: null }
  }

  if (days === FINE_START_DAY) {
    return {
      daysPastExpiry: days,
      amount: FINE_FLAT_AMOUNT,
      reason: `${days} days past expiry - ₹${FINE_FLAT_AMOUNT} flat late fee`,
    }
  }

  if (days > FINE_START_DAY) {
    return {
      daysPastExpiry: days,
      amount: FINE_FLAT_AMOUNT + FINE_DAILY_AMOUNT * (days - FINE_START_DAY),
      reason: `${days} days past expiry - ₹${FINE_FLAT_AMOUNT} + ₹${FINE_DAILY_AMOUNT}/day after day ${FINE_GRACE_DAYS}`,
    }
  }

  return {
    daysPastExpiry: days,
    amount: 0,
    reason: `${days} ${days === 1 ? 'day' : 'days'} past expiry - inside the ${FINE_GRACE_DAYS}-day grace period`,
  }
}

/** Whole IST days between an expiry date and `now`. Negative = still valid. */
export function daysPastExpiryOn(endsOn: string, now: Date = new Date()): number {
  return Math.max(0, daysBetween(endsOn, todayInKolkata(now)))
}

/** Convenience wrapper: the fine a renewal would carry if paid today. */
export function lateFeeForExpiry(endsOn: string, now: Date = new Date()): LateFee {
  return calculateLateFee(daysPastExpiryOn(endsOn, now))
}
