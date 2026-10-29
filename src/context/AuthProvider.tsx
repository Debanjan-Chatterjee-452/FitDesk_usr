import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { useQueryClient } from '@tanstack/react-query'
import type { Profile } from '@/types'
import { getMyProfile, isProfileComplete } from '@/lib/api/profile'
import {
  getStoredUserId,
  signOut as signOutApi,
  subscribeToAuthChanges,
} from '@/lib/api/auth'
import { toAppError } from '@/lib/errors'
import { clearAuthStorage } from '@/lib/supabase'

export type AuthStatus = 'loading' | 'authenticated' | 'unauthenticated'

interface AuthContextValue {
  status: AuthStatus
  userId: string | null
  profile: Profile | null
  profileLoading: boolean
  profileError: string | null
  isProfileComplete: boolean
  refreshProfile: () => Promise<Profile | null>
  reloadSession: () => Promise<Profile | null>
  signOutMember: () => Promise<void>
  clearProfileError: () => void
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()
  const [status, setStatus] = useState<AuthStatus>('loading')
  const [userId, setUserId] = useState<string | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [profileLoading, setProfileLoading] = useState(false)
  const [profileError, setProfileError] = useState<string | null>(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const loadProfile = useCallback(async (): Promise<Profile | null> => {
    setProfileLoading(true)
    setProfileError(null)
    try {
      const next = await getMyProfile()
      if (mountedRef.current) setProfile(next)
      return next
    } catch (error) {
      const appError = toAppError(error)
      if (mountedRef.current) {
        setProfileError(appError.message)
        if (appError.code === 'AUTH_REQUIRED') {
          setProfile(null)
          setUserId(null)
          setStatus('unauthenticated')
          clearAuthStorage()
        }
      }
      return null
    } finally {
      if (mountedRef.current) setProfileLoading(false)
    }
  }, [])

  const reloadSession = useCallback(async (): Promise<Profile | null> => {
    const id = await getStoredUserId()
    if (!id) {
      setUserId(null)
      setProfile(null)
      setStatus('unauthenticated')
      return null
    }
    setUserId(id)
    setStatus('authenticated')
    return loadProfile()
  }, [loadProfile])

  const refreshProfile = useCallback(async (): Promise<Profile | null> => {
    if (!userId) return null
    return loadProfile()
  }, [userId, loadProfile])

  useEffect(() => {
    let active = true
    void (async () => {
      const id = await getStoredUserId()
      if (!active) return
      if (id) {
        setUserId(id)
        setStatus('authenticated')
        await loadProfile()
      } else {
        setStatus('unauthenticated')
      }
    })()

    const unsubscribe = subscribeToAuthChanges((nextUserId) => {
      if (!active) return
      if (nextUserId) {
        setUserId(nextUserId)
        setStatus('authenticated')
        void loadProfile()
      } else {
        setUserId(null)
        setProfile(null)
        setProfileError(null)
        setStatus('unauthenticated')
        queryClient.clear()
      }
    })

    return () => {
      active = false
      unsubscribe()
    }
  }, [loadProfile, queryClient])

  const signOutMember = useCallback(async () => {
    try {
      await signOutApi()
    } finally {
      clearAuthStorage()
      setUserId(null)
      setProfile(null)
      setProfileError(null)
      setStatus('unauthenticated')
      queryClient.clear()
    }
  }, [queryClient])

  const clearProfileError = useCallback(() => setProfileError(null), [])

  const value = useMemo<AuthContextValue>(
    () => ({
      status,
      userId,
      profile,
      profileLoading,
      profileError,
      isProfileComplete: isProfileComplete(profile),
      refreshProfile,
      reloadSession,
      signOutMember,
      clearProfileError,
    }),
    [
      status,
      userId,
      profile,
      profileLoading,
      profileError,
      refreshProfile,
      reloadSession,
      signOutMember,
      clearProfileError,
    ],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth must be used inside AuthProvider')
  return context
}
