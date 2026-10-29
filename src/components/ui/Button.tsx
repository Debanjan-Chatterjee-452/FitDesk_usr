import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from 'react'
import { cva, type VariantProps } from 'class-variance-authority'
import { Loader2 } from 'lucide-react'
import { cn } from '@/lib/utils'

const buttonVariants = cva(
  [
    'relative inline-flex select-none items-center justify-center gap-2 whitespace-nowrap rounded-2xl font-semibold',
    'transition-[transform,background-color,color,box-shadow,border-color] duration-200 ease-spring',
    'active:scale-[0.975] disabled:pointer-events-none disabled:opacity-50',
    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-2 focus-visible:ring-offset-bg',
  ],
  {
    variants: {
      variant: {
        primary:
          'bg-primary text-primary-ink shadow-[0_10px_24px_-12px_rgb(var(--primary)/0.7)] hover:bg-primary-strong',
        secondary:
          'bg-elevated text-ink border border-line/90 hover:bg-surface hover:border-line',
        outline:
          'border border-line bg-transparent text-ink hover:bg-elevated',
        ghost: 'bg-transparent text-ink hover:bg-elevated',
        soft: 'bg-primary-soft text-primary-strong hover:bg-primary-soft/80',
        danger: 'bg-danger text-white hover:brightness-95',
        'danger-soft': 'bg-danger/10 text-danger hover:bg-danger/15',
        dark: 'bg-ink text-bg hover:opacity-90',
      },
      size: {
        sm: 'h-9 rounded-xl px-3.5 text-[13px]',
        md: 'h-11 px-5 text-sm',
        lg: 'h-[52px] px-6 text-[15px]',
        icon: 'h-11 w-11 rounded-2xl',
      },
      fullWidth: {
        true: 'w-full',
      },
    },
    defaultVariants: {
      variant: 'primary',
      size: 'md',
    },
  },
)

export interface ButtonProps
  extends ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  loading?: boolean
  leadingIcon?: ReactNode
  trailingIcon?: ReactNode
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { className, variant, size, fullWidth, loading, leadingIcon, trailingIcon, children, disabled, ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      className={cn(buttonVariants({ variant, size, fullWidth }), className)}
      disabled={disabled || loading}
      {...props}
    >
      {loading ? (
        <Loader2 className="h-[18px] w-[18px] animate-spin" aria-hidden="true" />
      ) : (
        leadingIcon
      )}
      {children}
      {!loading && trailingIcon}
    </button>
  )
})

export { buttonVariants }
