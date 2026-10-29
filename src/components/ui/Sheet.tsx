import { useEffect, useRef, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { AnimatePresence, motion } from 'framer-motion'
import { X } from 'lucide-react'
import { cn } from '@/lib/utils'

interface SheetProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  title?: string
  description?: string
  children: ReactNode
  footer?: ReactNode
  size?: 'sm' | 'md' | 'lg'
  className?: string
  hideClose?: boolean
}

const SIZES = {
  sm: 'sm:max-w-sm',
  md: 'sm:max-w-lg',
  lg: 'sm:max-w-2xl',
}

export function Sheet({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
  size = 'md',
  className,
  hideClose,
}: SheetProps) {
  const panelRef = useRef<HTMLDivElement>(null)
  const restoreFocusRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (!open) return
    restoreFocusRef.current = document.activeElement as HTMLElement | null
    const originalOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    const timer = window.setTimeout(() => panelRef.current?.focus(), 60)
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        onOpenChange(false)
      }
    }
    document.addEventListener('keydown', onKeyDown)

    return () => {
      window.clearTimeout(timer)
      document.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = originalOverflow
      restoreFocusRef.current?.focus?.()
    }
  }, [open, onOpenChange])

  if (typeof document === 'undefined') return null

  return createPortal(
    <AnimatePresence>
      {open ? (
        <div className="fixed inset-0 z-[90] flex items-end justify-center sm:items-center sm:p-6">
          <motion.button
            type="button"
            aria-label="Close dialog"
            className="absolute inset-0 bg-[#02100E]/60 backdrop-blur-[3px]"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.22 }}
            onClick={() => onOpenChange(false)}
            tabIndex={-1}
          />
          <motion.div
            ref={panelRef}
            role="dialog"
            aria-modal="true"
            aria-label={title ?? 'Dialog'}
            tabIndex={-1}
            initial={{ opacity: 0, y: 48, scale: 0.99 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 36, scale: 0.99 }}
            transition={{ type: 'spring', stiffness: 380, damping: 34 }}
            className={cn(
              'relative flex max-h-[92svh] w-full flex-col overflow-hidden rounded-t-[30px] border border-line bg-surface shadow-card-lg outline-none sm:rounded-[30px]',
              SIZES[size],
              className,
            )}
          >
            <div className="mx-auto mt-2.5 h-1.5 w-10 shrink-0 rounded-full bg-line sm:hidden" />
            {title || description || !hideClose ? (
              <div className="flex items-start justify-between gap-4 px-6 pb-4 pt-5 sm:pt-6">
                <div className="min-w-0">
                  {title ? (
                    <h2 className="text-xl font-semibold tracking-tight text-ink">{title}</h2>
                  ) : null}
                  {description ? (
                    <p className="mt-1 text-[13px] leading-relaxed text-muted">{description}</p>
                  ) : null}
                </div>
                {!hideClose ? (
                  <button
                    type="button"
                    onClick={() => onOpenChange(false)}
                    className="-mr-2 flex h-9 w-9 shrink-0 items-center justify-center rounded-xl text-muted transition hover:bg-elevated hover:text-ink"
                    aria-label="Close"
                  >
                    <X className="h-[18px] w-[18px]" />
                  </button>
                ) : null}
              </div>
            ) : null}
            <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-6 pb-6">
              {children}
            </div>
            {footer ? (
              <div className="shrink-0 border-t border-line/70 bg-surface px-6 pb-[max(env(safe-area-inset-bottom),1.25rem)] pt-4">
                {footer}
              </div>
            ) : (
              <div className="h-[max(env(safe-area-inset-bottom),0.5rem)]" />
            )}
          </motion.div>
        </div>
      ) : null}
    </AnimatePresence>,
    document.body,
  )
}
