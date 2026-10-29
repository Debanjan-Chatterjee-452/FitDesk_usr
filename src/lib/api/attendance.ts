import type { AttendanceRecord, AttendanceStats, CheckInResult } from '@/types'
import { isDemo } from '@/lib/env'
import { AppError, toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { addDaysToDate, monthKeyInKolkata, todayInKolkata } from '@/lib/kolkata'
import { DEMO_GYM_TOKEN, loadDemoDatabase, saveDemoDatabase } from '@/lib/demo/store'
import { requireUserId } from './session'

export async function getMyAttendance(limit = 180): Promise<AttendanceRecord[]> {
  if (isDemo) {
    const userId = await requireUserId()
    const user = loadDemoDatabase().users.find((item) => item.id === userId)
    if (!user) return []
    return [...user.attendance]
      .sort((a, b) => (a.check_in_at < b.check_in_at ? 1 : -1))
      .slice(0, limit)
  }

  try {
    const userId = await requireUserId()
    const { data, error } = await getSupabase()
      .from('attendance')
      .select('*')
      .eq('user_id', userId)
      .order('check_in_at', { ascending: false })
      .limit(limit)
    if (error) throw error
    return (data ?? []) as AttendanceRecord[]
  } catch (error) {
    throw toAppError(error)
  }
}

export async function checkInWithQr(token: string): Promise<CheckInResult> {
  const trimmed = token.trim()
  if (!trimmed) throw new AppError('INVALID_QR', 'This QR code is empty. Try scanning again.')

  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    if (!trimmed.toUpperCase().startsWith(DEMO_GYM_TOKEN.slice(0, 12))) {
      throw new AppError(
        'INVALID_QR',
        "That doesn't look like a FitDesk gym code. Try scanning the code at the front desk.",
      )
    }

    const today = todayInKolkata()
    const activeMembership = user.memberships
      .filter(
        (item) =>
          item.status !== 'cancelled' && item.starts_on <= today && item.ends_on >= today,
      )
      .sort((a, b) => (a.ends_on < b.ends_on ? 1 : -1))[0]
    if (!activeMembership) {
      throw new AppError(
        'MEMBERSHIP_INACTIVE',
        'Your membership is not active. Renew your plan to check in.',
      )
    }

    const closed = db.announcements.find(
      (item) =>
        item.is_active &&
        (item.kind === 'closure' || item.kind === 'holiday') &&
        item.starts_on <= today &&
        (!item.ends_on || item.ends_on >= today),
    )
    if (closed) {
      throw new AppError('GYM_CLOSED', 'The gym is closed today. Check the home screen for announcements.')
    }

    const existing = user.attendance.find((item) => item.check_in_date === today)
    if (existing) {
      return {
        status: 'already_checked_in',
        attendance_id: existing.id,
        check_in_at: existing.check_in_at,
        check_in_date: existing.check_in_date,
        gym_name: db.settings.name,
        message: 'You already checked in today. One scan per day is enough.',
      }
    }

    const now = new Date().toISOString()
    const record: AttendanceRecord = {
      id: crypto.randomUUID(),
      user_id: userId,
      check_in_at: now,
      check_in_date: today,
      source: 'qr',
      gym_qr_id: null,
      created_at: now,
    }
    user.attendance.push(record)
    saveDemoDatabase(db)

    return {
      status: 'checked_in',
      attendance_id: record.id,
      check_in_at: record.check_in_at,
      check_in_date: record.check_in_date,
      gym_name: db.settings.name,
      message: "You're in. Have a strong session.",
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('check_in_with_qr', {
      p_token: trimmed,
    })
    if (error) throw error
    if (!data) throw new AppError('UNKNOWN', 'Check-in could not be recorded. Please try again.')
    return data as CheckInResult
  } catch (error) {
    throw toAppError(error)
  }
}

export function computeAttendanceStats(
  records: AttendanceRecord[],
  now: Date = new Date(),
): AttendanceStats {
  const today = todayInKolkata(now)
  const monthKey = monthKeyInKolkata(now)
  const sorted = [...records].sort((a, b) =>
    a.check_in_at < b.check_in_at ? 1 : -1,
  )
  const dateSet = new Set(records.map((item) => item.check_in_date))
  const checkedInToday = dateSet.has(today)

  let cursor = checkedInToday ? today : addDaysToDate(today, -1)
  let streak = 0
  // A streak stays alive until the end of today if the member checked in
  // yesterday but has not checked in yet today.
  while (dateSet.has(cursor)) {
    streak += 1
    cursor = addDaysToDate(cursor, -1)
  }

  return {
    total: records.length,
    thisMonth: records.filter((item) => item.check_in_date.startsWith(monthKey)).length,
    streak,
    lastCheckIn: sorted[0] ?? null,
    checkedInToday,
  }
}
