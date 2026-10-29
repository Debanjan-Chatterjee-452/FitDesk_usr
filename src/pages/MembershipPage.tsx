import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  ArrowRight,
  CalendarCheck2,
  CalendarClock,
  CheckCircle2,
  Clock3,
  IndianRupee,
  ReceiptText,
  ShieldCheck,
  Sparkles,
  TriangleAlert,
  XCircle,
} from 'lucide-react'
import { toast } from 'sonner'
import type { GymPackage, Payment, PaymentVerification } from '@/types'
import { PageHeader } from '@/components/layout/PageHeader'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Button } from '@/components/ui/Button'
import { Badge } from '@/components/ui/Badge'
import { Sheet } from '@/components/ui/Sheet'
import { Skeleton } from '@/components/ui/Skeleton'
import { EmptyState } from '@/components/ui/EmptyState'
import { ErrorState } from '@/components/ui/ErrorState'
import { SectionHeading } from '@/components/ui/SectionHeading'
import { PackageCard } from '@/components/membership/PackageCard'
import { RenewalSheet } from '@/components/membership/RenewalSheet'
import {
  useMembershipSnapshot,
  usePackages,
  usePayments,
  usePendingPayment,
} from '@/hooks/queries'
import { formatKolkata } from '@/lib/kolkata'
import { cn, formatDuration, formatINR } from '@/lib/utils'

const PAYMENT_TONES = {
  pending: { tone: 'warning' as const, label: 'Pending verification' },
  approved: { tone: 'success' as const, label: 'Verified' },
  declined: { tone: 'danger' as const, label: 'Declined' },
}

type PaymentTone = {
  tone: 'warning' | 'success' | 'danger' | 'neutral'
  label: string
}

/**
 * Legacy failed/refunded/cancelled rows are preserved, not rewritten as plain
 * declines. Reconciliation rows are shown as such even before a payment id is
 * available.
 */
function paymentDisplay(payment: Payment): PaymentTone {
  if (payment.legacy_status === 'refunded') {
    return { tone: 'neutral', label: 'Refunded' }
  }
  if (payment.legacy_status === 'failed') {
    return { tone: 'danger', label: 'Failed' }
  }
  if (payment.legacy_status === 'cancelled') {
    return { tone: 'neutral', label: 'Cancelled' }
  }
  if (
    payment.reconciliation_required ||
    payment.checkout_state === 'reconciliation_required'
  ) {
    return { tone: 'warning', label: 'Needs reconciliation' }
  }
  if (payment.refund_status === 'refunded') {
    return { tone: 'neutral', label: 'Refunded' }
  }
  if (payment.refund_status === 'pending_manual_refund') {
    return { tone: 'warning', label: 'Refund pending' }
  }
  return PAYMENT_TONES[payment.status]
}

