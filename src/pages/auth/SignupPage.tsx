import { useMemo, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import {
  AlertCircle,
  ArrowRight,
  Check,
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
import { signUp } from '@/lib/api/auth'
import { getSessionPersistence } from '@/lib/supabase'
import { setPendingAuth } from '@/lib/pendingAuth'
import { toAppError } from '@/lib/errors'
import { cn } from '@/lib/utils'
import { DEMO_EMAIL } from '@/lib/demo/store'
import { useAuth } from '@/context/AuthProvider'

const schema = z
  .object({
    email: z
      .string()
      .trim()
      .toLowerCase()
      .pipe(z.email('Enter a valid email address')),
    password: z
      .string()
      .min(8, 'Use at least 8 characters')
      .regex(/[A-Za-z]/, 'Include at least one letter')
      .regex(/\d/, 'Include at least one number'),
    confirmPassword: z.string(),
    terms: z.boolean().refine((value) => value, 'Please accept the club rules to continue'),
  })
  .refine((values) => values.password === values.confirmPassword, {
    path: ['confirmPassword'],
    message: 'Passwords do not match',
  })

type FormValues = z.infer<typeof schema>

function passwordScore(password: string): number {
  let score = 0
  if (password.length >= 8) score += 1
  if (password.length >= 12) score += 1
  if (/[A-Z]/.test(password) && /[a-z]/.test(password)) score += 1
  if (/\d/.test(password) && /[^A-Za-z0-9]/.test(password)) score += 1
  return Math.min(4, score)
}

const STRENGTH_LABELS = ['Too short', 'Weak', 'Fair', 'Good', 'Strong']

export function SignupPage() {
  const navigate = useNavigate()
  const { reloadSession } = useAuth()
  const [formError, setFormError] = useState<string | null>(null)
  const [remember, setRemember] = useState(getSessionPersistence)
  const {
    register,
    handleSubmit,
    setValue,
    watch,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      email: '',
      password: '',
      confirmPassword: '',
      terms: false,
    },
  })

  const password = watch('password')
  const terms = watch('terms')
  const score = useMemo(() => passwordScore(password), [password])

  const onSubmit = async (values: FormValues) => {
    setFormError(null)
    try {
      const result = await signUp(values.email, values.password, remember)
      if (result.needsConfirmation) {
        setPendingAuth(values.email, 'signup')
        toast.success('Check your inbox', {
          description: `We sent a confirmation link to ${values.email}.`,
        })
        navigate('/check-email', { replace: true })
        return
      }
      await reloadSession()
      toast.success('Account created')
      navigate('/onboarding', { replace: true })
    } catch (error) {
      setFormError(toAppError(error).message)
    }
  }

  return (
    <AuthLayout
      eyebrow="New member"
      title="Start your FitDesk."
      subtitle="Create your member account, confirm your email, then add the details your gym needs."
      footer={
        <p className="text-center text-[13px] text-muted">
          Already a member?{' '}
          <Link
            to="/login"
            className="font-semibold text-primary-strong underline decoration-primary/30 underline-offset-4 hover:decoration-primary"
          >
            Sign in
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
          hint="We'll send a confirmation link here."
          error={errors.email?.message}
        />

        <div>
          <PasswordInput
            {...register('password')}
            label="Create password"
            placeholder="At least 8 characters"
            autoComplete="new-password"
            leading={<LockKeyhole className="h-[18px] w-[18px]" />}
            error={errors.password?.message}
          />
          {password ? (
            <div className="mt-2.5 flex items-center gap-2.5">
              <div className="flex flex-1 gap-1">
                {[0, 1, 2, 3].map((index) => (
                  <span
                    key={index}
                    className={cn(
                      'h-1 flex-1 rounded-full transition-colors',
                      index < score
                        ? score <= 1
                          ? 'bg-danger'
                          : score === 2
                            ? 'bg-warning'
                            : 'bg-success'
                        : 'bg-line',
                    )}
                  />
                ))}
              </div>
              <span className="w-20 text-right text-[10.5px] font-medium text-muted">
                {STRENGTH_LABELS[score]}
              </span>
            </div>
          ) : null}
        </div>

        <PasswordInput
          {...register('confirmPassword')}
          label="Confirm password"
          placeholder="Re-enter your password"
          autoComplete="new-password"
          leading={<ShieldCheck className="h-[18px] w-[18px]" />}
          error={errors.confirmPassword?.message}
        />

        <div>
          <button
            type="button"
            onClick={() =>
              setValue('terms', !terms, {
                shouldValidate: true,
                shouldDirty: true,
              })
            }
            className="flex w-full items-start gap-3 rounded-2xl border border-line/80 bg-surface p-3.5 text-left transition hover:border-primary/30"
            aria-pressed={terms}
          >
            <span
              className={cn(
                'mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-md border transition',
                terms
                  ? 'border-primary bg-primary text-primary-ink'
                  : 'border-line bg-elevated',
              )}
            >
              {terms ? <Check className="h-3.5 w-3.5" strokeWidth={3} /> : null}
            </span>
            <span className="text-[12px] leading-relaxed text-muted">
              I agree to the club rules, privacy policy, and to receive service emails for
              account confirmation and renewal reminders.
            </span>
          </button>
          {errors.terms?.message ? (
            <p className="mt-2 text-xs font-medium text-danger">{errors.terms.message}</p>
          ) : null}
        </div>

        <Toggle
          id="remember-signup"
          checked={remember}
          onChange={setRemember}
          label="Keep me signed in"
          description="Recommended on your personal phone"
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
          {isSubmitting ? 'Creating account…' : 'Create account'}
        </Button>
      </form>

      {isDemo ? (
        <div className="mt-6 flex items-start gap-2.5 rounded-2xl border border-dashed border-warning/35 bg-warning/[0.05] p-4">
          <Sparkles className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
          <p className="text-[11.5px] leading-relaxed text-muted">
            Demo mode: no email is sent. Register with <span className="font-semibold text-ink">{DEMO_EMAIL}</span>{' '}
            or any email, then confirm it from the next screen.
          </p>
        </div>
      ) : null}
    </AuthLayout>
  )
}
