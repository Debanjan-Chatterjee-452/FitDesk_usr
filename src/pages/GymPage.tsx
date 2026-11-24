import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  ArrowRight,
  Building2,
  CheckCircle2,
  Clock3,
  LogOut,
  Repeat2,
  ShieldCheck,
  XCircle,
} from 'lucide-react'
import { toast } from 'sonner'
import type { JoinRequestRow } from '@/types'
import { PageHeader } from '@/components/layout/PageHeader'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Sheet } from '@/components/ui/Sheet'
import { Skeleton } from '@/components/ui/Skeleton'
import { useAuth } from '@/context/AuthProvider'
import { useGymOverview } from '@/hooks/queries'
import { getMyJoinRequests, previewGymByJoinCode, requestJoinGym } from '@/lib/api/gymJoin'
import { leaveMyGym } from '@/lib/api/gymMembership'
import { toAppError } from '@/lib/errors'
import { formatKolkata } from '@/lib/kolkata'

/**
 * Gym membership control panel.
 *
 * State A (no gym): only "Join a Gym" — the same code-based request used by
 * first-time members. Profile and documents are already on file and are never
 * re-uploaded here.
 *
 * State B (in a gym): current gym name, "Change Gym" and "Leave Gym" only.
 * Both deactivate the old membership and notify the old gym's admin.
 */
