import type { Announcement, GymSettings, GymStatusInfo } from '@/types'
import { isDemo } from '@/lib/env'
import { toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { deriveGymStatus } from '@/lib/gymStatus'
import { todayInKolkata } from '@/lib/kolkata'
import { loadDemoDatabase } from '@/lib/demo/store'

export interface GymOverview {
  status: 'active' | 'suspended' | 'no_gym'
  gymId: string | null
  gymName: string | null
  isOpen: boolean
  settings: GymSettings | null
  announcements: Announcement[]
}

export async function getGymOverview(): Promise<GymOverview> {
  if (isDemo) {
    const db = loadDemoDatabase()
    const today = todayInKolkata()
    return {
      status: 'active',
      gymId: db.settings ? (db.settings as GymSettings).gym_id ?? null : null,
      gymName: db.settings?.name ?? 'FitDesk',
      isOpen: true,
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
    const { data, error } = await client.rpc('member_gym_overview')
    if (error) throw error

    const overview = (data ?? {}) as {
      status?: string
      gym_id?: string | null
      gym_name?: string | null
      is_open?: boolean
      settings?: GymSettings | null
      announcements?: Announcement[] | null
    }

    const announcements = ((overview.announcements ?? []) as Announcement[]).filter(
      (item) => !item.ends_on || item.ends_on >= today,
    )

    return {
      status: (overview.status as GymOverview['status']) ?? 'no_gym',
      gymId: overview.gym_id ?? null,
      gymName: overview.gym_name ?? null,
      isOpen: overview.is_open ?? true,
      settings: (overview.settings as GymSettings | null) ?? null,
      announcements,
    }
  } catch (error) {
    throw toAppError(error)
  }
}

export function getGymStatusFromOverview(overview: GymOverview, now: Date = new Date()): GymStatusInfo {
  return deriveGymStatus(overview.settings, overview.announcements, now)
}
