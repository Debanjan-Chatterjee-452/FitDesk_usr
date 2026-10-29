import {
  useEffect,
  useRef,
  type ClipboardEvent,
  type KeyboardEvent,
} from 'react'
import { cn } from '@/lib/utils'

interface OtpInputProps {
  value: string
  onChange: (value: string) => void
  length?: number
  disabled?: boolean
  autoFocus?: boolean
  error?: boolean
  className?: string
}

export function OtpInput({
  value,
  onChange,
  length = 6,
  disabled,
  autoFocus,
  error,
  className,
}: OtpInputProps) {
  const refs = useRef<Array<HTMLInputElement | null>>([])
  const digits = value.padEnd(length, ' ').slice(0, length).split('')

  useEffect(() => {
    if (autoFocus) refs.current[0]?.focus()
  }, [autoFocus])

  const commit = (next: string) => {
    onChange(next.replace(/\D/g, '').slice(0, length))
  }

  const focusAt = (index: number) => {
    const bounded = Math.max(0, Math.min(length - 1, index))
    refs.current[bounded]?.focus()
    refs.current[bounded]?.select()
  }

  const handleChange = (index: number, raw: string) => {
    const cleaned = raw.replace(/\D/g, '')
    if (!cleaned) return
    if (cleaned.length > 1) {
      const next = (value.slice(0, index) + cleaned).replace(/\D/g, '').slice(0, length)
      commit(next)
      focusAt(Math.min(next.length, length - 1))
      return
    }
    const chars = value.padEnd(length, ' ').split('')
    chars[index] = cleaned
    commit(chars.join('').trimEnd())
    focusAt(index + 1)
  }

  const handleKeyDown = (index: number, event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Backspace') {
      event.preventDefault()
      const chars = value.padEnd(length, ' ').split('')
      if (chars[index]?.trim()) {
        chars[index] = ' '
        commit(chars.join('').trimEnd())
        focusAt(index - 1)
      } else {
        chars[index - 1] = ' '
        commit(chars.join('').trimEnd())
        focusAt(index - 1)
      }
    }
    if (event.key === 'ArrowLeft') {
      event.preventDefault()
      focusAt(index - 1)
    }
    if (event.key === 'ArrowRight') {
      event.preventDefault()
      focusAt(index + 1)
    }
  }

  const handlePaste = (event: ClipboardEvent<HTMLInputElement>) => {
    event.preventDefault()
    const pasted = event.clipboardData.getData('text').replace(/\D/g, '').slice(0, length)
    if (!pasted) return
    commit(pasted)
    focusAt(Math.min(pasted.length, length - 1))
  }

  return (
    <div
      className={cn('flex items-center justify-between gap-2 sm:gap-2.5', className)}
      role="group"
      aria-label="One-time password"
    >
      {digits.map((digit, index) => (
        <input
          key={index}
          ref={(element) => {
            refs.current[index] = element
          }}
          value={digit.trim()}
          onChange={(event) => handleChange(index, event.target.value)}
          onKeyDown={(event) => handleKeyDown(index, event)}
          onPaste={handlePaste}
          onFocus={(event) => event.target.select()}
          inputMode="numeric"
          pattern="[0-9]*"
          autoComplete={index === 0 ? 'one-time-code' : 'off'}
          maxLength={1}
          disabled={disabled}
          aria-label={`Digit ${index + 1}`}
          aria-invalid={error}
          className={cn(
            'h-[54px] w-full min-w-0 rounded-2xl border bg-surface text-center font-display text-xl font-semibold text-ink outline-none transition',
            'focus:border-primary/70 focus:ring-4 focus:ring-primary/10',
            error ? 'border-danger/60' : 'border-line',
            'disabled:opacity-50',
          )}
        />
      ))}
    </div>
  )
}