export function MembershipPage() {
  const navigate = useNavigate()
  const membershipQuery = useMembershipSnapshot()
  const packagesQuery = usePackages()
  const paymentsQuery = usePayments()
  const pendingQuery = usePendingPayment()
  const [selectedPackage, setSelectedPackage] = useState<GymPackage | null>(null)
  const [renewalOpen, setRenewalOpen] = useState(false)
  const [verification, setVerification] = useState<PaymentVerification | null>(null)

  const snapshot = membershipQuery.snapshot
  const membership = snapshot.membership
  const upcoming = membershipQuery.upcoming
  const currentPackageId = membership?.package_id ?? null
  const pendingPayment = pendingQuery.data ?? null
  const reconciliationPayment =
    pendingPayment &&
    (pendingPayment.reconciliation_required ||
      pendingPayment.checkout_state === 'reconciliation_required')
      ? pendingPayment
      : null
  const latestPayment = paymentsQuery.data?.[0] ?? null
  const declinedPayment =
    !pendingPayment && latestPayment?.status === 'declined' ? latestPayment : null

  const openRenewal = (pkg: GymPackage) => {
    if (pendingPayment) {
      toast.info('Payment awaiting verification', {
        description:
          'The gym is still verifying your last payment. Wait for that decision before starting another renewal.',
      })
      return
    }
    setSelectedPackage(pkg)
    setRenewalOpen(true)
  }

  return (
    <div className="page-x">
      <PageHeader
        title="Membership"
        subtitle="Your plan, renewals and payment records."
        action={<ThemeToggle />}
      />

      {reconciliationPayment ? (
        <PaymentStatusBanner kind="reconciliation" payment={reconciliationPayment} />
      ) : pendingPayment ? (
        <PaymentStatusBanner kind="pending" payment={pendingPayment} />
      ) : declinedPayment ? (
        <PaymentStatusBanner kind="declined" payment={declinedPayment} />
      ) : null}

      <div className="mt-3 grid gap-5 lg:grid-cols-[minmax(0,1.6fr)_minmax(290px,1fr)] lg:items-start lg:gap-6">
        <div className="space-y-7">
          <section>
            <SectionHeading title="Your plan" description="Live status from the club records." />
            {membershipQuery.isError ? (
              <ErrorState
                title="Could not load your plan"
                message={membershipQuery.error instanceof Error ? membershipQuery.error.message : 'Try again.'}
                onRetry={() => void membershipQuery.refetch()}
              />
            ) : membershipQuery.isLoading ? (
              <Skeleton className="h-48 rounded-3xl" />
            ) : membership ? (
              <div className="card overflow-hidden">
                <div className="flex flex-wrap items-start justify-between gap-3 border-b border-line/70 p-5">
                  <div>
                    <div className="flex items-center gap-2">
                      <h3 className="display-accent text-[22px] text-ink">
                        {membership.package?.name ?? 'Membership'}
                      </h3>
                      <Badge tone={snapshot.isActive ? (snapshot.daysLeft <= 3 ? 'warning' : 'success') : 'danger'} dot>
                        {snapshot.isActive
                          ? snapshot.daysLeft === 0
                            ? 'Expires today'
                            : 'Active'
                          : 'Expired'}
                      </Badge>
                    </div>
                    <p className="mt-1 text-[11.5px] text-muted">
                      {formatKolkata(membership.starts_on, 'd MMM yyyy')} –{' '}
                      {formatKolkata(membership.ends_on, 'd MMM yyyy')} ·{' '}
                      {formatDuration(
                        Math.max(
                          1,
                          Math.round(
                            (new Date(membership.ends_on).getTime() - new Date(membership.starts_on).getTime()) /
                              86_400_000,
                          ) + 1,
                        ),
                      )}
                    </p>
                  </div>
                  <div className="text-right">
                    <p className="display-number display-accent text-[26px] leading-none text-ink">
                      {snapshot.isActive && snapshot.daysLeft > 0
                        ? snapshot.daysLeft
                        : snapshot.daysPastExpiry}
                    </p>
                    <p className="mt-1 text-[9.5px] font-semibold uppercase tracking-[0.12em] text-faint">
                      {snapshot.isActive && snapshot.daysLeft > 0 ? 'days left' : 'days past'}
                    </p>
                  </div>
                </div>
                <div className="p-5">
                  <div className="h-2 overflow-hidden rounded-full bg-elevated">
                    <div
                      className={cn(
                        'h-full rounded-full',
                        snapshot.isActive ? 'bg-primary' : 'bg-warning',
                      )}
                      style={{ width: `${Math.round((snapshot.isActive ? snapshot.progress : 1) * 100)}%` }}
                    />
                  </div>
                  <div className="mt-3 flex items-center justify-between gap-3">
                    <p className="text-[10.5px] text-muted">
                      {snapshot.isActive
                        ? 'Plan usage since start date'
                        : 'Renew to restore check-in access'}
                    </p>
                    <Button
                      variant="soft"
                      size="sm"
                      disabled={Boolean(pendingPayment)}
                      onClick={() => {
                        const pkg = packagesQuery.data?.find((item) => item.id === currentPackageId)
                        if (pkg) openRenewal(pkg)
                        else document.getElementById('plans')?.scrollIntoView({ behavior: 'smooth' })
                      }}
                    >
                      {pendingPayment
                        ? 'Awaiting verification'
                        : snapshot.isActive
                          ? 'Renew'
                          : 'Renew now'}
                    </Button>
                  </div>

                  {upcoming ? (
                    <div className="mt-4 flex items-start gap-2.5 rounded-2xl border border-primary/20 bg-primary-soft/60 p-3">
                      <CalendarClock className="mt-0.5 h-4 w-4 shrink-0 text-primary-strong" />
                      <p className="text-[10.5px] leading-relaxed text-muted">
                        <span className="font-semibold text-ink">Renewal queued</span> ·{' '}
                        {upcoming.package?.name ?? 'Membership'} runs{' '}
                        {formatKolkata(upcoming.starts_on, 'd MMM')} –{' '}
                        {formatKolkata(upcoming.ends_on, 'd MMM yyyy')}.
                      </p>
                    </div>
                  ) : null}

                  {snapshot.isExpired ? (
                    <div className="mt-4 flex items-start gap-2.5 rounded-2xl border border-warning/25 bg-warning/[0.05] p-3">
                      <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
                      <p className="text-[10.5px] leading-relaxed text-muted">
                        Your membership expired {snapshot.daysPastExpiry}{' '}
                        {snapshot.daysPastExpiry === 1 ? 'day' : 'days'} ago. A late fee applies
                        from day 8 — your renewal clears the outstanding fine once the gym
                        approves the payment.
                      </p>
                    </div>
                  ) : null}
                </div>
              </div>
            ) : (
              <EmptyState
                icon={<Sparkles className="h-5 w-5" />}
                title="No membership on file yet"
                description="Choose a plan below to unlock check-ins and your member dashboard."
                action={
                  <Button
                    size="sm"
                    onClick={() => document.getElementById('plans')?.scrollIntoView({ behavior: 'smooth' })}
                  >
                    Browse plans
                  </Button>
                }
              />
            )}
          </section>

          <section id="plans" className="scroll-mt-6">
            <SectionHeading
              title="Choose a plan"
              description="All plans include full gym access and QR check-in."
              action={
                <Badge tone="neutral" icon={<ShieldCheck className="h-3 w-3" />}>
                  Secure renewal
                </Badge>
              }
            />
            {packagesQuery.isError ? (
              <ErrorState
                title="Plans are unavailable"
                message={packagesQuery.error instanceof Error ? packagesQuery.error.message : 'Try again.'}
                onRetry={() => void packagesQuery.refetch()}
              />
            ) : packagesQuery.isLoading ? (
              <div className="grid gap-3 sm:grid-cols-2">
                {[0, 1, 2, 3].map((index) => (
                  <Skeleton key={index} className="h-[300px] rounded-3xl" />
                ))}
              </div>
            ) : (
              <div className="grid gap-3 sm:grid-cols-2">
                {(packagesQuery.data ?? []).map((pkg) => (
                  <PackageCard
                    key={pkg.id}
                    pkg={pkg}
                    isCurrent={pkg.id === currentPackageId && Boolean(snapshot.isActive)}
                    disabled={Boolean(pendingPayment)}
                    onSelect={openRenewal}
                  />
                ))}
              </div>
            )}
          </section>

          <section>
            <SectionHeading
              title="Payment history"
              description="Every renewal, reviewed by the gym."
              action={
                <span className="inline-flex items-center gap-1 text-[10px] font-semibold uppercase tracking-[0.1em] text-faint">
                  <ReceiptText className="h-3.5 w-3.5" />
                  {(paymentsQuery.data ?? []).length} records
                </span>
              }
            />
            <PaymentHistory
              payments={paymentsQuery.data ?? []}
              loading={paymentsQuery.isLoading}
              error={paymentsQuery.isError ? 'Could not load payment history.' : null}
              onRetry={() => void paymentsQuery.refetch()}
            />
          </section>
        </div>

        <aside className="space-y-4 lg:sticky lg:top-6">
          <div className="rounded-3xl border border-line/80 bg-surface p-4">
            <div className="flex items-center gap-2">
              <div className="flex h-8 w-8 items-center justify-center rounded-xl bg-primary-soft text-primary-strong">
                <CalendarCheck2 className="h-4 w-4" />
              </div>
              <div>
                <p className="text-[12px] font-semibold text-ink">Late renewal policy</p>
                <p className="text-[9.5px] uppercase tracking-[0.1em] text-faint">Calculated on the server</p>
              </div>
            </div>
            <div className="mt-4 space-y-2.5">
              <FeeRow days="0 – 7 days" fee="₹0" note="Grace period" tone="success" />
              <FeeRow days="Day 8" fee="₹50" note="Flat late fee" tone="warning" />
              <FeeRow days="Day 9 onwards" fee="₹50 + ₹10/day" note="Per extra day" tone="danger" />
            </div>
            <p className="mt-4 border-t border-line/70 pt-3 text-[10px] leading-relaxed text-muted">
              Fine is based on the expiry date of your latest plan, in IST. A renewal clears the
              outstanding status once the gym approves the payment.
            </p>
          </div>

          <div className="rounded-3xl border border-primary/15 bg-primary-soft/35 p-4">
            <div className="flex items-center gap-2 text-primary-strong">
              <ShieldCheck className="h-4 w-4" />
              <p className="text-[11.5px] font-semibold">Payments are verified, then approved</p>
            </div>
            <p className="mt-1.5 text-[10.5px] leading-relaxed text-muted">
              You pay the gym directly from any UPI app. The gym then matches your reference
              against their bank statement before approving it. Your plan starts, expiry extends,
              and fines clear only after that verification. Cancelling a payment never creates a
              membership.
            </p>
          </div>

          <button
            type="button"
            onClick={() => navigate('/attendance')}
            className="flex w-full items-center justify-between rounded-2xl border border-line/80 bg-surface px-4 py-3 text-left transition hover:border-primary/30"
          >
            <span className="flex items-center gap-2.5">
              <CalendarCheck2 className="h-4 w-4 text-primary-strong" />
              <span className="text-[12px] font-semibold text-ink">View attendance</span>
            </span>
            <ArrowRight className="h-4 w-4 text-muted" />
          </button>
        </aside>
      </div>

      <RenewalSheet
        open={renewalOpen}
        onOpenChange={setRenewalOpen}
        pkg={selectedPackage}
        onSuccess={(result) => {
          setRenewalOpen(false)
          setVerification(result)
          void membershipQuery.refetch()
          void paymentsQuery.refetch()
        }}
      />

      <SuccessSheet
        verification={verification}
        onClose={() => setVerification(null)}
        onViewPlan={() => {
          setVerification(null)
          window.scrollTo({ top: 0, behavior: 'smooth' })
        }}
      />
    </div>
  )
}

