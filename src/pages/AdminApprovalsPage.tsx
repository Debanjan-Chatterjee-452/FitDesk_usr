import { useState, type ReactNode } from 'react'
import {
  Banknote,
  CheckCircle2,
  Clock3,
  IndianRupee,
  Mail,
  Phone,
  ReceiptText,
  RefreshCcw,
  ShieldCheck,
  TriangleAlert,
  XCircle,
} from 'lucide-react'
import { toast } from 'sonner'
import type { AdminPaymentRow, AdminRefundRow } from '@/types'
import { PageHeader } from '@/components/layout/PageHeader'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Button } from '@/components/ui/Button'
import { Badge } from '@/components/ui/Badge'
import { Sheet } from '@/components/ui/Sheet'
import { Skeleton } from '@/components/ui/Skeleton'
import { EmptyState } from '@/components/ui/EmptyState'
import { ErrorState } from '@/components/ui/ErrorState'
import {
  useAdminPendingPayments,
  useAdminRefundPayments,
  useMarkPaymentRefunded,
  useReviewPayment,
} from '@/hooks/queries'
import { useAuth } from '@/context/AuthProvider'
import { formatKolkata } from '@/lib/kolkata'
import { cn, formatDuration, formatINR } from '@/lib/utils'

type Decision = 'approved' | 'declined'

interface Confirmation {
  payment: AdminPaymentRow
  decision: Decision
}

