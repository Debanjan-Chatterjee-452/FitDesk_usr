import { describe, expect, it } from 'vitest'
import {
  FINE_DAILY_AMOUNT,
  FINE_FLAT_AMOUNT,
  FINE_GRACE_DAYS,
  FINE_START_DAY,
  calculateLateFee,
  daysPastExpiryOn,
  lateFeeForExpiry,
} from './lateFee'

describe('late fee schedule', () => {
  it('publishes the policy the SQL uses', () => {
    expect(FINE_GRACE_DAYS).toBe(7)
    expect(FINE_START_DAY).toBe(8)
    expect(FINE_FLAT_AMOUNT).toBe(50)
    expect(FINE_DAILY_AMOUNT).toBe(5)
  })

  it('charges nothing on or before the expiry day', () => {
    expect(calculateLateFee(0)).toEqual({ daysPastExpiry: 0, amount: 0, reason: null })
  })

  it('charges nothing inside the 7-day grace period', () => {
    for (let days = 1; days <= FINE_GRACE_DAYS; days += 1) {
      const fee = calculateLateFee(days)
      expect(fee.amount, `${days} days past expiry`).toBe(0)
      expect(fee.reason, `${days} days past expiry`).toContain('grace period')
    }
  })

  it('charges a flat ₹50 on exactly day 8', () => {
    const fee = calculateLateFee(8)
    expect(fee.amount).toBe(50)
    expect(fee.reason).toContain('₹50 flat')
  })

  it('adds ₹5 for every day after day 8', () => {
    const cases: Array<[number, number]> = [
      [9, 55],
      [10, 60],
      [11, 65],
      [12, 70],
      [30, 160],
    ]
    for (const [days, amount] of cases) {
      const fee = calculateLateFee(days)
      expect(fee.amount, `${days} days past expiry`).toBe(amount)
      expect(fee.reason, `${days} days past expiry`).toContain('₹5/day')
    }
  })

  it('never produces a negative fine', () => {
    expect(calculateLateFee(-4).amount).toBe(0)
    expect(calculateLateFee(Number.NaN).amount).toBe(0)
  })
})

describe('IST day arithmetic', () => {
  it('counts whole Kolkata days, not milliseconds', () => {
    // 23:30 IST on 9 Oct is still 9 Oct in Kolkata, i.e. 8 days after 1 Oct.
    const lateNight = new Date('2026-10-09T23:30:00+05:30')
    expect(daysPastExpiryOn('2026-10-01', lateNight)).toBe(8)

    // Ten minutes later it is 9 days past expiry.
    const justAfterMidnight = new Date('2026-10-10T00:10:00+05:30')
    expect(daysPastExpiryOn('2026-10-01', justAfterMidnight)).toBe(9)
  })

  it('treats a UTC instant by its Kolkata calendar day', () => {
    // 2026-10-09T18:40Z is 2026-10-10 00:10 IST.
    const utc = new Date('2026-10-09T18:40:00Z')
    expect(daysPastExpiryOn('2026-10-01', utc)).toBe(9)
  })

  it('reports no fine while the plan still covers today', () => {
    const now = new Date('2026-10-30T12:00:00+05:30')
    expect(lateFeeForExpiry('2026-10-30', now).amount).toBe(0)
    expect(lateFeeForExpiry('2026-11-02', now).amount).toBe(0)
    expect(lateFeeForExpiry('2026-10-22', now).amount).toBe(50)
    expect(lateFeeForExpiry('2026-10-21', now).amount).toBe(55)
  })
})
