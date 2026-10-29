import { useEffect, useMemo, useState } from 'react'
import {
  AlertCircle,
  ArrowRight,
  CheckCircle2,
  Clock3,
  CreditCard,
  LockKeyhole,
  Minus,
  Plus,
  ShieldCheck,
  TriangleAlert,
} from 'lucide-react'
import type {
  GymPackage,
  PaymentVerification,
  UpiCheckoutReservation,
} from '@/types'
import { Sheet } from '@/components/ui/Sheet'
import { Button } from '@/components/ui/Button'
import { Skeleton } from '@/components/ui/Skeleton'
import { ErrorState } from '@/components/ui/ErrorState'
import { UpiPaymentPanel } from '@/components/membership/UpiPaymentPanel'
import { useRenewalQuote, useReserveUpiCheckout } from '@/hooks/queries'
import { toAppError } from '@/lib/errors'
import { formatKolkata } from '@/lib/kolkata'
import { clamp, cn, formatDuration, formatINR } from '@/lib/utils'

interface RenewalSheetProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  pkg: GymPackage | null
  onSuccess: (verification: PaymentVerification) => void
}

/**
 * `review`    – the quote, the duration picker, the total.
 * `pay`       – the direct-UPI instructions for a reserved payment row.
 * `conflict`  – a payment already exists whose amount differs from what was
 *               reviewed. Nothing is paid until the member chooses.
 * `reconcile` – an earlier payment needs a human at the desk first.
 */
type Stage = 'review' | 'pay' | 'conflict' | 'reconcile'

