import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

interface SectionHeadingProps {
  title: string
  description?: string
  action?: ReactNode
  className?: string
  eyebrow?: string
}

export function SectionHeading({
  title,
  description,
  action,
  className,
  eyebrow,
}: SectionHeadingProps) {
  return (
    <div className={cn('mb-3 flex items-end justify-between gap-3', className)}>
      <div className="min-w-0">
        {eyebrow ? <p className="eyebrow mb-1">{eyebrow}</p> : null}
        <h2 className="display-accent text-[16px] text-ink">{title}</h2>
        {description ? (
          <p className="mt-0.5 text-[11.5px] leading-relaxed text-muted">{description}</p>
        ) : null}
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </div>
  )
}
