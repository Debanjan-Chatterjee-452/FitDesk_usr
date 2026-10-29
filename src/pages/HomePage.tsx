import { Link, useNavigate } from 'react-router-dom'
import {
  CalendarCheck2,
  ChevronRight,
  Clock3,
  Dumbbell,
  Flame,
  RefreshCcw,
  ShieldCheck,
  Sparkles,
  XCircle,
} from 'lucide-react'
import { useAuth } from '@/context/AuthProvider'
import {
  useAdminPendingPayments,
  useAttendanceStats,
  useGymOverview,
  useMembershipSnapshot,
  useNow,
  usePayments,
  usePendingPayment,
} from '@/hooks/queries'
import { Avatar } from '@/components/ui/Avatar'
import { Badge } from '@/components/ui/Badge'
import { Button } from '@/components/ui/Button'
import { PageSkeleton, Skeleton } from '@/components/ui/Skeleton'
import { ErrorState } from '@/components/ui/ErrorState'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { SectionHeading } from '@/components/ui/SectionHeading'
import { MembershipHero } from '@/components/membership/MembershipHero'
import { ExpiryWarningBanner } from '@/components/membership/ExpiryWarningBanner'
import { GymStatusCard } from '@/components/gym/GymStatusCard'
import { CheckInCard } from '@/components/attendance/CheckInCard'
import { AttendanceRow } from '@/components/attendance/AttendanceRow'
import { StatTile } from '@/components/dashboard/StatTile'
import { AnnouncementItem } from '@/components/dashboard/AnnouncementList'
import { deriveGymStatus } from '@/lib/gymStatus'
import { formatKolkata, greetingForKolkata } from '@/lib/kolkata'
import { isDemo } from '@/lib/env'
import { formatINR, pluralize } from '@/lib/utils'

