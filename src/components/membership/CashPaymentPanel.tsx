import { useEffect, useMemo, useState } from 'react'
import {
  AlertCircle,
  BadgeCheck,
  Banknote,
  Clock3,
  Loader2,
  RefreshCw,
  ShieldCheck,
  Wallet,
  XCircle,
} from 'lucide-react'
import { toast } from 'sonner'
import type { PaymentVerification } from '@/types'
import { Button } from '@/components/ui/Button'
import { ErrorState } from '@/components/ui/ErrorState'
import { OtpInput } from '@/components/ui/OtpInput'
import { Skeleton } from '@/components/ui/Skeleton'
import { useCashPayment, useNow, useRequestCashPayment, useVerifyCashOtp } from '@/hooks/queries'
import { toAppError } from '@/lib/errors'
import { formatKolkata } from '@/lib/kolkata'
import { cn, formatDuration, formatINR } from '@/lib/utils'

interface CashPaymentPanelProps {
  paymentId: string
  packageId: string
  durationDays?: number | null
  isNewAdmission?: boolean
  onVerified: (verification: PaymentVerification) => void
  onBack: () => void
}

/**
 * Cash payment screen.
 *
 * The one-time code is generated when the member requests cash and is shown to
 * the gym only. The member hands over the cash, hears the 6-digit code from the
 * front desk, and types it here. A valid code activates the plan immediately.
 */
