import { cn } from '@/lib/utils'
import { formatKolkata } from '@/lib/kolkata'
import type { Membership } from '@/types'

export type CardTier = 'one-day' | 'one-month' | 'silver' | 'gold' | 'diamond' | 'premium'

export function tierForDuration(durationDays: number): CardTier {
  const months = Math.round(durationDays / 30)
  if (durationDays <= 1) return 'one-day'
  if (months <= 1) return 'one-month'
  if (months <= 3) return 'silver'
  if (months <= 6) return 'gold'
  if (months <= 9) return 'diamond'
  return 'premium'
}

interface MembershipCardProps {
  membership: Membership
  userName: string
  gymName: string
  now?: Date
}

const TIER_STYLES: Record<CardTier, { bg: string; text: string; accent: string; pattern?: string }> = {
  'one-day': {
    bg: 'bg-white',
    text: 'text-[#06201C]',
    accent: 'text-[#16A34A]',
    pattern: '',
  },
  'one-month': {
    bg: 'bg-gradient-to-br from-[#B87333] to-[#8B4513]',
    text: 'text-white',
    accent: 'text-[#FCD34D]',
  },
  silver: {
    bg: 'bg-gradient-to-br from-[#C0C0C0] to-[#808080]',
    text: 'text-[#1F2937]',
    accent: 'text-[#1F2937]',
  },
  gold: {
    bg: 'bg-gradient-to-br from-[#FFD700] to-[#B8860B]',
    text: 'text-[#1F2937]',
    accent: 'text-[#1F2937]',
  },
  diamond: {
    bg: 'bg-gradient-to-br from-[#87CEEB] to-[#4682B4]',
    text: 'text-white',
    accent: 'text-white',
    pattern: 'diamond',
  },
  premium: {
    bg: 'bg-gradient-to-br from-[#1A1A1A] to-[#000000]',
    text: 'text-[#D4AF37]',
    accent: 'text-[#D4AF37]',
  },
}

export function MembershipCard({ membership, userName, gymName, now = new Date() }: MembershipCardProps) {
  const tier = tierForDuration(
    membership.package?.duration_days ?? 1,
  )
  const style = TIER_STYLES[tier]
  const isOneDay = tier === 'one-day'
  const remaining = Math.max(0, Math.ceil((new Date(membership.ends_on).getTime() - now.getTime()) / (isOneDay ? 3600000 : 86400000)))
  const remainingLabel = isOneDay ? `${remaining}h left` : `${remaining}d left`

  return (
    <div
      className={cn(
        'relative overflow-hidden rounded-[24px] p-5 shadow-card-lg',
        style.bg,
        style.text,
      )}
    >
      {tier === 'diamond' && (
        <div
          className="pointer-events-none absolute inset-0 opacity-20"
          style={{
            backgroundImage:
              'linear-gradient(45deg, transparent 48%, rgba(255,255,255,0.4) 49%, rgba(255,255,255,0.4) 51%, transparent 52%), linear-gradient(-45deg, transparent 48%, rgba(255,255,255,0.4) 49%, rgba(255,255,255,0.4) 51%, transparent 52%)',
            backgroundSize: '20px 20px',
          }}
        />
      )}
      {tier === 'premium' && (
        <div className="pointer-events-none absolute -right-8 -top-8 h-32 w-32 rounded-full bg-[#D4AF37]/10 blur-2xl" />
      )}

      <div className="relative z-10">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className={cn('text-[9px] font-bold uppercase tracking-[0.2em]', style.accent)}>
              {gymName}
            </p>
            <h3 className={cn('mt-1 text-[20px] font-bold leading-tight', style.text)}>
              {userName}
            </h3>
          </div>
          <span
            className={cn(
              'shrink-0 rounded-full px-2.5 py-1 text-[9px] font-bold uppercase tracking-[0.12em]',
              tier === 'one-day' ? 'bg-green-100 text-green-700' : 'bg-white/20',
            )}
          >
            {membership.package?.name ?? 'Membership'}
          </span>
        </div>

        <div className="mt-4 grid grid-cols-2 gap-3">
          <div>
            <p className={cn('text-[9px] font-semibold uppercase tracking-[0.12em] opacity-60')}>
              Plan
            </p>
            <p className={cn('mt-0.5 text-[12px] font-semibold', style.text)}>
              {membership.package?.name ?? 'Membership'} · {membership.package?.duration_days ?? 0} days
            </p>
          </div>
          <div>
            <p className={cn('text-[9px] font-semibold uppercase tracking-[0.12em] opacity-60')}>
              Amount
            </p>
            <p className={cn('mt-0.5 text-[12px] font-semibold', style.text)}>
              ₹{membership.price_paid_inr.toLocaleString('en-IN')}
            </p>
          </div>
          <div>
            <p className={cn('text-[9px] font-semibold uppercase tracking-[0.12em] opacity-60')}>
              Start
            </p>
            <p className={cn('mt-0.5 text-[12px] font-semibold', style.text)}>
              {formatKolkata(membership.starts_on, 'd MMM yyyy')}
            </p>
          </div>
          <div>
            <p className={cn('text-[9px] font-semibold uppercase tracking-[0.12em] opacity-60')}>
              End
            </p>
            <p className={cn('mt-0.5 text-[12px] font-semibold', style.text)}>
              {formatKolkata(membership.ends_on, 'd MMM yyyy')}
            </p>
          </div>
        </div>

        <div
          className={cn(
            'mt-4 flex items-center justify-between rounded-xl px-3 py-2',
            tier === 'one-day' ? 'bg-green-50' : 'bg-white/10',
          )}
        >
          <span className={cn('text-[10px] font-semibold uppercase tracking-[0.12em]', style.accent)}>
            Remaining
          </span>
          <span className={cn('text-[14px] font-bold', style.text)}>{remainingLabel}</span>
        </div>
      </div>
    </div>
  )
}
