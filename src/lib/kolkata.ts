import { formatInTimeZone } from 'date-fns-tz'
import { TIMEZONE } from './env'

const IST_SUFFIX = '+05:30'

/** Today's calendar date in Asia/Kolkata, as `yyyy-MM-dd`. */
export function todayInKolkata(now: Date = new Date()): string {
  return formatInTimeZone(now, TIMEZONE, 'yyyy-MM-dd')
}

/** Format an instant or date string in the gym's timezone. */
export function formatKolkata(
  value: Date | string | null | undefined,
  pattern = 'd MMM yyyy',
): string {
  if (!value) return '—'
  const date = typeof value === 'string' ? parseDate(value) : value
  if (!date || Number.isNaN(date.getTime())) return '—'
  return formatInTimeZone(date, TIMEZONE, pattern)
}

export function formatKolkataTime(value: Date | string | null | undefined): string {
  return formatKolkata(value, 'h:mm a')
}

export function formatKolkataDateTime(value: Date | string | null | undefined): string {
  return formatKolkata(value, 'd MMM yyyy, h:mm a')
}

/**
 * Accepts either an ISO timestamp or a plain `yyyy-MM-dd` date. Plain dates are
 * anchored to midday IST so they never drift a day when converted.
 */
export function parseDate(value: string): Date | null {
  if (!value) return null
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return new Date(`${value}T12:00:00${IST_SUFFIX}`)
  }
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? null : date
}

/** Midnight at the start of an IST calendar day. */
export function startOfKolkataDay(date: string): Date {
  return new Date(`${date}T00:00:00${IST_SUFFIX}`)
}

/** Last millisecond of an IST calendar day. */
export function endOfKolkataDay(date: string): Date {
  return new Date(`${date}T23:59:59.999${IST_SUFFIX}`)
}

/** Whole calendar days from `from` to `to` (both `yyyy-MM-dd`). */
export function daysBetween(from: string, to: string): number {
  const a = Date.UTC(Number(from.slice(0, 4)), Number(from.slice(5, 7)) - 1, Number(from.slice(8, 10)))
  const b = Date.UTC(Number(to.slice(0, 4)), Number(to.slice(5, 7)) - 1, Number(to.slice(8, 10)))
  return Math.round((b - a) / 86_400_000)
}

/** Calendar days remaining until an expiry date (today = 0, yesterday = -1). */
export function daysUntil(date: string, now: Date = new Date()): number {
  return daysBetween(todayInKolkata(now), date)
}

export function addDaysToDate(date: string, days: number): string {
  const base = parseDate(date)
  if (!base) return date
  const next = new Date(base.getTime() + days * 86_400_000)
  return todayInKolkata(next)
}

/** Milliseconds remaining until the end of the IST expiry day. */
export function msUntilExpiry(expiryDate: string, now: Date = new Date()): number {
  return Math.max(0, endOfKolkataDay(expiryDate).getTime() - now.getTime())
}

export interface Countdown {
  days: number
  hours: number
  minutes: number
  totalMs: number
}

export function countdownTo(expiryDate: string, now: Date = new Date()): Countdown {
  const totalMs = msUntilExpiry(expiryDate, now)
  const days = Math.floor(totalMs / 86_400_000)
  const hours = Math.floor((totalMs % 86_400_000) / 3_600_000)
  const minutes = Math.floor((totalMs % 3_600_000) / 60_000)
  return { days, hours, minutes, totalMs }
}

export function relativeDayLabel(date: string, now: Date = new Date()): string {
  // Positive means the date is in the future.
  const diff = daysBetween(todayInKolkata(now), date)
  if (diff === 0) return 'Today'
  if (diff === -1) return 'Yesterday'
  if (diff === 1) return 'Tomorrow'
  if (diff < -1 && diff > -7) return formatKolkata(date, 'EEEE')
  if (diff > 1 && diff < 7) return formatKolkata(date, 'EEEE')
  return formatKolkata(date, 'd MMM')
}

export function ageFromDob(dob: string, now: Date = new Date()): number {
  const birth = parseDate(dob)
  if (!birth) return 0
  const today = parseDate(todayInKolkata(now))
  if (!today) return 0
  let age = today.getUTCFullYear() - birth.getUTCFullYear()
  const monthDiff = today.getUTCMonth() - birth.getUTCMonth()
  if (monthDiff < 0 || (monthDiff === 0 && today.getUTCDate() < birth.getUTCDate())) {
    age -= 1
  }
  return age
}

export function greetingForKolkata(now: Date = new Date()): string {
  const hour = Number(formatInTimeZone(now, TIMEZONE, 'H'))
  if (hour < 5) return 'Still up'
  if (hour < 12) return 'Good morning'
  if (hour < 17) return 'Good afternoon'
  if (hour < 21) return 'Good evening'
  return 'Good night'
}

export function timeFromTimeString(value: string | null | undefined): string {
  if (!value) return '—'
  const [hourRaw, minuteRaw] = value.split(':')
  const hour = Number(hourRaw)
  const minute = Number(minuteRaw)
  if (Number.isNaN(hour) || Number.isNaN(minute)) return value
  const suffix = hour >= 12 ? 'PM' : 'AM'
  const displayHour = hour % 12 === 0 ? 12 : hour % 12
  return `${displayHour}:${String(minute).padStart(2, '0')} ${suffix}`
}

/** 0 = Sunday … 6 = Saturday, evaluated in IST. */
export function kolkataWeekday(date: string | Date = new Date()): number {
  if (typeof date === 'string') {
    const parsed = parseDate(date)
    return parsed ? Number(formatInTimeZone(parsed, TIMEZONE, 'i')) % 7 : 0
  }
  return Number(formatInTimeZone(date, TIMEZONE, 'i')) % 7
}

export function minutesFromTimeString(value: string): number {
  const [hourRaw, minuteRaw] = value.split(':')
  return Number(hourRaw) * 60 + Number(minuteRaw)
}

export function minutesNowInKolkata(now: Date = new Date()): number {
  const hh = Number(formatInTimeZone(now, TIMEZONE, 'H'))
  const mm = Number(formatInTimeZone(now, TIMEZONE, 'm'))
  return hh * 60 + mm
}

export function monthKeyInKolkata(now: Date = new Date()): string {
  return formatInTimeZone(now, TIMEZONE, 'yyyy-MM')
}

export function monthLabel(monthKey: string): string {
  return formatKolkata(`${monthKey}-01`, 'MMMM yyyy')
}

export function shiftMonth(monthKey: string, delta: number): string {
  const [year, month] = monthKey.split('-').map(Number)
  const date = new Date(Date.UTC(year, month - 1 + delta, 1))
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, '0')}`
}

export function calendarDaysForMonth(monthKey: string): Array<string | null> {
  const [year, month] = monthKey.split('-').map(Number)
  const firstWeekday = new Date(Date.UTC(year, month - 1, 1)).getUTCDay()
  const totalDays = new Date(Date.UTC(year, month, 0)).getUTCDate()
  const cells: Array<string | null> = Array.from({ length: firstWeekday }, () => null)
  for (let day = 1; day <= totalDays; day += 1) {
    cells.push(`${monthKey}-${String(day).padStart(2, '0')}`)
  }
  while (cells.length % 7 !== 0) cells.push(null)
  return cells
}
