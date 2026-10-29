import { Link } from 'react-router-dom'
import { ArrowUpRight, CalendarClock, QrCode, Sparkles, TriangleAlert } from 'lucide-react'
import type { Membership, MembershipSnapshot } from '@/types'
import { Badge } from '@/components/ui/Badge'
import { ProgressRing } from '@/components/ui/ProgressRing'
import { countdownTo, formatKolkata } from '@/lib/kolkata'
import { cn, formatDuration, formatINR } from '@/lib/utils'

interface MembershipHeroProps {
  snapshot: MembershipSnapshot
  now: Date
  upcoming?: Membership | null
  onRenew: () => void
  onScan: () => void
}

export function MembershipHero({
  snapshot,
  now,
  upcoming,
  onRenew,
  onScan,
}: MembershipHeroProps) {
  const { membership, isActive, isExpired, daysLeft, daysPastExpiry, progress } = snapshot

  if (!membership) {
    return (
      <section className="relative overflow-hidden rounded-[30px] border border-white/10 mesh-teal p-6 text-white shadow-card-lg noise animate-fade-up">
        <div className="relative z-10">
          <div className="flex items-center justify-between">
            <p className="text-[10px] font-semibold uppercase tracking-[0.2em] text-white/50">
              Membership
            </p>
            <Badge className="border-white/15 bg-white/10 text-white/80" dot>
              Not started
            </Badge>
          </div>
          <h2 className="mt-5 display-accent text-[27px] leading-tight">
            Your next chapter starts at the door.
          </h2>
          <p className="mt-2 max-w-[36ch] text-[12.5px] leading-relaxed text-white/60">
            Pick a plan that fits your rhythm. Monthly, quarterly, yearly, or a custom
            duration — all managed right here.
          </p>
          {upcoming ? (
            <p className="mt-3 inline-flex items-center gap-1.5 rounded-full border border-white/10 bg-white/[0.06] px-3 py-1.5 text-[10.5px] font-medium text-white/70">
              <CalendarClock className="h-3 w-3" />
              {upcoming.package?.name ?? 'Membership'} starts{' '}
              {formatKolkata(upcoming.starts_on, 'd MMM yyyy')}
            </p>
          ) : null}
          <div className="mt-6 flex flex-wrap gap-2">
            <button
              type="button"
              onClick={onRenew}
              className="tap-scale inline-flex h-11 items-center gap-2 rounded-2xl bg-white px-5 text-[13px] font-semibold text-[#06201C] transition hover:bg-white/90"
            >
              <Sparkles className="h-4 w-4" />
              Explore plans
            </button>
            <button
              type="button"
              onClick={onScan}
              className="tap-scale inline-flex h-11 items-center gap-2 rounded-2xl border border-white/15 bg-white/[0.06] px-4 text-[13px] font-semibold text-white/85 transition hover:bg-white/10"
            >
              <QrCode className="h-4 w-4" />
              Scanner
            </button>
          </div>
        </div>
        <Decorations />
      </section>
    )
  }

  const countdown = countdownTo(membership.ends_on, now)
  const packageName = membership.package?.name ?? 'Membership'
  const planDuration = membership.package?.duration_days
    ? formatDuration(membership.package.duration_days)
    : formatDuration(
        Math.max(
          1,
          Math.round(
            (new Date(membership.ends_on).getTime() - new Date(membership.starts_on).getTime()) /
              86_400_000,
          ) + 1,
        ),
      )

  const stateLabel = isActive
    ? daysLeft === 0
      ? 'Expires today'
      : 'Active'
    : isExpired
      ? 'Expired'
      : 'Inactive'

  const badgeTone = isActive
    ? daysLeft <= 3
      ? 'warning'
      : 'success'
    : 'danger'

  const ringProgress = isActive ? Math.max(0.02, 1 - progress) : 1

  return (
    <section
      className={cn(
        'relative overflow-hidden rounded-[30px] border border-white/10 p-5 text-white shadow-card-lg noise sm:p-6 animate-fade-up',
        isExpired ? 'membership-expired' : 'mesh-teal',
      )}
      style={
        isExpired
          ? {
              backgroundImage:
                'radial-gradient(90% 100% at 100% 0%, rgba(251,146,60,0.3) 0%, transparent 58%), radial-gradient(70% 80% at 0% 100%, rgba(190,24,93,0.18) 0%, transparent 60%), linear-gradient(145deg, #2A1712 0%, #1A0F0D 50%, #120A08 100%)',
            }
          : undefined
      }
    >
      <div className="relative z-10">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="text-[9.5px] font-semibold uppercase tracking-[0.2em] text-white/45">
              Current membership
            </p>
            <div className="mt-1.5 flex flex-wrap items-center gap-2">
              <h2 className="display-accent text-[25px] leading-none sm:text-[28px]">
                {packageName}
              </h2>
              {membership.package?.is_recommended ? (
                <span className="rounded-full border border-[#5EEAD4]/25 bg-[#5EEAD4]/10 px-2 py-0.5 text-[9px] font-bold uppercase tracking-[0.12em] text-[#5EEAD4]">
                  Popular
                </span>
              ) : null}
            </div>
            <p className="mt-2 text-[11.5px] font-medium text-white/45">
              {planDuration} plan · {formatINR(membership.price_paid_inr)}
            </p>
          </div>
          <Badge
            tone={badgeTone}
            dot
            className={cn(
              'shrink-0 border-white/10',
              isActive
                ? daysLeft <= 3
                  ? 'bg-warning/15 text-warning'
                  : 'bg-[#5EEAD4]/10 text-[#7DF3E1]'
                : 'bg-danger/15 text-[#FDA4AF]',
            )}
          >
            {stateLabel}
          </Badge>
        </div>

        <div className="mt-6 flex items-center justify-between gap-4">
          <div className="min-w-0">
            <p className="text-[10px] font-medium uppercase tracking-[0.14em] text-white/35">
              {isActive ? 'Valid until' : 'Expired on'}
            </p>
            <p className="mt-1 font-display text-[17px] font-semibold tracking-tight text-white/90">
              {formatKolkata(membership.ends_on, 'd MMM yyyy')}
            </p>

            {isActive ? (
              <div className="mt-3 flex items-baseline gap-1.5">
                <span className="display-number display-accent text-[34px] leading-none text-white">
                  {String(countdown.days).padStart(2, '0')}
                </span>
                <span className="text-[11px] font-semibold text-white/55">
                  {countdown.days === 1 ? 'day' : 'days'} left
                </span>
                <span className="ml-1 text-[10.5px] tabular-nums text-white/35">
                  {String(countdown.hours).padStart(2, '0')}h {String(countdown.minutes).padStart(2, '0')}m
                </span>
              </div>
            ) : (
              <div className="mt-3 flex items-baseline gap-1.5">
                <span className="display-number display-accent text-[30px] leading-none text-[#FDBA74]">
                  {daysPastExpiry}
                </span>
                <span className="text-[11px] font-semibold text-white/50">
                  {daysPastExpiry === 1 ? 'day' : 'days'} ago
                </span>
              </div>
            )}
          </div>

          <ProgressRing
            progress={ringProgress}
            size={82}
            strokeWidth={6}
            trackClassName="stroke-white/10"
            barClassName={isActive ? 'stroke-[#5EEAD4]' : 'stroke-[#FB923C]'}
            className="shrink-0"
          >
            {isActive ? (
              <>
                <span className="display-number text-[20px] leading-none text-white">
                  {daysLeft}
                </span>
                <span className="mt-0.5 text-[7.5px] font-semibold uppercase tracking-[0.12em] text-white/40">
                  days
                </span>
              </>
            ) : (
              <TriangleAlert className="h-5 w-5 text-[#FDBA74]" />
            )}
          </ProgressRing>
        </div>

        <div className="mt-5">
          <div className="flex items-center justify-between text-[9.5px] font-medium text-white/35">
            <span>{formatKolkata(membership.starts_on, 'd MMM')}</span>
            <span>{formatKolkata(membership.ends_on, 'd MMM')}</span>
          </div>
          <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-white/10">
            <div
              className={cn(
                'h-full rounded-full transition-all duration-700 ease-spring',
                isExpired ? 'bg-[#FB923C]' : 'bg-[#5EEAD4]',
              )}
              style={{ width: `${Math.round((isActive ? progress : 1) * 100)}%` }}
            />
          </div>
        </div>

        {upcoming ? (
          <div className="mt-4 flex items-start gap-2 rounded-2xl border border-white/10 bg-white/[0.06] px-3 py-2.5">
            <CalendarClock className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#7DF3E1]" />
            <p className="text-[10.5px] leading-relaxed text-white/65">
              <span className="font-semibold text-white/85">Renewal queued</span> ·{' '}
              {upcoming.package?.name ?? 'Membership'} runs{' '}
              {formatKolkata(upcoming.starts_on, 'd MMM')} –{' '}
              {formatKolkata(upcoming.ends_on, 'd MMM yyyy')}.
            </p>
          </div>
        ) : null}

        {isExpired ? (
          <div className="mt-4 flex items-start gap-2 rounded-2xl border border-white/10 bg-white/[0.06] px-3 py-2.5">
            <CalendarClock className="mt-0.5 h-3.5 w-3.5 shrink-0 text-[#FDBA74]" />
            <p className="text-[10.5px] leading-relaxed text-white/65">
              Renew to restore access and keep your training rhythm.
            </p>
          </div>
        ) : null}

        <div className="mt-5 flex gap-2">
          <button
            type="button"
            onClick={onRenew}
            className="tap-scale inline-flex h-11 flex-1 items-center justify-center gap-2 rounded-2xl bg-white px-4 text-[12.5px] font-semibold text-[#06201C] transition hover:bg-white/90 sm:flex-none sm:px-5"
          >
            <ArrowUpRight className="h-4 w-4" />
            {isActive ? 'Renew or upgrade' : 'Renew membership'}
          </button>
          <Link
            to="/attendance"
            className="tap-scale inline-flex h-11 items-center justify-center gap-2 rounded-2xl border border-white/10 bg-white/[0.07] px-4 text-[12.5px] font-semibold text-white/80 transition hover:bg-white/[0.12]"
          >
            <CalendarClock className="h-4 w-4" />
            <span className="hidden sm:inline">History</span>
          </Link>
        </div>

      </div>

      <Decorations />
    </section>
  )
}

function Decorations() {
  return (
    <>
      <div
        className="pointer-events-none absolute -right-16 -top-24 h-64 w-64 rounded-full border border-white/10"
        aria-hidden="true"
      />
      <div
        className="pointer-events-none absolute -right-8 -top-12 h-44 w-44 rounded-full border border-white/[0.07]"
        aria-hidden="true"
      />
      <div
        className="pointer-events-none absolute -bottom-20 -left-10 h-52 w-52 rounded-full bg-[#2DD4BF]/10 blur-2xl"
        aria-hidden="true"
      />
      <div
        className="pointer-events-none absolute right-4 top-16 grid grid-cols-4 gap-1.5 opacity-20"
        aria-hidden="true"
      >
        {Array.from({ length: 16 }).map((_, index) => (
          <span key={index} className="h-1 w-1 rounded-full bg-white" />
        ))}
      </div>
    </>
  )
}
