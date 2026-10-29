import { describe, expect, it } from 'vitest'
import type { Membership } from '@/types'
import { pickMembershipOverview } from './memberships'

/** 27 Oct 2026, 12:00 IST. */
const NOON_IST = new Date('2026-10-27T06:30:00.000Z')

function membership(patch: Partial<Membership> & { id: string }): Membership {
  return {
    user_id: 'user-1',
    package_id: 'pkg-monthly',
    starts_on: '2026-10-01',
    ends_on: '2026-10-30',
    price_paid_inr: 1499,
    fine_paid_inr: 0,
    status: 'active',
    created_at: '2026-10-01T06:30:00.000Z',
    updated_at: '2026-10-01T06:30:00.000Z',
    ...patch,
  }
}

describe('pickMembershipOverview', () => {
  it('shows the plan covering today and the queued renewal separately', () => {
    const current = membership({ id: 'current', starts_on: '2026-10-15', ends_on: '2026-11-14' })
    const upcoming = membership({ id: 'next', starts_on: '2026-11-15', ends_on: '2026-12-14' })
    const overview = pickMembershipOverview([upcoming, current], NOON_IST)
    expect(overview.current?.id).toBe('current')
    expect(overview.upcoming?.id).toBe('next')
  })

  it('keeps a plan that ends today as the current plan', () => {
    const overview = pickMembershipOverview(
      [membership({ id: 'today', starts_on: '2026-09-28', ends_on: '2026-10-27' })],
      NOON_IST,
    )
    expect(overview.current?.id).toBe('today')
    expect(overview.upcoming).toBeNull()
  })

  it('returns the latest expired plan when nothing is live', () => {
    const overview = pickMembershipOverview(
      [
        membership({ id: 'older', starts_on: '2026-08-01', ends_on: '2026-08-30', status: 'expired' }),
        membership({ id: 'newer', starts_on: '2026-08-31', ends_on: '2026-09-29', status: 'expired' }),
      ],
      NOON_IST,
    )
    expect(overview.current?.id).toBe('newer')
    expect(overview.upcoming).toBeNull()
  })

  it('does not present a future-only plan as the current plan', () => {
    const upcoming = membership({ id: 'future', starts_on: '2026-11-01', ends_on: '2026-11-30' })
    const overview = pickMembershipOverview([upcoming], NOON_IST)
    expect(overview.current).toBeNull()
    expect(overview.upcoming?.id).toBe('future')
  })

  it('ignores cancelled plans and picks the longest live overlap', () => {
    const overview = pickMembershipOverview(
      [
        membership({ id: 'cancelled', starts_on: '2026-10-01', ends_on: '2026-12-31', status: 'cancelled' }),
        membership({ id: 'short', starts_on: '2026-10-20', ends_on: '2026-10-28' }),
        membership({ id: 'long', starts_on: '2026-10-01', ends_on: '2026-11-14' }),
        membership({ id: 'future', starts_on: '2026-12-01', ends_on: '2026-12-31' }),
      ],
      NOON_IST,
    )
    expect(overview.current?.id).toBe('long')
    expect(overview.upcoming?.id).toBe('future')
  })

  it('uses the earliest queued renewal when several exist', () => {
    const overview = pickMembershipOverview(
      [
        membership({ id: 'current', starts_on: '2026-10-15', ends_on: '2026-11-14' }),
        membership({ id: 'later', starts_on: '2026-12-15', ends_on: '2027-01-13' }),
        membership({ id: 'sooner', starts_on: '2026-11-15', ends_on: '2026-12-14' }),
      ],
      NOON_IST,
    )
    expect(overview.upcoming?.id).toBe('sooner')
  })

  it('handles an empty history', () => {
    expect(pickMembershipOverview([], NOON_IST)).toEqual({ current: null, upcoming: null })
  })
})
