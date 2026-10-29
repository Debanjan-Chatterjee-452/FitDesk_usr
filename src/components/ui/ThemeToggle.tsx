import { Moon, Sun } from 'lucide-react'
import { useTheme } from '@/context/ThemeProvider'
import { cn } from '@/lib/utils'

interface ThemeToggleProps {
  className?: string
}

export function ThemeToggle({ className }: ThemeToggleProps) {
  const { resolved, cycleMode } = useTheme()
  return (
    <button
      type="button"
      onClick={cycleMode}
      aria-label={resolved === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'}
      className={cn(
        'flex h-10 w-10 items-center justify-center rounded-2xl border border-line/80 bg-surface/70 text-muted transition hover:text-ink hover:shadow-sm',
        className,
      )}
    >
      {resolved === 'dark' ? <Sun className="h-[18px] w-[18px]" /> : <Moon className="h-[18px] w-[18px]" />}
    </button>
  )
}