export function RenewalSheet({ open, onOpenChange, pkg, onSuccess }: RenewalSheetProps) {
  const isPerDay = pkg?.pricing_mode === 'per_day'
  const minDays = pkg?.min_days ?? 7
  const maxDays = pkg?.max_days ?? 180
  const [duration, setDuration] = useState(30)
  const [stage, setStage] = useState<Stage>('review')
  const [error, setError] = useState<string | null>(null)
  const [reservation, setReservation] = useState<UpiCheckoutReservation | null>(null)
  const [payAmount, setPayAmount] = useState<number | null>(null)

  const quoteQuery = useRenewalQuote(
    open && pkg ? pkg.id : null,
    isPerDay ? duration : null,
  )
  const reserveCheckout = useReserveUpiCheckout()

  const quote = quoteQuery.data
  const busy = reserveCheckout.isPending

  useEffect(() => {
    if (!open) return
    setStage('review')
    setError(null)
    setReservation(null)
    setPayAmount(null)
    if (pkg?.pricing_mode === 'per_day') {
      setDuration(clamp(30, pkg.min_days ?? 7, pkg.max_days ?? 180))
    }
  }, [open, pkg])

  const stepDuration = (delta: number) => {
    setStage('review')
    setError(null)
    setDuration((value) => clamp(value + delta, minDays, maxDays))
  }

  const handleOpenChange = (next: boolean) => {
    if (!next && busy) return
    if (!next) {
      setStage('review')
      setError(null)
      setReservation(null)
      setPayAmount(null)
    }
    onOpenChange(next)
  }

  const handlePay = async () => {
    if (!pkg || !quote) return
    setError(null)
    try {
      const result = await reserveCheckout.mutateAsync({
        packageId: pkg.id,
        durationDays: isPerDay ? duration : null,
      })

      if (result.status === 'reconciliation_required') {
        setReservation(result)
        setStage('reconcile')
        return
      }

      const serverAmount = result.amount_inr ?? result.quote?.total_amount ?? null
      if (serverAmount === null || !Number.isFinite(serverAmount) || serverAmount <= 0) {
        setError(
          'The server did not return a payable amount for this renewal. Nothing has been charged — please try again or pay at the front desk.',
        )
        return
      }

      // A previously reserved checkout may be for a different plan or a stale
      // price. Never swap the amount silently: show both and make the member
      // choose.
      if (
        result.status === 'resume_checkout' &&
        Math.abs(serverAmount - quote.total_amount) > 0.005
      ) {
        setReservation(result)
        setPayAmount(serverAmount)
        setStage('conflict')
        return
      }

      setReservation(result)
      setPayAmount(serverAmount)
      setStage('pay')
    } catch (paymentError) {
      setError(toAppError(paymentError).message)
    }
  }

  const fineTone = quote && quote.fine_amount > 0 ? 'warning' : 'success'

  const stepChips = useMemo(() => {
    if (!isPerDay) return []
    return [30, 60, 90, 180].filter((value) => value >= minDays && value <= maxDays)
  }, [isPerDay, minDays, maxDays])

  const reviewing = stage === 'review'
  const paying = stage === 'pay' && reservation && payAmount !== null

  const title =
    stage === 'pay'
      ? 'Pay by UPI'
      : stage === 'conflict'
        ? 'Payment already in progress'
        : stage === 'reconcile'
          ? 'Payment needs the front desk'
          : 'Renew membership'

  const description =
    stage === 'pay'
      ? 'Pay the gym directly with any UPI app, then submit the reference.'
      : stage === 'conflict'
        ? 'An earlier reservation for this account has a different amount.'
        : stage === 'reconcile'
          ? 'This renewal cannot continue online yet.'
          : pkg
            ? `${pkg.name} plan · select your details below`
            : undefined

  return (
    <Sheet
      open={open}
      onOpenChange={handleOpenChange}
      title={title}
      description={description}
      hideClose={busy}
      footer={
        reviewing && quote ? (
          <div>
            <div className="mb-3 flex items-end justify-between">
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
                  Total payable
                </p>
                <p className="text-[10.5px] text-muted">
                  {quote.duration_days} days · {formatKolkata(quote.starts_on, 'd MMM')} –{' '}
                  {formatKolkata(quote.ends_on, 'd MMM')}
                </p>
              </div>
              <p className="display-number text-[24px] leading-none text-ink">
                {formatINR(quote.total_amount)}
              </p>
            </div>
            <Button
              type="button"
              size="lg"
              fullWidth
              onClick={() => void handlePay()}
              loading={busy}
              leadingIcon={<LockKeyhole className="h-4 w-4" />}
              trailingIcon={!busy ? <ArrowRight className="h-4 w-4" /> : undefined}
            >
              {busy ? 'Preparing payment…' : `Pay ${formatINR(quote.total_amount)}`}
            </Button>
            <p className="mt-2 flex items-center justify-center gap-1.5 text-center text-[9.5px] text-faint">
              <ShieldCheck className="h-3 w-3" />
              Your plan activates only after the gym verifies the payment.
            </p>
          </div>
        ) : undefined
      }
    >
      {paying ? (
        <UpiPaymentPanel
          paymentId={reservation.payment_id}
          expectedAmount={payAmount}
          onSubmitted={(verification) => {
            onSuccess(verification)
          }}
          onBack={() => {
            setStage('review')
            setReservation(null)
            setPayAmount(null)
          }}
        />
      ) : stage === 'conflict' && reservation && payAmount !== null && quote ? (
        <div className="space-y-4">
          <div className="rounded-2xl border border-warning/25 bg-warning/[0.05] p-4">
            <div className="flex items-start gap-2.5">
              <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
              <div>
                <p className="text-[12px] font-semibold text-ink">You already have a payment open</p>
                <p className="mt-1 text-[10.5px] leading-relaxed text-muted">
                  A renewal started earlier on this account for{' '}
                  <span className="font-semibold text-ink">{formatINR(payAmount)}</span>. The plan you
                  just reviewed costs {formatINR(quote.total_amount)}. Nothing has been charged.
                </p>
              </div>
            </div>
          </div>

          <div className="rounded-2xl border border-line/80 bg-surface p-4">
            <Row label="Open payment" value={formatINR(payAmount)} />
            <Row label="Reviewed plan" value={formatINR(quote.total_amount)} />
            <Row
              label="Plan on the open payment"
              value={reservation.quote?.package_name ?? reservation.package_name ?? 'Membership'}
            />
          </div>

          <Button
            type="button"
            size="lg"
            fullWidth
            onClick={() => setStage('pay')}
            leadingIcon={<CreditCard className="h-4 w-4" />}
          >
            Continue with {formatINR(payAmount)}
          </Button>
          <p className="text-center text-[9.5px] leading-relaxed text-faint">
            The pay screen shows the recipient and amount the server has on file. Check both before
            paying.
          </p>
          <Button
            type="button"
            variant="ghost"
            fullWidth
            onClick={() => {
              setStage('review')
              setReservation(null)
              setPayAmount(null)
            }}
          >
            Back to review
          </Button>
          <Button type="button" variant="ghost" fullWidth onClick={() => handleOpenChange(false)}>
            Close and pay later
          </Button>
        </div>
      ) : stage === 'reconcile' ? (
        <div className="space-y-4">
          <div className="rounded-2xl border border-warning/25 bg-warning/[0.05] p-4">
            <div className="flex items-start gap-2.5">
              <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
              <div>
                <p className="text-[12px] font-semibold text-ink">
                  An earlier payment needs a manual check
                </p>
                <p className="mt-1 text-[10.5px] leading-relaxed text-muted">
                  A previous payment on this account may already have left your bank. The gym needs
                  to reconcile it at the front desk before another renewal can be paid online. Your
                  current plan and expiry are unchanged.
                </p>
                {reservation?.reconciliation_reason ? (
                  <p className="mt-2 rounded-xl bg-surface px-2.5 py-2 text-[10px] text-muted">
                    {reservation.reconciliation_reason}
                  </p>
                ) : null}
              </div>
            </div>
          </div>
          <Button type="button" variant="secondary" fullWidth onClick={() => handleOpenChange(false)}>
            Close
          </Button>
        </div>
      ) : (
        <div className="space-y-5">
          {pkg ? (
            <div className="flex items-center justify-between gap-3 rounded-2xl border border-line/80 bg-elevated/40 p-3.5">
              <div className="flex items-center gap-2.5">
                <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-primary-soft text-primary-strong">
                  <CreditCard className="h-[17px] w-[17px]" />
                </div>
                <div>
                  <p className="text-[13px] font-semibold text-ink">{pkg.name}</p>
                  <p className="text-[10.5px] text-muted">
                    {pkg.pricing_mode === 'per_day'
                      ? `${formatINR(pkg.price_inr)} per day`
                      : `${formatDuration(pkg.duration_days)} plan`}
                  </p>
                </div>
              </div>
              <p className="text-[12px] font-semibold text-ink">
                {pkg.pricing_mode === 'per_day' ? 'Flexible' : formatINR(pkg.price_inr)}
              </p>
            </div>
          ) : null}

          {isPerDay ? (
            <div className="rounded-2xl border border-line/80 bg-surface p-4">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-[12px] font-semibold text-ink">Choose duration</p>
                  <p className="mt-0.5 text-[10.5px] text-muted">
                    {minDays}–{maxDays} days · {formatINR(pkg?.price_inr ?? 0)}/day
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={() => stepDuration(-1)}
                    disabled={duration <= minDays || busy}
                    aria-label="Decrease days"
                    className="flex h-9 w-9 items-center justify-center rounded-xl border border-line bg-surface text-ink transition disabled:opacity-40"
                  >
                    <Minus className="h-3.5 w-3.5" />
                  </button>
                  <div className="w-14 text-center">
                    <p className="display-number text-[18px] text-ink">{duration}</p>
                    <p className="text-[8.5px] uppercase tracking-[0.1em] text-faint">days</p>
                  </div>
                  <button
                    type="button"
                    onClick={() => stepDuration(1)}
                    disabled={duration >= maxDays || busy}
                    aria-label="Increase days"
                    className="flex h-9 w-9 items-center justify-center rounded-xl border border-line bg-surface text-ink transition disabled:opacity-40"
                  >
                    <Plus className="h-3.5 w-3.5" />
                  </button>
                </div>
              </div>
              {stepChips.length > 0 ? (
                <div className="mt-3 flex flex-wrap gap-1.5">
                  {stepChips.map((value) => (
                    <button
                      key={value}
                      type="button"
                      onClick={() => {
                        setDuration(value)
                        setStage('review')
                      }}
                      className={cn(
                        'rounded-full border px-2.5 py-1 text-[10px] font-semibold transition',
                        duration === value
                          ? 'border-primary/30 bg-primary-soft text-primary-strong'
                          : 'border-line bg-elevated/40 text-muted hover:text-ink',
                      )}
                    >
                      {value} days
                    </button>
                  ))}
                </div>
              ) : null}
            </div>
          ) : null}

          {quoteQuery.isLoading ? (
            <div className="space-y-3">
              <Skeleton className="h-20 rounded-2xl" />
              <Skeleton className="h-28 rounded-2xl" />
            </div>
          ) : quoteQuery.isError ? (
            <ErrorState
              compact
              title="Could not calculate this renewal"
              message={
                quoteQuery.error instanceof Error
                  ? quoteQuery.error.message
                  : 'Please try again.'
              }
              onRetry={() => void quoteQuery.refetch()}
            />
          ) : quote ? (
            <>
              <div className="rounded-2xl border border-line/80 bg-surface p-4">
                <div className="flex items-center justify-between text-[11px]">
                  <span className="text-muted">New validity</span>
                  <span className="font-semibold text-ink">
                    {formatKolkata(quote.starts_on, 'd MMM yyyy')} →{' '}
                    {formatKolkata(quote.ends_on, 'd MMM yyyy')}
                  </span>
                </div>
                <div className="mt-1.5 flex items-center justify-between text-[11px]">
                  <span className="text-muted">Duration</span>
                  <span className="font-semibold text-ink">
                    {quote.duration_days} days
                  </span>
                </div>
                {quote.is_stacked ? (
                  <div className="mt-3 flex items-start gap-2 rounded-xl bg-primary-soft/50 px-2.5 py-2">
                    <Clock3 className="mt-0.5 h-3.5 w-3.5 shrink-0 text-primary-strong" />
                    <p className="text-[10.5px] leading-relaxed text-primary-strong">
                      Your current plan runs until{' '}
                      {formatKolkata(quote.current_ends_on, 'd MMM')}. This renewal starts the
                      next day — no days are lost.
                    </p>
                  </div>
                ) : quote.current_ends_on ? (
                  <div className="mt-3 flex items-start gap-2 rounded-xl bg-elevated/60 px-2.5 py-2">
                    <Clock3 className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted" />
                    <p className="text-[10.5px] leading-relaxed text-muted">
                      Your last plan ended on{' '}
                      {formatKolkata(quote.current_ends_on, 'd MMM')}. The new plan starts
                      today.
                    </p>
                  </div>
                ) : null}
              </div>

              {quote.days_past_expiry > 0 ? (
                <div
                  className={cn(
                    'rounded-2xl border p-3.5',
                    fineTone === 'warning'
                      ? 'border-warning/25 bg-warning/[0.05]'
                      : 'border-success/20 bg-success/[0.04]',
                  )}
                >
                  <div className="flex items-start gap-2.5">
                    {fineTone === 'warning' ? (
                      <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
                    ) : (
                      <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" />
                    )}
                    <div>
                      <p className="text-[11.5px] font-semibold text-ink">
                        {quote.days_past_expiry} days past expiry
                      </p>
                      <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
                        {quote.fine_reason ??
                          'You are within the 7-day grace period, so no late fee applies.'}
                      </p>
                      <p className="mt-1 text-[9.5px] text-faint">
                        Grace: 0–7 days ₹0 · day 8 ₹50 flat · day 9+ ₹50 + ₹10/day
                      </p>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="flex items-start gap-2.5 rounded-2xl border border-success/20 bg-success/[0.04] p-3.5">
                  <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" />
                  <div>
                    <p className="text-[11.5px] font-semibold text-ink">No late fee</p>
                    <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
                      {quote.is_stacked
                        ? 'Renewing before expiry keeps you inside the grace window and locks the next period.'
                        : 'A fresh start — no outstanding fine on this renewal.'}
                    </p>
                  </div>
                </div>
              )}

              <div className="rounded-2xl border border-line/80 bg-surface p-4">
                <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-faint">
                  Price breakdown
                </p>
                <div className="mt-3 space-y-2.5">
                  {quote.breakdown.map((item) => (
                    <div key={item.label} className="flex items-center justify-between gap-3">
                      <span className="text-[11.5px] text-muted">{item.label}</span>
                      <span className="text-[12px] font-semibold tabular-nums text-ink">
                        {formatINR(item.amount)}
                      </span>
                    </div>
                  ))}
                  <div className="border-t border-line/70 pt-2.5">
                    <div className="flex items-end justify-between">
                      <span className="text-[12px] font-semibold text-ink">Total</span>
                      <span className="display-number text-[20px] leading-none text-ink">
                        {formatINR(quote.total_amount)}
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              <p className="text-[10px] leading-relaxed text-muted">
                Pay the gym directly from Google Pay, PhonePe, Paytm or any other UPI app. FitDesk
                never asks for your UPI PIN, OTP or banking password.
              </p>

              {error ? (
                <div className="flex items-start gap-2.5 rounded-2xl border border-danger/15 bg-danger/[0.05] p-3.5">
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
                  <p className="text-[11.5px] leading-relaxed text-danger">{error}</p>
                </div>
              ) : null}
            </>
          ) : null}
        </div>
      )}
    </Sheet>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-4 border-b border-line/50 py-2 last:border-0">
      <span className="text-[11px] text-muted">{label}</span>
      <span className="text-right text-[11.5px] font-semibold text-ink">{value}</span>
    </div>
  )
}
