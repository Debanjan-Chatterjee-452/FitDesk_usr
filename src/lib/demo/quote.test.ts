import { describe, expect, it } from 'vitest'
import { addDaysToDate, todayInKolkata } from '@/lib/kolkata'
import {
  calculateDemoQuote,
  createSeedDatabase,
  DEMO_PHONE,
  PACKAGE_IDS,
  type DemoDatabase,
} from './store'

function seededDatabase(expiryOffset: number): { db: DemoDatabase; userId: string } {
  const db = createSeedDatabase()
  const user = db.users[0]!
  const today = todayInKolkata()
  user.memberships = [
    {
      ...user.memberships[0]!,
      starts_on: addDaysToDate(today, expiryOffset - 29),
      ends_on: addDaysToDate(today, expiryOffset),
      status: expiryOffset < 0 ? 'expired' : 'active',
    },
  ]
  return { db, userId: user.id }
}

describe('late renewal fine', () => {
  it('charges nothing inside the 7-day grace period', () => {
    for (let past = 1; past <= 7; past += 1) {
      const { db, userId } = seededDatabase(-past)
      const quote = calculateDemoQuote(userId, PACKAGE_IDS.monthly, null, db)
      expect(quote.days_past_expiry, `${past} days past expiry`).toBe(past)
      expect(quote.fine_amount, `${past} days past expiry`).toBe(0)
      expect(quote.total_amount).toBe(1499)
    }
  })

  it('charges a flat ₹50 on exactly day 8', () => {
    const { db, userId } = seededDatabase(-8)
    const quote = calculateDemoQuote(userId, PACKAGE_IDS.monthly, null, db)
    expect(quote.days_past_expiry).toBe(8)
    expect(quote.fine_amount).toBe(50)
    expect(quote.total_amount).toBe(1549)
    expect(quote.fine_reason).toContain('₹50 flat')
  })

  it('adds ₹5 for every day after day 8', () => {
    const cases: Array<[number, number]> = [
      [9, 55],
      [10, 60],
      [12, 70],
      [30, 160],
    ]
    for (const [past, fine] of cases) {
      const { db, userId } = seededDatabase(-past)
      const quote = calculateDemoQuote(userId, PACKAGE_IDS.monthly, null, db)
      expect(quote.fine_amount, `${past} days past expiry`).toBe(fine)
      expect(quote.total_amount).toBe(1499 + fine)
      expect(quote.breakdown).toContainEqual({ label: 'Late renewal fee', amount: fine })
    }
  })

  it('starts an expired renewal today', () => {
    const { db, userId } = seededDatabase(-3)
    const quote = calculateDemoQuote(userId, PACKAGE_IDS.monthly, null, db)
    expect(quote.starts_on).toBe(todayInKolkata())
    expect(quote.ends_on).toBe(addDaysToDate(todayInKolkata(), 29))
    expect(quote.is_stacked).toBe(false)
  })
})

describe('stacked renewals', () => {
  it('starts after the current plan without a gap', () => {
    const { db, userId } = seededDatabase(18)
    const latestEnd = db.users[0]!.memberships[0]!.ends_on
    const quote = calculateDemoQuote(userId, PACKAGE_IDS.monthly, null, db)
    expect(quote.is_stacked).toBe(true)
    expect(quote.starts_on).toBe(addDaysToDate(latestEnd, 1))
    expect(quote.ends_on).toBe(addDaysToDate(latestEnd, 30))
    expect(quote.fine_amount).toBe(0)
    expect(quote.days_past_expiry).toBe(0)
  })

  it('treats a plan ending today as still active', () => {
    const { db, userId } = seededDatabase(0)
    const quote = calculateDemoQuote(userId, PACKAGE_IDS.monthly, null, db)
    expect(quote.is_stacked).toBe(true)
    expect(quote.starts_on).toBe(addDaysToDate(todayInKolkata(), 1))
    expect(quote.fine_amount).toBe(0)
  })
})

describe('per-day packages', () => {
  it('clamps Flex duration to its published bounds', () => {
    const db = createSeedDatabase()
    const userId = db.users[0]!.id

    const short = calculateDemoQuote(userId, PACKAGE_IDS.flex, 3, db)
    expect(short.duration_days).toBe(7)
    expect(short.base_amount).toBe(7 * 79)

    const long = calculateDemoQuote(userId, PACKAGE_IDS.flex, 500, db)
    expect(long.duration_days).toBe(180)
    expect(long.base_amount).toBe(180 * 79)

    const exact = calculateDemoQuote(userId, PACKAGE_IDS.flex, 45, db)
    expect(exact.duration_days).toBe(45)
    expect(exact.base_amount).toBe(45 * 79)
    expect(exact.total_amount).toBe(45 * 79)
  })
})

describe('demo pricing integrity', () => {
  it('bills the database price, ignoring any client suggestion', () => {
    const db = createSeedDatabase()
    db.packages = db.packages.map((pkg) =>
      pkg.id === PACKAGE_IDS.monthly ? { ...pkg, price_inr: 1799 } : pkg,
    )
    const quote = calculateDemoQuote(db.users[0]!.id, PACKAGE_IDS.monthly, null, db)
    expect(quote.base_amount).toBe(1799)
    expect(quote.total_amount).toBe(1799)
  })

  it('rejects unknown or inactive packages', () => {
    const db = createSeedDatabase()
    const userId = db.users[0]!.id
    expect(() => calculateDemoQuote(userId, 'does-not-exist', null, db)).toThrow('PACKAGE_NOT_FOUND')

    db.packages = db.packages.map((pkg) => ({ ...pkg, is_active: false }))
    expect(() => calculateDemoQuote(userId, PACKAGE_IDS.monthly, null, db)).toThrow(
      'PACKAGE_NOT_FOUND',
    )
  })

  it('exposes the seeded demo identity', () => {
    const db = createSeedDatabase()
    expect(db.users[0]!.phone).toBe(DEMO_PHONE)
    expect(db.users[0]!.phone).toMatch(/^\d{10}$/)
  })
})
