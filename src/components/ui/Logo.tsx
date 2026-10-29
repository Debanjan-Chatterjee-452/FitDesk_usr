import { useId } from 'react'
import { cn } from '@/lib/utils'

interface LogoProps {
  className?: string
  markClassName?: string
  showWordmark?: boolean
  subtitle?: string
  inverted?: boolean
}

export function Logo({
  className,
  markClassName,
  showWordmark = true,
  subtitle,
  inverted,
}: LogoProps) {
  const id = useId()
  return (
    <div className={cn('inline-flex items-center gap-2.5', className)}>
      <svg
        viewBox="0 0 44 44"
        className={cn('h-10 w-10 shrink-0', markClassName)}
        role="img"
        aria-label="FitDesk"
      >
        <defs>
          <linearGradient id={`${id}-bg`} x1="4" y1="2" x2="40" y2="42" gradientUnits="userSpaceOnUse">
            <stop stopColor="#2DD4BF" />
            <stop offset="0.55" stopColor="#0F9E8F" />
            <stop offset="1" stopColor="#0B5F57" />
          </linearGradient>
          <linearGradient id={`${id}-shine`} x1="8" y1="6" x2="28" y2="26" gradientUnits="userSpaceOnUse">
            <stop stopColor="#FFFFFF" stopOpacity="0.5" />
            <stop offset="1" stopColor="#FFFFFF" stopOpacity="0" />
          </linearGradient>
        </defs>
        <rect x="1" y="1" width="42" height="42" rx="13" fill={`url(#${id}-bg)`} />
        <rect x="1" y="1" width="42" height="42" rx="13" fill={`url(#${id}-shine)`} />
        <rect x="1" y="1" width="42" height="42" rx="13" stroke="rgba(255,255,255,0.22)" />
        <path
          d="M14 12h16v5.4H19.6v5.1h9.1v5.2h-9.1V32H14V12Z"
          fill="white"
          fillOpacity="0.97"
        />
        <path
          d="M30.5 22.4a2.9 2.9 0 1 1-5.8 0 2.9 2.9 0 0 1 5.8 0Z"
          fill="#052E2A"
          fillOpacity="0.35"
        />
      </svg>
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
