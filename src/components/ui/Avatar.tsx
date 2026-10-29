import { cn, initials } from '@/lib/utils'

interface AvatarProps {
  name: string | null | undefined
  size?: 'sm' | 'md' | 'lg' | 'xl'
  className?: string
}

const SIZES = {
  sm: 'h-9 w-9 text-[11px] rounded-xl',
  md: 'h-11 w-11 text-[13px] rounded-2xl',
  lg: 'h-14 w-14 text-base rounded-2xl',
  xl: 'h-20 w-20 text-2xl rounded-[26px]',
}

export function Avatar({ name, size = 'md', className }: AvatarProps) {
  return (
    <div
      className={cn(
        'relative flex shrink-0 items-center justify-center overflow-hidden bg-gradient-to-br from-primary via-primary-strong to-[#0B5F57] font-display font-semibold text-white shadow-[inset_0_1px_0_rgba(255,255,255,0.25)]',
        SIZES[size],
        className,
      )}
      aria-hidden="true"
    >
      <span className="relative z-10">{initials(name)}</span>
      <span className="absolute -right-3 -top-4 h-9 w-9 rounded-full bg-white/15 blur-[1px]" />
      <span className="absolute -bottom-4 -left-2 h-8 w-8 rounded-full bg-black/10" />
    </div>
  )
}
