import type { LeaveGymResult, Membership } from '@/types'
import { isDemo } from '@/lib/env'
import { AppError, toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { loadDemoDatabase, saveDemoDatabase } from '@/lib/demo/store'
import { requireUserId } from './session'

/**
 * Leave the current gym without deleting the FitDesk account, profile or
 * legal documents. The server unlinks the profile, deactivates that gym's
 * memberships and notifies the gym's admin.
 */
export async function leaveMyGym(): Promise<LeaveGymResult> {
  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')

    const gymId = user.profile.gym_id ?? null
    if (!gymId) return { status: 'not_in_gym' }

    user.profile.gym_id = null
    user.memberships = user.memberships.map((membership) => {
      const gymIdOnMembership = (membership as Membership & { gym_id?: string | null }).gym_id
      const status = membership.status as string
      return gymIdOnMembership === gymId && (status === 'active' || status === 'paused')
        ? { ...membership, status: 'cancelled' as typeof membership.status }
        : membership
    })
    saveDemoDatabase(db)
    return {
      status: 'left',
      gym_id: gymId,
      gym_name: db.gyms?.find((gym) => gym.id === gymId)?.name ?? 'your gym',
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('member_leave_gym')
    if (error) throw error
    if (!data) throw new Error('LEAVE_GYM_FAILED')
    return data as LeaveGymResult
  } catch (error) {
    throw toAppError(error)
  }
}
