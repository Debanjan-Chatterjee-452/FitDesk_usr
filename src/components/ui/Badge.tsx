import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

type BadgeTone = 'primary' | 'success' | 'warning' | 'danger' | 'neutral' | 'info' | 'dark'

const TONES: Record<BadgeTone, string> = {
  primary: 'bg-primary/10 text-primary-strong border-primary/15',
  success: 'bg-success/10 text-success border-success/15',
  warning: 'bg-warning/10 text-warning border-warning/20',
  danger: 'bg-danger/10 text-danger border-danger/20',
  neutral: 'bg-elevated text-muted border-line',
  info: 'bg-info/10 text-info border-info/15',
  dark: 'bg-ink/90 text-bg border-transparent',
}

interface BadgeProps {
  children: ReactNode
  tone?: BadgeTone
  dot?: boolean
  className?: string
  icon?: ReactNode
}

export function Badge({ children, tone = 'neutral', dot, className, icon }: BadgeProps) {
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-semibold leading-none tracking-wide',
        TONES[tone],
        className,
      )}
    >
      {dot ? <span className="h-1.5 w-1.5 rounded-full bg-current" /> : icon}
      {children}
    </span>
  )
}
