import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { AlertCircle, ArrowRight, KeyRound, Loader2, ShieldCheck } from 'lucide-react'
import { toast } from 'sonner'
import { AuthLayout } from '@/components/layout/AuthLayout'
import { PasswordInput } from '@/components/ui/Input'
import { Button } from '@/components/ui/Button'
import { exchangeEmailLink, getStoredUserId, startDemoPasswordReset, updatePassword } from '@/lib/api/auth'
import {
  clearPendingAuth,
  clearRecoverySession,
  getPendingAuth,
  hasRecoverySession,
  markRecoverySession,
} from '@/lib/pendingAuth'
import { getSessionPersistence } from '@/lib/supabase'
import { isDemo } from '@/lib/env'
import { toAppError } from '@/lib/errors'
import { useAuth } from '@/context/AuthProvider'

const schema = z
  .object({
    password: z
      .string()
      .min(8, 'Use at least 8 characters')
      .regex(/[A-Za-z]/, 'Include at least one letter')
      .regex(/\d/, 'Include at least one number'),
    confirmPassword: z.string(),
  })
  .refine((values) => values.password === values.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords do not match',
  })

type FormValues = z.infer<typeof schema>

type Phase = 'checking' | 'ready' | 'invalid'

export function ResetPasswordPage() {
  const navigate = useNavigate()
  const { signOutMember } = useAuth()
  const [pending] = useState(() => getPendingAuth())
  const [phase, setPhase] = useState<Phase>('checking')
  const [linkError, setLinkError] = useState<string | null>(null)
  const [formError, setFormError] = useState<string | null>(null)
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { password: '', confirmPassword: '' },
  })

  useEffect(() => {
    let active = true

    const invalid = (message: string) => {
      if (!active) return
      setLinkError(message)
      setPhase('invalid')
    }

    void (async () => {
      const params = new URLSearchParams(window.location.search)
      const linkErrorParam = params.get('error_description') ?? params.get('error')
      const code = params.get('code')

      if (linkErrorParam) {
        invalid('This password reset link is invalid or has expired. Request a new one.')
        return
      }

      if (isDemo) {
        const demoPending = getPendingAuth()
        if (!demoPending || demoPending.flow !== 'reset') {
          invalid('Open the demo reset link from the forgot-password screen first.')
          return
        }
        try {
          await startDemoPasswordReset(demoPending.email, getSessionPersistence())
          markRecoverySession()
          if (active) setPhase('ready')
        } catch (error) {
          invalid(toAppError(error).message)
        }
        return
      }

      if (code) {
        try {
          await exchangeEmailLink(code)
          if (!active) return
          window.history.replaceState({}, '', '/reset-password')
          markRecoverySession()
          setPhase('ready')
        } catch (error) {
          invalid(toAppError(error).message)
        }
        return
      }

      if (hasRecoverySession()) {
        const userId = await getStoredUserId()
        if (userId) {
          if (active) setPhase('ready')
          return
        }
      }

      invalid('This page needs a valid password reset link. Request a new one below.')
    })()

    return () => {
      active = false
    }
  }, [])

  const onSubmit = async (values: FormValues) => {
    setFormError(null)
    try {
      await updatePassword(values.password)
      clearPendingAuth()
      clearRecoverySession()
      await signOutMember()
      toast.success('Password updated', {
        description: 'Sign in with your new password.',
      })
      navigate('/login', { replace: true })
    } catch (error) {
      setFormError(toAppError(error).message)
    }
  }

  if (phase === 'checking') {
    return (
      <AuthLayout
        eyebrow="Password reset"
        title="Opening your secure link…"
        subtitle="One moment while we verify the reset link."
      >
        <div className="flex flex-col items-center gap-4 py-6 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-primary-soft text-primary-strong">
            <Loader2 className="h-6 w-6 animate-spin" />
          </div>
          <p className="text-[12px] text-muted">Checking your recovery session</p>
        </div>
      </AuthLayout>
    )
  }

  if (phase === 'invalid') {
    return (
      <AuthLayout
        eyebrow="Password reset"
        title="This link won't work."
        subtitle="Reset links are single-use, time-limited, and tied to the browser that requested them."
        footer={
          <p className="text-center text-[13px] text-muted">
            Remembered your password?{' '}
            <Link
              to="/login"
              className="font-semibold text-primary-strong underline decoration-primary/30 underline-offset-4 hover:decoration-primary"
            >
              Back to sign in
            </Link>
          </p>
        }
      >
        <div className="space-y-4">
          <div
            role="alert"
            className="flex items-start gap-2.5 rounded-2xl border border-danger/15 bg-danger/[0.05] px-3.5 py-3"
          >
            <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
            <p className="text-[12.5px] leading-relaxed text-danger">
              {linkError ?? 'Request a new password reset link to continue.'}
            </p>
          </div>
          <Button
            type="button"
            fullWidth
            onClick={() => navigate('/forgot-password', { replace: true })}
          >
            Request a new link
          </Button>
        </div>
      </AuthLayout>
    )
  }

  return (
    <AuthLayout
      eyebrow="Choose a new password"
      title="Fresh password, fresh start."
      subtitle={
        pending?.email
          ? `Your email ${pending.email} is verified. Set a new password for your FitDesk account.`
          : 'Set a new password for your FitDesk account.'
      }
      footer={
        <p className="text-center text-[10.5px] leading-relaxed text-faint">
          You'll be signed out once the password is updated and asked to sign in again.
        </p>
      }
    >
      <form onSubmit={handleSubmit(onSubmit)} className="space-y-5" noValidate>
        <PasswordInput
          {...register('password')}
          label="New password"
          placeholder="At least 8 characters"
          autoComplete="new-password"
          leading={<KeyRound className="h-[18px] w-[18px]" />}
          hint="Use a mix of letters and numbers. Avoid your email address."
          error={errors.password?.message}
        />

        <PasswordInput
          {...register('confirmPassword')}
          label="Confirm new password"
          placeholder="Re-enter your new password"
          autoComplete="new-password"
          leading={<ShieldCheck className="h-[18px] w-[18px]" />}
          error={errors.confirmPassword?.message}
        />

        {formError ? (
          <div
            role="alert"
            className="flex items-start gap-2.5 rounded-2xl border border-danger/15 bg-danger/[0.05] px-3.5 py-3"
          >
            <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
            <p className="text-[12.5px] leading-relaxed text-danger">{formError}</p>
          </div>
        ) : null}

        <Button
          type="submit"
          size="lg"
          fullWidth
          loading={isSubmitting}
          trailingIcon={<ArrowRight className="h-4 w-4" />}
        >
          {isSubmitting ? 'Updating password…' : 'Update password'}
        </Button>
      </form>
    </AuthLayout>
  )
}
