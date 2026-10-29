import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

interface StatTileProps {
  icon: ReactNode
  value: string
  label: string
  hint?: string
  className?: string
  accent?: boolean
}

export function StatTile({ icon, value, label, hint, className, accent }: StatTileProps) {
  return (
    <div
      className={cn(
        'rounded-2xl border border-line/75 bg-surface p-3.5',
        accent && 'border-primary/15 bg-primary-soft/40',
        className,
      )}
    >
      <div className="flex items-center gap-1.5 text-muted">
        <span className={cn(accent && 'text-primary-strong')}>{icon}</span>
        <span className="text-[9.5px] font-semibold uppercase tracking-[0.12em]">{label}</span>
      </div>
      <p className="mt-2 display-number display-accent text-[22px] leading-none text-ink">{value}</p>
      {hint ? <p className="mt-1 text-[10px] text-muted">{hint}</p> : null}
    </div>
  )
}
