import type { JoinRequestResult, JoinRequestRow } from '@/types'
import { toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { isDemo } from '@/lib/env'

/**
 * Gym membership join API.
 *
 * A brand-new member's profile starts with no gym. They request to join a gym
 * using the gym's join code (shared by the gym admin); the gym admin approves
 * the request from the admin website. Server-side only assignment: the member
 * can never stamp their own profile.
 */
export async function requestJoinGym(joinCode: string): Promise<JoinRequestResult> {
  if (isDemo) {
    return {
      status: 'already_member',
      gym_id: 'demo-gym',
      gym_name: 'Demo Gym',
    }
  }

  const { data, error } = await getSupabase().rpc('request_join_gym', {
    p_join_code: joinCode,
  })
  if (error) throw toAppError(error)
  if (!data) throw toAppError(new Error('JOIN_REQUEST_FAILED'))
  return data as JoinRequestResult
}

/** The signed-in member's own join-requests (their own rows only, by RLS). */
export async function getMyJoinRequests(): Promise<JoinRequestRow[]> {
  if (isDemo) {
    return [
      {
        status: 'approved',
        gym_id: 'demo-gym',
        gym_name: 'Demo Gym',
        requested_at: null,
      },
    ]
  }

  const { data, error } = await getSupabase().rpc('my_join_requests')
  if (error) throw toAppError(error)
  return (data ?? []) as JoinRequestRow[]
}
