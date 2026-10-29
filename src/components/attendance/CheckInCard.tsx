import { ArrowUpRight, CheckCircle2, QrCode, ScanLine } from 'lucide-react'
import type { AttendanceRecord } from '@/types'
import { formatKolkata } from '@/lib/kolkata'

interface CheckInCardProps {
  checkedInToday: boolean
  lastCheckIn: AttendanceRecord | null
  onScan: () => void
  onViewHistory: () => void
  disabled?: boolean
}

export function CheckInCard({
  checkedInToday,
  lastCheckIn,
  onScan,
  onViewHistory,
}: CheckInCardProps) {
  if (checkedInToday && lastCheckIn) {
    return (
      <section className="relative overflow-hidden rounded-[26px] border border-primary/25 bg-primary-soft/70 p-4 dark:bg-primary-soft/40">
        <div className="flex items-center gap-3.5">
          <div className="relative flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-primary text-primary-ink">
            <span className="absolute inset-0 animate-pulse-ring rounded-2xl bg-primary/30" />
            <CheckCircle2 className="relative h-6 w-6" />
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-primary-strong/70">
              Checked in today
            </p>
            <p className="mt-0.5 text-[15px] font-semibold text-ink">
              {formatKolkata(lastCheckIn.check_in_at, 'h:mm a')}
            </p>
            <p className="mt-0.5 text-[11px] text-muted">Session logged · one scan per day</p>
          </div>
          <button
            type="button"
            onClick={onViewHistory}
            aria-label="View attendance history"
            className="flex h-9 w-9 items-center justify-center rounded-xl bg-surface/70 text-primary-strong transition hover:bg-surface"
          >
            <ArrowUpRight className="h-4 w-4" />
          </button>
        </div>
      </section>
    )
  }

  return (
    <section className="relative overflow-hidden rounded-[26px] border border-primary/30 bg-primary p-1 shadow-[0_18px_44px_-22px_rgb(var(--primary)/0.8)]">
      <button
        type="button"
        onClick={onScan}
        className="group relative flex w-full items-center gap-4 overflow-hidden rounded-[22px] px-4 py-4 text-left text-primary-ink transition active:scale-[0.99]"
      >
        <span className="relative flex h-14 w-14 shrink-0 items-center justify-center rounded-2xl bg-black/10">
          <QrCode className="h-7 w-7" />
          <span className="absolute -right-1 -top-1 flex h-4 w-4 items-center justify-center rounded-full bg-white">
            <ScanLine className="h-2.5 w-2.5 text-primary-strong" />
          </span>
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-[10px] font-bold uppercase tracking-[0.16em] opacity-90">
            Attendance
          </span>
          <span className="mt-0.5 block font-display text-[18px] font-semibold tracking-[-0.02em]">
            Scan to check in
          </span>
          <span className="mt-0.5 block text-[11px] leading-relaxed opacity-70">
            Point your camera at the front-desk QR
          </span>
        </span>
        <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-black/10 transition-transform group-hover:translate-x-0.5">
          <ArrowUpRight className="h-4 w-4" />
        </span>
        <span className="pointer-events-none absolute -bottom-10 -right-8 h-28 w-28 rounded-full border border-white/15" />
        <span className="pointer-events-none absolute -bottom-4 -right-2 h-16 w-16 rounded-full border border-white/10" />
      </button>
    </section>
  )
}
