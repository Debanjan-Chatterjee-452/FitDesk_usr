import { useEffect, useMemo, useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { AlertCircle, ArrowRight, MailCheck, RotateCw, Sparkles } from 'lucide-react'
import { toast } from 'sonner'
import { AuthLayout } from '@/components/layout/AuthLayout'
import { Button } from '@/components/ui/Button'
import { isDemo } from '@/lib/env'
import {
  confirmDemoEmail,
  resendConfirmationEmail,
  requestPasswordReset,
  startDemoPasswordReset,
} from '@/lib/api/auth'
import { isProfileComplete } from '@/lib/api/profile'
import { getSessionPersistence } from '@/lib/supabase'
import {
  getPendingAuth,
  markRecoverySession,
} from '@/lib/pendingAuth'
import { toAppError } from '@/lib/errors'
import { useAuth } from '@/context/AuthProvider'

export function CheckEmailPage() {
  const navigate = useNavigate()
  const { reloadSession } = useAuth()
  const pending = useMemo(() => getPendingAuth(), [])
  const [resendIn, setResendIn] = useState(30)
  const [resending, setResending] = useState(false)
  const [demoWorking, setDemoWorking] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (resendIn <= 0) return
    const timer = window.setTimeout(() => setResendIn((value) => value - 1), 1000)
    return () => window.clearTimeout(timer)
  }, [resendIn])

  if (!pending) {
    return <Navigate to="/login" replace />
  }

  const isReset = pending.flow === 'reset'

  const handleResend = async () => {
    if (resendIn > 0 || resending) return
    setResending(true)
    setError(null)
    try {
      if (isReset) {
        await requestPasswordReset(pending.email)
      } else {
        await resendConfirmationEmail(pending.email)
      }
      setResendIn(30)
      toast.success('Email sent', {
        description: `Check ${pending.email} for the latest link.`,
      })
    } catch (resendError) {
      setError(toAppError(resendError).message)
    } finally {
      setResending(false)
    }
  }

  const handleDemoAction = async () => {
    setDemoWorking(true)
    setError(null)
    try {
      if (isReset) {
        await startDemoPasswordReset(pending.email, getSessionPersistence())
        markRecoverySession()
        toast.success('Demo reset link opened')
        navigate('/reset-password', { replace: true })
        return
      }

      await confirmDemoEmail(pending.email, getSessionPersistence())
      const profile = await reloadSession()
      toast.success('Email confirmed', {
        description: 'Your FitDesk account is ready.',
      })
      navigate(profile && isProfileComplete(profile) ? '/' : '/onboarding', {
        replace: true,
      })
    } catch (demoError) {
      setError(toAppError(demoError).message)
    } finally {
      setDemoWorking(false)
    }
  }

  return (
    <AuthLayout
      eyebrow={isReset ? 'Password recovery' : 'Confirm your email'}
      title="Check your inbox."
      subtitle={
        isReset
          ? `If an account exists for ${pending.email}, we sent a password reset link.`
          : `We sent a confirmation link to ${pending.email}. Open it to activate your FitDesk account.`
      }
      footer={
        <p className="text-center text-[13px] text-muted">
          Wrong email?{' '}
          <Link
            to={isReset ? '/forgot-password' : '/signup'}
            className="font-semibold text-primary-strong underline decoration-primary/30 underline-offset-4 hover:decoration-primary"
          >
            {isReset ? 'Try another address' : 'Start again'}
          </Link>
        </p>
      }
    >
      <div className="space-y-6">
        <div className="flex items-start gap-3 rounded-2xl border border-line/80 bg-surface px-4 py-3.5">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-primary-soft text-primary-strong">
            <MailCheck className="h-[19px] w-[19px]" />
          </div>
          <div className="min-w-0">
            <p className="text-[12.5px] font-semibold text-ink">
              {isReset ? 'Reset link sent' : 'Confirmation link sent'}
            </p>
            <p className="mt-1 text-[11.5px] leading-relaxed text-muted">
              The link can only be used once. Open it on this device and browser for the
              smoothest experience.
            </p>
          </div>
        </div>

        {error ? (
          <div
            role="alert"
            className="flex items-start gap-2.5 rounded-2xl border border-danger/15 bg-danger/[0.05] px-3.5 py-3"
          >
            <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
            <p className="text-[12.5px] leading-relaxed text-danger">{error}</p>
          </div>
        ) : null}

        <div className="flex items-center justify-between gap-3">
          <p className="text-[12px] text-muted">
            {resendIn > 0 ? `Resend available in ${resendIn}s` : "Didn't get the email?"}
          </p>
          <button
            type="button"
            onClick={handleResend}
            disabled={resendIn > 0 || resending}
            className="inline-flex items-center gap-1.5 text-[12px] font-semibold text-primary-strong transition disabled:cursor-not-allowed disabled:text-faint"
          >
            <RotateCw className={`h-3.5 w-3.5 ${resending ? 'animate-spin' : ''}`} />
            {resending ? 'Sending…' : isReset ? 'Resend reset link' : 'Resend email'}
          </button>
        </div>

        <Button
          type="button"
          variant="secondary"
          fullWidth
          onClick={() => navigate('/login', { replace: true })}
          trailingIcon={<ArrowRight className="h-4 w-4" />}
        >
          Back to sign in
        </Button>

        {isDemo ? (
          <div className="rounded-2xl border border-dashed border-warning/35 bg-warning/[0.05] p-4">
            <div className="flex items-start gap-2.5">
              <Sparkles className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
              <div className="min-w-0">
                <p className="text-[11.5px] leading-relaxed text-muted">
                  Demo mode does not send email. Open the{' '}
                  {isReset ? 'demo reset link' : 'demo confirmation link'} for{' '}
                  <span className="font-semibold text-ink">{pending.email}</span>.
                </p>
                <Button
                  type="button"
                  size="sm"
                  className="mt-3"
                  loading={demoWorking}
                  onClick={handleDemoAction}
                >
                  {isReset ? 'Open demo reset link' : 'Confirm email (demo)'}
                </Button>
              </div>
            </div>
          </div>
        ) : null}
      </div>
    </AuthLayout>
  )
}
