import { cn } from '@/lib/utils'

interface GeometricBackgroundProps {
  className?: string
  variant?: 'page' | 'panel'
}

/**
 * Subtle abstract geometry: concentric rings, a faint grid, and soft
 * teal light blooms. Purely decorative.
 */
export function GeometricBackground({ className, variant = 'page' }: GeometricBackgroundProps) {
  return (
    <div
      className={cn('pointer-events-none absolute inset-0 overflow-hidden', className)}
      aria-hidden="true"
    >
      <div className="absolute inset-0 bg-grid-faint bg-grid opacity-[0.45] [mask-image:radial-gradient(ellipse_at_center,black_20%,transparent_75%)]" />
      <div className="absolute -right-24 -top-24 h-80 w-80 rounded-full bg-primary/10 blur-3xl" />
      <div className="absolute -bottom-32 -left-20 h-96 w-96 rounded-full bg-primary/[0.07] blur-3xl" />
      <svg
        className="absolute -right-20 top-1/3 h-[430px] w-[430px] text-primary/20 animate-spin-slow"
        viewBox="0 0 400 400"
        fill="none"
      >
        <circle cx="200" cy="200" r="150" stroke="currentColor" strokeWidth="0.8" />
        <circle cx="200" cy="200" r="112" stroke="currentColor" strokeWidth="0.8" strokeDasharray="3 9" />
        <circle cx="200" cy="200" r="74" stroke="currentColor" strokeWidth="0.8" />
        <path d="M200 50V350M50 200H350" stroke="currentColor" strokeWidth="0.5" strokeDasharray="2 12" />
      </svg>
      <svg
        className="absolute -left-24 bottom-8 h-64 w-64 text-primary/15"
        viewBox="0 0 200 200"
        fill="none"
      >
        <rect x="30" y="30" width="140" height="140" rx="36" stroke="currentColor" />
        <rect x="56" y="56" width="88" height="88" rx="24" stroke="currentColor" strokeDasharray="4 8" />
        <circle cx="100" cy="100" r="6" fill="currentColor" />
      </svg>
      {variant === 'page' ? (
        <div className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-primary/20 to-transparent" />
      ) : null}
    </div>
  )
}
