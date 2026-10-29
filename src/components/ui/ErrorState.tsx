import { RefreshCcw, TriangleAlert } from 'lucide-react'
import { Button } from './Button'
import { cn } from '@/lib/utils'

interface ErrorStateProps {
  title?: string
  message: string
  onRetry?: () => void
  retryLabel?: string
  className?: string
  compact?: boolean
}

export function ErrorState({
  title = 'Something went sideways',
  message,
  onRetry,
  retryLabel = 'Try again',
  className,
  compact,
}: ErrorStateProps) {
  return (
    <div
      className={cn(
        'flex flex-col items-center justify-center rounded-3xl border border-danger/15 bg-danger/[0.04] px-6 text-center',
        compact ? 'py-6' : 'py-10',
        className,
      )}
      role="alert"
    >
      <div className="mb-3 flex h-11 w-11 items-center justify-center rounded-2xl bg-danger/10 text-danger">
        <TriangleAlert className="h-5 w-5" />
      </div>
      <h3 className="text-[14px] font-semibold text-ink">{title}</h3>
      <p className="mt-1 max-w-[36ch] text-[12.5px] leading-relaxed text-muted">{message}</p>
      {onRetry ? (
        <Button
          variant="secondary"
          size="sm"
          className="mt-4"
          onClick={onRetry}
          leadingIcon={<RefreshCcw className="h-3.5 w-3.5" />}
        >
          {retryLabel}
        </Button>
      ) : null}
    </div>
  )
}