export function AdminApprovalsPage() {
  const { userId } = useAuth()
  const queueQuery = useAdminPendingPayments()
  const refundsQuery = useAdminRefundPayments()
  const reviewPayment = useReviewPayment()
  const markRefunded = useMarkPaymentRefunded()
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null)
  const [note, setNote] = useState('')
  const [refundConfirmation, setRefundConfirmation] = useState<AdminRefundRow | null>(null)
  const [refundNote, setRefundNote] = useState('')

  const payments = queueQuery.data ?? []
  const refunds = refundsQuery.data ?? []
  const totalValue = payments.reduce((sum, item) => sum + item.total_amount_inr, 0)

  const askToReview = (payment: AdminPaymentRow, decision: Decision) => {
    setNote('')
    setConfirmation({ payment, decision })
  }

  const closeConfirmation = () => {
    if (reviewPayment.isPending) return
    setConfirmation(null)
    setNote('')
  }

  const confirmReview = async () => {
    if (!confirmation) return
    const { payment, decision } = confirmation
    if (payment.reconciliation_required && !note.trim()) {
      toast.error('A reconciliation note is required', {
        description:
          'Record what you checked against the bank statement before approving or declining this payment.',
      })
      return
    }
    try {
      const result = await reviewPayment.mutateAsync({
        paymentId: payment.payment_id,
        decision,
        note: note.trim() || null,
      })
      if (result.status === 'approved') {
        toast.success('Payment approved', {
          description: `${result.package_name} activated for ${payment.member_name}${
            result.starts_on ? ` from ${formatKolkata(result.starts_on, 'd MMM yyyy')}` : ''
          }${
            result.ends_on ? ` to ${formatKolkata(result.ends_on, 'd MMM yyyy')}` : ''
          }. Existing access was preserved.`,
        })
      } else {
        toast.success('Payment declined', {
          description:
            result.refund_status === 'pending_manual_refund'
              ? `${payment.member_name}'s current plan is unchanged. A manual refund is now tracked in the refund queue.`
              : `${payment.member_name}'s current plan is unchanged.`,
        })
      }
      setConfirmation(null)
      setNote('')
    } catch {
      // The mutation surfaces a toast; keep the modal open for a retry.
    }
  }

  const openRefundConfirmation = (refund: AdminRefundRow) => {
    setRefundNote('')
    setRefundConfirmation(refund)
  }

  const closeRefundConfirmation = () => {
    if (markRefunded.isPending) return
    setRefundConfirmation(null)
    setRefundNote('')
  }

  const confirmRefund = async () => {
    if (!refundConfirmation) return
    try {
      await markRefunded.mutateAsync({
        paymentId: refundConfirmation.payment_id,
        note: refundNote.trim() || null,
      })
      toast.success('Refund recorded', {
        description: `Marked as refunded outside FitDesk for ${refundConfirmation.member_name}. No refund API was called.`,
      })
      setRefundConfirmation(null)
      setRefundNote('')
    } catch {
      // The mutation surfaces a toast; keep the modal open for a retry.
    }
  }

  const isApprove = confirmation?.decision === 'approved'

  return (
    <div className="page-x">
      <PageHeader
        title="Payment approvals"
        subtitle="Review package purchases and renewals before they activate."
        action={<ThemeToggle />}
      />

      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        <SummaryTile
          icon={<Clock3 className="h-4 w-4" />}
          label="Waiting for review"
          value={String(payments.length)}
          tone="warning"
        />
        <SummaryTile
          icon={<IndianRupee className="h-4 w-4" />}
          label="Pending value"
          value={formatINR(totalValue)}
          tone="primary"
        />
        <SummaryTile
          icon={<ShieldCheck className="h-4 w-4" />}
          label="Admin only"
          value="RLS enforced"
          tone="success"
        />
      </div>

      <div className="mt-5 flex items-center justify-between gap-3">
        <div className="flex items-center gap-2 text-[11px] font-semibold text-muted">
          <ReceiptText className="h-3.5 w-3.5" />
          Pending queue
          {queueQuery.isFetching ? (
            <RefreshCcw className="h-3 w-3 animate-spin text-faint" />
          ) : null}
        </div>
        <button
          type="button"
          onClick={() => void queueQuery.refetch()}
          className="inline-flex items-center gap-1 text-[11px] font-semibold text-primary-strong"
        >
          <RefreshCcw className="h-3 w-3" />
          Refresh
        </button>
      </div>

      <div className="mt-3">
        {queueQuery.isError ? (
          <ErrorState
            title="Could not load the approval queue"
            message={
              queueQuery.error instanceof Error
                ? queueQuery.error.message
                : 'Check your connection and try again.'
            }
            onRetry={() => void queueQuery.refetch()}
          />
        ) : queueQuery.isLoading ? (
          <div className="space-y-3">
            {[0, 1, 2].map((index) => (
              <Skeleton key={index} className="h-48 rounded-3xl" />
            ))}
          </div>
        ) : payments.length === 0 ? (
          <EmptyState
            icon={<CheckCircle2 className="h-5 w-5" />}
            title="Queue is clear"
            description="No payments are waiting for approval. New submissions will appear here automatically."
            className="py-12"
          />
        ) : (
          <div className="space-y-3">
            {payments.map((payment) => (
              <ApprovalCard
                key={payment.payment_id}
                payment={payment}
                isSelf={payment.user_id === userId}
                onApprove={() => askToReview(payment, 'approved')}
                onDecline={() => askToReview(payment, 'declined')}
              />
            ))}
          </div>
        )}
      </div>

      <div className="mt-7 flex items-center justify-between gap-3">
        <div className="flex items-center gap-2 text-[11px] font-semibold text-muted">
          <Banknote className="h-3.5 w-3.5" />
          Manual refund queue
          {refundsQuery.isFetching ? (
            <RefreshCcw className="h-3 w-3 animate-spin text-faint" />
          ) : null}
        </div>
        <button
          type="button"
          onClick={() => void refundsQuery.refetch()}
          className="inline-flex items-center gap-1 text-[11px] font-semibold text-primary-strong"
        >
          <RefreshCcw className="h-3 w-3" />
          Refresh
        </button>
      </div>

      <div className="mt-3">
        {refundsQuery.isError ? (
          <ErrorState
            title="Could not load the refund queue"
            message={
              refundsQuery.error instanceof Error
                ? refundsQuery.error.message
                : 'Check your connection and try again.'
            }
            onRetry={() => void refundsQuery.refetch()}
          />
        ) : refundsQuery.isLoading ? (
          <Skeleton className="h-32 rounded-3xl" />
        ) : refunds.length === 0 ? (
          <EmptyState
            icon={<Banknote className="h-5 w-5" />}
            title="No refunds pending"
            description="Declined payments with a captured gateway payment appear here for manual tracking. FitDesk never calls a live refund API."
            className="py-8"
          />
        ) : (
          <div className="space-y-3">
            {refunds.map((refund) => (
              <RefundCard
                key={refund.payment_id}
                refund={refund}
                onMarkRefunded={() => openRefundConfirmation(refund)}
              />
            ))}
          </div>
        )}
      </div>

      <p className="mt-6 text-center text-[10px] text-faint">
        Approvals are final. Only Admin-role accounts can change a payment to approved or
        declined. Refunds are performed manually outside FitDesk and are only recorded here.
      </p>

      <Sheet
        open={Boolean(confirmation)}
        onOpenChange={(open) => {
          if (!open) closeConfirmation()
        }}
        title={isApprove ? 'Approve this payment?' : 'Decline this payment?'}
        description={
          confirmation
            ? `${confirmation.payment.member_name} · ${
                confirmation.payment.package_name
              } · ${formatINR(confirmation.payment.total_amount_inr)}`
            : undefined
        }
        size="sm"
        hideClose={reviewPayment.isPending}
        footer={
          <div className="grid grid-cols-2 gap-2">
            <Button
              variant="secondary"
              onClick={closeConfirmation}
              disabled={reviewPayment.isPending}
            >
              Cancel
            </Button>
            <Button
              variant={isApprove ? 'primary' : 'danger'}
              onClick={() => void confirmReview()}
              loading={reviewPayment.isPending}
              disabled={
                confirmation?.payment.user_id === userId ||
                (confirmation?.payment.reconciliation_required === true &&
                  !note.trim())
              }
              leadingIcon={
                isApprove ? (
                  <CheckCircle2 className="h-4 w-4" />
                ) : (
                  <XCircle className="h-4 w-4" />
                )
              }
            >
              {isApprove ? 'Approve' : 'Decline'}
            </Button>
          </div>
        }
      >
        {confirmation ? (
          <div className="space-y-4">
            {confirmation.payment.user_id === userId ? (
              <div className="flex items-start gap-3 rounded-2xl border border-danger/20 bg-danger/[0.05] p-3.5">
                <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
                <p className="text-[11.5px] leading-relaxed text-ink">
                  You cannot review your own payment. Ask another Admin-role account to approve
                  or decline it.
                </p>
              </div>
            ) : null}

            {confirmation.payment.reconciliation_required ? (
              <div className="rounded-2xl border border-warning/25 bg-warning/[0.06] p-3.5">
                <div className="flex items-start gap-3">
                  <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
                  <div>
                    <p className="text-[11.5px] font-semibold text-ink">
                      Reconciliation required
                    </p>
                    <p className="mt-1 text-[10.5px] leading-relaxed text-muted">
                      {confirmation.payment.reconciliation_reason ??
                        'This payment may already have been sent. Check the bank statement before deciding.'}
                    </p>
                    <p className="mt-1 text-[10px] leading-relaxed text-faint">
                      A note is required. If the payment was captured and you decline it, it will
                      be added to the manual refund queue.
                    </p>
                  </div>
                </div>
              </div>
            ) : null}

            <div
              className={cn(
                'flex items-start gap-3 rounded-2xl border p-3.5',
                isApprove
                  ? 'border-warning/25 bg-warning/[0.06]'
                  : 'border-danger/20 bg-danger/[0.05]',
              )}
            >
              <TriangleAlert
                className={cn(
                  'mt-0.5 h-4 w-4 shrink-0',
                  isApprove ? 'text-warning' : 'text-danger',
                )}
              />
              <p className="text-[11.5px] leading-relaxed text-ink">
                Are you sure you want to {isApprove ? 'approve' : 'decline'} this transaction?
                This action cannot be undone.
              </p>
            </div>

            {isApprove ? (
              <p className="text-[11px] leading-relaxed text-muted">
                Approving activates the purchased package. If the member&apos;s current plan is
                still valid, the new plan starts the day after it expires so no paid days are
                lost. If the plan has already lapsed, the new plan starts today.
              </p>
            ) : (
              <p className="text-[11px] leading-relaxed text-muted">
                Declining keeps the member&apos;s current plan and expiry unchanged. The member is
                told to contact the gym for a manual refund, and no plan is activated.
              </p>
            )}

            <label className="block">
              <span className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
                {confirmation.payment.reconciliation_required
                  ? 'Reconciliation note (required)'
                  : 'Note to the member (optional)'}
              </span>
              <textarea
                value={note}
                onChange={(event) => setNote(event.target.value)}
                rows={2}
                maxLength={240}
                placeholder={
                  confirmation.payment.reconciliation_required
                    ? 'e.g. Checked bank statement: payment received / not received, refund requested'
                    : isApprove
                      ? 'e.g. Verified at the front desk'
                      : 'e.g. Payment could not be verified'
                }
                className="mt-1.5 w-full resize-none rounded-xl border border-line bg-surface px-3 py-2 text-[12px] text-ink outline-none transition focus:border-primary/40 focus:ring-2 focus:ring-primary/15"
              />
            </label>
          </div>
        ) : null}
      </Sheet>

      <Sheet
        open={Boolean(refundConfirmation)}
        onOpenChange={(open) => {
          if (!open) closeRefundConfirmation()
        }}
        title="Record a manual refund?"
        description={
          refundConfirmation
            ? `${refundConfirmation.member_name} · ${refundConfirmation.package_name} · ${formatINR(refundConfirmation.total_amount_inr)}`
            : undefined
        }
        size="sm"
        hideClose={markRefunded.isPending}
        footer={
          <div className="grid grid-cols-2 gap-2">
            <Button
              variant="secondary"
              onClick={closeRefundConfirmation}
              disabled={markRefunded.isPending}
            >
              Cancel
            </Button>
            <Button
              onClick={() => void confirmRefund()}
              loading={markRefunded.isPending}
              leadingIcon={<Banknote className="h-4 w-4" />}
            >
              Mark refunded
            </Button>
          </div>
        }
      >
        {refundConfirmation ? (
          <div className="space-y-4">
            <div className="flex items-start gap-3 rounded-2xl border border-warning/25 bg-warning/[0.06] p-3.5">
              <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
              <p className="text-[11.5px] leading-relaxed text-ink">
                Only confirm this after the refund has actually been issued from the gym's UPI app
                or bank account. FitDesk does not call a refund API and cannot verify that money
                moved.
              </p>
            </div>

            <div className="rounded-2xl border border-line/80 bg-elevated/40 p-3.5">
              <div className="flex items-center justify-between text-[11px]">
                <span className="text-muted">UPI / transaction reference</span>
                <span className="max-w-[190px] truncate font-mono text-[10px] text-ink">
                  {refundConfirmation.provider_payment_id ?? '—'}
                </span>
              </div>
              <div className="mt-2 flex items-center justify-between text-[11px]">
                <span className="text-muted">Declined on</span>
                <span className="font-semibold text-ink">
                  {refundConfirmation.reviewed_at
                    ? formatKolkata(refundConfirmation.reviewed_at, 'd MMM yyyy, h:mm a')
                    : '—'}
                </span>
              </div>
            </div>

            <label className="block">
              <span className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
                Refund reference / note (optional)
              </span>
              <textarea
                value={refundNote}
                onChange={(event) => setRefundNote(event.target.value)}
                rows={2}
                maxLength={240}
                placeholder="e.g. UPI refund 123456789012 processed on 28 Oct"
                className="mt-1.5 w-full resize-none rounded-xl border border-line bg-surface px-3 py-2 text-[12px] text-ink outline-none transition focus:border-primary/40 focus:ring-2 focus:ring-primary/15"
              />
            </label>
          </div>
        ) : null}
      </Sheet>
    </div>
  )
}

