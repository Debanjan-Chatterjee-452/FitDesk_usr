import { Dumbbell } from 'lucide-react'
import type { AttendanceRecord } from '@/types'
import { formatKolkata, formatKolkataTime, relativeDayLabel } from '@/lib/kolkata'
import { cn } from '@/lib/utils'

export function AttendanceRow({
  record,
  showDate = true,
  className,
}: {
  record: AttendanceRecord
  showDate?: boolean
  className?: string
}) {
  return (
    <div className={cn('flex items-center gap-3 py-2.5', className)}>
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-primary-soft/70 text-primary-strong">
        <Dumbbell className="h-[15px] w-[15px]" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="text-[12.5px] font-semibold text-ink">
          {showDate ? relativeDayLabel(record.check_in_date) : 'Gym session'}
        </p>
        <p className="text-[10.5px] text-muted">
          {formatKolkata(record.check_in_date, 'EEE, d MMM')} · {formatKolkataTime(record.check_in_at)}
        </p>
      </div>
      <span className="shrink-0 rounded-full border border-line bg-elevated/60 px-2 py-1 text-[9px] font-semibold uppercase tracking-[0.08em] text-muted">
        {record.source === 'qr' ? 'QR scan' : record.source}
      </span>
    </div>
  )
}
