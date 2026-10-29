import { Link, useNavigate } from 'react-router-dom'
import { ArrowRight, Compass, MoveLeft } from 'lucide-react'
import { Logo } from '@/components/ui/Logo'
import { Button } from '@/components/ui/Button'
import { GeometricBackground } from '@/components/layout/GeometricBackground'

export function NotFoundPage() {
  const navigate = useNavigate()

  return (
    <div className="relative flex min-h-[100svh] flex-col overflow-hidden">
      <GeometricBackground />
      <header className="safe-top relative z-10 flex items-center justify-between px-5 py-3 sm:px-8">
        <Link to="/" aria-label="FitDesk home" className="rounded-xl focus-ring">
          <Logo subtitle="Member app" />
        </Link>
        <Link
          to="/login"
          className="rounded-xl px-3 py-2 text-[11.5px] font-semibold text-muted transition hover:text-ink"
        >
          Sign in
        </Link>
      </header>

      <main className="relative z-10 flex flex-1 items-center justify-center px-5 pb-16">
        <div className="w-full max-w-md text-center">
          <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl border border-primary/15 bg-primary-soft/70 text-primary-strong">
            <Compass className="h-6 w-6" />
          </div>
          <p className="mt-6 display-number display-accent text-[86px] leading-none text-ink/90 sm:text-[104px]">
            404
          </p>
          <h1 className="mt-2 display-accent text-[27px] leading-[1.1] text-ink sm:text-[32px]">
            This corner of the club doesn't exist.
          </h1>
          <p className="mx-auto mt-3 max-w-[38ch] text-[13px] leading-relaxed text-muted">
            The page may have moved, or the link is incomplete. Your membership and
            check-ins are safe.
          </p>

          <div className="mt-7 flex flex-col gap-2.5 sm:flex-row sm:justify-center">
            <Button
              type="button"
              size="lg"
              onClick={() => navigate('/')}
              trailingIcon={<ArrowRight className="h-4 w-4" />}
            >
              Back to dashboard
            </Button>
            <Button
              type="button"
              size="lg"
              variant="secondary"
              onClick={() => navigate(-1)}
              leadingIcon={<MoveLeft className="h-4 w-4" />}
            >
              Go back
            </Button>
          </div>

          <p className="mt-8 text-[10.5px] text-faint">
            Looking for the scanner? Open the dashboard and tap the Scan button.
          </p>
        </div>
      </main>
    </div>
  )
}
