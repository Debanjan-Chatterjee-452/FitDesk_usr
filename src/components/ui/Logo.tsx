import { cn } from '@/lib/utils'
import { FitDeskIcon } from './FitDeskLogo'

interface LogoProps {
  className?: string
  markClassName?: string
  showWordmark?: boolean
  subtitle?: string
  inverted?: boolean
}

/**
 * Backwards-compatible wrapper around the exact FitDesk artwork. Existing
 * headers keep their compact icon + wordmark layout; the icon is the real
 * emblem from the official SVG, not a redrawn approximation.
 */
export function Logo({
  className,
  markClassName,
  showWordmark = true,
  subtitle,
  inverted,
}: LogoProps) {
  return (
    <div className={cn('inline-flex items-center gap-2.5', className)}>
      <FitDeskIcon
        className={cn(
          'h-10 w-10 shrink-0',
          inverted ? 'text-white' : 'text-primary',
          markClassName,
        )}
      />
      {showWordmark ? (
        <div className="leading-none">
          <span
            className={cn(
              'font-display text-[19px] font-semibold tracking-[-0.035em]',
              inverted ? 'text-white' : 'text-ink',
            )}
          >
            FitDesk
          </span>
          {subtitle ? (
            <span
              className={cn(
                'mt-1 block text-[9px] font-semibold uppercase tracking-[0.24em]',
                inverted ? 'text-white/55' : 'text-muted',
              )}
            >
              {subtitle}
            </span>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
