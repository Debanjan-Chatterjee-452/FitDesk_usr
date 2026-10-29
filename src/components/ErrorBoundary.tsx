import { Component, type ErrorInfo, type ReactNode } from 'react'
import { RefreshCcw, ShieldAlert } from 'lucide-react'
import { Logo } from '@/components/ui/Logo'
import { Button } from '@/components/ui/Button'
import { GeometricBackground } from '@/components/layout/GeometricBackground'

interface ErrorBoundaryProps {
  children: ReactNode
}

interface ErrorBoundaryState {
  hasError: boolean
  message: string | null
}

/**
 * Last line of defence: a render error should never leave a white screen.
 * The user can reload, and the error is logged for diagnostics.
 */
export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { hasError: false, message: null }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return {
      hasError: true,
      message: error.message || null,
    }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error('FitDesk render error', error, info.componentStack)
  }

  render() {
    if (!this.state.hasError) return this.props.children

    return (
      <div className="relative flex min-h-[100svh] flex-col overflow-hidden">
        <GeometricBackground />
        <header className="safe-top relative z-10 px-5 py-3 sm:px-8">
          <Logo subtitle="Member app" />
        </header>
        <main className="relative z-10 flex flex-1 items-center justify-center px-5 pb-16">
          <div className="w-full max-w-md text-center">
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl border border-danger/15 bg-danger/[0.06] text-danger">
              <ShieldAlert className="h-6 w-6" />
            </div>
            <h1 className="mt-6 font-display text-[27px] font-semibold leading-[1.1] tracking-[-0.04em] text-ink">
              Something interrupted the app.
            </h1>
            <p className="mx-auto mt-3 max-w-[38ch] text-[13px] leading-relaxed text-muted">
              Your membership and check-in records are safe. Reload the app to pick up
              where you left off.
            </p>
            {this.state.message ? (
              <p className="mx-auto mt-4 max-w-full overflow-hidden rounded-2xl border border-line/80 bg-elevated/60 px-4 py-3 font-mono text-[10.5px] leading-relaxed text-muted">
                {this.state.message}
              </p>
            ) : null}
            <div className="mt-6 flex flex-col justify-center gap-2.5 sm:flex-row">
              <Button
                type="button"
                size="lg"
                onClick={() => window.location.reload()}
                leadingIcon={<RefreshCcw className="h-4 w-4" />}
              >
                Reload FitDesk
              </Button>
              <a
                href="/login"
                className="inline-flex h-[52px] items-center justify-center rounded-2xl border border-line bg-elevated px-6 text-[15px] font-semibold text-ink transition hover:border-primary/30 hover:text-primary-strong"
              >
                Back to sign in
              </a>
            </div>
          </div>
        </main>
      </div>
    )
  }
}
