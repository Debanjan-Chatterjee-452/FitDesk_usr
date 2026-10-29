import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import {
  AlertCircle,
  ArrowRight,
  Fingerprint,
  LockKeyhole,
  ShieldCheck,
  Sparkles,
} from 'lucide-react'
import { toast } from 'sonner'
import { AuthLayout } from '@/components/layout/AuthLayout'
import { Input, PasswordInput } from '@/components/ui/Input'
import { Toggle } from '@/components/ui/Toggle'
import { Button } from '@/components/ui/Button'
import { isDemo } from '@/lib/env'
import { signIn } from '@/lib/api/auth'
import { getSessionPersistence } from '@/lib/supabase'
import { isProfileComplete } from '@/lib/api/profile'
import { toAppError } from '@/lib/errors'
import { DEMO_EMAIL, DEMO_PASSWORD } from '@/lib/demo/store'
import { useAuth } from '@/context/AuthProvider'

const schema = z.object({
  email: z
    .string()
    .trim()
    .toLowerCase()
    .pipe(z.email('Enter a valid email address')),
  password: z.string().min(8, 'Password must be at least 8 characters'),
})

type FormValues = z.infer<typeof schema>

export function LoginPage() {
  const navigate = useNavigate()
  const { reloadSession } = useAuth()
  const [remember, setRemember] = useState(getSessionPersistence)
  const [formError, setFormError] = useState<string | null>(null)
  const {
    register,
    handleSubmit,
    setValue,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { email: '', password: '' },
  })

  const onSubmit = async (values: FormValues) => {
    setFormError(null)
    try {
      await signIn(values.email, values.password, remember)
      const profile = await reloadSession()
      toast.success('Welcome back', {
        description: 'Your training desk is ready.',
      })
      navigate(profile && isProfileComplete(profile) ? '/' : '/onboarding', {
        replace: true,
      })
    } catch (error) {
      setFormError(toAppError(error).message)
    }
  }

  const fillDemo = () => {
    setValue('email', DEMO_EMAIL, { shouldValidate: true })
    setValue('password', DEMO_PASSWORD, { shouldValidate: true })
  }

  return (
    <AuthLayout
      eyebrow="Member access"
      title="Welcome back."
      subtitle="Sign in with the email address registered at the club."
      footer={
        <p className="text-center text-[13px] text-muted">
          New to FitDesk?{' '}
          <Link
            to="/signup"
            className="font-semibold text-primary-strong underline decoration-primary/30 underline-offset-4 hover:decoration-primary"
          >
            Create your account
          </Link>
        </p>
      }
    >
      <form onSubmit={handleSubmit(onSubmit)} className="space-y-5" noValidate>
        <Input
          {...register('email')}
          type="email"
          label="Email address"
          placeholder="you@example.com"
          inputMode="email"
          autoComplete="email"
          leading={<span className="text-[13px] font-semibold text-muted">@</span>}
          hint="The email you use for your FitDesk membership."
          error={errors.email?.message}
        />

        <PasswordInput
          {...register('password')}
          label="Password"
          placeholder="Enter your password"
          autoComplete="current-password"
          leading={<LockKeyhole className="h-[18px] w-[18px]" />}
          error={errors.password?.message}
        />

        <div className="flex items-center justify-between gap-3 pt-0.5">
          <Toggle
            id="remember"
            checked={remember}
            onChange={setRemember}
            label="Keep me signed in"
            description={remember ? 'Stay signed in on this device' : 'Sign out when the tab closes'}
            className="flex-1"
          />
          <Link
            to="/forgot-password"
            className="shrink-0 text-[12px] font-semibold text-primary-strong underline decoration-primary/25 underline-offset-4 transition hover:decoration-primary"
          >
            Forgot?
          </Link>
        </div>

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
          {isSubmitting ? 'Signing in…' : 'Sign in'}
        </Button>

        <div className="flex items-center justify-center gap-4 pt-1 text-[10.5px] font-medium text-faint">
          <span className="inline-flex items-center gap-1.5">
            <ShieldCheck className="h-3.5 w-3.5" />
            Encrypted session
          </span>
          <span className="h-3 w-px bg-line" />
          <span className="inline-flex items-center gap-1.5">
            <Fingerprint className="h-3.5 w-3.5" />
            Private by default
          </span>
        </div>
      </form>

      {isDemo ? (
        <div className="mt-7 rounded-2xl border border-dashed border-warning/35 bg-warning/[0.05] p-4">
          <div className="flex items-center gap-2">
            <Sparkles className="h-4 w-4 text-warning" />
            <p className="text-[12px] font-semibold text-ink">Demo workspace</p>
          </div>
          <p className="mt-1.5 text-[11.5px] leading-relaxed text-muted">
            Explore the full member journey with sample data. Use{' '}
            <span className="font-semibold text-ink">{DEMO_EMAIL}</span> and password{' '}
            <span className="font-semibold text-ink">{DEMO_PASSWORD}</span>.
          </p>
          <Button
            type="button"
            variant="secondary"
            size="sm"
            className="mt-3"
            onClick={fillDemo}
          >
            Use demo account
          </Button>
        </div>
      ) : null}
    </AuthLayout>
  )
}