function FeeRow({
  days,
  fee,
  note,
  tone,
}: {
  days: string
  fee: string
  note: string
  tone: 'success' | 'warning' | 'danger'
}) {
  const dot =
    tone === 'success' ? 'bg-success' : tone === 'warning' ? 'bg-warning' : 'bg-danger'
  return (
    <div className="flex items-center justify-between gap-3">
      <div className="flex items-center gap-2">
        <span className={cn('h-1.5 w-1.5 rounded-full', dot)} />
        <div>
          <p className="text-[11px] font-semibold text-ink">{days}</p>
          <p className="text-[9.5px] text-faint">{note}</p>
        </div>
      </div>
      <span className="text-[11px] font-semibold tabular-nums text-ink">{fee}</span>
    </div>
  )
}

function PaymentHistory({
  payments,
  loading,
  error,
  onRetry,
}: {
  payments: Payment[]
  loading: boolean
  error: string | null
  onRetry: () => void
}) {
  if (loading) {
    return (
      <div className="space-y-2">
        {[0, 1, 2].map((index) => (
          <Skeleton key={index} className="h-16 rounded-2xl" />
        ))}
      </div>
    )
  }
  if (error) {
    return <ErrorState compact message={error} onRetry={onRetry} />
  }
  if (payments.length === 0) {
    return (
      <EmptyState
        icon={<IndianRupee className="h-5 w-5" />}
        title="No payments yet"
        description="Your renewal receipts will appear here after your first plan."
        className="py-7"
      />
    )
  }

  return (
    <div className="overflow-hidden rounded-3xl border border-line/80 bg-surface">
      {payments.map((payment) => {
        const display = paymentDisplay(payment)
        const packageName = payment.package?.name ?? 'Membership'
        return (
          <div
            key={payment.id}
            className="flex items-center gap-3 border-b border-line/60 px-4 py-3.5 last:border-0"
          >
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-elevated text-muted">
              {display.tone === 'success' ? (
                <CheckCircle2 className="h-[18px] w-[18px] text-success" />
              ) : display.tone === 'danger' ? (
                <XCircle className="h-[18px] w-[18px] text-danger" />
              ) : (
                <Clock3 className="h-[18px] w-[18px] text-warning" />
              )}
            </div>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-1.5">
                <p className="text-[12.5px] font-semibold text-ink">
                  {packageName} · {payment.duration_days} days
                </p>
                <Badge tone={display.tone}>{display.label}</Badge>
              </div>
              <p className="mt-0.5 text-[10.5px] text-muted">
                {formatKolkata(
                  payment.reviewed_at ?? payment.paid_at ?? payment.created_at,
                  'd MMM yyyy, h:mm a',
                )}
                {payment.fine_amount_inr > 0
                  ? ` · includes ${formatINR(payment.fine_amount_inr)} late fee`
                  : ''}
              </p>
            </div>
            <div className="shrink-0 text-right">
              <p className="text-[12.5px] font-semibold tabular-nums text-ink">
                {formatINR(payment.total_amount_inr)}
              </p>
              {display.label === 'Refund pending' ? (
                <p className="text-[9px] text-warning">refund at desk</p>
              ) : display.label === 'Refunded' ? (
                <p className="text-[9px] text-muted">refunded</p>
              ) : payment.status === 'pending' ? (
                <p className="text-[9px] text-warning">awaiting gym</p>
              ) : payment.status === 'declined' ? (
                <p className="text-[9px] text-danger">contact the gym</p>
              ) : null}
            </div>
          </div>
        )
      })}
    </div>
  )
}