function SummaryTile({
  icon,
  label,
  value,
  tone,
}: {
  icon: ReactNode
  label: string
  value: string
  tone: 'warning' | 'primary' | 'success'
}) {
  const toneClass =
    tone === 'warning'
      ? 'bg-warning/10 text-warning'
      : tone === 'success'
        ? 'bg-success/10 text-success'
        : 'bg-primary-soft text-primary-strong'
  return (
    <div className="rounded-2xl border border-line/80 bg-surface p-3.5">
      <div className="flex items-center gap-2">
        <span className={cn('flex h-8 w-8 items-center justify-center rounded-xl', toneClass)}>
          {icon}
        </span>
        <span className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
          {label}
        </span>
      </div>
      <p className="mt-2 display-number text-[20px] leading-none text-ink">{value}</p>
    </div>
  )
}

function RefundCard({
  refund,
  onMarkRefunded,
}: {
  refund: AdminRefundRow
  onMarkRefunded: () => void
}) {
  return (
    <article className="overflow-hidden rounded-3xl border border-line/80 bg-surface shadow-card">
      <div className="flex flex-wrap items-start justify-between gap-3 p-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-[13.5px] font-semibold text-ink">{refund.member_name}</h3>
            <Badge tone="warning" dot>
              Refund pending
            </Badge>
          </div>
          <p className="mt-1 text-[10.5px] text-muted">
            {refund.package_name} · declined{' '}
            {refund.reviewed_at
              ? formatKolkata(refund.reviewed_at, 'd MMM yyyy, h:mm a')
              : 'recently'}
          </p>
          <p className="mt-1 max-w-[42ch] font-mono text-[10px] text-muted">
            {refund.provider_payment_id ?? 'No captured payment id recorded'}
          </p>
          {refund.refund_note ? (
            <p className="mt-1 text-[10px] leading-relaxed text-faint">{refund.refund_note}</p>
          ) : null}
        </div>
        <div className="text-right">
          <p className="display-number text-[19px] leading-none text-ink">
            {formatINR(refund.total_amount_inr)}
          </p>
          <Button
            variant="soft"
            size="sm"
            className="mt-2"
            onClick={onMarkRefunded}
            leadingIcon={<Banknote className="h-3.5 w-3.5" />}
          >
            Mark refunded
          </Button>
        </div>
      </div>
    </article>
  )
}

