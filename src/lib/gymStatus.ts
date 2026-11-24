import type { Announcement, GymSettings, GymStatusInfo } from '@/types'
import {
  minutesFromTimeString,
  minutesNowInKolkata,
  timeFromTimeString,
  todayInKolkata,
} from './kolkata'

/**
 * The gym's live status comes only from the admin's controls:
 *   - the shutter toggle on public.gyms (is_open), and
 *   - published closures/holidays (announcements, including the closure
 *     calendar).
 *
 * There is deliberately no weekday assumption here. A gym may be open on
 * Sundays or run 24/7; the app never closes a day on its own.
 */
export function deriveGymStatus(
  settings: GymSettings | null,
  announcements: Announcement[],
  now: Date = new Date(),
  shutterClosed = false,
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

  // The admin's manual shutter overrides published hours and announcements.
  if (shutterClosed) {
    return {
      state: 'closed',
      isOpenNow: false,
      label: 'Closed',
      detail: 'The gym shutter is currently down. Please check with the front desk.',
      hours,
      announcement: special,
      settings,
    }
  }

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
  const nowMinutes = minutesNowInKolkata(now)
  const openMinutes = minutesFromTimeString(settings.open_time)

  if (nowMinutes < openMinutes) {
    return `Opens today at ${timeFromTimeString(settings.open_time)}`
  }
  return `Opens tomorrow at ${timeFromTimeString(settings.open_time)}`
}
