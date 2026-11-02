import { useEffect, useState } from 'react'
import { LogOut, CheckCircle2, Clock3, XCircle } from 'lucide-react'
import { toast } from 'sonner'
import { Logo } from '@/components/ui/Logo'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Input } from '@/components/ui/Input'
import { Button } from '@/components/ui/Button'
import { FullScreenLoader } from '@/components/ui/FullScreenLoader'
import { GeometricBackground } from '@/components/layout/GeometricBackground'
import { useAuth } from '@/context/AuthProvider'
import { getMyJoinRequests, requestJoinGym } from '@/lib/api/gymJoin'
import { toAppError } from '@/lib/errors'

/**
 * Gym-join gate. New members arrive here after onboarding until a gym admin
 * approves their join request — no gym means no packages, payments or scans.
 */
export function JoinGymPage() {
  const { profile, profileLoading, refreshProfile, signOutMember } = useAuth()
  const [code, setCode] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [requests, setRequests] = useState<Awaited<ReturnType<typeof getMyJoinRequests>>>([])
  const [loadingRequests, setLoadingRequests] = useState(true)

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

  if (profileLoading && !profile) {
    return <FullScreenLoader label="Loading your profile" />
  }

  const submit = async () => {
    if (!code.trim()) {
      setError('Enter the gym join code from your gym.')
      return
    }
    setSubmitting(true)
    setError(null)
    try {
      await requestJoinGym(code.trim())
      setCode('')
      await loadRequests()
      toast.success('Join request sent. The gym admin will review it shortly.')
    } catch (err) {
      const appError = toAppError(err)
      setError(appError.message)
    } finally {
      setSubmitting(false)
    }
  }

  const pending = requests.filter((item) => item.status === 'pending')
  const declined = requests.filter((item) => item.status === 'declined')

  return (
    <div className="relative flex min-h-[100svh] flex-col bg-bg text-ink">
      <GeometricBackground />
      <header className="relative z-10 flex items-center justify-between px-5 pt-5">
        <Logo />
        <ThemeToggle />
      </header>

      <main className="relative z-10 mx-auto flex w-full max-w-md flex-1 flex-col gap-5 px-5 pb-10 pt-6">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-[0.2em] text-muted">
            One step left
          </p>
          <h1 className="mt-1 text-2xl font-bold tracking-tight text-ink">Join your gym</h1>
          <p className="mt-2 text-sm leading-relaxed text-muted">
            Your profile is saved. Now ask your gym for their join code — once the
            gym admin approves, plans, payments and check-ins unlock.
          </p>
        </div>

        {loadingRequests ? (
          <FullScreenLoader label="Checking your requests" />
        ) : (
          <>
            {pending.length > 0 && (
              <div className="flex items-start gap-3 rounded-2xl border border-warning/40 bg-warning/10 p-4">
                <Clock3 className="mt-0.5 h-5 w-5 shrink-0 text-warning" />
                <div>
                  <p className="text-sm font-semibold text-ink">Waiting for approval</p>
                  <p className="mt-0.5 text-xs leading-relaxed text-muted">
                    {pending.map((item) => item.gym_name ?? 'Your gym').join(', ')}
                    {' — '}
                    your request is with the gym admin.
                  </p>
                  <button
                    type="button"
                    onClick={() => void loadRequests()}
                    className="mt-2 text-xs font-semibold text-warning underline decoration-dotted underline-offset-2 hover:no-underline"
                  >
                    Refresh status
                  </button>
                </div>
              </div>
            )}

            {declined.length > 0 && (
              <div className="flex items-start gap-3 rounded-2xl border border-danger/40 bg-danger/10 p-4">
                <XCircle className="mt-0.5 h-5 w-5 shrink-0 text-danger" />
                <p className="text-sm leading-relaxed text-muted">
                  A request for {declined.map((item) => item.gym_name ?? 'a gym').join(', ')} was
                  declined. You can try again with the correct join code.
                </p>
              </div>
            )}

            {requests.some((item) => item.status === 'approved') && (
              <div className="flex items-start gap-3 rounded-2xl border border-success/40 bg-success/10 p-4">
                <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-success" />
                <div className="flex-1">
                  <p className="text-sm font-semibold text-ink">You are approved</p>
                  <p className="mt-0.5 text-xs text-muted">Reload to enter the gym app.</p>
                  <Button
                    className="mt-2"
                    size="sm"
                    variant="primary"
                    onClick={() => void refreshProfile().then(() => window.location.reload())}
                  >
                    Enter FitDesk
                  </Button>
                </div>
              </div>
            )}

            <section className="rounded-2xl border border-line bg-surface p-5 shadow-card">
              <h2 className="text-sm font-bold text-ink">Have a join code?</h2>
              <p className="mt-1 text-xs leading-relaxed text-muted">
                The gym's front desk can share a code like{' '}
                <code className="font-mono">FD-7K2P-QM9X</code>.
              </p>
              <div className="mt-4 flex flex-col gap-3">
                <Input
                  label="Gym join code"
                  value={code}
                  onChange={(event) => setCode(event.target.value.toUpperCase())}
                  placeholder="FD-XXXX-XXXX"
                  autoCapitalize="characters"
                  autoComplete="off"
                  error={error ?? undefined}
                />
                <Button
                  variant="primary"
                  onClick={() => void submit()}
                  disabled={submitting || !code.trim()}
                >
                  {submitting ? 'Sending…' : 'Request to join'}
                </Button>
              </div>
            </section>
          </>
        )}

        <div className="mt-auto pt-4">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => void signOutMember()}
            leadingIcon={<LogOut className="h-3.5 w-3.5" />}
          >
            Sign out
          </Button>
        </div>
      </main>
    </div>
  )
}
