import { NavLink, useNavigate } from 'react-router-dom'
import {
  CalendarDays,
  CreditCard,
  House,
  ScanLine,
  UserRound,
  type LucideIcon,
} from 'lucide-react'
import { cn } from '@/lib/utils'

interface NavItem {
  to: string
  label: string
  icon: LucideIcon
  end?: boolean
}

const ITEMS: NavItem[] = [
  { to: '/', label: 'Home', icon: House, end: true },
  { to: '/membership', label: 'Membership', icon: CreditCard },
  { to: '/attendance', label: 'Activity', icon: CalendarDays },
  { to: '/profile', label: 'Profile', icon: UserRound },
]

export function BottomNav() {
  const navigate = useNavigate()

  return (
    <nav
      aria-label="Primary navigation"
      className="fixed bottom-[max(env(safe-area-inset-bottom),0.65rem)] left-1/2 z-50 w-[calc(100%-1.75rem)] max-w-[430px] -translate-x-1/2 lg:hidden"
    >
      <div className="glass flex h-[70px] items-center justify-between rounded-[26px] border border-line/60 px-2 shadow-nav">
        {ITEMS.slice(0, 2).map((item) => (
          <NavItemLink key={item.to} item={item} />
        ))}

        <button
          type="button"
          onClick={() => navigate('/scan')}
          className="group flex w-[64px] shrink-0 flex-col items-center justify-start gap-1"
          aria-label="Scan gym QR code"
        >
          <span className="-mt-7 flex h-[54px] w-[54px] items-center justify-center rounded-[20px] border-[4px] border-bg bg-primary text-primary-ink shadow-[0_14px_30px_-8px_rgb(var(--primary)/0.75)] transition duration-200 ease-spring group-active:scale-95">
            <ScanLine className="h-[23px] w-[23px]" strokeWidth={2.2} />
          </span>
          <span className="-mt-0.5 text-[9.5px] font-bold uppercase tracking-[0.08em] text-primary-strong">
            Scan
          </span>
        </button>

        {ITEMS.slice(2).map((item) => (
          <NavItemLink key={item.to} item={item} />
        ))}
      </div>
    </nav>
  )
}

function NavItemLink({ item }: { item: NavItem }) {
  const Icon = item.icon
  return (
    <NavLink
      to={item.to}
      end={item.end}
      className={({ isActive }) =>
        cn(
          'relative flex w-[64px] flex-col items-center gap-1.5 rounded-2xl py-1.5 text-[9.5px] font-semibold tracking-[0.02em] transition-colors',
          isActive ? 'text-primary-strong' : 'text-muted hover:text-ink',
        )
      }
    >
      {({ isActive }) => (
        <>
          <Icon
            className={cn('h-[21px] w-[21px] transition-transform', isActive && 'scale-105')}
            strokeWidth={isActive ? 2.3 : 1.9}
          />
          <span>{item.label}</span>
          <span
            className={cn(
              'absolute -bottom-0.5 h-1 w-1 rounded-full bg-primary transition-opacity',
              isActive ? 'opacity-100' : 'opacity-0',
            )}
          />
        </>
      )}
    </NavLink>
  )
}
