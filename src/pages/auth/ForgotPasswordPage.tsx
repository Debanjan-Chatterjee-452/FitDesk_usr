import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { AlertCircle, ArrowRight, MessageSquareText, ShieldQuestion } from 'lucide-react'
import { toast } from 'sonner'
import { AuthLayout } from '@/components/layout/AuthLayout'
import { Input } from '@/components/ui/Input'
import { Button } from '@/components/ui/Button'
import { requestPasswordReset } from '@/lib/api/auth'
import { setPendingAuth } from '@/lib/pendingAuth'
import { toAppError } from '@/lib/errors'

const schema = z.object({
  email: z
    .string()
    .trim()
    .toLowerCase()
    .pipe(z.email('Enter the email address on your membership')),
})

type FormValues = z.infer<typeof schema>

export function ForgotPasswordPage() {
  const navigate = useNavigate()
  const [formError, setFormError] = useState<string | null>(null)
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { email: '' },
  })

  const onSubmit = async (values: FormValues) => {
    setFormError(null)
    try {
      await requestPasswordReset(values.email)
      setPendingAuth(values.email, 'reset')
      toast.success('Check your inbox', {
        description: `If an account exists for ${values.email}, we sent a password reset link.`,
      })
      navigate('/check-email', { replace: true })
    } catch (error) {
      setFormError(toAppError(error).message)
    }
  }

  return (
    <AuthLayout
      eyebrow="Account recovery"
      title="Let's get you back in."
      subtitle="Enter the email registered at the club. We'll send a secure link to reset your password."
      footer={
        <p className="text-center text-[13px] text-muted">
          Remembered it?{' '}
          <Link
            to="/login"
            className="font-semibold text-primary-strong underline decoration-primary/30 underline-offset-4 hover:decoration-primary"
          >
            Back to sign in
          </Link>
        </p>
      }
    >
      <form onSubmit={handleSubmit(onSubmit)} className="space-y-5" noValidate>
        <Input
          {...register('email')}
          type="email"
          label="Registered email address"
          placeholder="you@example.com"
          inputMode="email"
          autoComplete="email"
          leading={<span className="text-[13px] font-semibold text-muted">@</span>}
          hint="The same email you use to sign in."
          error={errors.email?.message}
        />

        <div className="rounded-2xl border border-line/80 bg-elevated/60 p-4">
          <div className="flex items-start gap-2.5">
            <ShieldQuestion className="mt-0.5 h-4 w-4 shrink-0 text-primary-strong" />
            <div>
              <p className="text-[12px] font-semibold text-ink">Keep it secure</p>
              <p className="mt-1 text-[11.5px] leading-relaxed text-muted">
                FitDesk will never ask for your password over a call or message. If your
                email has changed, visit the front desk with an ID.
              </p>
            </div>
          </div>
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
          {isSubmitting ? 'Sending link…' : 'Send reset link'}
        </Button>

        <p className="flex items-center justify-center gap-1.5 text-center text-[10.5px] text-faint">
          <MessageSquareText className="h-3.5 w-3.5" />
          The link expires after a short time for your security.
        </p>
      </form>
    </AuthLayout>
  )
}