function ApprovalCard({
  payment,
  isSelf,
  onApprove,
  onDecline,
}: {
  payment: AdminPaymentRow
  isSelf: boolean
  onApprove: () => void
  onDecline: () => void
}) {
  const submittedAt = payment.paid_at ?? payment.created_at
  const quote = payment.quote
  const needsReconciliation = payment.reconciliation_required

  return (
    <article className="overflow-hidden rounded-3xl border border-line/80 bg-surface shadow-card">
      <div className="flex flex-wrap items-start justify-between gap-3 border-b border-line/70 p-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="text-[14px] font-semibold text-ink">{payment.member_name}</h3>
            <Badge tone={needsReconciliation ? 'danger' : 'warning'} dot>
              {needsReconciliation ? 'Needs reconciliation' : 'Pending approval'}
            </Badge>
            {isSelf ? <Badge tone="neutral">Your payment</Badge> : null}
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-[10.5px] text-muted">
            {payment.member_email ? (
              <span className="inline-flex items-center gap-1">
                <Mail className="h-3 w-3" />
                {payment.member_email}
              </span>
            ) : null}
            {payment.member_phone ? (
              <span className="inline-flex items-center gap-1">
                <Phone className="h-3 w-3" />
                {payment.member_phone}
              </span>
            ) : null}
          </div>
        </div>
        <div className="text-right">
          <p className="display-number text-[22px] leading-none text-ink">
            {formatINR(payment.total_amount_inr)}
          </p>
          <p className="mt-1 text-[9.5px] font-semibold uppercase tracking-[0.1em] text-faint">
            {formatKolkata(submittedAt, 'd MMM yyyy, h:mm a')}
          </p>
        </div>
      </div>

      {needsReconciliation ? (
        <div className="border-b border-line/70 bg-danger/[0.04] px-4 py-3">
          <div className="flex items-start gap-2.5">
            <TriangleAlert className="mt-0.5 h-3.5 w-3.5 shrink-0 text-danger" />
            <div>
              <p className="text-[11px] font-semibold text-ink">
                Verify this payment against the bank statement before deciding
              </p>
              <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
                {payment.reconciliation_reason ??
                  'A payment may already have been sent. This row is preserved until an admin reconciles it.'}
              </p>
            </div>
          </div>
        </div>
      ) : null}

      <div className="grid gap-3 p-4 sm:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
        <div className="rounded-2xl border border-line/70 bg-elevated/30 p-3">
          <div className="flex items-center justify-between text-[11px]">
            <span className="text-muted">Plan</span>
            <span className="font-semibold text-ink">
              {payment.package_name} · {formatDuration(payment.duration_days)}
            </span>
          </div>
          <div className="mt-2 flex items-center justify-between text-[11px]">
            <span className="text-muted">Quoted period</span>
            <span className="font-semibold text-ink">
              {quote?.starts_on ? formatKolkata(quote.starts_on, 'd MMM') : '—'} →{' '}
              {quote?.ends_on ? formatKolkata(quote.ends_on, 'd MMM yyyy') : '—'}
            </span>
          </div>
          <p className="mt-1 text-right text-[9px] leading-relaxed text-faint">
            Recalculated on approval to preserve remaining days.
          </p>
          <div className="mt-2 flex items-center justify-between text-[11px]">
            <span className="text-muted">Late fee</span>
            <span
              className={cn(
                'font-semibold',
                payment.fine_amount_inr > 0 ? 'text-warning' : 'text-ink',
              )}
            >
              {payment.fine_amount_inr > 0 ? formatINR(payment.fine_amount_inr) : 'None'}
            </span>
          </div>
          <div className="mt-2 flex items-center justify-between text-[11px]">
            <span className="text-muted">Provider payment</span>
            <span className="max-w-[190px] truncate font-mono text-[10px] text-muted">
              {payment.provider_payment_id ?? '—'}
            </span>
          </div>
        </div>

        <div className="flex flex-col justify-between gap-2">
          <div className="rounded-2xl border border-line/70 bg-elevated/30 p-3">
            <p className="text-[9.5px] font-semibold uppercase tracking-[0.12em] text-faint">
              Amount split
            </p>
            <div className="mt-1.5 flex items-center justify-between text-[10.5px]">
              <span className="text-muted">Plan</span>
              <span className="font-semibold tabular-nums text-ink">
                {formatINR(payment.base_amount_inr)}
              </span>
            </div>
            <div className="mt-1 flex items-center justify-between text-[10.5px]">
              <span className="text-muted">Fine</span>
              <span className="font-semibold tabular-nums text-ink">
                {formatINR(payment.fine_amount_inr)}
              </span>
            </div>
          </div>

          {isSelf ? (
            <p className="rounded-xl border border-line/70 bg-elevated/40 px-2.5 py-2 text-[10px] leading-relaxed text-muted">
              You cannot review your own payment. Ask another Admin-role account.
            </p>
          ) : null}

          <div className="grid grid-cols-2 gap-2">
            <Button
              variant="danger"
              size="sm"
              onClick={onDecline}
              disabled={isSelf}
              leadingIcon={<XCircle className="h-3.5 w-3.5" />}
            >
              Decline
            </Button>
            <Button
              size="sm"
              onClick={onApprove}
              disabled={isSelf}
              leadingIcon={<CheckCircle2 className="h-3.5 w-3.5" />}
            >
              Approve
            </Button>
          </div>
        </div>
      </div>
    </article>
  )
}
