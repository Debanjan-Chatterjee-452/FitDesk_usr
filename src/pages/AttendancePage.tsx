import { useMemo, useState, type ReactNode } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  CalendarDays,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Dumbbell,
  Flame,
  QrCode,
  ScanLine,
  Sparkles,
} from 'lucide-react'
import { PageHeader } from '@/components/layout/PageHeader'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Button } from '@/components/ui/Button'
import { Skeleton } from '@/components/ui/Skeleton'
import { EmptyState } from '@/components/ui/EmptyState'
import { ErrorState } from '@/components/ui/ErrorState'
import { SectionHeading } from '@/components/ui/SectionHeading'
import { AttendanceRow } from '@/components/attendance/AttendanceRow'
import { useAttendance, useAttendanceStats, useNow } from '@/hooks/queries'
import {
  calendarDaysForMonth,
  formatKolkata,
  formatKolkataTime,
  monthKeyInKolkata,
  monthLabel,
  relativeDayLabel,
  shiftMonth,
  todayInKolkata,
} from '@/lib/kolkata'
import { cn, pluralize } from '@/lib/utils'

const WEEKDAYS = ['S', 'M', 'T', 'W', 'T', 'F', 'S']

export function AttendancePage() {
  const navigate = useNavigate()
  const now = useNow(60_000)
  const attendanceQuery = useAttendance()
  const { stats } = useAttendanceStats()
  const [month, setMonth] = useState(() => monthKeyInKolkata())
  const [selectedDate, setSelectedDate] = useState<string | null>(null)
  const [showAll, setShowAll] = useState(false)

  const records = useMemo(() => attendanceQuery.data ?? [], [attendanceQuery.data])
  const today = todayInKolkata(now)
  const currentMonth = monthKeyInKolkata(now)
  const byDate = useMemo(() => {
    const map = new Map<string, (typeof records)[number]>()
    for (const record of records) map.set(record.check_in_date, record)
    return map
  }, [records])
  const monthRecords = records.filter((record) => record.check_in_date.startsWith(month))
  const cells = calendarDaysForMonth(month)
  const selectedRecord = selectedDate ? byDate.get(selectedDate) : null

  const goMonth = (delta: number) => {
    const next = shiftMonth(month, delta)
    if (next > currentMonth) return
    setMonth(next)
    setSelectedDate(null)
  }

  return (
    <div className="page-x">
      <PageHeader
        title="Activity"
        subtitle="Every check-in, in your timezone."
        action={<ThemeToggle />}
      />

      <div className="mt-3 grid gap-5 lg:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] lg:items-start lg:gap-6">
        <div className="space-y-5">
          <section className="grid grid-cols-3 gap-2">
            <SummaryStat
              icon={<CalendarDays className="h-4 w-4" />}
              label="This month"
              value={String(stats.thisMonth)}
              hint={pluralize(stats.thisMonth, 'visit')}
            />
            <SummaryStat
              icon={<Flame className="h-4 w-4" />}
              label="Streak"
              value={String(stats.streak)}
              hint={pluralize(stats.streak, 'day')}
              accent={stats.streak >= 3}
            />
            <SummaryStat
              icon={<Dumbbell className="h-4 w-4" />}
              label="All time"
              value={String(stats.total)}
              hint="sessions"
            />
          </section>

          {stats.checkedInToday ? (
            <section className="flex items-center gap-3 rounded-3xl border border-primary/20 bg-primary-soft/50 p-4">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-primary text-primary-ink">
                <CheckCircle2 className="h-5 w-5" />
              </div>
              <div className="min-w-0 flex-1">
                <p className="text-[12.5px] font-semibold text-ink">Checked in today</p>
                <p className="mt-0.5 text-[10.5px] text-muted">
                  {stats.lastCheckIn
                    ? `Logged at ${formatKolkataTime(stats.lastCheckIn.check_in_at)} IST`
                    : 'Your session is logged.'}
                </p>
              </div>
              <Button variant="secondary" size="sm" onClick={() => navigate('/scan')}>
                Scan again
              </Button>
            </section>
          ) : (
            <button
              type="button"
              onClick={() => navigate('/scan')}
              className="group flex w-full items-center gap-3.5 rounded-3xl border border-primary/20 bg-primary p-4 text-left text-primary-ink transition active:scale-[0.99]"
            >
              <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-2xl bg-black/10">
                <QrCode className="h-5 w-5" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-[13px] font-semibold">Scan in for today</span>
                <span className="mt-0.5 block text-[10.5px] opacity-70">
                  Point your camera at the front-desk QR
                </span>
              </span>
              <ScanLine className="h-5 w-5 opacity-70 transition-transform group-hover:translate-x-0.5" />
            </button>
          )}

          <section className="card p-4 sm:p-5">
            <div className="flex items-center justify-between">
              <div>
                <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-faint">
                  Calendar
                </p>
                <h2 className="mt-0.5 font-display text-[17px] font-semibold tracking-tight text-ink">
                  {monthLabel(month)}
                </h2>
              </div>
              <div className="flex items-center gap-1.5">
                <button
                  type="button"
                  onClick={() => goMonth(-1)}
                  aria-label="Previous month"
                  className="flex h-8 w-8 items-center justify-center rounded-xl border border-line bg-surface text-muted transition hover:text-ink"
                >
                  <ChevronLeft className="h-4 w-4" />
                </button>
                <button
                  type="button"
                  onClick={() => goMonth(1)}
                  disabled={month >= currentMonth}
                  aria-label="Next month"
                  className="flex h-8 w-8 items-center justify-center rounded-xl border border-line bg-surface text-muted transition hover:text-ink disabled:opacity-40"
                >
                  <ChevronRight className="h-4 w-4" />
                </button>
              </div>
            </div>

            <div className="mt-4 grid grid-cols-7 gap-1">
              {WEEKDAYS.map((day, index) => (
                <div
                  key={`${day}-${index}`}
                  className="pb-1 text-center text-[9.5px] font-semibold uppercase tracking-wide text-faint"
                >
                  {day}
                </div>
              ))}
              {cells.map((date, index) => {
                if (!date) return <div key={`empty-${index}`} className="aspect-square" />
                const record = byDate.get(date)
                const isToday = date === today
                const isFuture = date > today
                const isSelected = date === selectedDate
                return (
                  <button
                    key={date}
                    type="button"
                    onClick={() => setSelectedDate(record ? (isSelected ? null : date) : null)}
                    disabled={!record}
                    aria-label={`${formatKolkata(date, 'd MMMM yyyy')}${record ? ', checked in' : ', no session'}`}
                    aria-pressed={isSelected}
                    className={cn(
                      'relative flex aspect-square items-center justify-center rounded-xl text-[11.5px] font-semibold transition',
                      isSelected
                        ? 'bg-primary text-primary-ink shadow-[0_6px_14px_-8px_rgb(var(--primary)/0.8)]'
                        : record
                          ? 'bg-primary-soft/70 text-primary-strong hover:bg-primary-soft'
                          : isFuture
                            ? 'text-faint/60'
                            : 'text-muted hover:bg-elevated',
                      isToday && !isSelected ? 'ring-1 ring-primary/50' : '',
                    )}
                  >
                    {Number(date.slice(8, 10))}
                    {record && !isSelected ? (
                      <span className="absolute bottom-1 h-1 w-1 rounded-full bg-primary" />
                    ) : null}
                  </button>
                )
              })}
            </div>

            <div className="mt-4 flex items-center justify-between border-t border-line/70 pt-3">
              {selectedRecord ? (
                <div className="min-w-0">
                  <p className="text-[11px] font-semibold text-ink">
                    {relativeDayLabel(selectedRecord.check_in_date, now)} ·{' '}
                    {formatKolkataTime(selectedRecord.check_in_at)}
                  </p>
                  <p className="text-[10px] text-muted">
                    {formatKolkata(selectedRecord.check_in_date, 'EEEE, d MMMM')} ·{' '}
                    {selectedRecord.source === 'qr' ? 'QR check-in' : selectedRecord.source}
                  </p>
                </div>
              ) : (
                <div>
                  <p className="text-[11px] font-semibold text-ink">
                    {monthRecords.length} {pluralize(monthRecords.length, 'session')} in{' '}
                    {formatKolkata(`${month}-01`, 'MMMM')}
                  </p>
                  <p className="text-[10px] text-muted">Tap a highlighted day for details.</p>
                </div>
              )}
              {month !== currentMonth ? (
                <button
                  type="button"
                  onClick={() => {
                    setMonth(currentMonth)
                    setSelectedDate(null)
                  }}
                  className="shrink-0 text-[10.5px] font-semibold text-primary-strong"
                >
                  Today
                </button>
              ) : null}
            </div>
          </section>
        </div>

        <section>
          <SectionHeading
            title="Session log"
            description="One entry per day, newest first."
            action={
              <span className="text-[10px] font-semibold uppercase tracking-[0.1em] text-faint">
                {records.length} total
              </span>
            }
          />
          {attendanceQuery.isError ? (
            <ErrorState
              title="Could not load attendance"
              message={
                attendanceQuery.error instanceof Error
                  ? attendanceQuery.error.message
                  : 'Try again.'
              }
              onRetry={() => void attendanceQuery.refetch()}
            />
          ) : attendanceQuery.isLoading ? (
            <div className="space-y-2">
              {[0, 1, 2, 3, 4].map((index) => (
                <Skeleton key={index} className="h-16 rounded-2xl" />
              ))}
            </div>
          ) : records.length === 0 ? (
            <EmptyState
              icon={<Sparkles className="h-5 w-5" />}
              title="No check-ins yet"
              description="Scan the QR at the front desk to log your first session."
              action={<Button onClick={() => navigate('/scan')}>Open scanner</Button>}
            />
          ) : (
            <>
              <div className="overflow-hidden rounded-3xl border border-line/80 bg-surface">
                {(showAll ? records : records.slice(0, 24)).map((record) => (
                  <div
                    key={record.id}
                    className="border-b border-line/60 px-4 last:border-0"
                  >
                    <AttendanceRow record={record} />
                  </div>
                ))}
              </div>
              {records.length > 24 ? (
                <button
                  type="button"
                  onClick={() => setShowAll((value) => !value)}
                  className="mt-3 w-full rounded-2xl border border-line bg-surface py-2.5 text-[11px] font-semibold text-muted transition hover:text-ink"
                >
                  {showAll ? 'Show less' : `Show all ${records.length} sessions`}
                </button>
              ) : null}
            </>
          )}
        </section>
      </div>
    </div>
  )
}

function SummaryStat({
  icon,
  label,
  value,
  hint,
  accent,
}: {
  icon: ReactNode
  label: string
  value: string
  hint: string
  accent?: boolean
}) {
  return (
    <div
      className={cn(
        'rounded-2xl border border-line/75 bg-surface p-3',
        accent && 'border-primary/15 bg-primary-soft/35',
      )}
    >
      <div className={cn('flex items-center gap-1.5 text-muted', accent && 'text-primary-strong')}>
        {icon}
        <span className="text-[9px] font-semibold uppercase tracking-[0.1em]">{label}</span>
      </div>
      <p className="mt-2 display-number display-accent text-[22px] leading-none text-ink">{value}</p>
      <p className="mt-1 text-[9.5px] text-muted">{hint}</p>
    </div>
  )
}