export function GymPage() {
  const navigate = useNavigate()
  const { profile, refreshProfile } = useAuth()
  const gymQuery = useGymOverview()

  const [confirm, setConfirm] = useState<'leave' | 'change' | null>(null)
  const [submittingLeave, setSubmittingLeave] = useState(false)
  const [code, setCode] = useState('')
  const [submittingJoin, setSubmittingJoin] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [preview, setPreview] = useState<{ status: string; gym_name?: string } | null>(null)
  const [previewLoading, setPreviewLoading] = useState(false)
  const [requests, setRequests] = useState<JoinRequestRow[]>([])
  const [loadingRequests, setLoadingRequests] = useState(true)

  const inGym = Boolean(profile?.gym_id)
  const gymName = gymQuery.data?.gymName ?? 'Your gym'

  const loadRequests = async () => {
    try {
      setRequests(await getMyJoinRequests())
    } catch {
      setRequests([])
    } finally {
      setLoadingRequests(false)
    }
  }

  useEffect(() => {
    void loadRequests()
  }, [])

  useEffect(() => {
    const trimmed = code.trim()
    if (!trimmed) {
      setPreview(null)
      setPreviewLoading(false)
      return
    }
    setPreviewLoading(true)
    const handle = window.setTimeout(async () => {
      try {
        setPreview(await previewGymByJoinCode(trimmed))
      } catch {
        setPreview({ status: 'not_found' })
      } finally {
        setPreviewLoading(false)
      }
    }, 350)
    return () => window.clearTimeout(handle)
  }, [code])

  const handleLeave = async () => {
    setSubmittingLeave(true)
    setError(null)
    try {
      const result = await leaveMyGym()
      if (result.status === 'left') {
        await refreshProfile()
        void gymQuery.refetch()
        toast.success(`You have left ${result.gym_name ?? 'your gym'}.`, {
          description: 'Your account and documents are safe. You can join another gym anytime.',
        })
      }
      setConfirm(null)
      if (confirm === 'change') {
        setCode('')
        setError(null)
      }
    } catch (leaveError) {
      const appError = toAppError(leaveError)
      setError(appError.message)
      toast.error(appError.message)
    } finally {
      setSubmittingLeave(false)
    }
  }

  const submitJoin = async () => {
    if (!code.trim()) {
      setError('Enter the gym ID / join code from your gym.')
      return
    }
    setSubmittingJoin(true)
    setError(null)
    try {
      const result = await requestJoinGym(code.trim())
      if (result.status === 'already_member') {
        toast.info('You are already in a gym.', {
          description: 'Leave or change your gym first to request another one.',
        })
        await refreshProfile()
        return
      }
      setCode('')
      await loadRequests()
      toast.success('Join request sent', {
        description: `${result.gym_name ?? 'The gym'} admin will review it shortly.`,
      })
    } catch (joinError) {
      setError(toAppError(joinError).message)
    } finally {
      setSubmittingJoin(false)
    }
  }

  const pending = requests.filter((item) => item.status === 'pending')

  return (
    <div className="page-x">
      <PageHeader
        title="Gym"
        subtitle="Your gym membership and where you train."
        action={<ThemeToggle />}
      />

      {error && !inGym ? (
        <p className="mt-3 rounded-xl border border-danger/20 bg-danger/5 px-3.5 py-2.5 text-[11px] text-danger">
          {error}
        </p>
      ) : null}

      {inGym ? (
        <div className="mt-4 space-y-4">
          <section className="card overflow-hidden">
            <div className="flex items-start gap-4 border-b border-line/70 p-5">
              <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-primary-soft text-primary-strong">
                <Building2 className="h-5 w-5" />
              </span>
              <div className="min-w-0 flex-1">
                <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-faint">
                  Current gym
                </p>
                <h2 className="display-accent mt-1 text-[24px] leading-tight text-ink">{gymName}</h2>
                <p className="mt-1 flex items-center gap-1.5 text-[10.5px] text-muted">
                  <ShieldCheck className="h-3.5 w-3.5 text-success" />
                  Your membership is linked to this gym.
                </p>
              </div>
            </div>

            <div className="grid gap-2 p-4 sm:grid-cols-2">
              <Button
                variant="primary"
                size="lg"
                fullWidth
                onClick={() => setConfirm('change')}
                disabled={submittingLeave}
                leadingIcon={<Repeat2 className="h-4 w-4" />}
              >
                Change Gym
              </Button>
              <Button
                variant="outline"
                size="lg"
                fullWidth
                onClick={() => setConfirm('leave')}
                disabled={submittingLeave}
                leadingIcon={<LogOut className="h-4 w-4" />}
              >
                Leave Gym
              </Button>
            </div>
          </section>

          <p className="rounded-2xl border border-line/80 bg-elevated/40 p-4 text-[10.5px] leading-relaxed text-muted">
            Your FitDesk account, profile, identity documents and payment history are kept either
            way. Leaving only unlinks you from this gym; you can join another gym at any time.
          </p>
        </div>
      ) : (
        <div className="mt-4 space-y-4">
          <section className="card p-5">
            <div className="flex items-start gap-3">
              <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-warning/10 text-warning">
                <Building2 className="h-[18px] w-[18px]" />
              </span>
              <div>
                <h2 className="text-[14px] font-semibold text-ink">
                  You are not currently in a gym
                </h2>
                <p className="mt-1 text-[10.5px] leading-relaxed text-muted">
                  Ask your gym for its join code. Your profile and documents are already saved —
                  you do not need to register again. The gym admin will approve your request.
                </p>
              </div>
            </div>
          </section>

          {loadingRequests ? (
            <Skeleton className="h-24 rounded-2xl" />
          ) : pending.length > 0 ? (
            <section className="flex items-start gap-3 rounded-2xl border border-warning/30 bg-warning/[0.06] p-4">
              <Clock3 className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
              <div>
                <p className="text-[12px] font-semibold text-ink">Waiting for approval</p>
                <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
                  {pending.map((item) => item.gym_name ?? 'Your gym').join(', ')} — your request is
                  with the gym admin.
                </p>
                <button
                  type="button"
                  onClick={() => void loadRequests()}
                  className="mt-1.5 text-[10.5px] font-semibold text-warning underline decoration-dotted underline-offset-2"
                >
                  Refresh status
                </button>
              </div>
            </section>
          ) : null}

          {requests.some((item) => item.status === 'approved') ? (
            <section className="flex items-start gap-3 rounded-2xl border border-success/25 bg-success/[0.06] p-4">
              <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" />
              <div className="flex-1">
                <p className="text-[12px] font-semibold text-ink">You are approved</p>
                <p className="mt-0.5 text-[10.5px] text-muted">Tap below to enter FitDesk.</p>
                <Button
                  className="mt-2"
                  size="sm"
                  onClick={() =>
                    void refreshProfile().then(() => navigate('/', { replace: true }))
                  }
                >
                  Enter FitDesk
                </Button>
              </div>
            </section>
          ) : null}

          <section className="card p-5">
            <h2 className="text-[14px] font-semibold text-ink">Join a Gym</h2>
            <p className="mt-1 text-[10.5px] leading-relaxed text-muted">
              Enter the gym ID / join code shared by the gym admin, like{' '}
              <code className="font-mono">FD-7K2P-QM9X</code>.
            </p>
            <div className="mt-3 space-y-2">
              <Input
                label="Gym ID / Join code"
                value={code}
                onChange={(event) => setCode(event.target.value.toUpperCase())}
                placeholder="FD-XXXX-XXXX"
                autoCapitalize="characters"
                autoComplete="off"
                error={error ?? undefined}
              />
              {previewLoading ? (
                <p className="text-[10.5px] text-muted">Checking code…</p>
              ) : preview?.status === 'found' ? (
                <p className="text-[10.5px] font-semibold text-success">✓ {preview.gym_name}</p>
              ) : preview?.status === 'not_found' ? (
                <p className="text-[10.5px] text-danger">No gym matches that code.</p>
              ) : null}
              <Button
                fullWidth
                size="lg"
                onClick={() => void submitJoin()}
                disabled={submittingJoin || !code.trim()}
                trailingIcon={!submittingJoin ? <ArrowRight className="h-4 w-4" /> : undefined}
              >
                {submittingJoin ? 'Sending…' : 'Request to join'}
              </Button>
            </div>
          </section>

          {requests.some((item) => item.status === 'declined') ? (
            <p className="flex items-start gap-1.5 text-[10px] leading-relaxed text-muted">
              <XCircle className="mt-0.5 h-3 w-3 shrink-0 text-danger" />
              A previous request was declined. Check the code with the front desk and try again.
            </p>
          ) : null}

          {requests[0]?.requested_at ? (
            <p className="text-center text-[9.5px] text-faint">
              Last request {formatKolkata(requests[0].requested_at, 'd MMM yyyy, h:mm a')}
            </p>
          ) : null}
        </div>
      )}

      <Sheet
        open={confirm !== null}
        onOpenChange={(open) => {
          if (!open && !submittingLeave) setConfirm(null)
        }}
        title={confirm === 'change' ? 'Change your gym?' : 'Leave your gym?'}
        description={confirm === 'change' ? 'This cannot be undone.' : 'Your account stays with FitDesk.'}
        size="sm"
      >
        <div className="space-y-4">
          <p className="rounded-2xl border border-warning/25 bg-warning/[0.06] p-3.5 text-[11.5px] leading-relaxed text-ink">
            {confirm === 'change'
              ? 'To change your gym, you must leave your current gym first. Your current gym membership will be deactivated.'
              : 'Do you really want to leave your gym? Your current gym membership will be deactivated.'}
          </p>
          <p className="text-[10.5px] leading-relaxed text-muted">
            Your FitDesk account, profile, legal documents and payment history stay intact. The gym
            admin will be notified.
          </p>
          <div className="grid gap-2">
            <Button
              fullWidth
              size="lg"
              variant="primary"
              onClick={() => void handleLeave()}
              loading={submittingLeave}
            >
              {confirm === 'change' ? 'Yes, Leave & Change Gym' : 'Yes'}
            </Button>
            <Button
              fullWidth
              variant="ghost"
              onClick={() => setConfirm(null)}
              disabled={submittingLeave}
            >
              Cancel
            </Button>
          </div>
        </div>
      </Sheet>
    </div>
  )
}
