import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

interface ProgressRingProps {
  progress: number
  size?: number
  strokeWidth?: number
  className?: string
  trackClassName?: string
  barClassName?: string
  children?: ReactNode
}

export function ProgressRing({
  progress,
  size = 96,
  strokeWidth = 6,
  className,
  trackClassName = 'stroke-white/15',
  barClassName = 'stroke-primary',
  children,
}: ProgressRingProps) {
  const clamped = Math.min(1, Math.max(0, progress))
  const radius = (size - strokeWidth) / 2
  const circumference = 2 * Math.PI * radius
  const dashOffset = circumference * (1 - clamped)

  return (
    <div
      className={cn('relative inline-flex items-center justify-center', className)}
      style={{ width: size, height: size }}
    >
      <svg width={size} height={size} className="-rotate-90" aria-hidden="true">
        <circle
          cx={size / 2}
          cy={size / 2}
          r={radius}
          fill="none"
          strokeWidth={strokeWidth}
          className={trackClassName}
        />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={radius}
          fill="none"
          strokeWidth={strokeWidth}
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={dashOffset}
          className={cn('transition-[stroke-dashoffset] duration-700 ease-spring', barClassName)}
        />
      </svg>
      <div className="absolute inset-0 flex flex-col items-center justify-center">{children}</div>
    </div>
  )
}
