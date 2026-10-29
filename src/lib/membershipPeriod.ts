import type { Membership } from '@/types'
import { addDaysToDate, todayInKolkata } from './kolkata'

export interface ApprovedMembershipPeriod {
  starts_on: string
  ends_on: string
  /** True when the new plan starts after a plan that still covers today. */
  is_stacked: boolean
  /** Expiry of the latest non-cancelled plan used to place the new plan. */
  current_ends_on: string | null
}

type MembershipPeriodInput = Pick<Membership, 'starts_on' | 'ends_on' | 'status'>

/**
 * Resolves the dates a newly approved payment may occupy.
 *
 * Approval always recalculates the period from the member's latest
 * non-cancelled plan instead of trusting the dates stored on the checkout
 * quote. A still-valid plan keeps every remaining day: the purchased plan is
 * queued after its expiry. If the latest plan has lapsed, the purchased plan
 * starts today. Only the purchased duration is taken from the payment.
 */
export function resolveApprovedMembershipPeriod(
  memberships: MembershipPeriodInput[],
  durationDays: number,
  now: Date = new Date(),
): ApprovedMembershipPeriod {
  const duration = Math.trunc(durationDays)
  if (!Number.isFinite(duration) || duration < 1) {
    throw new Error('INVALID_MEMBERSHIP_DURATION')
  }

  const today = todayInKolkata(now)
  const latest =
    memberships
      .filter((membership) => membership.status !== 'cancelled')
      .sort((a, b) => {
        if (a.ends_on !== b.ends_on) return a.ends_on < b.ends_on ? 1 : -1
        if (a.starts_on !== b.starts_on) return a.starts_on < b.starts_on ? 1 : -1
        return 0
      })[0] ?? null

  const isStacked = Boolean(latest && latest.ends_on >= today)
  const startsOn = latest && isStacked ? addDaysToDate(latest.ends_on, 1) : today
  const endsOn = addDaysToDate(startsOn, duration - 1)

  return {
    starts_on: startsOn,
    ends_on: endsOn,
    is_stacked: isStacked,
    current_ends_on: latest?.ends_on ?? null,
  }
}
