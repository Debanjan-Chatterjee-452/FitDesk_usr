import { Link } from 'react-router-dom'
import { BellRing, ChevronRight, TriangleAlert } from 'lucide-react'
import type { MembershipSnapshot } from '@/types'
import { buildExpiryWarning, type ExpiryWarningTone } from '@/lib/expiryWarning'
import { cn, formatINR } from '@/lib/utils'

const TONE_STYLES: Record<ExpiryWarningTone, { wrap: string; badge: string; icon: string }> = {
  reminder: {
    wrap: 'border-primary/20 bg-primary-soft/50 hover:border-primary/35',
    badge: 'bg-primary/10',
    icon: 'text-primary-strong',
  },
  warning: {
    wrap: 'border-warning/25 bg-warning/[0.06] hover:border-warning/40',
    badge: 'bg-warning/10',
    icon: 'text-warning',
  },
  danger: {
    wrap: 'border-danger/20 bg-danger/[0.05] hover:border-danger/35',
    badge: 'bg-danger/10',
    icon: 'text-danger',
  },
}

interface ExpiryWarningBannerProps {
  snapshot: MembershipSnapshot
  /** Ticking clock, so day counts stay correct without a reload. */
  now: Date
  /** An approved renewal already queued after this plan. */
  hasUpcomingPlan?: boolean
  /** A UTR has been submitted and is awaiting admin verification. */
  paymentPending?: boolean
  className?: string
}

/**
 * In-app expiry / late-fee warning. Renders nothing when the member has no
 * plan, is outside the 3-day window, is cancelled, or already has an approved
 * renewal queued. It disappears automatically once approval extends or stacks
 * the membership, because that changes the plan the counts are derived from.
 */
export function ExpiryWarningBanner({
  snapshot,
  now,
  hasUpcomingPlan = false,
  paymentPending = false,
  className,
}: ExpiryWarningBannerProps) {
  const membership = snapshot.membership
  if (!membership) return null

  const warning = buildExpiryWarning({
    endsOn: membership.ends_on,
    now,
    isCancelled: membership.status === 'cancelled',
    hasUpcomingPlan,
  })
  if (!warning) return null

  const styles = TONE_STYLES[warning.tone]
  const Icon = warning.tone === 'reminder' ? BellRing : TriangleAlert

  return (
    <Link
      to="/membership"
      className={cn(
        'flex items-start gap-3 rounded-2xl border p-3.5 transition focus-ring animate-fade-up',
        styles.wrap,
        className,
      )}
    >
      <span
        className={cn(
          'mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-xl',
          styles.badge,
        )}
      >
        <Icon className={cn('h-4 w-4', styles.icon)} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="block text-[12px] font-semibold text-ink">{warning.title}</span>
        <span className="mt-0.5 block text-[10.5px] leading-relaxed text-muted">
          {warning.message}
        </span>
        {warning.fine > 0 ? (
          <span className="mt-1.5 inline-flex items-center rounded-full bg-ink/[0.05] px-2 py-0.5 text-[9.5px] font-semibold tabular-nums text-ink">
            Renewal fine if paid today: {formatINR(warning.fine)}
          </span>
        ) : null}
        {paymentPending ? (
          <span className="mt-1.5 block text-[9.5px] leading-relaxed text-faint">
            Your submitted payment is awaiting gym verification. Your expiry date and any fine
            stay unchanged until it is approved.
          </span>
        ) : null}
      </span>
      <ChevronRight className="mt-1 h-4 w-4 shrink-0 text-muted" />
    </Link>
  )
}
