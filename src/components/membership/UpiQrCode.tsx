import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import {
  ImageOff,
  Loader2,
  RefreshCcw,
  ShieldAlert,
  ShieldCheck,
} from 'lucide-react'
import { getSupabase } from '@/lib/supabase'
import { loadAndDecodeQrImage } from '@/lib/upi/decode'
import { buildUpiQrDataUrl } from '@/lib/upi/qr'
import {
  buildUpiUri,
  interpretUpiQrPayload,
  type QrVerification,
} from '@/lib/upi/upi'
import { cn } from '@/lib/utils'

interface UpiQrCodeProps {
  upiId: string
  payeeName: string | null
  amountInr: number
  reference: string
  gymName: string
  qrBucket: string | null
  qrPath: string | null
}

type Source = 'provided' | 'generated' | 'fallback'

type FallbackReason =
  | 'unavailable'
  | 'undecodable'
  | 'not_upi'
  | 'missing_amount'
  | 'payee_mismatch'
  | 'amount_mismatch'

interface QrState {
  /** Identifies the inputs this state was computed for. */
  key: string
  phase: 'loading' | 'ready'
  source: Source
  imageUrl: string | null
  verification: QrVerification | null
  /** Why a configured image was replaced by a generated one. */
  fallbackReason: FallbackReason | null
}

function loadingState(key: string): QrState {
  return {
    key,
    phase: 'loading',
    source: 'generated',
    imageUrl: null,
    verification: null,
    fallbackReason: null,
  }
}

/**
 * Renders the gym's UPI QR.
 *
 * A QR is only shown as the gym supplied it when we could decode it and the
 * decoded UPI intent points at the same UPI ID and amount the server returned.
 * Otherwise we render a QR generated from that verified UPI ID and say so —
 * we never present an unverified image as payment-ready.
 *
 * The image itself is never cropped, stretched, overlaid or tinted: it sits
 * inside a white card with padding and `object-contain`.
 */
