import {
  forwardRef,
  useId,
  useState,
  type InputHTMLAttributes,
  type ReactNode,
} from 'react'
import { Eye, EyeOff } from 'lucide-react'
import { cn } from '@/lib/utils'

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  label?: string
  hint?: string
  error?: string | null
  leading?: ReactNode
  trailing?: ReactNode
  containerClassName?: string
}

export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { className, containerClassName, label, hint, error, leading, trailing, id, ...props },
  ref,
) {
  const generatedId = useId()
  const inputId = id ?? generatedId
  const describedBy = error
    ? `${inputId}-error`
    : hint
      ? `${inputId}-hint`
      : undefined

  return (
    <div className={cn('w-full', containerClassName)}>
      {label ? (
        <label
          htmlFor={inputId}
          className="mb-2 block text-[13px] font-semibold text-ink"
        >
          {label}
        </label>
      ) : null}
      <div className="relative">
        {leading ? (
          <span className="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-muted">
            {leading}
          </span>
        ) : null}
        <input
          ref={ref}
          id={inputId}
          aria-invalid={Boolean(error)}
          aria-describedby={describedBy}
          className={cn(
            'h-[52px] w-full rounded-2xl border bg-surface px-4 text-[15px] font-medium text-ink outline-none transition',
            'placeholder:font-normal placeholder:text-faint',
            'hover:border-line/100 focus:border-primary/60 focus:ring-4 focus:ring-primary/10',
            'disabled:cursor-not-allowed disabled:bg-elevated disabled:text-muted',
            leading ? 'pl-11' : '',
            trailing ? 'pr-12' : '',
            error
              ? 'border-danger/60 focus:border-danger focus:ring-danger/10'
              : 'border-line',
            className,
          )}
          {...props}
        />
        {trailing ? (
          <span className="absolute right-2 top-1/2 -translate-y-1/2">{trailing}</span>
        ) : null}
      </div>
      {error ? (
        <p id={`${inputId}-error`} className="mt-2 text-xs font-medium text-danger">
          {error}
        </p>
      ) : hint ? (
        <p id={`${inputId}-hint`} className="mt-2 text-xs leading-relaxed text-muted">
          {hint}
        </p>
      ) : null}
    </div>
  )
})

export interface PasswordInputProps extends Omit<InputProps, 'type' | 'trailing'> {
  showLabel?: string
  hideLabel?: string
}

export const PasswordInput = forwardRef<HTMLInputElement, PasswordInputProps>(
  function PasswordInput({ showLabel = 'Show password', hideLabel = 'Hide password', ...props }, ref) {
    const [visible, setVisible] = useState(false)
    return (
      <Input
        ref={ref}
        type={visible ? 'text' : 'password'}
        autoCapitalize="none"
        autoCorrect="off"
        trailing={
          <button
            type="button"
            onClick={() => setVisible((value) => !value)}
            aria-label={visible ? hideLabel : showLabel}
            className="flex h-9 w-9 items-center justify-center rounded-xl text-muted transition hover:bg-elevated hover:text-ink"
          >
            {visible ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
          </button>
        }
        {...props}
      />
    )
  },
)
