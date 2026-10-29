import type { Announcement, GymSettings, GymStatusInfo } from '@/types'
import {
  kolkataWeekday,
  minutesFromTimeString,
  minutesNowInKolkata,
  timeFromTimeString,
  todayInKolkata,
} from './kolkata'

const WEEKDAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

export function deriveGymStatus(
  settings: GymSettings | null,
  announcements: Announcement[],
  now: Date = new Date(),
): GymStatusInfo {
  const today = todayInKolkata(now)
  const activeToday = announcements.filter(
    (item) =>
      item.is_active &&
      item.starts_on <= today &&
      (!item.ends_on || item.ends_on >= today),
  )
  const closure = activeToday.find((item) => item.kind === 'closure') ?? null
  const holiday = activeToday.find((item) => item.kind === 'holiday') ?? null
  const special = closure ?? holiday

  const hours = settings
    ? `${timeFromTimeString(settings.open_time)} – ${timeFromTimeString(settings.close_time)}`
    : 'Hours unavailable'

  if (!settings) {
    return {
      state: 'closed',
      isOpenNow: false,
      label: 'Status unavailable',
      detail: 'Gym hours have not been published yet.',
      hours,
      announcement: special,
      settings,
    }
  }

  if (special) {
    const state = special.kind === 'closure' ? 'closed' : 'holiday'
    return {
      state,
      isOpenNow: false,
      label: special.kind === 'closure' ? 'Closed' : 'Holiday',
      detail: special.title,
      hours,
      announcement: special,
      settings,
    }
  }

  const weekday = kolkataWeekday(now)
  const weeklyOff = settings.closed_weekdays.includes(weekday)
  if (weeklyOff) {
    return {
      state: 'closed',
      isOpenNow: false,
      label: 'Closed today',
      detail: `${WEEKDAY_NAMES[weekday]} is the weekly off. ${nextOpeningLabel(settings, now)}`,
      hours,
      announcement: null,
      settings,
    }
  }

  const openMinutes = minutesFromTimeString(settings.open_time)
  const closeMinutes = minutesFromTimeString(settings.close_time)
  const nowMinutes = minutesNowInKolkata(now)
  const isOpenNow =
    closeMinutes > openMinutes
      ? nowMinutes >= openMinutes && nowMinutes < closeMinutes
      : nowMinutes >= openMinutes || nowMinutes < closeMinutes

  if (!isOpenNow) {
    return {
      state: 'closed',
      isOpenNow: false,
      label: 'Closed',
      detail: nextOpeningLabel(settings, now),
      hours,
      announcement: null,
      settings,
    }
  }

  return {
    state: 'open',
    isOpenNow: true,
    label: 'Open now',
    detail: `Closes at ${timeFromTimeString(settings.close_time)}`,
    hours,
    announcement: null,
    settings,
  }
}

function nextOpeningLabel(settings: GymSettings, now: Date): string {
  const today = todayInKolkata(now)
  const nowMinutes = minutesNowInKolkata(now)
  const openMinutes = minutesFromTimeString(settings.open_time)
  const weekday = kolkataWeekday(now)

  if (!settings.closed_weekdays.includes(weekday) && nowMinutes < openMinutes) {
    return `Opens today at ${timeFromTimeString(settings.open_time)}`
  }

  const parsed = new Date(`${today}T12:00:00+05:30`)
  for (let offset = 1; offset <= 7; offset += 1) {
    const next = new Date(parsed.getTime() + offset * 86_400_000)
    const nextWeekday = kolkataWeekday(next)
    if (settings.closed_weekdays.includes(nextWeekday)) continue
    if (offset === 1) return `Opens tomorrow at ${timeFromTimeString(settings.open_time)}`
    return `Opens ${WEEKDAY_NAMES[nextWeekday]} at ${timeFromTimeString(settings.open_time)}`
  }
  return 'Check back soon'
}
