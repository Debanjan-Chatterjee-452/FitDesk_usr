import { BadgeCheck, Lock } from 'lucide-react'
import type { Payment } from '@/types'
import { Sheet } from '@/components/ui/Sheet'
import { Button } from '@/components/ui/Button'
import { Badge } from '@/components/ui/Badge'
import { formatKolkata } from '@/lib/kolkata'
import { formatINR } from '@/lib/utils'

function methodLabel(payment: Payment): string {
  if (payment.provider === 'cash') return 'Cash at the gym'
  if (payment.provider === 'phonepe') return 'UPI · PhonePe'
  if (payment.provider === 'google_pay') return 'UPI · Google Pay'
  if (payment.provider === 'paytm') return 'UPI · Paytm'
  if (payment.provider === 'upi') return 'UPI'
  return payment.provider ? payment.provider.replace(/_/g, ' ') : 'Direct payment'
}

/**
 * View-only receipt for an approved payment.
 *
 * Everything is read back from the approved payment row; the member cannot
 * edit it and no gateway call is involved.
 */
export function ReceiptSheet({
  open,
  onOpenChange,
  payment,
  memberName,
  gymName,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  payment: Payment | null
  memberName?: string | null
  gymName?: string | null
}) {
  const approved = payment?.status === 'approved'
  const period =
    payment?.quote?.starts_on && payment.quote?.ends_on
      ? `${formatKolkata(payment.quote.starts_on, 'd MMM yyyy')} – ${formatKolkata(payment.quote.ends_on, 'd MMM yyyy')}`
      : null

  return (
    <Sheet
      open={open}
      onOpenChange={onOpenChange}
      title="Payment receipt"
      description="View only · issued by your gym"
    >
      {!payment || !approved ? (
        <div className="py-6 text-center text-[11.5px] text-muted">
          This receipt is available once the gym approves the payment.
        </div>
      ) : (
        <div className="space-y-4">
          <div className="rounded-2xl border border-success/20 bg-success/[0.05] p-4">
            <div className="flex items-center gap-2.5">
              <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-success/15 text-success">
                <BadgeCheck className="h-4 w-4" />
              </span>
              <div>
                <p className="text-[12.5px] font-semibold text-ink">Payment completed</p>
                <p className="text-[10px] text-muted">
                  {gymName ?? 'Your gym'} · {payment.package?.name ?? 'Membership'}
                </p>
              </div>
              <span className="ml-auto">
                <Badge tone="success" dot>
                  Paid
                </Badge>
              </span>
            </div>
          </div>

          <div className="rounded-2xl border border-line/80 bg-surface p-4">
            <ReceiptRow label="Receipt no." value={`FD-${payment.id.slice(0, 8).toUpperCase()}`} mono />
            <ReceiptRow label="Member" value={memberName || 'FitDesk member'} />
            <ReceiptRow label="Gym" value={gymName ?? 'Your gym'} />
            <ReceiptRow label="Plan" value={payment.package?.name ?? 'Membership'} />
            <ReceiptRow label="Duration" value={`${payment.duration_days} days`} />
            {period ? <ReceiptRow label="Period" value={period} /> : null}
            <ReceiptRow label="Payment method" value={methodLabel(payment)} />
            <ReceiptRow
              label="Confirmed on"
              value={formatKolkata(payment.reviewed_at ?? payment.updated_at, 'd MMM yyyy, h:mm a')}
            />
          </div>

          <div className="rounded-2xl border border-line/80 bg-elevated/40 p-4">
            <div className="flex items-center justify-between text-[11px]">
              <span className="text-muted">Plan amount</span>
              <span className="font-semibold tabular-nums text-ink">
                {formatINR(payment.base_amount_inr)}
              </span>
            </div>
            {payment.fine_amount_inr > 0 ? (
              <div className="mt-1.5 flex items-center justify-between text-[11px]">
                <span className="text-muted">Late fee</span>
                <span className="font-semibold tabular-nums text-ink">
                  {formatINR(payment.fine_amount_inr)}
                </span>
              </div>
            ) : null}
            <div className="mt-2.5 flex items-end justify-between border-t border-line/70 pt-2.5">
              <span className="text-[12px] font-semibold text-ink">Total paid</span>
              <span className="display-number text-[20px] leading-none text-ink">
                {formatINR(payment.total_amount_inr)}
              </span>
            </div>
          </div>

          <p className="flex items-start gap-1.5 text-[9.5px] leading-relaxed text-faint">
            <Lock className="mt-0.5 h-3 w-3 shrink-0" />
            This receipt cannot be edited. It records a payment already confirmed by the gym and is
            not a tax invoice.
          </p>

          <Button fullWidth variant="secondary" onClick={() => onOpenChange(false)}>
            Close
          </Button>
        </div>
      )}
    </Sheet>
  )
}

function ReceiptRow({
  label,
  value,
  mono,
}: {
  label: string
  value: string
  mono?: boolean
}) {
  return (
    <div className="flex items-center justify-between gap-4 border-b border-line/50 py-2 last:border-0">
      <span className="text-[10.5px] text-muted">{label}</span>
      <span
        className={
          mono
            ? 'text-right font-mono text-[10.5px] font-semibold text-ink'
            : 'text-right text-[11px] font-semibold text-ink'
        }
      >
        {value}
      </span>
    </div>
  )
}
