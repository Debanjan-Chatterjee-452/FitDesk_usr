import { daysBetween, todayInKolkata } from './kolkata'
import { FINE_DAILY_AMOUNT, FINE_FLAT_AMOUNT, calculateLateFee } from './lateFee'

/**
 * In-app expiry / late-fee banner copy.
 *
 * Every day count is derived from the same IST calendar arithmetic the SQL
 * quote uses (`(now() at time zone 'Asia/Kolkata')::date - ends_on`), so the
 * banner can never disagree with the amount the server charges.
 */

export type ExpiryWarningTone = 'reminder' | 'warning' | 'danger'

export interface ExpiryWarning {
  tone: ExpiryWarningTone
  /** Short heading. The exact required sentence lives in `message`. */
  title: string
  message: string
  /** Fine the server would charge for a renewal paid today. 0 inside grace. */
  fine: number
}

export interface ExpiryWarningInput {
  /** `memberships.ends_on` — a `yyyy-MM-dd` IST calendar date. */
  endsOn: string
  now?: Date
  /** Cancelled rows never warn. */
  isCancelled?: boolean
  /** An approved renewal already queued after this plan — nothing to chase. */
  hasUpcomingPlan?: boolean
}

/** Banner for an active plan. Hidden once more than 3 days remain. */
function activeWarning(daysLeft: number): ExpiryWarning | null {
  if (daysLeft > 3) return null

  const message =
    daysLeft === 3
      ? 'Reminder: Your membership expires in 3 days.'
      : daysLeft === 2
        ? 'Reminder: Your membership expires in 2 days.'
        : daysLeft === 1
          ? 'Reminder: Your membership expires tomorrow. Renew now to avoid interruption.'
          : 'Reminder: Your membership expires today. Renew now to avoid interruption.'

  return {
    tone: 'reminder',
    title: daysLeft === 0 ? 'Expires today' : 'Membership reminder',
    message,
    fine: 0,
  }
}

/** Banner for a lapsed plan, from day 1 to day 7+ past expiry. */
function expiredWarning(daysPastExpiry: number): ExpiryWarning {
  const { amount } = calculateLateFee(daysPastExpiry)

  if (daysPastExpiry === 7) {
    return {
      tone: 'warning',
      title: 'Fine starts tomorrow',
      message: `Warning: Your membership expired 7 days ago. A ₹${FINE_FLAT_AMOUNT} fine will be added to your renewal starting tomorrow.`,
      fine: amount,
    }
  }

  if (daysPastExpiry === 8) {
    return {
      tone: 'danger',
      title: 'Late fee applied',
      message: `Overdue: A ₹${FINE_FLAT_AMOUNT} fine has been added to your renewal fee.`,
      fine: amount,
    }
  }

  if (daysPastExpiry >= 9) {
    return {
      tone: 'danger',
      title: 'Late fee applied',
      message: `Overdue: A ₹${FINE_FLAT_AMOUNT} fine plus an additional ₹${FINE_DAILY_AMOUNT} daily late fee is being applied to your renewal.`,
      fine: amount,
    }
  }

  const days = `${daysPastExpiry} ${daysPastExpiry === 1 ? 'day' : 'days'}`
  return {
    tone: 'warning',
    title: 'Membership expired',
    message: `Overdue: Your membership expired ${days} ago. Renew now — you are still inside the 7-day grace period, so no fine applies yet.`,
    fine: amount,
  }
}

/**
 * Returns the banner to show today, or `null` when the member is active with
 * more than 3 days left, has no plan, is cancelled, or has an approved renewal
 * already queued.
 */
export function buildExpiryWarning({
  endsOn,
  now = new Date(),
  isCancelled = false,
  hasUpcomingPlan = false,
}: ExpiryWarningInput): ExpiryWarning | null {
  if (!endsOn || isCancelled || hasUpcomingPlan) return null

  const today = todayInKolkata(now)
  const daysLeft = daysBetween(today, endsOn)

  return daysLeft >= 0 ? activeWarning(daysLeft) : expiredWarning(-daysLeft)
}
