import { useEffect, useRef, useState, type ReactNode } from 'react'
import {
  AlertCircle,
  ArrowLeft,
  BadgeCheck,
  BadgeIndianRupee,
  Check,
  CheckCircle2,
  Clock3,
  Copy,
  Info,
  Loader2,
  QrCode,
  ShieldCheck,
  Smartphone,
  XCircle,
} from 'lucide-react'
import { toast } from 'sonner'
import type { PaymentVerification } from '@/types'
import { Button } from '@/components/ui/Button'
import { ErrorState } from '@/components/ui/ErrorState'
import { Input } from '@/components/ui/Input'
import { Skeleton } from '@/components/ui/Skeleton'
import { useSubmitUpiReference, useUpiPaymentInstructions } from '@/hooks/queries'
import { toAppError } from '@/lib/errors'
import { formatKolkata } from '@/lib/kolkata'
import { copyText } from '@/lib/upi/clipboard'
import { UpiQrCode } from '@/components/membership/UpiQrCode'
import {
  buildUpiUri,
  isValidUpiReference,
  normalizeUpiReference,
} from '@/lib/upi/upi'
import { cn, formatDuration, formatINR } from '@/lib/utils'

interface UpiPaymentPanelProps {
  paymentId: string
  /** The quote total shown on the review step, from the same server RPC. */
  expectedAmount: number
  onSubmitted: (verification: PaymentVerification) => void
  onBack: () => void
}

type CopyTarget = 'upi' | 'amount' | null

/**
 * The direct-UPI payment screen.
 *
 * Everything rendered here comes from `get_my_upi_payment`, which is scoped to
 * the signed-in member's own payment. The amount, the recipient and the gym are
 * never taken from the browser.
 */