function PaymentStatusBanner({
  kind,
  payment,
}: {
  kind: 'pending' | 'declined' | 'reconciliation'
  payment: Payment
}) {
  const packageName = payment.package?.name ?? 'membership'

  if (kind === 'reconciliation') {
    return (
      <div className="mt-4 flex items-start gap-3 rounded-2xl border border-warning/25 bg-warning/[0.06] p-3.5">
        <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
        <div>
          <p className="text-[12px] font-semibold text-ink">Payment needs reconciliation</p>
          <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
            A payment for your {packageName} renewal may have been sent, but FitDesk could not
            record it automatically. The gym will check it against their bank statement before
            approving or declining. Your current plan, expiry date, and any fines stay unchanged.
            Keep your UPI reference or receipt handy and contact the front desk.
          </p>
        </div>
      </div>
    )
  }

  if (kind === 'pending') {
    return (
      <div className="mt-4 flex items-start gap-3 rounded-2xl border border-warning/25 bg-warning/[0.06] p-3.5">
        <Clock3 className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
        <div>
          <p className="text-[12px] font-semibold text-ink">Payment pending verification</p>
          <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
            Your {formatINR(payment.total_amount_inr)} payment reference for the {packageName} plan
            is waiting for the gym. Your current plan, expiry date, and any fines stay unchanged
            until it is verified, so keep using your existing access. New renewals are locked
            while this review is open.
          </p>
        </div>
      </div>
    )
  }

  if (payment.legacy_status === 'refunded' || payment.refund_status === 'refunded') {
    return (
      <div className="mt-4 flex items-start gap-3 rounded-2xl border border-line/80 bg-elevated/40 p-3.5">
        <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" />
        <div>
          <p className="text-[12px] font-semibold text-ink">Refund recorded</p>
          <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
            Your {formatINR(payment.total_amount_inr)} payment for the {packageName} plan was
            refunded outside FitDesk. Refunds are processed manually by the gym. Your current
            plan and expiry are unchanged.
          </p>
        </div>
      </div>
    )
  }

  if (payment.legacy_status === 'failed') {
    return (
      <div className="mt-4 flex items-start gap-3 rounded-2xl border border-danger/20 bg-danger/[0.05] p-3.5">
        <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
        <div>
          <p className="text-[12px] font-semibold text-ink">Payment not completed</p>
          <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
            This {packageName} payment attempt was not completed. No plan was activated. Your
            current plan and expiry are unchanged.
          </p>
        </div>
      </div>
    )
  }

  if (payment.legacy_status === 'cancelled') {
    return (
      <div className="mt-4 flex items-start gap-3 rounded-2xl border border-line/80 bg-elevated/40 p-3.5">
        <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-muted" />
        <div>
          <p className="text-[12px] font-semibold text-ink">Payment cancelled</p>
          <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
            This historical {packageName} payment was cancelled before completion. No plan was
            activated. Your current plan and expiry are unchanged.
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="mt-4 flex items-start gap-3 rounded-2xl border border-danger/20 bg-danger/[0.05] p-3.5">
      <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
      <div>
        <p className="text-[12px] font-semibold text-ink">Payment declined</p>
        <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
          The gym could not approve your {formatINR(payment.total_amount_inr)} payment for the{' '}
          {packageName} plan.{' '}
          {payment.refund_status === 'pending_manual_refund'
            ? 'A manual refund is pending at the front desk.'
            : 'Contact the front desk for a manual refund.'}{' '}
          Your current plan and expiry are unchanged.
        </p>
      </div>
    </div>
  )
}

function SuccessSheet({
  verification,
  onClose,
  onViewPlan,
}: {
  verification: PaymentVerification | null
  onClose: () => void
  onViewPlan: () => void
}) {
  const approved = verification?.status === 'already_approved'
  const alreadyPending = verification?.status === 'already_pending'
  const reconciliation = verification?.status === 'reconciliation_required'
  const packageName = verification?.package_name ?? 'membership'
  const endsOn = verification?.ends_on
    ? formatKolkata(verification.ends_on, 'd MMM yyyy')
    : 'To be confirmed'
  const startsOn = verification?.starts_on
    ? formatKolkata(verification.starts_on, 'd MMM')
    : 'After approval'

  return (
    <Sheet
      open={Boolean(verification)}
      onOpenChange={(open) => {
        if (!open) onClose()
      }}
      size="sm"
      hideClose
    >
      <div className="flex flex-col items-center pb-2 pt-4 text-center">
        <div className="relative mb-5 flex h-20 w-20 items-center justify-center">
          <span
            className={cn(
              'absolute inset-0 animate-pulse-ring rounded-full',
              approved ? 'bg-success/15' : 'bg-warning/15',
            )}
          />
          <span
            className={cn(
              'absolute inset-2 rounded-full',
              approved ? 'bg-success/15' : 'bg-warning/15',
            )}
          />
          <span
            className={cn(
              'relative flex h-14 w-14 items-center justify-center rounded-full text-white',
              approved
                ? 'bg-success shadow-[0_12px_30px_-10px_rgb(var(--success)/0.8)]'
                : 'bg-warning shadow-[0_12px_30px_-10px_rgb(var(--warning)/0.8)]',
            )}
          >
            {approved ? (
              <CheckCircle2 className="h-7 w-7" strokeWidth={2.5} />
            ) : (
              <Clock3 className="h-7 w-7" strokeWidth={2.5} />
            )}
          </span>
        </div>
        <h2 className="display-accent text-[23px] text-ink">
          {approved
            ? 'Payment verified.'
            : reconciliation
              ? 'Payment needs reconciliation.'
              : alreadyPending
                ? 'Already awaiting verification.'
                : 'Reference submitted.'}
        </h2>
        <p className="mt-1.5 max-w-[34ch] text-[12px] leading-relaxed text-muted">
          {approved ? (
            <>
              Your {packageName} plan is active until {endsOn}. Any remaining days on your
              previous plan were preserved.
            </>
          ) : reconciliation ? (
            <>
              A payment for your {packageName} renewal may have been sent, but it could not be
              recorded automatically. The gym will check it against their bank statement before
              approving or declining. Your expiry date and any fines stay unchanged.
            </>
          ) : (
            <>
              Your reference for the {packageName} payment was recorded and is waiting for the gym
              to verify it. Your expiry date and any fines stay unchanged until it is approved.
            </>
          )}
        </p>

        <div className="mt-5 w-full rounded-2xl border border-line/80 bg-elevated/50 p-3.5 text-left">
          <div className="flex items-center justify-between">
            <span className="text-[10.5px] text-muted">Plan</span>
            <span className="text-[11.5px] font-semibold text-ink">{packageName}</span>
          </div>
          <div className="mt-2 flex items-center justify-between">
            <span className="text-[10.5px] text-muted">
              {approved ? 'Valid until' : 'Requested period'}
            </span>
            <span className="text-[11.5px] font-semibold text-ink">
              {approved ? endsOn : `${startsOn} → ${endsOn}`}
            </span>
          </div>
          <div className="mt-2 flex items-center justify-between">
            <span className="text-[10.5px] text-muted">Payment</span>
            {approved ? (
              <Badge tone="success" dot>
                Verified
              </Badge>
            ) : reconciliation ? (
              <Badge tone="warning" dot>
                Needs reconciliation
              </Badge>
            ) : (
              <Badge tone="warning" dot>
                Pending verification
              </Badge>
            )}
          </div>
        </div>

        <div className="mt-5 grid w-full grid-cols-2 gap-2">
          <Button variant="secondary" onClick={onClose}>
            Done
          </Button>
          <Button onClick={onViewPlan} trailingIcon={<ArrowRight className="h-3.5 w-3.5" />}>
            View plan
          </Button>
        </div>
      </div>
    </Sheet>
  )
}
