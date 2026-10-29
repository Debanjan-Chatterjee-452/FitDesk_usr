import { cn } from '@/lib/utils'

interface ToggleProps {
  checked: boolean
  onChange: (next: boolean) => void
  label?: string
  description?: string
  disabled?: boolean
  id?: string
  className?: string
}

export function Toggle({
  checked,
  onChange,
  label,
  description,
  disabled,
  id,
  className,
}: ToggleProps) {
  return (
    <div className={cn('flex items-center justify-between gap-4', className)}>
      {label || description ? (
        <div className="min-w-0">
          {label ? (
            <label htmlFor={id} className="block text-sm font-semibold text-ink">
              {label}
            </label>
          ) : null}
          {description ? (
            <p className="mt-0.5 text-xs leading-relaxed text-muted">{description}</p>
          ) : null}
        </div>
      ) : null}
      <button
        id={id}
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={!label ? 'Toggle' : undefined}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        className={cn(
          'relative h-7 w-[46px] shrink-0 rounded-full border transition-colors duration-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-2 focus-visible:ring-offset-bg disabled:opacity-50',
          checked
            ? 'border-primary/30 bg-primary'
            : 'border-line bg-elevated',
        )}
      >
        <span
          className={cn(
            'absolute top-[3px] h-[20px] w-[20px] rounded-full bg-white shadow-sm transition-all duration-300 ease-spring',
            checked ? 'left-[23px]' : 'left-[3px]',
          )}
        />
      </button>
    </div>
  )
}
