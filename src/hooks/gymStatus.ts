import { useAuth } from '@/context/AuthProvider'

/**
 * Which gym the signed-in member belongs to, from their server-side profile.
 * Admin assignment stamps `profiles.gym_id`; null means "not approved yet".
 */
export function useGymStatus() {
  const { profile, profileLoading } = useAuth()
  return {
    gymId: profile?.gym_id ?? null,
    loading: profileLoading && profileLoading,
  }
}
