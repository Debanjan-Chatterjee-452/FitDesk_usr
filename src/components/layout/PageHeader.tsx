import type { ReactNode } from 'react'
import { useNavigate } from 'react-router-dom'
import { ChevronLeft } from 'lucide-react'
import { cn } from '@/lib/utils'

interface PageHeaderProps {
  title?: string
  subtitle?: string
  eyebrow?: string
  back?: boolean
  fallbackPath?: string
  action?: ReactNode
  className?: string
  children?: ReactNode
}

export function PageHeader({
  title,
  subtitle,
  eyebrow,
  back,
  fallbackPath = '/',
  action,
  className,
  children,
}: PageHeaderProps) {
  const navigate = useNavigate()

  const goBack = () => {
    if (window.history.length > 1) navigate(-1)
    else navigate(fallbackPath)
  }

  return (
    <header className={cn('safe-top', className)}>
      <div className="flex items-center justify-between gap-3 py-3">
        <div className="flex min-w-0 items-center gap-3">
          {back ? (
            <button
              type="button"
              onClick={goBack}
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl border border-line/80 bg-surface text-ink transition hover:bg-elevated"
              aria-label="Go back"
            >
              <ChevronLeft className="h-5 w-5" />
            </button>
          ) : null}
          <div className="min-w-0">
            {eyebrow ? <p className="eyebrow mb-1">{eyebrow}</p> : null}
            {title ? (
              <h1 className="truncate display-accent text-[22px] text-ink sm:text-2xl">
                {title}
              </h1>
            ) : null}
            {subtitle ? (
              <p className="mt-0.5 truncate text-[12.5px] text-muted">{subtitle}</p>
            ) : null}
            {children}
          </div>
        </div>
        {action ? <div className="flex shrink-0 items-center gap-2">{action}</div> : null}
      </div>
    </header>
  )
}
