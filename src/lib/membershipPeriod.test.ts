import { describe, expect, it } from 'vitest'
import type { Membership } from '@/types'
import { addDaysToDate } from '@/lib/kolkata'
import { resolveApprovedMembershipPeriod } from './membershipPeriod'

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

describe('resolveApprovedMembershipPeriod', () => {
  it('queues the purchased plan after a still-valid membership', () => {
    const period = resolveApprovedMembershipPeriod(
      [membership({ id: 'current', starts_on: '2026-10-15', ends_on: '2026-11-14' })],
      90,
      NOON_IST,
    )

    expect(period.is_stacked).toBe(true)
    expect(period.current_ends_on).toBe('2026-11-14')
    expect(period.starts_on).toBe('2026-11-15')
    expect(period.ends_on).toBe('2027-02-12')
  })

  it('keeps a plan ending today valid until tomorrow', () => {
    const period = resolveApprovedMembershipPeriod(
      [membership({ id: 'today', starts_on: '2026-09-28', ends_on: '2026-10-27' })],
      30,
      NOON_IST,
    )

    expect(period.is_stacked).toBe(true)
    expect(period.starts_on).toBe('2026-10-28')
    expect(period.ends_on).toBe('2026-11-26')
  })

  it('starts a lapsed membership today', () => {
    const period = resolveApprovedMembershipPeriod(
      [membership({ id: 'lapsed', starts_on: '2026-09-01', ends_on: '2026-09-30', status: 'expired' })],
      30,
      NOON_IST,
    )

    expect(period.is_stacked).toBe(false)
    expect(period.starts_on).toBe('2026-10-27')
    expect(period.ends_on).toBe('2026-11-25')
  })

  it('stacks after the latest future plan when several are queued', () => {
    const period = resolveApprovedMembershipPeriod(
      [
        membership({ id: 'current', starts_on: '2026-10-15', ends_on: '2026-11-14' }),
        membership({ id: 'later', starts_on: '2026-12-15', ends_on: '2027-01-13' }),
        membership({ id: 'sooner', starts_on: '2026-11-15', ends_on: '2026-12-14' }),
      ],
      30,
      NOON_IST,
    )

    expect(period.starts_on).toBe('2027-01-14')
    expect(period.ends_on).toBe('2027-02-12')
    expect(period.current_ends_on).toBe('2027-01-13')
  })

  it('ignores cancelled plans', () => {
    const period = resolveApprovedMembershipPeriod(
      [
        membership({
          id: 'cancelled',
          starts_on: '2026-10-01',
          ends_on: '2027-12-31',
          status: 'cancelled',
        }),
      ],
      30,
      NOON_IST,
    )

    expect(period.is_stacked).toBe(false)
    expect(period.starts_on).toBe('2026-10-27')
  })

  it('uses the purchased duration, not a fixed month', () => {
    const period = resolveApprovedMembershipPeriod(
      [membership({ id: 'current', ends_on: '2026-11-14' })],
      7,
      NOON_IST,
    )

    expect(period.starts_on).toBe('2026-11-15')
    expect(period.ends_on).toBe(addDaysToDate('2026-11-15', 6))
  })

  it('rejects an invalid duration', () => {
    expect(() => resolveApprovedMembershipPeriod([], 0, NOON_IST)).toThrow(
      'INVALID_MEMBERSHIP_DURATION',
    )
    expect(() => resolveApprovedMembershipPeriod([], Number.NaN, NOON_IST)).toThrow(
      'INVALID_MEMBERSHIP_DURATION',
    )
  })
})