export function UpiQrCode({
  upiId,
  payeeName,
  amountInr,
  reference,
  gymName,
  qrBucket,
  qrPath,
}: UpiQrCodeProps) {
  const [attempt, setAttempt] = useState(0)

  const uri = useMemo(() => {
    try {
      return buildUpiUri({
        upiId,
        payeeName,
        amountInr,
        reference,
        note: `${gymName} membership`,
      })
    } catch {
      return null
    }
  }, [upiId, payeeName, amountInr, reference, gymName])

  const stateKey = `${uri ?? 'invalid'}#${attempt}`
  const [state, setState] = useState<QrState>(() => loadingState(stateKey))
  const isStale = state.key !== stateKey
  const loading = isStale || state.phase === 'loading'

  useEffect(() => {
    if (!uri) return
    let cancelled = false

    const settle = (next: Omit<QrState, 'key'>) => {
      if (!cancelled) setState({ key: stateKey, ...next })
    }

    const load = async () => {
      let generated: string
      try {
        generated = await buildUpiQrDataUrl(uri)
      } catch {
        settle({
          phase: 'ready',
          source: 'fallback',
          imageUrl: null,
          verification: null,
          fallbackReason: 'unavailable',
        })
        return
      }
      if (cancelled) return

      if (!qrPath || !qrBucket) {
        settle({
          phase: 'ready',
          source: 'generated',
          imageUrl: generated,
          verification: null,
          fallbackReason: null,
        })
        return
      }

      let publicUrl: string
      try {
        publicUrl = getSupabase().storage.from(qrBucket).getPublicUrl(qrPath).data.publicUrl
      } catch {
        settle({
          phase: 'ready',
          source: 'fallback',
          imageUrl: generated,
          verification: null,
          fallbackReason: 'unavailable',
        })
        return
      }

      const { image, payload } = await loadAndDecodeQrImage(publicUrl)
      if (cancelled) return

      if (!image) {
        settle({
          phase: 'ready',
          source: 'fallback',
          imageUrl: generated,
          verification: null,
          fallbackReason: 'unavailable',
        })
        return
      }

      if (!payload) {
        settle({
          phase: 'ready',
          source: 'fallback',
          imageUrl: generated,
          verification: null,
          fallbackReason: 'undecodable',
        })
        return
      }

      const verdict = interpretUpiQrPayload(payload, { upiId, amountInr })
      if (verdict.status === 'verified') {
        settle({
          phase: 'ready',
          source: 'provided',
          imageUrl: publicUrl,
          verification: verdict,
          fallbackReason: null,
        })
        return
      }

      settle({
        phase: 'ready',
        source: 'fallback',
        imageUrl: generated,
        verification: verdict,
        fallbackReason: verdict.status,
      })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [uri, stateKey, qrPath, qrBucket, upiId, amountInr])

  const retry = useCallback(() => setAttempt((value) => value + 1), [])

  return (
    <div>
      <div className="rounded-3xl border border-line/80 bg-white p-3 shadow-[0_1px_0_rgba(0,0,0,0.03)]">
        {loading ? (
          <div
            className="mx-auto flex aspect-square w-full max-w-[260px] items-center justify-center rounded-2xl bg-[#F4F7F7]"
            role="status"
            aria-live="polite"
          >
            <div className="flex flex-col items-center gap-2 text-[#4B615C]">
              <Loader2 className="h-5 w-5 animate-spin" />
              <p className="text-[10.5px] font-medium">Checking the gym&apos;s QR code…</p>
            </div>
          </div>
        ) : state.imageUrl ? (
          <img
            src={state.imageUrl}
            alt={`UPI payment QR code for ${gymName}`}
            width={640}
            height={640}
            decoding="async"
            className="mx-auto block h-auto w-full max-w-[260px] object-contain"
          />
        ) : (
          <div className="mx-auto flex aspect-square w-full max-w-[260px] flex-col items-center justify-center gap-2 rounded-2xl bg-[#F4F7F7] p-4 text-center text-[#4B615C]">
            <ImageOff className="h-6 w-6" />
            <p className="text-[10.5px] font-medium leading-relaxed">
              The QR code could not be created. Use the UPI ID below instead.
            </p>
            <button
              type="button"
              onClick={retry}
              className="mt-1 inline-flex items-center gap-1.5 rounded-full border border-[#D5E2DF] bg-white px-2.5 py-1 text-[10px] font-semibold text-[#0F766E]"
            >
              <RefreshCcw className="h-3 w-3" />
              Retry
            </button>
          </div>
        )}
      </div>

      <div className="mt-2.5">
        {loading ? (
          <p className="text-center text-[10px] text-faint">Verifying the gym&apos;s QR code…</p>
        ) : state.source === 'provided' ? (
          <Status tone="success" icon={<ShieldCheck className="h-3.5 w-3.5" />}>
            QR verified — it points at {gymName}&apos;s UPI ID and this exact amount.
          </Status>
        ) : state.source === 'generated' ? (
          <Status tone="neutral" icon={<ShieldCheck className="h-3.5 w-3.5" />}>
            QR generated from {gymName}&apos;s UPI ID and this amount.
          </Status>
        ) : state.fallbackReason === 'payee_mismatch' ? (
          <Status tone="warning" icon={<ShieldAlert className="h-3.5 w-3.5" />}>
            The gym&apos;s uploaded QR points at a different UPI ID, so it is not shown. This QR was
            generated from the UPI ID on file.
            <RetryButton onClick={retry} />
          </Status>
        ) : state.fallbackReason === 'amount_mismatch' ? (
          <Status tone="warning" icon={<ShieldAlert className="h-3.5 w-3.5" />}>
            The gym&apos;s uploaded QR carries a different amount, so it is not shown. This QR was
            generated for the amount below.
            <RetryButton onClick={retry} />
          </Status>
        ) : state.fallbackReason === 'not_upi' ? (
          <Status tone="warning" icon={<ShieldAlert className="h-3.5 w-3.5" />}>
            The gym&apos;s uploaded image is not a UPI QR code. This QR was generated from the UPI ID
            on file instead.
            <RetryButton onClick={retry} />
          </Status>
        ) : state.fallbackReason === 'missing_amount' ? (
          <Status tone="warning" icon={<ShieldAlert className="h-3.5 w-3.5" />}>
            The gym&apos;s uploaded QR does not carry this amount, so this QR was generated for the
            exact amount below. Check the recipient before paying.
            <RetryButton onClick={retry} />
          </Status>
        ) : state.fallbackReason === 'undecodable' ? (
          <Status tone="warning" icon={<ShieldAlert className="h-3.5 w-3.5" />}>
            We could not read the gym&apos;s uploaded QR image, so this QR was generated from the UPI
            ID on file. Check the recipient below before paying.
            <RetryButton onClick={retry} />
          </Status>
        ) : (
          <Status tone="warning" icon={<ShieldAlert className="h-3.5 w-3.5" />}>
            The gym&apos;s QR image could not be loaded. This QR was generated from the UPI ID on
            file instead.
            <RetryButton onClick={retry} />
          </Status>
        )}
      </div>
    </div>
  )
}

function Status({
  tone,
  icon,
  children,
}: {
  tone: 'success' | 'warning' | 'neutral'
  icon: ReactNode
  children: ReactNode
}) {
  return (
    <div
      className={cn(
        'flex items-start gap-2 rounded-2xl border px-3 py-2 text-[10.5px] leading-relaxed',
        tone === 'success' && 'border-success/20 bg-success/[0.05] text-muted',
        tone === 'warning' && 'border-warning/25 bg-warning/[0.06] text-muted',
        tone === 'neutral' && 'border-line/80 bg-elevated/40 text-muted',
      )}
    >
      <span
        className={cn(
          'mt-0.5 shrink-0',
          tone === 'success' && 'text-success',
          tone === 'warning' && 'text-warning',
          tone === 'neutral' && 'text-primary-strong',
        )}
      >
        {icon}
      </span>
      <div className="min-w-0">{children}</div>
    </div>
  )
}

function RetryButton({ onClick }: { onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="mt-1.5 inline-flex items-center gap-1.5 rounded-full border border-line bg-surface px-2.5 py-1 text-[10px] font-semibold text-ink transition hover:border-primary/30"
    >
      <RefreshCcw className="h-3 w-3" />
      Retry QR check
    </button>
  )
}
