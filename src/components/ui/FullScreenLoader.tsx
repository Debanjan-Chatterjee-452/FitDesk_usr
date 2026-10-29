import { Logo } from '@/components/ui/Logo'

export function FullScreenLoader({ label = 'Getting things ready' }: { label?: string }) {
  return (
    <main className="flex min-h-[100svh] flex-col items-center justify-center gap-6 bg-bg px-6">
      <div className="relative">
        <div className="absolute inset-0 animate-ping rounded-[18px] bg-primary/15" />
        <div className="relative rounded-[18px] bg-surface p-1 shadow-card">
          <Logo showWordmark={false} markClassName="h-12 w-12" />
        </div>
      </div>
      <div className="text-center" role="status" aria-live="polite">
        <p className="font-display text-[15px] font-semibold text-ink">{label}</p>
        <p className="mt-1 text-[11.5px] text-muted">FitDesk · Member app</p>
      </div>
      <div className="flex gap-1.5" aria-hidden="true">
        {[0, 1, 2].map((index) => (
          <span
            key={index}
            className="h-1.5 w-1.5 animate-bounce rounded-full bg-primary/60"
            style={{ animationDelay: `${index * 120}ms` }}
          />
        ))}
      </div>
    </main>
  )
}
