import { describe, expect, it } from 'vitest'
import {
  addDaysToDate,
  ageFromDob,
  calendarDaysForMonth,
  countdownTo,
  daysBetween,
  daysUntil,
  formatKolkata,
  formatKolkataDateTime,
  kolkataWeekday,
  monthKeyInKolkata,
  monthLabel,
  msUntilExpiry,
  relativeDayLabel,
  shiftMonth,
  timeFromTimeString,
  todayInKolkata,
} from './kolkata'

/** 27 Oct 2026, 12:00 IST. */
const NOON_IST = new Date('2026-10-27T06:30:00.000Z')

describe('todayInKolkata', () => {
  it('rolls over at IST midnight, not UTC midnight', () => {
    expect(todayInKolkata(new Date('2026-10-27T18:29:59.999Z'))).toBe('2026-10-27')
    expect(todayInKolkata(new Date('2026-10-27T18:30:00.000Z'))).toBe('2026-10-28')
    expect(todayInKolkata(new Date('2026-10-27T00:00:00.000Z'))).toBe('2026-10-27')
  })
})

describe('daysBetween and daysUntil', () => {
  it('counts whole calendar days across months and years', () => {
    expect(daysBetween('2026-10-27', '2026-10-27')).toBe(0)
    expect(daysBetween('2026-10-27', '2026-10-28')).toBe(1)
    expect(daysBetween('2026-10-28', '2026-10-27')).toBe(-1)
    expect(daysBetween('2026-02-28', '2026-03-01')).toBe(1)
    expect(daysBetween('2024-02-28', '2024-03-01')).toBe(2)
    expect(daysBetween('2026-12-31', '2027-01-01')).toBe(1)
  })

  it('measures remaining days from the IST calendar day', () => {
    expect(daysUntil('2026-10-27', NOON_IST)).toBe(0)
    expect(daysUntil('2026-10-30', NOON_IST)).toBe(3)
    expect(daysUntil('2026-10-24', NOON_IST)).toBe(-3)
    // 18:29 UTC is still 27 Oct in IST.
    expect(daysUntil('2026-10-28', new Date('2026-10-27T18:29:00.000Z'))).toBe(1)
    // 18:30 UTC is already 28 Oct in IST.
    expect(daysUntil('2026-10-28', new Date('2026-10-27T18:30:00.000Z'))).toBe(0)
  })
})

describe('addDaysToDate', () => {
  it('crosses month and year boundaries without drift', () => {
    expect(addDaysToDate('2026-10-27', 5)).toBe('2026-11-01')
    expect(addDaysToDate('2026-12-31', 1)).toBe('2027-01-01')
    expect(addDaysToDate('2026-03-01', -1)).toBe('2026-02-28')
    expect(addDaysToDate('2024-03-01', -1)).toBe('2024-02-29')
    expect(addDaysToDate('2026-10-27', 0)).toBe('2026-10-27')
  })
})

describe('expiry countdown', () => {
  it('runs to the end of the expiry day in IST', () => {
    const total = msUntilExpiry('2026-10-27', NOON_IST)
    expect(total).toBe(11 * 60 * 60 * 1000 + 59 * 60 * 1000 + 59 * 1000 + 999)
    expect(countdownTo('2026-10-27', NOON_IST)).toMatchObject({
      days: 0,
      hours: 11,
      minutes: 59,
    })
  })

  it('never goes negative once the day has ended', () => {
    expect(msUntilExpiry('2026-10-26', NOON_IST)).toBe(0)
    expect(countdownTo('2026-10-26', NOON_IST)).toMatchObject({
      days: 0,
      hours: 0,
      minutes: 0,
      totalMs: 0,
    })
  })
})

describe('relativeDayLabel', () => {
  it('labels recent days in IST', () => {
    expect(relativeDayLabel('2026-10-27', NOON_IST)).toBe('Today')
    expect(relativeDayLabel('2026-10-26', NOON_IST)).toBe('Yesterday')
    expect(relativeDayLabel('2026-10-28', NOON_IST)).toBe('Tomorrow')
    expect(relativeDayLabel('2026-10-25', NOON_IST)).toBe('Sunday')
    expect(relativeDayLabel('2026-10-23', NOON_IST)).toBe('Friday')
    expect(relativeDayLabel('2026-10-20', NOON_IST)).toBe('20 Oct')
    expect(relativeDayLabel('2026-09-27', NOON_IST)).toBe('27 Sep')
  })
})

describe('ageFromDob', () => {
  it('turns over on the birthday in IST', () => {
    expect(ageFromDob('1996-04-18', new Date('2026-04-17T06:30:00.000Z'))).toBe(29)
    expect(ageFromDob('1996-04-18', new Date('2026-04-18T06:30:00.000Z'))).toBe(30)
    expect(ageFromDob('1996-04-18', new Date('2026-04-18T18:29:00.000Z'))).toBe(30)
    expect(ageFromDob('1996-04-18', new Date('2026-04-18T18:30:00.000Z'))).toBe(30)
  })
})

describe('calendar helpers', () => {
  it('builds a padded, seven-column month grid', () => {
    const days = calendarDaysForMonth('2026-10')
    expect(days.slice(0, 4)).toEqual([null, null, null, null])
    expect(days[4]).toBe('2026-10-01')
    expect(days[34]).toBe('2026-10-31')
    expect(days).toHaveLength(35)
  })

  it('handles leap February and months starting on Sunday', () => {
    expect(calendarDaysForMonth('2024-02').filter(Boolean)).toHaveLength(29)
    expect(calendarDaysForMonth('2026-03')[0]).toBe('2026-03-01')
  })

  it('shifts months across year boundaries', () => {
    expect(shiftMonth('2026-10', 1)).toBe('2026-11')
    expect(shiftMonth('2026-01', -1)).toBe('2025-12')
    expect(shiftMonth('2026-12', 1)).toBe('2027-01')
    expect(monthLabel('2026-10')).toBe('October 2026')
  })
})

describe('IST weekdays and clock helpers', () => {
  it('maps IST weekdays with Sunday as 0', () => {
    expect(kolkataWeekday('2026-10-25')).toBe(0)
    expect(kolkataWeekday('2026-10-26')).toBe(1)
    expect(kolkataWeekday('2026-10-27')).toBe(2)
    expect(kolkataWeekday('2026-10-31')).toBe(6)
    // 18:30 UTC on Saturday is already Sunday in IST.
    expect(kolkataWeekday(new Date('2026-10-31T18:30:00.000Z'))).toBe(0)
  })

  it('formats stored time strings as 12-hour IST times', () => {
    expect(timeFromTimeString('05:00')).toBe('5:00 AM')
    expect(timeFromTimeString('12:00')).toBe('12:00 PM')
    expect(timeFromTimeString('00:00')).toBe('12:00 AM')
    expect(timeFromTimeString('23:05')).toBe('11:05 PM')
    expect(timeFromTimeString('')).toBe('—')
    expect(timeFromTimeString(null)).toBe('—')
  })

  it('formats instants in IST', () => {
    expect(formatKolkata('2026-10-27T18:30:00.000Z', 'd MMM yyyy')).toBe('28 Oct 2026')
    expect(formatKolkataDateTime('2026-10-27T00:00:00.000Z')).toBe('27 Oct 2026, 5:30 AM')
    expect(formatKolkata(null)).toBe('—')
    expect(monthKeyInKolkata(NOON_IST)).toBe('2026-10')
  })
})
