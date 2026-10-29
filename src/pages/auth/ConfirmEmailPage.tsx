import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { AlertCircle, Loader2, MailCheck } from 'lucide-react'
import { toast } from 'sonner'
import { AuthLayout } from '@/components/layout/AuthLayout'
import { Button } from '@/components/ui/Button'
import { exchangeEmailLink } from '@/lib/api/auth'
import { isProfileComplete } from '@/lib/api/profile'
import { clearPendingAuth } from '@/lib/pendingAuth'
import { toAppError } from '@/lib/errors'
import { useAuth } from '@/context/AuthProvider'

export function ConfirmEmailPage() {
  const navigate = useNavigate()
  const { reloadSession } = useAuth()
  const [error, setError] = useState<string | null>(() => {
    const params = new URLSearchParams(window.location.search)
    const linkError = params.get('error_description') ?? params.get('error')
    if (linkError) {
      return 'This confirmation link is invalid or has expired. Sign in and request a new email.'
    }
    if (!params.get('code')) {
      return 'This confirmation link is incomplete. Request a new email and try again.'
    }
    return null
  })

  useEffect(() => {
    if (error) return () => undefined
    let active = true
    const params = new URLSearchParams(window.location.search)
    const code = params.get('code')

    if (!code) return () => undefined

    void (async () => {
      try {
        await exchangeEmailLink(code)
        window.history.replaceState({}, '', '/confirm-email')
        clearPendingAuth()
        const profile = await reloadSession()
        if (!active) return
        toast.success('Email confirmed', {
          description: 'Welcome to FitDesk. Your account is ready.',
        })
        navigate(profile && isProfileComplete(profile) ? '/' : '/onboarding', {
          replace: true,
        })
      } catch (exchangeError) {
        if (!active) return
        setError(toAppError(exchangeError).message)
      }
    })()

    return () => {
      active = false
    }
  }, [error, navigate, reloadSession])

  return (
    <AuthLayout
      eyebrow="Email confirmation"
      title={error ? 'That link needs a refresh.' : 'Confirming your email…'}
      subtitle={
        error
          ? 'Confirmation links are single-use and time-limited.'
          : 'One moment while we verify your link and open your member account.'
      }
      footer={
        <p className="text-center text-[13px] text-muted">
          Need help?{' '}
          <Link
            to="/login"
            className="font-semibold text-primary-strong underline decoration-primary/30 underline-offset-4 hover:decoration-primary"
          >
            Back to sign in
          </Link>
        </p>
      }
    >
      {error ? (
        <div className="space-y-4">
          <div
            role="alert"
            className="flex items-start gap-2.5 rounded-2xl border border-danger/15 bg-danger/[0.05] px-3.5 py-3"
          >
            <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
            <p className="text-[12.5px] leading-relaxed text-danger">{error}</p>
          </div>
          <Button
            type="button"
            fullWidth
            onClick={() => navigate('/check-email', { replace: true })}
          >
            Request a new link
          </Button>
        </div>
      ) : (
        <div className="flex flex-col items-center gap-4 py-6 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-primary-soft text-primary-strong">
            <MailCheck className="h-6 w-6" />
          </div>
          <p className="flex items-center gap-2 text-[12px] text-muted">
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
            Verifying your link
          </p>
        </div>
      )}
    </AuthLayout>
  )
}