export function CashPaymentPanel({
  paymentId,
  packageId,
  durationDays,
  isNewAdmission,
  onVerified,
  onBack,
}: CashPaymentPanelProps) {
  const cashQuery = useCashPayment(paymentId)
  const verifyOtp = useVerifyCashOtp()
  const requestCash = useRequestCashPayment()
  const now = useNow(1000)
  const [otp, setOtp] = useState('')
  const [formError, setFormError] = useState<string | null>(null)

  const data = cashQuery.data

  useEffect(() => {
    if (!data) return
    if (data.payment_state === 'AWAITING_CASH' && !data.otp_expires_at) {
      // The code lapsed while the member was away. Re-open the window once so
      // they are not stuck, but never in a tight loop.
      void requestCash
        .mutateAsync({ packageId, durationDays, isNewAdmission })
        .catch(() => undefined)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data?.payment_id, data?.payment_state, data?.otp_expires_at])

  const secondsLeft = useMemo(() => {
    if (!data?.otp_expires_at) return 0
    return Math.max(0, Math.ceil((new Date(data.otp_expires_at).getTime() - now.getTime()) / 1000))
  }, [data?.otp_expires_at, now])

  const expired = Boolean(data?.otp_expires_at) && secondsLeft <= 0
  const canRequestNew = !data?.otp_expires_at || expired

  const handleVerify = async () => {
    if (otp.length !== 6) return
    setFormError(null)
    try {
      const result = await verifyOtp.mutateAsync({ paymentId, otp })
      setOtp('')
      toast.success('Cash payment confirmed', {
        description: `${result.package_name} is now active.`,
      })
      onVerified(result)
    } catch (error) {
      setFormError(toAppError(error).message)
    }
  }

  const handleNewCode = async () => {
    setFormError(null)
    try {
      await requestCash.mutateAsync({ packageId, durationDays, isNewAdmission })
      setOtp('')
      toast.success('New code requested', {
        description: 'Ask the front desk to read out the new 6-digit code.',
      })
      void cashQuery.refetch()
    } catch (error) {
      setFormError(toAppError(error).message)
    }
  }

  if (cashQuery.isLoading) {
    return (
      <div className="space-y-4" role="status" aria-live="polite">
        <div className="flex items-center gap-2 text-[11px] text-muted">
          <Loader2 className="h-3.5 w-3.5 animate-spin" />
          Loading your cash request…
        </div>
        <Skeleton className="h-24 rounded-2xl" />
        <Skeleton className="h-40 rounded-2xl" />
      </div>
    )
  }

  if (cashQuery.isError) {
    return (
      <ErrorState
        title="Could not load this cash request"
        message={toAppError(cashQuery.error).message}
        onRetry={() => void cashQuery.refetch()}
      />
    )
  }

  if (!data) {
    return (
      <ErrorState
        title="This cash request is unavailable"
        message="Please start the renewal again."
        onRetry={() => void cashQuery.refetch()}
      />
    )
  }

  if (data.payment_state === 'VERIFIED') {
    return (
      <div className="space-y-4">
        <StateCard
          tone="success"
          icon={<BadgeCheck className="h-4 w-4" />}
          title="Cash payment confirmed"
          body={`The front desk code was accepted. Your ${data.package_name} plan is active.`}
        >
          <DetailRow label="Gym" value={data.gym_name ?? 'Your gym'} />
          <DetailRow
            label="Valid"
            value={
              data.starts_on && data.ends_on
                ? `${formatKolkata(data.starts_on, 'd MMM yyyy')} – ${formatKolkata(data.ends_on, 'd MMM yyyy')}`
                : 'Confirmed by the gym'
            }
          />
          <DetailRow label="Receipt" value="View only · in payment history" />
        </StateCard>
        <Button fullWidth onClick={onBack}>
          Done
        </Button>
      </div>
    )
  }

  if (data.payment_state === 'FAILED' || data.payment_state === 'CANCELLED') {
    return (
      <div className="space-y-4">
        <StateCard
          tone="danger"
          icon={<XCircle className="h-4 w-4" />}
          title="This cash payment was not completed"
          body="No plan was activated. If you already handed over cash, speak to the front desk."
        />
        <Button fullWidth onClick={onBack}>
          Choose a plan
        </Button>
      </div>
    )
  }

  if (data.payment_state === 'RECONCILIATION') {
    return (
      <div className="space-y-4">
        <StateCard
          tone="warning"
          icon={<AlertCircle className="h-4 w-4" />}
          title="This payment needs the front desk"
          body="The gym has to check this record before it can be completed. Your current plan is unchanged."
        />
        <Button variant="secondary" fullWidth onClick={onBack}>
          Close
        </Button>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="rounded-2xl border border-line/80 bg-surface p-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
              Cash payment
            </p>
            <p className="mt-0.5 truncate text-[13px] font-semibold text-ink">
              {data.gym_name ?? 'Your gym'}
            </p>
            <p className="mt-0.5 text-[10.5px] text-muted">
              {data.package_name} · {formatDuration(data.duration_days)}
            </p>
          </div>
          <div className="text-right">
            <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
              Pay at desk
            </p>
            <p className="display-number text-[22px] leading-tight text-ink">
              {formatINR(data.amount_inr)}
            </p>
          </div>
        </div>
      </div>

      <div className="rounded-2xl border border-primary/15 bg-primary-soft/40 p-4">
        <div className="flex items-center gap-2 text-primary-strong">
          <Banknote className="h-4 w-4" />
          <p className="text-[12px] font-semibold">Hand the cash to the front desk</p>
        </div>
        <ol className="mt-2.5 space-y-1.5 text-[10.5px] leading-relaxed text-muted">
          <li>1. Pay {formatINR(data.amount_inr)} in cash to the gym staff.</li>
          <li>2. They will read out a 6-digit confirmation code.</li>
          <li>3. Type that code below — your plan starts immediately.</li>
        </ol>
      </div>

      {expired ? (
        <div className="rounded-2xl border border-warning/25 bg-warning/[0.05] p-4">
          <div className="flex items-start gap-2.5">
            <Clock3 className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
            <div>
              <p className="text-[12px] font-semibold text-ink">The last code expired</p>
              <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
                Codes last 5 minutes. Request a fresh one and ask the staff to read it out again.
              </p>
            </div>
          </div>
        </div>
      ) : (
        <div className="flex items-center justify-between gap-3 rounded-2xl border border-line/80 bg-elevated/40 px-3.5 py-2.5">
          <span className="flex items-center gap-1.5 text-[10.5px] text-muted">
            <Clock3 className="h-3.5 w-3.5" />
            Code from the desk expires in
          </span>
          <span className="font-mono text-[12px] font-semibold tabular-nums text-ink">
            {formatCountdown(secondsLeft)}
          </span>
        </div>
      )}

      <div className="rounded-2xl border border-line/80 bg-surface p-4">
        <p className="text-[12px] font-semibold text-ink">Enter the 6-digit code</p>
        <p className="mt-0.5 text-[10.5px] text-muted">
          The code is shown to the gym staff, not sent to your phone.
        </p>

        <div className="mt-3">
          <OtpInput
            value={otp}
            onChange={(value) => {
              setOtp(value)
              if (formError) setFormError(null)
            }}
            length={6}
            disabled={verifyOtp.isPending}
            autoFocus
          />
        </div>

        <Button
          type="button"
          className="mt-3"
          size="lg"
          fullWidth
          onClick={() => void handleVerify()}
          loading={verifyOtp.isPending}
          disabled={otp.length !== 6}
          leadingIcon={!verifyOtp.isPending ? <ShieldCheck className="h-4 w-4" /> : undefined}
        >
          {verifyOtp.isPending ? 'Checking…' : 'Confirm cash payment'}
        </Button>

        {formError ? (
          <p className="mt-2 flex items-start gap-1.5 text-[10px] leading-relaxed text-danger">
            <AlertCircle className="mt-0.5 h-3 w-3 shrink-0" />
            {formError}
          </p>
        ) : null}

        {canRequestNew ? (
          <Button
            type="button"
            variant="ghost"
            fullWidth
            className="mt-2"
            onClick={() => void handleNewCode()}
            loading={requestCash.isPending}
            leadingIcon={!requestCash.isPending ? <RefreshCw className="h-3.5 w-3.5" /> : undefined}
          >
            Request a new code
          </Button>
        ) : (
          <p className="mt-2 text-center text-[9.5px] leading-relaxed text-faint">
            You can request a new code once this one expires.
          </p>
        )}
      </div>

      <div className="flex items-start gap-2 rounded-2xl border border-line/80 bg-elevated/40 p-3.5">
        <Wallet className="mt-0.5 h-3.5 w-3.5 shrink-0 text-primary-strong" />
        <p className="text-[10px] leading-relaxed text-muted">
          Nothing is charged from the app. The gym collects the cash in person and confirms it with
          the code.
        </p>
      </div>

      <Button variant="ghost" fullWidth onClick={onBack}>
        Pay later
      </Button>
    </div>
  )
}

function formatCountdown(totalSeconds: number): string {
  const safe = Math.max(0, totalSeconds)
  const minutes = Math.floor(safe / 60)
  const seconds = safe % 60
  return `${minutes}:${String(seconds).padStart(2, '0')}`
}

function StateCard({
  tone,
  icon,
  title,
  body,
  children,
}: {
  tone: 'success' | 'warning' | 'danger'
  icon: React.ReactNode
  title: string
  body: string
  children?: React.ReactNode
}) {
  return (
    <div
      className={cn(
        'rounded-2xl border p-4',
        tone === 'success' && 'border-success/20 bg-success/[0.04]',
        tone === 'warning' && 'border-warning/25 bg-warning/[0.05]',
        tone === 'danger' && 'border-danger/20 bg-danger/[0.05]',
      )}
      role="status"
    >
      <div className="flex items-start gap-2.5">
        <span
          className={cn(
            'mt-0.5 shrink-0',
            tone === 'success' && 'text-success',
            tone === 'warning' && 'text-warning',
            tone === 'danger' && 'text-danger',
          )}
        >
          {icon}
        </span>
        <div className="min-w-0">
          <p className="text-[12.5px] font-semibold text-ink">{title}</p>
          <p className="mt-1 text-[10.5px] leading-relaxed text-muted">{body}</p>
        </div>
      </div>
      {children ? <div className="mt-3 space-y-1.5 border-t border-line/60 pt-3">{children}</div> : null}
    </div>
  )
}

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-[10px] text-muted">{label}</span>
      <span className="text-right text-[10.5px] font-semibold text-ink">{value}</span>
    </div>
  )
}