export function UpiPaymentPanel({
  paymentId,
  expectedAmount,
  onSubmitted,
  onBack,
}: UpiPaymentPanelProps) {
  const instructionsQuery = useUpiPaymentInstructions(paymentId)
  const submitReference = useSubmitUpiReference()
  const [reference, setReference] = useState('')
  const [formError, setFormError] = useState<string | null>(null)
  const [launchHint, setLaunchHint] = useState(false)
  const [copied, setCopied] = useState<CopyTarget>(null)
  const copiedTimer = useRef<number | null>(null)

  useEffect(() => {
    return () => {
      if (copiedTimer.current) window.clearTimeout(copiedTimer.current)
    }
  }, [])

  const data = instructionsQuery.data

  const copy = async (target: Exclude<CopyTarget, null>, value: string) => {
    const ok = await copyText(value)
    if (!ok) {
      toast.error('Could not copy automatically', {
        description: 'Select the text and copy it manually.',
      })
      return
    }
    setCopied(target)
    if (copiedTimer.current) window.clearTimeout(copiedTimer.current)
    copiedTimer.current = window.setTimeout(() => setCopied(null), 1800)
    toast.success(target === 'upi' ? 'UPI ID copied' : 'Amount copied')
  }

  const handleSubmitReference = async () => {
    const normalized = normalizeUpiReference(reference)
    if (!isValidUpiReference(normalized)) {
      setFormError('Enter the UPI reference (UTR) from your payment app — 6 to 40 letters or digits.')
      return
    }
    setFormError(null)
    try {
      const verification = await submitReference.mutateAsync({ paymentId, reference: normalized })
      toast.success('Payment submitted for verification', {
        description:
          'The gym will match your reference against their bank statement before activating the plan.',
      })
      onSubmitted(verification)
    } catch (error) {
      setFormError(toAppError(error).message)
    }
  }

  if (instructionsQuery.isLoading) {
    return (
      <div className="space-y-4" role="status" aria-live="polite">
        <div className="flex items-center gap-2 text-[11px] text-muted">
          <Loader2 className="h-3.5 w-3.5 animate-spin" />
          Loading {`this gym's`} payment details…
        </div>
        <Skeleton className="h-[300px] rounded-3xl" />
        <Skeleton className="h-24 rounded-2xl" />
        <Skeleton className="h-16 rounded-2xl" />
      </div>
    )
  }

  if (instructionsQuery.isError) {
    const error = toAppError(instructionsQuery.error)
    return (
      <ErrorState
        title="Could not load payment details"
        message={error.message}
        onRetry={() => void instructionsQuery.refetch()}
        retryLabel="Retry"
      />
    )
  }

  if (!data) {
    return (
      <ErrorState
        title="Payment details are unavailable"
        message="We could not load the payment details for this renewal. Please try again."
        onRetry={() => void instructionsQuery.refetch()}
      />
    )
  }

  const amountMismatch =
    Number.isFinite(expectedAmount) &&
    Math.abs(expectedAmount - data.amount_inr) > 0.005

  if (amountMismatch) {
    return (
      <div className="space-y-4">
        <StateCard
          tone="warning"
          icon={<AlertCircle className="h-4 w-4" />}
          title="The amount on this payment changed"
          body={`You reviewed ${formatINR(expectedAmount)}, but the server has ${formatINR(
            data.amount_inr,
          )} for this payment. Nothing has been charged. Go back, review the new total, and start again.`}
        />
        <div className="grid gap-2">
          <Button variant="secondary" onClick={onBack} leadingIcon={<ArrowLeft className="h-4 w-4" />}>
            Back to review
          </Button>
          <Button
            variant="ghost"
            onClick={() => void instructionsQuery.refetch()}
            loading={instructionsQuery.isFetching}
          >
            Refresh payment details
          </Button>
        </div>
      </div>
    )
  }

  if (data.payment_state === 'PENDING_VERIFICATION') {
    return (
      <div className="space-y-4">
        <StateCard
          tone="warning"
          icon={<Clock3 className="h-4 w-4" />}
          title="Waiting for the gym to verify this payment"
          body={`We recorded your reference for the ${data.package_name} plan (${formatINR(
            data.amount_inr,
          )}). Your membership activates only after the gym matches it with their bank statement. Your current plan and expiry do not change until then.`}
        >
          <DetailRow label="Gym" value={data.gym_name} />
          <DetailRow label="Reference" value={data.upi_reference ?? '—'} mono />
          <DetailRow label="Submitted" value={formatKolkata(data.submitted_at, 'd MMM yyyy, h:mm a')} />
          <DetailRow label="Status" value="Pending verification" />
        </StateCard>
        <p className="text-[10.5px] leading-relaxed text-muted">
          Keep your UPI app receipt until the gym approves the payment. If the gym cannot find the
          transfer, they will contact you using the details on your account.
        </p>
        <Button variant="secondary" fullWidth onClick={onBack}>
          Back to plans
        </Button>
      </div>
    )
  }

  if (data.payment_state === 'VERIFIED') {
    return (
      <div className="space-y-4">
        <StateCard
          tone="success"
          icon={<BadgeCheck className="h-4 w-4" />}
          title="Payment verified"
          body={`The gym verified your ${formatINR(data.amount_inr)} payment. Your ${data.package_name} plan is active.`}
        >
          <DetailRow label="Gym" value={data.gym_name} />
          <DetailRow
            label="Valid"
            value={
              data.starts_on && data.ends_on
                ? `${formatKolkata(data.starts_on, 'd MMM yyyy')} – ${formatKolkata(data.ends_on, 'd MMM yyyy')}`
                : 'Confirmed by the gym'
            }
          />
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
          tone={data.payment_state === 'FAILED' ? 'danger' : 'neutral'}
          icon={data.payment_state === 'FAILED' ? <XCircle className="h-4 w-4" /> : <AlertCircle className="h-4 w-4" />}
          title={data.payment_state === 'FAILED' ? 'This payment was declined' : 'This checkout was cancelled'}
          body={
            data.payment_state === 'FAILED'
              ? 'The gym could not verify this payment. Nothing was activated. If money left your account, contact the front desk with your UPI reference for a manual refund.'
              : 'No payment was completed and no membership change was made. You can start a new renewal.'
          }
        />
        <Button fullWidth onClick={onBack}>
          Choose a plan
        </Button>
      </div>
    )
  }

  if (!data.payee.available || !data.payee.upi_id) {
    return (
      <div className="space-y-4">
        <StateCard
          tone="warning"
          icon={<AlertCircle className="h-4 w-4" />}
          title="Payment is not available for this gym yet."
          body={
            data.payee.reason === 'AMOUNT_INVALID'
              ? 'The amount on this renewal could not be confirmed, so online payment is disabled. Please renew at the front desk.'
              : data.payee.reason === 'INVALID_UPI_ID'
                ? 'This gym has not finished configuring its UPI payment details. Please pay at the front desk until the gym completes the setup.'
                : 'The gym owner has not added a UPI ID and QR code yet. Please pay at the front desk — nothing has been charged.'
          }
        />
        <div className="grid gap-2">
          <Button
            variant="secondary"
            onClick={() => void instructionsQuery.refetch()}
            loading={instructionsQuery.isFetching}
            leadingIcon={<RefreshIcon />}
          >
            Check again
          </Button>
          <Button variant="ghost" onClick={onBack}>
            Back to plans
          </Button>
        </div>
      </div>
    )
  }

  // The guard above proves the recipient is present; widen it to a plain
  // string so nothing below can silently build a URI from a missing VPA.
  const payee = { ...data.payee, upi_id: data.payee.upi_id }
  const openUpiApp = () => {
    let uri: string
    try {
      uri = buildUpiUri({
        upiId: payee.upi_id,
        payeeName: payee.name,
        amountInr: data.amount_inr,
        reference: data.reference,
        note: `${data.gym_name} membership`,
      })
    } catch {
      toast.error('These payment details are incomplete. Please pay at the front desk.')
      return
    }

    setLaunchHint(false)
    window.setTimeout(() => {
      // If the page is still visible, no app took over. Say so without claiming
      // anything happened.
      if (document.visibilityState === 'visible') setLaunchHint(true)
    }, 2200)

    try {
      window.location.href = uri
    } catch {
      setLaunchHint(true)
    }
  }

  return (
    <div className="space-y-4">
      <div className="rounded-2xl border border-line/80 bg-surface p-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
              Paying
            </p>
            <p className="mt-0.5 truncate text-[13px] font-semibold text-ink">{data.gym_name}</p>
            <p className="mt-0.5 text-[10.5px] text-muted">
              {data.package_name} · {formatDuration(data.duration_days)}
            </p>
          </div>
          <div className="text-right">
            <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
              Amount
            </p>
            <p className="display-number text-[22px] leading-tight text-ink">
              {formatINR(data.amount_inr)}
            </p>
            <button
              type="button"
              onClick={() => void copy('amount', String(data.amount_inr))}
              className="mt-1 inline-flex items-center gap-1 text-[9.5px] font-semibold text-primary-strong"
            >
              {copied === 'amount' ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />}
              {copied === 'amount' ? 'Copied' : 'Copy amount'}
            </button>
          </div>
        </div>

        <div className="mt-3 flex items-center justify-between gap-3 rounded-xl bg-elevated/60 px-3 py-2">
          <div className="min-w-0">
            <p className="text-[9px] font-semibold uppercase tracking-[0.12em] text-faint">
              Recipient UPI ID
            </p>
            <p className="truncate font-mono text-[11.5px] font-semibold text-ink">
              {payee.upi_id}
            </p>
            {payee.name ? (
              <p className="truncate text-[9.5px] text-muted">{payee.name}</p>
            ) : null}
          </div>
          <button
            type="button"
            onClick={() => void copy('upi', payee.upi_id)}
            aria-label="Copy UPI ID"
            className="flex shrink-0 items-center gap-1 rounded-full border border-line bg-surface px-2.5 py-1.5 text-[10px] font-semibold text-ink transition hover:border-primary/30"
          >
            {copied === 'upi' ? (
              <Check className="h-3 w-3 text-success" />
            ) : (
              <Copy className="h-3 w-3" />
            )}
            {copied === 'upi' ? 'Copied' : 'Copy'}
          </button>
        </div>
      </div>

      <UpiQrCode
        upiId={payee.upi_id}
        payeeName={payee.name}
        amountInr={data.amount_inr}
        reference={data.reference}
        gymName={data.gym_name}
        qrBucket={payee.qr_bucket}
        qrPath={payee.qr_path}
      />

      <div className="grid gap-2">
        <Button
          type="button"
          size="lg"
          fullWidth
          onClick={openUpiApp}
          leadingIcon={<Smartphone className="h-4 w-4" />}
        >
          Pay using a UPI app
        </Button>
        {launchHint ? (
          <p className="flex items-start gap-1.5 rounded-xl bg-warning/[0.07] px-3 py-2 text-[10px] leading-relaxed text-muted">
            <Info className="mt-0.5 h-3 w-3 shrink-0 text-warning" />
            If no UPI app opened, this device or browser may not support UPI links. Scan the QR code
            above, or copy the UPI ID and amount and pay from any UPI app.
          </p>
        ) : (
          <p className="text-center text-[9.5px] leading-relaxed text-faint">
            Opens Google Pay, PhonePe, Paytm or any other UPI app installed on this device. Nothing is
            charged until you approve it in the app.
          </p>
        )}
      </div>

      <div className="rounded-2xl border border-line/80 bg-elevated/40 p-3.5">
        <div className="flex items-start gap-2">
          <QrCode className="mt-0.5 h-3.5 w-3.5 shrink-0 text-primary-strong" />
          <p className="text-[10.5px] leading-relaxed text-muted">
            Scan this QR using Google Pay, PhonePe, Paytm, or another UPI app. Check that the recipient
            is <span className="font-semibold text-ink">{payee.name ?? data.gym_name}</span> and the
            amount is{' '}
            <span className="font-semibold text-ink">{formatINR(data.amount_inr)}</span> before you
            authorize the payment.
          </p>
        </div>
      </div>

      {data.upi_reference ? (
        <StateCard
          tone="warning"
          icon={<Clock3 className="h-4 w-4" />}
          title="Reference already submitted"
          body={`We already have reference ${data.upi_reference} for this payment. The gym will verify it before activating the plan.`}
        />
      ) : (
        <div className="rounded-2xl border border-line/80 bg-surface p-4">
          <div className="flex items-center gap-2">
            <div className="flex h-7 w-7 items-center justify-center rounded-lg bg-primary-soft text-primary-strong">
              <BadgeIndianRupee className="h-3.5 w-3.5" />
            </div>
            <div>
              <p className="text-[12px] font-semibold text-ink">Already paid?</p>
              <p className="text-[9.5px] text-muted">Submit the reference so the gym can verify it.</p>
            </div>
          </div>

          <div className="mt-3">
            <Input
              label="UPI reference / UTR"
              placeholder="e.g. 123456789012"
              value={reference}
              onChange={(event) => {
                setReference(event.target.value)
                if (formError) setFormError(null)
              }}
              autoComplete="off"
              spellCheck={false}
              inputMode="text"
              hint="Open your UPI app → tap this payment → copy the UTR / transaction ID."
              error={formError}
              disabled={submitReference.isPending}
            />
          </div>

          <Button
            type="button"
            className="mt-3"
            fullWidth
            variant="secondary"
            onClick={() => void handleSubmitReference()}
            loading={submitReference.isPending}
            leadingIcon={!submitReference.isPending ? <ShieldCheck className="h-4 w-4" /> : undefined}
          >
            {submitReference.isPending ? 'Submitting…' : 'Submit for verification'}
          </Button>

          <p className="mt-2 text-center text-[9.5px] leading-relaxed text-faint">
            Submitting a reference does not activate the plan. The gym verifies every direct UPI
            payment manually. FitDesk never asks for your UPI PIN, OTP, or banking password.
          </p>
        </div>
      )}

      <Button variant="ghost" fullWidth onClick={onBack}>
        Pay later
      </Button>
    </div>
  )
}

function StateCard({
  tone,
  icon,
  title,
  body,
  children,
}: {
  tone: 'success' | 'warning' | 'danger' | 'neutral'
  icon: ReactNode
  title: string
  body: string
  children?: ReactNode
}) {
  return (
    <div
      className={cn(
        'rounded-2xl border p-4',
        tone === 'success' && 'border-success/20 bg-success/[0.04]',
        tone === 'warning' && 'border-warning/25 bg-warning/[0.05]',
        tone === 'danger' && 'border-danger/20 bg-danger/[0.05]',
        tone === 'neutral' && 'border-line/80 bg-elevated/40',
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
            tone === 'neutral' && 'text-muted',
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

function DetailRow({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-[10px] text-muted">{label}</span>
      <span
        className={cn(
          'text-right text-[10.5px] font-semibold text-ink',
          mono && 'font-mono text-[10px]',
        )}
      >
        {value}
      </span>
    </div>
  )
}

function RefreshIcon() {
  return <CheckCircle2 className="h-4 w-4" />
}
