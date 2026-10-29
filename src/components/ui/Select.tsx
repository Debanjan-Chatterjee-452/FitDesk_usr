import { forwardRef, type SelectHTMLAttributes } from 'react'
import { ChevronDown } from 'lucide-react'
import { cn } from '@/lib/utils'

export interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  label?: string
  hint?: string
  error?: string | null
  containerClassName?: string
}

export const Select = forwardRef<HTMLSelectElement, SelectProps>(function Select(
  { className, containerClassName, label, hint, error, id, children, ...props },
  ref,
) {
  return (
    <div className={cn('w-full', containerClassName)}>
      {label ? (
        <label htmlFor={id} className="mb-2 block text-[13px] font-semibold text-ink">
          {label}
        </label>
      ) : null}
      <div className="relative">
        <select
          ref={ref}
          id={id}
          className={cn(
            'h-[52px] w-full appearance-none rounded-2xl border border-line bg-surface pl-4 pr-11 text-[15px] font-medium text-ink outline-none transition',
            'hover:border-line focus:border-primary/60 focus:ring-4 focus:ring-primary/10',
            error && 'border-danger/60',
            className,
          )}
          {...props}
        >
          {children}
        </select>
        <ChevronDown className="pointer-events-none absolute right-4 top-1/2 h-4 w-4 -translate-y-1/2 text-muted" />
      </div>
      {error ? (
        <p className="mt-2 text-xs font-medium text-danger">{error}</p>
      ) : hint ? (
        <p className="mt-2 text-xs text-muted">{hint}</p>
      ) : null}
    </div>
  )
})
