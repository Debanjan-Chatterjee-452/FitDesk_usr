import type { Announcement, GymSettings, GymStatusInfo } from '@/types'
import { isDemo } from '@/lib/env'
import { toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { deriveGymStatus } from '@/lib/gymStatus'
import { todayInKolkata } from '@/lib/kolkata'
import { loadDemoDatabase } from '@/lib/demo/store'

export interface GymOverview {
  settings: GymSettings | null
  announcements: Announcement[]
}

export async function getGymOverview(): Promise<GymOverview> {
  if (isDemo) {
    const db = loadDemoDatabase()
    const today = todayInKolkata()
    return {
      settings: db.settings,
      announcements: db.announcements
        .filter(
          (item) =>
            item.is_active &&
            item.starts_on <= today &&
            (!item.ends_on || item.ends_on >= today),
        )
        .sort((a, b) => (a.created_at < b.created_at ? 1 : -1)),
    }
  }

  try {
    const today = todayInKolkata()
    const client = getSupabase()
    const [settingsResult, announcementsResult] = await Promise.all([
      client.from('gym_settings').select('*').eq('id', 1).maybeSingle(),
      client
        .from('announcements')
        .select('*')
        .eq('is_active', true)
        .lte('starts_on', today)
        .order('created_at', { ascending: false })
        .limit(20),
    ])
    if (settingsResult.error) throw settingsResult.error
    if (announcementsResult.error) throw announcementsResult.error

    const announcements = ((announcementsResult.data ?? []) as Announcement[]).filter(
      (item) => !item.ends_on || item.ends_on >= today,
    )

    return {
      settings: (settingsResult.data as GymSettings | null) ?? null,
      announcements,
    }
  } catch (error) {
    throw toAppError(error)
  }
}

export function getGymStatusFromOverview(overview: GymOverview, now: Date = new Date()): GymStatusInfo {
  return deriveGymStatus(overview.settings, overview.announcements, now)
}
