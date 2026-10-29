import { Clock3, MapPin, PartyPopper, ShieldAlert, Wifi } from 'lucide-react'
import type { GymStatusInfo } from '@/types'
import { Badge } from '@/components/ui/Badge'
import { cn } from '@/lib/utils'

const STATE_STYLES = {
  open: {
    card: 'border-success/20 bg-success/[0.055]',
    icon: 'bg-success/10 text-success',
    dot: 'bg-success',
    badge: 'success' as const,
  },
  closed: {
    card: 'border-danger/15 bg-danger/[0.04]',
    icon: 'bg-danger/10 text-danger',
    dot: 'bg-danger',
    badge: 'danger' as const,
  },
  holiday: {
    card: 'border-warning/20 bg-warning/[0.055]',
    icon: 'bg-warning/10 text-warning',
    dot: 'bg-warning',
    badge: 'warning' as const,
  },
}

export function GymStatusCard({ gym }: { gym: GymStatusInfo }) {
  const styles = STATE_STYLES[gym.state]
  const Icon = gym.state === 'open' ? Wifi : gym.state === 'holiday' ? PartyPopper : ShieldAlert

  return (
    <section className={cn('rounded-3xl border p-4', styles.card)}>
      <div className="flex items-start justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <div className={cn('flex h-9 w-9 items-center justify-center rounded-xl', styles.icon)}>
            <Icon className="h-[17px] w-[17px]" />
          </div>
          <div>
            <p className="text-[10px] font-semibold uppercase tracking-[0.16em] text-faint">
              Gym status
            </p>
            <p className="mt-0.5 flex items-center gap-1.5 text-[13px] font-semibold text-ink">
              <span className={cn('h-1.5 w-1.5 rounded-full', styles.dot)} />
              {gym.label}
            </p>
          </div>
        </div>
        <Badge tone={styles.badge}>{gym.state === 'open' ? 'Open' : gym.state === 'holiday' ? 'Holiday' : 'Closed'}</Badge>
      </div>

      <p className="mt-3 text-[12px] leading-relaxed text-muted">{gym.detail}</p>

      <div className="mt-3 grid gap-2 border-t border-line/60 pt-3 text-[11px] text-muted">
        <div className="flex items-center gap-2">
          <Clock3 className="h-3.5 w-3.5 text-faint" />
          <span>Today · {gym.hours}</span>
        </div>
        {gym.settings?.address ? (
          <div className="flex items-start gap-2">
            <MapPin className="mt-0.5 h-3.5 w-3.5 shrink-0 text-faint" />
            <span className="line-clamp-2">{gym.settings.address}</span>
          </div>
        ) : null}
      </div>

      {gym.announcement && gym.announcement.kind !== 'info' ? (
        <p className="mt-3 rounded-xl bg-surface/70 px-2.5 py-2 text-[10.5px] font-medium text-ink">
          {gym.announcement.title}
        </p>
      ) : null}
    </section>
  )
}
