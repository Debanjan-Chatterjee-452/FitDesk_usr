import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

export interface SegmentOption<T extends string> {
  value: T
  label: string
  icon?: ReactNode
}

interface SegmentedControlProps<T extends string> {
  options: Array<SegmentOption<T>>
  value: T
  onChange: (value: T) => void
  className?: string
  size?: 'sm' | 'md'
  ariaLabel?: string
}

export function SegmentedControl<T extends string>({
  options,
  value,
  onChange,
  className,
  size = 'md',
  ariaLabel,
}: SegmentedControlProps<T>) {
  return (
    <div
      role="radiogroup"
      aria-label={ariaLabel}
      className={cn(
        'grid w-full gap-1 rounded-2xl border border-line/80 bg-elevated p-1',
        className,
      )}
      style={{ gridTemplateColumns: `repeat(${options.length}, minmax(0, 1fr))` }}
    >
      {options.map((option) => {
        const selected = option.value === value
        return (
          <button
            key={option.value}
            type="button"
            role="radio"
            aria-checked={selected}
            onClick={() => onChange(option.value)}
            className={cn(
              'flex items-center justify-center gap-1.5 rounded-xl font-semibold transition-all duration-200',
              size === 'sm' ? 'h-8 px-2 text-[11px]' : 'h-10 px-3 text-[13px]',
              selected
                ? 'bg-surface text-ink shadow-sm'
                : 'text-muted hover:text-ink',
            )}
          >
            {option.icon}
            {option.label}
          </button>
        )
      })}
    </div>
  )
}
