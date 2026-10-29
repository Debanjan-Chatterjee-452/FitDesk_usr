import { useState, type ReactNode } from 'react'
import { Check, Copy, Database, ExternalLink, KeyRound, Terminal } from 'lucide-react'
import { AuthLayout } from '@/components/layout/AuthLayout'
import { Button } from '@/components/ui/Button'
import { cn } from '@/lib/utils'

const ENV_SNIPPET = `VITE_SUPABASE_URL=https://YOUR-PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR-PUBLISHABLE-ANON-KEY
VITE_RAZORPAY_KEY_ID=rzp_test_XXXXXXXXXXXX
VITE_DEMO_MODE=false`

export function SetupPage() {
  const [copied, setCopied] = useState(false)

  const copyEnv = async () => {
    try {
      await navigator.clipboard.writeText(ENV_SNIPPET)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 1800)
    } catch {
      setCopied(false)
    }
  }

  return (
    <AuthLayout
      eyebrow="Setup required"
      title="Connect your gym backend."
      subtitle="FitDesk is ready — it just needs your Supabase project. Add two public environment values, run the migration, and you're live."
      footer={
        <p className="text-center text-[10.5px] leading-relaxed text-faint">
          Full setup instructions, SQL migrations and Edge Functions are included in the
          project README.
        </p>
      }
    >
      <div className="space-y-5">
        <div className="rounded-3xl border border-line/80 bg-surface p-4">
          <div className="mb-3 flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Terminal className="h-4 w-4 text-primary-strong" />
              <p className="text-[12px] font-semibold text-ink">.env.local</p>
            </div>
            <button
              type="button"
              onClick={copyEnv}
              className={cn(
                'inline-flex items-center gap-1.5 rounded-lg px-2 py-1 text-[10.5px] font-semibold transition',
                copied
                  ? 'bg-success/10 text-success'
                  : 'bg-elevated text-muted hover:text-ink',
              )}
            >
              {copied ? <Check className="h-3 w-3" /> : <Copy className="h-3 w-3" />}
              {copied ? 'Copied' : 'Copy'}
            </button>
          </div>
          <pre className="overflow-x-auto rounded-xl bg-[#06110F] p-3.5 text-[10.5px] leading-relaxed text-[#B7E4DC]">
            {ENV_SNIPPET}
          </pre>
        </div>

        <div className="space-y-3">
          <SetupStep
            icon={<Database className="h-4 w-4" />}
            title="Create the schema"
            body={
              <>
                Run the migration in <code className="rounded bg-elevated px-1 py-0.5 text-[10.5px]">supabase/migrations</code>{' '}
                and seed the starter packages with <code className="rounded bg-elevated px-1 py-0.5 text-[10.5px]">supabase db reset</code>.
              </>
            }
          />
          <SetupStep
            icon={<KeyRound className="h-4 w-4" />}
            title="Add the public keys"
            body="Use the anon/publishable key only. Service-role and Razorpay secret keys belong in Edge Function secrets, never in Vite env vars."
          />
          <SetupStep
            icon={<ExternalLink className="h-4 w-4" />}
            title="Enable email auth"
            body="Turn on the Email provider in Supabase Auth, keep Confirm email enabled, and add your app URL plus /confirm-email and /reset-password to the redirect allow-list."
          />
        </div>

        <div className="rounded-2xl border border-dashed border-warning/35 bg-warning/[0.05] p-4">
          <p className="text-[11.5px] font-semibold text-ink">Just want to explore the UI?</p>
          <p className="mt-1 text-[11px] leading-relaxed text-muted">
            Set <code className="rounded bg-surface px-1 py-0.5">VITE_DEMO_MODE=true</code> in{' '}
            <code className="rounded bg-surface px-1 py-0.5">.env.local</code> and restart the dev
            server. Demo mode runs entirely in your browser and is never enabled in production.
          </p>
        </div>

        <Button type="button" fullWidth variant="secondary" onClick={() => window.location.reload()}>
          I've added the keys — reload
        </Button>
      </div>
    </AuthLayout>
  )
}

function SetupStep({
  icon,
  title,
  body,
}: {
  icon: ReactNode
  title: string
  body: ReactNode
}) {
  return (
    <div className="flex gap-3 rounded-2xl border border-line/70 bg-surface px-4 py-3.5">
      <div className="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-primary-soft text-primary-strong">
        {icon}
      </div>
      <div>
        <p className="text-[12px] font-semibold text-ink">{title}</p>
        <p className="mt-0.5 text-[11px] leading-relaxed text-muted">{body}</p>
      </div>
    </div>
  )
}
