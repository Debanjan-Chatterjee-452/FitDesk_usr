import { describe, expect, it } from 'vitest'
import { addDaysToDate, todayInKolkata } from './kolkata'
import { buildExpiryWarning } from './expiryWarning'

const NOW = new Date('2026-10-30T10:00:00+05:30')
const TODAY = todayInKolkata(NOW)

function warningForOffset(offset: number) {
  return buildExpiryWarning({ endsOn: addDaysToDate(TODAY, offset), now: NOW })
}

describe('active membership warnings', () => {
  it('shows the exact 3-day reminder', () => {
    expect(warningForOffset(3)).toMatchObject({
      tone: 'reminder',
      message: 'Reminder: Your membership expires in 3 days.',
      fine: 0,
    })
  })

  it('shows the exact 1-day reminder', () => {
    expect(warningForOffset(1)).toMatchObject({
      tone: 'reminder',
      message: 'Reminder: Your membership expires tomorrow. Renew now to avoid interruption.',
    })
  })

  it('shows a reminder on the expiry day itself', () => {
    const warning = warningForOffset(0)
    expect(warning?.tone).toBe('reminder')
    expect(warning?.message).toContain('expires today')
  })

  it('is hidden once more than 3 days remain', () => {
    expect(warningForOffset(4)).toBeNull()
    expect(warningForOffset(30)).toBeNull()
  })

  it('is hidden with no plan, a cancelled plan, or an approved renewal queued', () => {
    expect(buildExpiryWarning({ endsOn: '', now: NOW })).toBeNull()
    expect(
      buildExpiryWarning({
        endsOn: addDaysToDate(TODAY, -9),
        now: NOW,
        isCancelled: true,
      }),
    ).toBeNull()
    expect(
      buildExpiryWarning({
        endsOn: addDaysToDate(TODAY, 2),
        now: NOW,
        hasUpcomingPlan: true,
      }),
    ).toBeNull()
  })
})

describe('expired membership warnings', () => {
  it('shows the exact day-7 warning', () => {
    expect(warningForOffset(-7)).toMatchObject({
      tone: 'warning',
      message:
        'Warning: Your membership expired 7 days ago. A ₹50 fine will be added to your renewal starting tomorrow.',
      fine: 0,
    })
  })

  it('shows the exact day-8 overdue notice', () => {
    expect(warningForOffset(-8)).toMatchObject({
      tone: 'danger',
      message: 'Overdue: A ₹50 fine has been added to your renewal fee.',
      fine: 50,
    })
  })

  it('shows the exact day-9+ overdue notice', () => {
    expect(warningForOffset(-9)).toMatchObject({
      tone: 'danger',
      message:
        'Overdue: A ₹50 fine plus an additional ₹5 daily late fee is being applied to your renewal.',
      fine: 55,
    })
    expect(warningForOffset(-30)?.fine).toBe(160)
  })

  it('stays calm and fee-free inside the grace period', () => {
    for (const offset of [-1, -2, -5, -6]) {
      const warning = warningForOffset(offset)
      expect(warning?.tone, `offset ${offset}`).toBe('warning')
      expect(warning?.fine, `offset ${offset}`).toBe(0)
      expect(warning?.message, `offset ${offset}`).toContain('grace period')
    }
  })
})

describe('timezone boundary', () => {
  it('treats 00:05 IST as the new Kolkata day, not the previous UTC day', () => {
    const justAfterMidnight = new Date('2026-10-31T00:05:00+05:30')
    // 2026-10-30T18:35Z — still 30 Oct in UTC, already 31 Oct in Kolkata.
    expect(justAfterMidnight.toISOString()).toBe('2026-10-30T18:35:00.000Z')

    const warning = buildExpiryWarning({ endsOn: '2026-10-31', now: justAfterMidnight })
    expect(warning?.message).toContain('expires today')
  })
})
