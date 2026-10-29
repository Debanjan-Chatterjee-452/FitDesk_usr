import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { LogOut } from 'lucide-react'
import { useAuth } from '@/context/AuthProvider'
import { FullScreenLoader } from '@/components/ui/FullScreenLoader'
import { ErrorState } from '@/components/ui/ErrorState'
import { Button } from '@/components/ui/Button'
import { Logo } from '@/components/ui/Logo'
import { isProfileComplete } from '@/lib/api/profile'

export function PublicOnly() {
  const { status, profile, profileLoading, isProfileComplete: completed } = useAuth()

  if (status === 'loading') return <FullScreenLoader label="Checking your session" />
  if (status === 'authenticated') {
    if (profileLoading && !profile) return <FullScreenLoader label="Loading your profile" />
    if (profile && completed) return <Navigate to="/" replace />
    if (profile && !completed) return <Navigate to="/onboarding" replace />
    return <Navigate to="/" replace />
  }
  return <Outlet />
}

export function RequireSession() {
  const { status } = useAuth()
  const location = useLocation()

  if (status === 'loading') return <FullScreenLoader label="Checking your session" />
  if (status === 'unauthenticated') {
    return <Navigate to="/login" replace state={{ from: location.pathname }} />
  }
  return <Outlet />
}

export function RequireCompleteProfile() {
  const {
    profile,
    profileLoading,
    profileError,
    isProfileComplete: completed,
    refreshProfile,
    signOutMember,
  } = useAuth()

  if (profileLoading && !profile) return <FullScreenLoader label="Loading your profile" />

  if (!profile) {
    return (
      <div className="relative flex min-h-[100svh] flex-col items-center justify-center gap-6 px-5">
        <Logo />
        <div className="w-full max-w-md">
          <ErrorState
            title="Your profile is taking a break"
            message={
              profileError ??
              'We could not load your member profile. Check your connection and try again.'
            }
            onRetry={() => void refreshProfile()}
            retryLabel="Reload profile"
          />
          <div className="mt-3 flex items-center justify-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => void signOutMember()}
              leadingIcon={<LogOut className="h-3.5 w-3.5" />}
            >
              Sign out
            </Button>
          </div>
        </div>
      </div>
    )
  }

  const complete = completed || isProfileComplete(profile)
  if (!complete) return <Navigate to="/onboarding" replace />
  return <Outlet />
}

/** Only Admin-role profiles may open the payment approval queue. */
export function RequireAdmin() {
  const { profile, profileLoading } = useAuth()

  if (profileLoading && !profile) {
    return <FullScreenLoader label="Checking admin access" />
  }
  if (!profile?.is_admin) return <Navigate to="/" replace />
  return <Outlet />
}
