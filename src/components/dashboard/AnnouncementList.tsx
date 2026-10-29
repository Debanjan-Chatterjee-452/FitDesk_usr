import { CalendarOff, Info, Megaphone } from 'lucide-react'
import type { Announcement } from '@/types'
import { Badge } from '@/components/ui/Badge'
import { formatKolkata } from '@/lib/kolkata'
import { cn } from '@/lib/utils'

const KIND_STYLES = {
  info: {
    icon: Info,
    badge: 'info' as const,
    wrapper: 'border-line/75 bg-surface',
    iconWrapper: 'bg-info/10 text-info',
  },
  holiday: {
    icon: Megaphone,
    badge: 'warning' as const,
    wrapper: 'border-warning/20 bg-warning/[0.04]',
    iconWrapper: 'bg-warning/10 text-warning',
  },
  closure: {
    icon: CalendarOff,
    badge: 'danger' as const,
    wrapper: 'border-danger/15 bg-danger/[0.035]',
    iconWrapper: 'bg-danger/10 text-danger',
  },
}

export function AnnouncementItem({ announcement }: { announcement: Announcement }) {
  const styles = KIND_STYLES[announcement.kind]
  const Icon = styles.icon
  const dateLabel =
    announcement.starts_on === announcement.ends_on
      ? formatKolkata(announcement.starts_on, 'd MMM')
      : `${formatKolkata(announcement.starts_on, 'd MMM')} – ${formatKolkata(
          announcement.ends_on ?? announcement.starts_on,
          'd MMM',
        )}`

  return (
    <article className={cn('rounded-2xl border p-3.5', styles.wrapper)}>
      <div className="flex gap-3">
        <div
          className={cn(
            'flex h-9 w-9 shrink-0 items-center justify-center rounded-xl',
            styles.iconWrapper,
          )}
        >
          <Icon className="h-[16px] w-[16px]" />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-2">
            <h3 className="text-[12.5px] font-semibold leading-snug text-ink">
              {announcement.title}
            </h3>
            <Badge tone={styles.badge} className="shrink-0">
              {announcement.kind === 'info' ? 'Notice' : announcement.kind === 'holiday' ? 'Holiday' : 'Closure'}
            </Badge>
          </div>
          {announcement.body ? (
            <p className="mt-1 text-[11px] leading-relaxed text-muted">{announcement.body}</p>
          ) : null}
          <p className="mt-1.5 text-[9.5px] font-medium uppercase tracking-[0.1em] text-faint">
            {dateLabel}
          </p>
        </div>
      </div>
    </article>
  )
}