export function HomePage() {
  const navigate = useNavigate()
  const { profile } = useAuth()
  const now = useNow(30_000)
  const membershipQuery = useMembershipSnapshot()
  const gymQuery = useGymOverview()
  const attendanceQuery = useAttendanceStats()
  const paymentsQuery = usePayments()
  const pendingQuery = usePendingPayment()
  const adminQuery = useAdminPendingPayments()

  const firstName = profile?.full_name?.trim().split(/\s+/)[0] ?? 'Athlete'
  const snapshot = membershipQuery.snapshot
  const gym = gymQuery.data
    ? deriveGymStatus(gymQuery.data.settings, gymQuery.data.announcements, now)
    : null
  const stats = attendanceQuery.stats
  const pendingPayment = pendingQuery.data ?? null
  const reconciliationPayment =
    pendingPayment &&
    (pendingPayment.reconciliation_required ||
      pendingPayment.checkout_state === 'reconciliation_required')
      ? pendingPayment
      : null
  const latestPayment = paymentsQuery.data?.[0] ?? null
  const declinedPayment =
    !pendingPayment && latestPayment?.status === 'declined' ? latestPayment : null
  const pendingApprovals = profile?.is_admin ? (adminQuery.data?.length ?? 0) : 0

  if (membershipQuery.isLoading && attendanceQuery.isLoading && gymQuery.isLoading) {
    return <PageSkeleton />
  }

  const announcements = (gymQuery.data?.announcements ?? []).slice(0, 3)
  const recent = (attendanceQuery.data ?? []).slice(0, 4)

  const sidebar = (
    <>
      <CheckInCard
        checkedInToday={stats.checkedInToday}
        lastCheckIn={stats.lastCheckIn}
        onScan={() => navigate('/scan')}
        onViewHistory={() => navigate('/attendance')}
      />

      {gym ? (
        <GymStatusCard gym={gym} />
      ) : gymQuery.isError ? (
        <div className="rounded-3xl border border-line bg-surface p-4">
          <p className="text-[12px] font-semibold text-ink">Club status unavailable</p>
          <button
            type="button"
            onClick={() => void gymQuery.refetch()}
            className="mt-1 inline-flex items-center gap-1 text-[11px] font-semibold text-primary-strong"
          >
            <RefreshCcw className="h-3 w-3" />
            Retry
          </button>
        </div>
      ) : (
        <Skeleton className="h-40 rounded-3xl" />
      )}

      <div className="grid grid-cols-3 gap-2">
        <StatTile
          icon={<CalendarCheck2 className="h-3.5 w-3.5" />}
          value={String(stats.thisMonth)}
          label="This month"
          hint={pluralize(stats.thisMonth, 'visit')}
        />
        <StatTile
          icon={<Flame className="h-3.5 w-3.5" />}
          value={String(stats.streak)}
          label="Streak"
          hint={pluralize(stats.streak, 'day')}
          accent={stats.streak >= 3}
        />
        <StatTile
          icon={<Dumbbell className="h-3.5 w-3.5" />}
          value={String(stats.total)}
          label="All time"
          hint="sessions"
        />
      </div>
    </>
  )

  return (
    <div className="page-x pb-4">
      <header className="safe-top flex items-start justify-between gap-3 py-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <p className="text-[10.5px] font-semibold uppercase tracking-[0.16em] text-muted">
              {greetingForKolkata(now)}
            </p>
            {isDemo ? (
              <Badge tone="warning" className="px-1.5 py-0.5 text-[8.5px]">
                Demo
              </Badge>
            ) : null}
          </div>
          <h1 className="mt-1 truncate display-accent text-[25px] text-ink sm:text-[28px]">
            {firstName}
          </h1>
          <p className="mt-0.5 text-[11.5px] font-medium text-muted">
            {formatKolkata(now, 'EEEE, d MMMM')} ·{' '}
            {stats.checkedInToday ? 'Session logged' : 'Ready when you are'}
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {profile?.is_admin ? (
            <Link
              to="/admin/approvals"
              className="relative flex h-10 w-10 items-center justify-center rounded-2xl border border-line bg-surface text-primary-strong transition hover:border-primary/30 focus-ring"
            >
              <ShieldCheck className="h-[18px] w-[18px]" />
              {pendingApprovals > 0 ? (
                <span className="absolute -right-1 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-warning px-1 text-[9px] font-bold text-white">
                  {pendingApprovals}
                </span>
              ) : null}
              <span className="sr-only">Payment approvals</span>
            </Link>
          ) : null}
          <ThemeToggle />
          <Link to="/profile" className="rounded-2xl focus-ring">
            <Avatar name={profile?.full_name} size="md" />
            <span className="sr-only">Open profile</span>
          </Link>
        </div>
      </header>

      {reconciliationPayment ? (
        <Link
          to="/membership"
          className="mt-1 flex items-start gap-3 rounded-2xl border border-warning/25 bg-warning/[0.06] p-3.5 transition hover:border-warning/40 focus-ring"
        >
          <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
          <span className="min-w-0">
            <span className="block text-[12px] font-semibold text-ink">
              Payment needs reconciliation
            </span>
            <span className="mt-0.5 block text-[10.5px] leading-relaxed text-muted">
              A payment for your {reconciliationPayment.package?.name ?? 'membership'}{' '}
              renewal may already have been sent. The gym will check it against their bank
              statement. Your current plan, expiry, and any fines stay unchanged.
            </span>
          </span>
          <ChevronRight className="mt-0.5 ml-auto h-4 w-4 shrink-0 text-muted" />
        </Link>
      ) : pendingPayment ? (
        <Link
          to="/membership"
          className="mt-1 flex items-start gap-3 rounded-2xl border border-warning/25 bg-warning/[0.06] p-3.5 transition hover:border-warning/40 focus-ring"
        >
          <Clock3 className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
          <span className="min-w-0">
            <span className="block text-[12px] font-semibold text-ink">
              Payment pending verification
            </span>
            <span className="mt-0.5 block text-[10.5px] leading-relaxed text-muted">
              Your {formatINR(pendingPayment.total_amount_inr)} payment for the{' '}
              {pendingPayment.package?.name ?? 'membership'} plan is waiting for the gym to verify
              it. Your current plan, expiry, and any fines stay unchanged, so keep using your
              existing access until it is verified.
            </span>
          </span>
          <ChevronRight className="mt-0.5 ml-auto h-4 w-4 shrink-0 text-muted" />
        </Link>
      ) : declinedPayment ? (
        <Link
          to="/membership"
          className="mt-1 flex items-start gap-3 rounded-2xl border border-danger/20 bg-danger/[0.05] p-3.5 transition hover:border-danger/35 focus-ring"
        >
          <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
          <span className="min-w-0">
            <span className="block text-[12px] font-semibold text-ink">
              {declinedPayment.legacy_status === 'refunded' ||
              declinedPayment.refund_status === 'refunded'
                ? 'Refund recorded'
                : declinedPayment.legacy_status === 'failed'
                  ? 'Payment failed'
                  : declinedPayment.legacy_status === 'cancelled'
                    ? 'Payment cancelled'
                    : 'Payment declined'}
            </span>
            <span className="mt-0.5 block text-[10.5px] leading-relaxed text-muted">
              {declinedPayment.legacy_status === 'refunded' ||
              declinedPayment.refund_status === 'refunded'
                ? `Your ${formatINR(declinedPayment.total_amount_inr)} payment was refunded manually by the gym. Your current plan and expiry are unchanged.`
                : declinedPayment.legacy_status === 'failed' ||
                    declinedPayment.legacy_status === 'cancelled'
                  ? 'This historical payment attempt did not complete. No plan was activated and your current plan is unchanged.'
                  : `The gym could not approve your ${formatINR(declinedPayment.total_amount_inr)} payment. Contact the front desk for a manual refund. Your current plan and expiry are unchanged.`}
            </span>
          </span>
          <ChevronRight className="mt-0.5 ml-auto h-4 w-4 shrink-0 text-muted" />
        </Link>
      ) : null}

      <div className="mt-4 grid gap-4 lg:grid-cols-[minmax(0,1.65fr)_minmax(290px,1fr)] lg:items-start lg:gap-6">
        <div className="space-y-5">
          {membershipQuery.isError ? (
            <ErrorState
              compact
              title="Membership unavailable"
              message={
                membershipQuery.error instanceof Error
                  ? membershipQuery.error.message
                  : 'Could not load your plan.'
              }
              onRetry={() => void membershipQuery.refetch()}
            />
          ) : membershipQuery.isLoading ? (
            <Skeleton className="h-[330px] rounded-[30px]" />
          ) : (
            <MembershipHero
              snapshot={snapshot}
              now={now}
              upcoming={membershipQuery.upcoming}
              onRenew={() => navigate('/membership')}
              onScan={() => navigate('/scan')}
            />
          )}

          {!membershipQuery.isLoading && !membershipQuery.isError ? (
            <ExpiryWarningBanner
              snapshot={snapshot}
              now={now}
              hasUpcomingPlan={Boolean(membershipQuery.upcoming)}
              paymentPending={Boolean(pendingPayment)}
            />
          ) : null}

          <div className="space-y-5 lg:hidden">{sidebar}</div>

          {announcements.length > 0 ? (
            <section className="animate-fade-up" style={{ animationDelay: '60ms' }}>
              <SectionHeading
                title="From the club"
                description="Hours, closures and what's new."
                action={
                  <span className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
                    {announcements.length} {pluralize(announcements.length, 'notice')}
                  </span>
                }
              />
              <div className="space-y-2">
                {announcements.map((announcement) => (
                  <AnnouncementItem key={announcement.id} announcement={announcement} />
                ))}
              </div>
            </section>
          ) : null}

          <section className="animate-fade-up" style={{ animationDelay: '120ms' }}>
            <SectionHeading
              title="Recent activity"
              description="Your last few gym sessions."
              action={
                <Link
                  to="/attendance"
                  className="inline-flex items-center gap-0.5 text-[11px] font-semibold text-primary-strong"
                >
                  View all
                  <ChevronRight className="h-3.5 w-3.5" />
                </Link>
              }
            />
            <div className="rounded-3xl border border-line/80 bg-surface px-4 py-2 shadow-card">
              {attendanceQuery.isLoading ? (
                <div className="space-y-2 py-2">
                  {[0, 1, 2].map((index) => (
                    <Skeleton key={index} className="h-12 rounded-xl" />
                  ))}
                </div>
              ) : recent.length > 0 ? (
                <div className="divide-y divide-line/60">
                  {recent.map((record) => (
                    <AttendanceRow key={record.id} record={record} />
                  ))}
                </div>
              ) : (
                <div className="flex flex-col items-center py-7 text-center">
                  <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-primary-soft text-primary-strong">
                    <Sparkles className="h-4 w-4" />
                  </div>
                  <p className="mt-2 text-[12.5px] font-semibold text-ink">No sessions yet</p>
                  <p className="mt-0.5 text-[11px] text-muted">
                    Your first scan will show up here.
                  </p>
                  <Button
                    variant="soft"
                    size="sm"
                    className="mt-3"
                    onClick={() => navigate('/scan')}
                  >
                    Open scanner
                  </Button>
                </div>
              )}
            </div>
          </section>
        </div>

        <aside className="hidden space-y-4 lg:sticky lg:top-6 lg:block">{sidebar}</aside>
      </div>

      <p className="mt-8 text-center text-[10px] text-faint">
        All dates and times are in Asia/Kolkata (IST) · Amounts in INR
      </p>
    </div>
  )
}
