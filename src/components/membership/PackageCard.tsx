import { ArrowRight, Check, Sparkles } from 'lucide-react'
import type { GymPackage } from '@/types'
import { Badge } from '@/components/ui/Badge'
import { Button } from '@/components/ui/Button'
import { cn, formatDuration, formatINR } from '@/lib/utils'

interface PackageCardProps {
  pkg: GymPackage
  isCurrent?: boolean
  disabled?: boolean
  onSelect: (pkg: GymPackage) => void
}

export function PackageCard({ pkg, isCurrent, disabled, onSelect }: PackageCardProps) {
  const isPerDay = pkg.pricing_mode === 'per_day'
  const monthlyEquivalent = isPerDay
    ? pkg.price_inr * 30
    : (pkg.price_inr / pkg.duration_days) * 30
  const displayDuration = isPerDay
    ? `${pkg.min_days ?? 7}–${pkg.max_days ?? 180} days`
    : formatDuration(pkg.duration_days)

  return (
    <article
      className={cn(
        'relative flex flex-col overflow-hidden rounded-3xl border p-4 transition sm:p-5',
        pkg.is_recommended
          ? 'border-primary/30 bg-primary-soft/35 shadow-[0_18px_40px_-24px_rgb(var(--primary)/0.55)]'
          : 'border-line/80 bg-surface hover:border-line',
      )}
    >
      {pkg.is_recommended ? (
        <div className="absolute right-4 top-0 rounded-b-lg bg-primary px-2.5 pb-1 pt-1.5 text-[8.5px] font-bold uppercase tracking-[0.12em] text-primary-ink">
          Best value
        </div>
      ) : null}

      <div className="flex items-start justify-between gap-3 pr-12">
        <div>
          <div className="flex items-center gap-2">
            <h3 className="font-display text-[17px] font-semibold tracking-[-0.02em] text-ink">
              {pkg.name}
            </h3>
            {isCurrent ? <Badge tone="primary">Current</Badge> : null}
          </div>
          <p className="mt-0.5 text-[10.5px] font-medium uppercase tracking-[0.1em] text-faint">
            {displayDuration}
          </p>
        </div>
      </div>

      <div className="mt-4 flex items-baseline gap-1.5">
        <span className="display-number text-[28px] leading-none text-ink">
          {formatINR(pkg.price_inr)}
        </span>
        <span className="text-[11px] font-medium text-muted">
          {isPerDay ? '/ day' : '/ plan'}
        </span>
      </div>
      <p className="mt-1 text-[10.5px] text-muted">
        {isPerDay
          ? `Custom duration · about ${formatINR(monthlyEquivalent)} / month`
          : `Works out to ${formatINR(monthlyEquivalent)} / month`}
      </p>

      {pkg.description ? (
        <p className="mt-3 text-[11.5px] leading-relaxed text-muted">{pkg.description}</p>
      ) : null}

      <div className="mt-4 flex flex-wrap gap-1.5">
        <span className="inline-flex items-center gap-1 rounded-full border border-line/70 bg-surface/70 px-2 py-1 text-[9.5px] font-semibold text-muted">
          <Check className="h-3 w-3 text-primary-strong" />
          Full gym access
        </span>
        <span className="inline-flex items-center gap-1 rounded-full border border-line/70 bg-surface/70 px-2 py-1 text-[9.5px] font-semibold text-muted">
          <Check className="h-3 w-3 text-primary-strong" />
          QR check-in
        </span>
      </div>

      <Button
        type="button"
        variant={pkg.is_recommended ? 'primary' : 'secondary'}
        size="md"
        fullWidth
        className="mt-5"
        disabled={disabled}
        onClick={() => onSelect(pkg)}
        trailingIcon={
          pkg.is_recommended ? <ArrowRight className="h-4 w-4" /> : <Sparkles className="h-3.5 w-3.5" />
        }
      >
        {disabled ? 'Awaiting verification' : isCurrent ? 'Renew this plan' : 'Choose plan'}
      </Button>
    </article>
  )
}
