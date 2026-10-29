import type { ReactNode } from 'react'
import { CalendarCheck2, Dumbbell, QrCode, ShieldCheck, Sparkles } from 'lucide-react'
import { Logo } from '@/components/ui/Logo'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { GeometricBackground } from './GeometricBackground'

interface AuthLayoutProps {
  eyebrow?: string
  title: string
  subtitle?: string
  children: ReactNode
  below?: ReactNode
  footer?: ReactNode
}

const HIGHLIGHTS = [
  {
    icon: QrCode,
    title: 'Scan in, in seconds',
    body: 'Your gym pass lives on your phone. One scan logs the session.',
  },
  {
    icon: CalendarCheck2,
    title: 'Never miss a renewal',
    body: 'Live validity, clear expiry countdowns, and instant online renewal.',
  },
  {
    icon: ShieldCheck,
    title: 'Your records, private',
    body: 'Attendance, payments and identity documents stay yours alone.',
  },
]

export function AuthLayout({
  eyebrow = 'Member access',
  title,
  subtitle,
  children,
  below,
  footer,
}: AuthLayoutProps) {
  return (
    <div className="relative grid min-h-[100svh] lg:grid-cols-[minmax(0,1.05fr)_minmax(0,1fr)]">
      {/* Brand panel */}
      <aside className="relative hidden overflow-hidden mesh-teal p-10 text-white lg:flex lg:flex-col lg:justify-between xl:p-14">
        <div className="noise absolute inset-0" aria-hidden="true" />
        <div
          className="absolute inset-0 opacity-[0.14]"
          style={{
            backgroundImage:
              'linear-gradient(to right, rgba(255,255,255,0.35) 1px, transparent 1px), linear-gradient(to bottom, rgba(255,255,255,0.35) 1px, transparent 1px)',
            backgroundSize: '64px 64px',
            maskImage: 'radial-gradient(ellipse at 30% 20%, black 10%, transparent 70%)',
          }}
          aria-hidden="true"
        />
        <div className="absolute -right-32 top-1/4 h-[420px] w-[420px] rounded-full border border-white/10" aria-hidden="true" />
        <div className="absolute -right-20 top-1/4 h-[300px] w-[300px] rounded-full border border-white/10" aria-hidden="true" />
        <div className="absolute -right-8 top-1/4 h-[180px] w-[180px] rounded-full bg-primary/20 blur-2xl" aria-hidden="true" />

        <div className="relative z-10">
          <Logo inverted subtitle="Member application" />
        </div>

        <div className="relative z-10 max-w-[480px] py-10">
          <div className="mb-6 inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/[0.06] px-3 py-1.5 text-[10px] font-semibold uppercase tracking-[0.18em] text-white/75 backdrop-blur">
            <Sparkles className="h-3 w-3 text-[#5EEAD4]" />
            Built for the everyday athlete
          </div>
          <h2 className="display-accent text-[40px] leading-[1.06] xl:text-[46px]">
            Everything between you and your next session.
            <span className="text-[#5EEAD4]"> Sorted.</span>
          </h2>
          <p className="mt-5 max-w-[42ch] text-[14px] leading-relaxed text-white/65">
            One quiet place for your membership, check-ins, renewals and records. No
            counters, no paper, no guesswork.
          </p>

          <div className="mt-10 space-y-5">
            {HIGHLIGHTS.map(({ icon: Icon, title: itemTitle, body }) => (
              <div key={itemTitle} className="flex gap-3.5">
                <div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-xl border border-white/10 bg-white/[0.07]">
                  <Icon className="h-4 w-4 text-[#5EEAD4]" />
                </div>
                <div>
                  <p className="text-[13px] font-semibold text-white">{itemTitle}</p>
                  <p className="mt-0.5 text-[12px] leading-relaxed text-white/50">{body}</p>
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="relative z-10 flex items-center justify-between border-t border-white/10 pt-5 text-[11px] text-white/40">
          <span className="inline-flex items-center gap-2">
            <Dumbbell className="h-3.5 w-3.5" />
            FitDesk Performance Club
          </span>
          <span>Asia/Kolkata · ₹ INR</span>
        </div>
      </aside>

      {/* Form panel */}
      <main className="relative flex min-h-[100svh] flex-col overflow-hidden bg-bg">
        <GeometricBackground className="lg:hidden" />
        <div className="relative z-10 flex min-h-[100svh] w-full flex-col px-5 sm:px-8 lg:px-12">
          <div className="safe-top flex items-center justify-between py-3 lg:justify-end">
            <Logo className="lg:hidden" />
            <ThemeToggle />
          </div>

          <div className="mx-auto flex w-full max-w-[430px] flex-1 flex-col justify-center py-8 sm:py-10">
            <div className="animate-fade-up">
              <p className="eyebrow mb-3">{eyebrow}</p>
              <h1 className="display-accent text-[30px] leading-[1.12] text-ink sm:text-[34px]">
                {title}
              </h1>
              {subtitle ? (
                <p className="mt-3 text-[13.5px] leading-relaxed text-muted">{subtitle}</p>
              ) : null}
              <div className="mt-8">{children}</div>
              {below ? <div className="mt-6">{below}</div> : null}
            </div>
          </div>

          <div className="safe-bottom relative z-10 mx-auto w-full max-w-[430px] pb-4">
            {footer ? (
              <div className="mb-4">{footer}</div>
            ) : null}
            <p className="text-center text-[10.5px] leading-relaxed text-faint">
              Protected by Supabase Auth · Attendance times shown in IST · By continuing you
              agree to the club rules.
            </p>
          </div>
        </div>
      </main>
    </div>
  )
}
