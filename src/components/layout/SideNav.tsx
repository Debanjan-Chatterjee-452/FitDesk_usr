import { NavLink, Link } from 'react-router-dom'
import {
  ArrowUpRight,
  CalendarDays,
  CreditCard,
  House,
  ScanLine,
  ShieldCheck,
  UserRound,
  type LucideIcon,
} from 'lucide-react'
import { Logo } from '@/components/ui/Logo'
import { Avatar } from '@/components/ui/Avatar'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Badge } from '@/components/ui/Badge'
import { useAuth } from '@/context/AuthProvider'
import { useGymOverview } from '@/hooks/queries'
import { deriveGymStatus } from '@/lib/gymStatus'
import { cn, prettyPhone } from '@/lib/utils'
import { isDemo } from '@/lib/env'

interface NavItem {
  to: string
  label: string
  icon: LucideIcon
  end?: boolean
}

const ITEMS: NavItem[] = [
  { to: '/', label: 'Overview', icon: House, end: true },
  { to: '/membership', label: 'Membership', icon: CreditCard },
  { to: '/attendance', label: 'Activity', icon: CalendarDays },
  { to: '/profile', label: 'Profile', icon: UserRound },
]

const DOT: Record<string, string> = {
  open: 'bg-success',
  closed: 'bg-danger',
  holiday: 'bg-warning',
}

export function SideNav() {
  const { profile } = useAuth()
  const gymQuery = useGymOverview()
  const gym = gymQuery.data
    ? deriveGymStatus(gymQuery.data.settings, gymQuery.data.announcements)
    : null
  const items: NavItem[] = profile?.is_admin
    ? [...ITEMS, { to: '/admin/approvals', label: 'Approvals', icon: ShieldCheck }]
    : ITEMS

  return (
    <aside className="fixed inset-y-0 left-0 z-40 hidden w-[268px] flex-col border-r border-line/70 bg-surface/55 px-5 backdrop-blur-xl lg:flex">
      <div className="flex h-[88px] items-center justify-between">
        <Link to="/" aria-label="FitDesk home" className="rounded-xl focus-ring">
          <Logo subtitle="Member app" />
        </Link>
      </div>

      <div className="mt-4">
        <Link
          to="/scan"
          className="group flex items-center justify-between rounded-2xl border border-primary/20 bg-primary-soft/60 px-3.5 py-3 transition hover:border-primary/35 hover:bg-primary-soft"
        >
          <span className="flex items-center gap-2.5">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-primary text-primary-ink shadow-[0_8px_18px_-8px_rgb(var(--primary)/0.8)]">
              <ScanLine className="h-[18px] w-[18px]" strokeWidth={2.2} />
            </span>
            <span>
              <span className="block text-[13px] font-semibold text-ink">Scan to check in</span>
              <span className="block text-[10.5px] text-muted">Use the front-desk QR</span>
            </span>
          </span>
          <ArrowUpRight className="h-4 w-4 text-primary-strong transition-transform group-hover:-translate-y-0.5 group-hover:translate-x-0.5" />
        </Link>
      </div>

      <nav className="mt-7 space-y-1" aria-label="Primary">
        <p className="eyebrow mb-3 px-2">Workspace</p>
        {items.map((item) => {
          const Icon = item.icon
          return (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.end}
              className={({ isActive }) =>
                cn(
                  'flex items-center gap-3 rounded-xl px-3 py-2.5 text-[13.5px] font-semibold transition-colors',
                  isActive
                    ? 'bg-elevated text-ink shadow-sm'
                    : 'text-muted hover:bg-elevated/60 hover:text-ink',
                )
              }
            >
              {({ isActive }) => (
                <>
                  <Icon
                    className={cn('h-[18px] w-[18px]', isActive && 'text-primary-strong')}
                    strokeWidth={isActive ? 2.2 : 1.9}
                  />
                  <span className="flex-1">{item.label}</span>
                  {isActive ? <span className="h-1.5 w-1.5 rounded-full bg-primary" /> : null}
                </>
              )}
            </NavLink>
          )
        })}
      </nav>

      <div className="mt-auto pb-5">
        {gym ? (
          <div className="mb-3 rounded-2xl border border-line/80 bg-surface p-3.5">
            <div className="flex items-center justify-between">
              <span className="text-[10px] font-semibold uppercase tracking-[0.16em] text-faint">
                Club status
              </span>
              <span className="flex items-center gap-1.5 text-[10.5px] font-semibold text-ink">
                <span className={cn('h-1.5 w-1.5 rounded-full', DOT[gym.state])} />
                {gym.label}
              </span>
            </div>
            <p className="mt-2 text-[11.5px] leading-relaxed text-muted">{gym.detail}</p>
          </div>
        ) : null}

        {isDemo ? (
          <div className="mb-3">
            <Badge tone="warning" dot>
              Demo mode
            </Badge>
          </div>
        ) : null}

        <div className="flex items-center gap-2 rounded-2xl border border-line/80 bg-surface p-2.5">
          <Link to="/profile" className="flex min-w-0 flex-1 items-center gap-2.5 rounded-xl p-1 transition hover:bg-elevated">
            <Avatar name={profile?.full_name} size="sm" />
            <span className="min-w-0">
              <span className="block truncate text-[12.5px] font-semibold text-ink">
                {profile?.full_name ?? 'FitDesk member'}
              </span>
              <span className="block truncate text-[10.5px] text-muted">
                {profile?.email || prettyPhone(profile?.phone)}
              </span>
            </span>
          </Link>
          <ThemeToggle className="h-9 w-9 rounded-xl border-transparent bg-elevated/60" />
        </div>
      </div>
    </aside>
  )
}
