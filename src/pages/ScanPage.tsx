import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { AnimatePresence, motion } from 'framer-motion'
import {
  BrowserCodeReader,
  BrowserQRCodeReader,
  type IScannerControls,
} from '@zxing/browser'
import {
  AlertTriangle,
  ArrowRight,
  Camera,
  CameraOff,
  Check,
  CheckCircle2,
  CreditCard,
  Keyboard,
  Loader2,
  RefreshCcw,
  ScanLine,
  ShieldCheck,
  Sparkles,
  SwitchCamera,
  X,
  Zap,
  ZapOff,
} from 'lucide-react'
import { toast } from 'sonner'
import type { CheckInResult } from '@/types'
import type { ErrorCode } from '@/lib/errors'
import { useCheckIn } from '@/hooks/queries'
import { parseGymQrPayload } from '@/lib/qr'
import { DEMO_EMAIL, DEMO_GYM_TOKEN } from '@/lib/demo/store'
import { isDemo } from '@/lib/env'
import { toAppError } from '@/lib/errors'
import { formatKolkata, formatKolkataTime, todayInKolkata } from '@/lib/kolkata'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/Button'
import { Input } from '@/components/ui/Input'
import { Sheet } from '@/components/ui/Sheet'

type Phase = 'starting' | 'scanning' | 'processing' | 'success' | 'failure'

interface FailureState {
  title: string
  message: string
  code?: ErrorCode
  cameraIssue?: boolean
}

function vibrate(pattern: number | number[]): void {
  try {
    navigator.vibrate?.(pattern)
  } catch {
    // Haptics are a progressive enhancement.
  }
}

function cameraFailure(error: unknown): FailureState {
  const name =
    error && typeof error === 'object' && 'name' in error
      ? String((error as { name?: unknown }).name)
      : ''

  if (!window.isSecureContext) {
    return {
      title: 'Camera needs a secure connection',
      message:
        'Browsers only allow camera access over HTTPS. Open FitDesk on its published HTTPS address, or enter the code from the front desk manually.',
      cameraIssue: true,
    }
  }
  if (name === 'NotAllowedError' || name === 'SecurityError') {
    return {
      title: 'Camera access is blocked',
      message:
        'Allow camera access for FitDesk in your browser settings, then try again. You can also type the front-desk code below.',
      cameraIssue: true,
    }
  }
  if (name === 'NotFoundError' || name === 'DevicesNotFoundError') {
    return {
      title: 'No camera found',
      message:
        'This device does not have a camera available. Enter the code printed under the gym QR instead.',
      cameraIssue: true,
    }
  }
  if (name === 'NotReadableError' || name === 'TrackStartError') {
    return {
      title: 'Camera is busy',
      message:
        'Another app may be using the camera. Close it and try again, or enter the code manually.',
      cameraIssue: true,
    }
  }
  return {
    title: 'Camera could not start',
    message:
      'We could not open the camera on this device. Try again, or enter the front-desk code manually.',
    cameraIssue: true,
  }
}

function failureFromError(error: unknown): FailureState {
  const appError = toAppError(error)
  if (appError.code === 'MEMBERSHIP_INACTIVE') {
    return {
      title: 'Membership inactive',
      message: appError.message,
      code: appError.code,
    }
  }
  if (appError.code === 'GYM_CLOSED') {
    return {
      title: 'The club is closed',
      message: appError.message,
      code: appError.code,
    }
  }
  if (appError.code === 'DUPLICATE_CHECKIN') {
    return {
      title: 'Already checked in today',
      message: appError.message,
      code: appError.code,
    }
  }
  if (appError.code === 'AUTH_REQUIRED') {
    return {
      title: 'Session expired',
      message: 'Please sign in again to record your session.',
      code: appError.code,
    }
  }
  return {
    title: 'Check-in not recorded',
    message: appError.message,
    code: appError.code,
  }
}

export function ScanPage() {
  const navigate = useNavigate()
  const [searchParams, setSearchParams] = useSearchParams()
  const { mutateAsync: submitCheckIn } = useCheckIn()

  const videoRef = useRef<HTMLVideoElement>(null)
  const controlsRef = useRef<IScannerControls | null>(null)
  const handledRef = useRef(false)
  const submitRef = useRef<(raw: string) => Promise<void>>(async () => undefined)

  const [phase, setPhase] = useState<Phase>('starting')
  const [result, setResult] = useState<CheckInResult | null>(null)
  const [failure, setFailure] = useState<FailureState | null>(null)
  const [cameraNonce, setCameraNonce] = useState(0)
  const [deviceIndex, setDeviceIndex] = useState(0)
  const [devices, setDevices] = useState<MediaDeviceInfo[]>([])
  const [torchAvailable, setTorchAvailable] = useState(false)
  const [torchOn, setTorchOn] = useState(false)
  const [manualOpen, setManualOpen] = useState(false)
  const [manualValue, setManualValue] = useState('')
  const [manualError, setManualError] = useState<string | null>(null)

  const deepLinkToken = useMemo(() => {
    const candidate =
      searchParams.get('gym') ??
      searchParams.get('token') ??
      searchParams.get('code') ??
      ''
    return candidate ? (parseGymQrPayload(candidate)?.token ?? null) : null
  }, [searchParams])

  /**
   * A failed deep link keeps `?gym=…` in the URL, which would otherwise force
   * every "Scan again" retry to skip the camera. Clear those params before
   * restarting so the scanner can boot normally.
   */
  const clearDeepLink = useCallback(() => {
    if (
      !searchParams.has('gym') &&
      !searchParams.has('token') &&
      !searchParams.has('code')
    ) {
      return
    }
    setSearchParams(
      (current) => {
        const next = new URLSearchParams(current)
        next.delete('gym')
        next.delete('token')
        next.delete('code')
        return next
      },
      { replace: true },
    )
  }, [searchParams, setSearchParams])

  const stopCamera = useCallback(() => {
    const controls = controlsRef.current
    controlsRef.current = null
    if (controls) {
      try {
        controls.stop()
      } catch {
        // The stream may already have ended.
      }
    }
    setTorchOn(false)
  }, [])

  const submitToken = useCallback(
    async (raw: string) => {
      if (handledRef.current) return
      const parsed = parseGymQrPayload(raw)
      if (!parsed) {
        stopCamera()
        setFailure({
          title: 'That code is not valid',
          message:
            'The code we read is incomplete or not a FitDesk gym code. Face the camera at the front-desk QR and try again.',
          code: 'INVALID_QR',
        })
        setPhase('failure')
        return
      }

      handledRef.current = true
      stopCamera()
      setFailure(null)
      setPhase('processing')
      vibrate(18)

      try {
        const response = await submitCheckIn(parsed.token)
        setResult(response)
        setPhase('success')
        vibrate(response.status === 'checked_in' ? [40, 60, 40] : 30)
      } catch (error) {
        const next = failureFromError(error)
        setFailure(next)
        setPhase('failure')
        handledRef.current = false
        vibrate([25, 45, 25])
      }
    },
    [stopCamera, submitCheckIn],
  )

  useEffect(() => {
    submitRef.current = submitToken
  }, [submitToken])

  // Deep links (`/scan?gym=…`) are checked in without ever opening the camera.
  useEffect(() => {
    if (!deepLinkToken) return
    void submitRef.current(deepLinkToken)
  }, [deepLinkToken])

  useEffect(() => {
    if (deepLinkToken) return
    const video = videoRef.current
    if (!video) return

    let cancelled = false
    let controls: IScannerControls | null = null
    const reader = new BrowserQRCodeReader()

    handledRef.current = false
    setFailure(null)
    setResult(null)
    setPhase('starting')
    setTorchAvailable(false)
    setTorchOn(false)

    const boot = async () => {
      if (!navigator.mediaDevices?.getUserMedia) {
        if (cancelled) return
        setFailure({
          title: 'Camera is not supported',
          message:
            'This browser cannot open a camera. Enter the code from the front desk instead.',
          cameraIssue: true,
        })
        setPhase('failure')
        return
      }

      try {
        const available = await BrowserCodeReader.listVideoInputDevices().catch(
          () => [] as MediaDeviceInfo[],
        )
        if (cancelled) return
        if (available.length > 0) setDevices(available)

        const index = Math.min(deviceIndex, Math.max(0, available.length - 1))
        const deviceId = available[index]?.deviceId

        controls = await reader.decodeFromVideoDevice(deviceId, video, (scanResult) => {
          if (cancelled || !scanResult) return
          void submitRef.current(scanResult.getText())
        })

        if (cancelled) {
          controls.stop()
          return
        }

        controlsRef.current = controls
        setPhase('scanning')

        try {
          // @zxing/browser types the filter as returning tracks, but its
          // implementation proxies Array.find and expects a boolean predicate.
          const filter = ((track: MediaStreamTrack) =>
            Boolean(track)) as unknown as (track: MediaStreamTrack) => MediaStreamTrack[]
          const capabilities = controls.streamVideoCapabilitiesGet?.(filter) as
            | (MediaTrackCapabilities & { torch?: boolean })
            | undefined
          setTorchAvailable(Boolean(capabilities?.torch))
        } catch {
          setTorchAvailable(false)
        }
      } catch (error) {
        if (cancelled) return
        setFailure(cameraFailure(error))
        setPhase('failure')
      }
    }

    void boot()

    return () => {
      cancelled = true
      const active = controls ?? controlsRef.current
      controlsRef.current = null
      if (active) {
        try {
          active.stop()
        } catch {
          // Safe to ignore: the stream may already have ended.
        }
      }
    }
  }, [cameraNonce, deviceIndex, deepLinkToken])

  const restartCamera = () => {
    clearDeepLink()
    handledRef.current = false
    setResult(null)
    setFailure(null)
    setManualValue('')
    setManualError(null)
    setPhase('starting')
    setCameraNonce((value) => value + 1)
  }

  const openManual = () => {
    stopCamera()
    setManualError(null)
    setManualOpen(true)
  }

  const handleManualOpenChange = (open: boolean) => {
    setManualOpen(open)
    if (!open && !handledRef.current && phase !== 'success') {
      restartCamera()
    }
  }

  const submitManual = () => {
    const raw = manualValue.trim()
    if (!raw) {
      setManualError('Enter the code printed under the gym QR.')
      return
    }
    if (!parseGymQrPayload(raw)) {
      setManualError("That doesn't look like a FitDesk gym code.")
      return
    }
    setManualError(null)
    setManualOpen(false)
    setManualValue('')
    void submitToken(raw)
  }

  const toggleTorch = async () => {
    const controls = controlsRef.current
    if (!controls?.switchTorch) {
      toast.error('Torch is not available on this camera')
      return
    }
    const next = !torchOn
    try {
      await controls.switchTorch(next)
      setTorchOn(next)
    } catch {
      toast.error('Could not switch the torch on this device')
    }
  }

  const flipCamera = () => {
    if (devices.length < 2) {
      toast.error('Only one camera is available')
      return
    }
    stopCamera()
    setDeviceIndex((value) => (value + 1) % devices.length)
  }

  const close = () => {
    if (phase === 'processing') return
    stopCamera()
    navigate('/', { replace: true })
  }

  const checkedIn = result?.status === 'checked_in'
  const cameraVisible = phase === 'starting' || phase === 'scanning'

  return (
    <div className="fixed inset-0 z-[70] overflow-hidden bg-[#03100E] text-white">
      <video
        ref={videoRef}
        muted
        playsInline
        autoPlay
        aria-label="Camera preview"
        className={cn(
          'absolute inset-0 h-full w-full object-cover transition-opacity duration-700',
          cameraVisible ? 'opacity-100' : 'opacity-0',
        )}
      />

      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(90%_70%_at_50%_10%,rgba(13,148,136,0.18),transparent_60%)]" />
      <div className="pointer-events-none absolute inset-0 bg-gradient-to-b from-[#02100E]/85 via-transparent to-[#02100E]/95" />
      <div className="noise pointer-events-none absolute inset-0" />

      <header className="safe-top absolute inset-x-0 top-0 z-30 px-4">
        <div className="mx-auto flex max-w-3xl items-center justify-between">
          <button
            type="button"
            onClick={close}
            disabled={phase === 'processing'}
            aria-label="Close scanner"
            className="flex h-11 w-11 items-center justify-center rounded-2xl border border-white/15 bg-black/25 text-white backdrop-blur-md transition hover:bg-black/40 disabled:opacity-40"
          >
            <X className="h-5 w-5" />
          </button>

          <div className="flex items-center gap-2 rounded-full border border-white/10 bg-black/25 px-3 py-1.5 backdrop-blur-md">
            <span
              className={cn(
                'h-1.5 w-1.5 rounded-full',
                phase === 'scanning'
                  ? 'bg-emerald-300 shadow-[0_0_10px_rgba(110,231,183,0.9)]'
                  : 'bg-white/40',
              )}
            />
            <span className="text-[10px] font-semibold uppercase tracking-[0.16em] text-white/75">
              {phase === 'starting'
                ? 'Starting camera'
                : phase === 'scanning'
                  ? 'Camera live'
                  : phase === 'processing'
                    ? 'Checking in'
                    : phase === 'success'
                      ? 'Confirmed'
                      : 'Scanner'}
            </span>
          </div>

          <button
            type="button"
            onClick={close}
            disabled={phase === 'processing'}
            aria-label="Go to dashboard"
            className="flex h-11 w-11 items-center justify-center rounded-2xl border border-white/15 bg-black/25 text-white backdrop-blur-md transition hover:bg-black/40 disabled:opacity-40"
          >
            <ShieldCheck className="h-5 w-5" />
          </button>
        </div>
      </header>

      {cameraVisible || phase === 'processing' ? (
        <div className="absolute inset-0 flex flex-col items-center justify-center px-8 pb-44 pt-24">
          <div className="relative aspect-square w-full max-w-[292px]">
            <span className="absolute -left-1 -top-1 h-9 w-9 rounded-tl-2xl border-l-2 border-t-2 border-white/90" />
            <span className="absolute -right-1 -top-1 h-9 w-9 rounded-tr-2xl border-r-2 border-t-2 border-white/90" />
            <span className="absolute -bottom-1 -left-1 h-9 w-9 rounded-bl-2xl border-b-2 border-l-2 border-white/90" />
            <span className="absolute -bottom-1 -right-1 h-9 w-9 rounded-br-2xl border-b-2 border-r-2 border-white/90" />

            <div className="absolute inset-4 rounded-[28px] border border-white/10 bg-black/10 backdrop-blur-[1px]" />

            <div className="absolute inset-0 flex items-center justify-center">
              <div className="flex flex-col items-center text-white/45">
                <ScanLine className="h-10 w-10" strokeWidth={1.4} />
                <span className="mt-2 text-[9px] font-semibold uppercase tracking-[0.24em]">
                  FitDesk check-in
                </span>
              </div>
            </div>

            {phase === 'scanning' ? (
              <>
                <div className="pointer-events-none absolute inset-4 overflow-hidden rounded-[28px]">
                  <div className="absolute inset-x-0 h-px animate-scanline bg-gradient-to-r from-transparent via-emerald-300 to-transparent shadow-[0_0_14px_rgba(110,231,183,0.9)]" />
                  <div className="absolute inset-x-6 bottom-5 h-16 bg-gradient-to-t from-emerald-400/10 to-transparent blur-md" />
                </div>
                <span className="absolute left-1/2 top-1/2 h-16 w-16 -translate-x-1/2 -translate-y-1/2 animate-pulse-ring rounded-full border border-emerald-300/40" />
              </>
            ) : null}
          </div>

          <p className="mt-7 max-w-[30ch] text-center text-[12.5px] font-medium leading-relaxed text-white/70">
            {phase === 'starting'
              ? 'Waking up the camera…'
              : phase === 'processing'
                ? 'Recording your session with the club…'
                : 'Hold steady. The gym QR should sit inside the frame.'}
          </p>

          {phase === 'processing' ? (
            <div className="mt-4 flex items-center gap-2 rounded-full border border-white/10 bg-black/30 px-4 py-2 backdrop-blur-md">
              <Loader2 className="h-3.5 w-3.5 animate-spin text-emerald-300" />
              <span className="text-[11px] font-semibold text-white/80">
                Verifying your membership
              </span>
            </div>
          ) : null}
        </div>
      ) : null}

      <AnimatePresence>
        {phase === 'failure' && failure ? (
          <motion.div
            key="failure"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="absolute inset-0 z-20 flex items-center justify-center bg-[#03100E]/92 px-5 pb-24 pt-24"
          >
            <motion.div
              initial={{ opacity: 0, y: 20, scale: 0.98 }}
              animate={{ opacity: 1, y: 0, scale: 1 }}
              transition={{ type: 'spring', stiffness: 380, damping: 32 }}
              className="w-full max-w-sm rounded-[30px] border border-white/10 bg-white/[0.055] p-6 text-center shadow-2xl backdrop-blur-xl"
            >
              <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-3xl border border-amber-300/20 bg-amber-300/10 text-amber-200">
                {failure.cameraIssue ? (
                  <CameraOff className="h-7 w-7" />
                ) : failure.code === 'MEMBERSHIP_INACTIVE' ? (
                  <CreditCard className="h-7 w-7" />
                ) : (
                  <AlertTriangle className="h-7 w-7" />
                )}
              </div>
              <h1 className="mt-5 font-display text-[23px] font-semibold tracking-[-0.03em] text-white">
                {failure.title}
              </h1>
              <p className="mt-2 text-[12.5px] leading-relaxed text-white/60">
                {failure.message}
              </p>

              <div className="mt-6 space-y-2.5">
                {failure.code === 'MEMBERSHIP_INACTIVE' ? (
                  <Button
                    fullWidth
                    onClick={() => navigate('/membership')}
                    trailingIcon={<ArrowRight className="h-4 w-4" />}
                  >
                    Renew membership
                  </Button>
                ) : failure.code === 'AUTH_REQUIRED' ? (
                  <Button fullWidth onClick={() => navigate('/login', { replace: true })}>
                    Sign in again
                  </Button>
                ) : (
                  <Button
                    fullWidth
                    onClick={restartCamera}
                    leadingIcon={<RefreshCcw className="h-4 w-4" />}
                  >
                    {failure.cameraIssue ? 'Try camera again' : 'Scan again'}
                  </Button>
                )}

                <Button
                  fullWidth
                  variant="secondary"
                  onClick={openManual}
                  leadingIcon={<Keyboard className="h-4 w-4" />}
                  className="border-white/15 bg-white/10 text-white hover:bg-white/15 hover:text-white"
                >
                  Enter code manually
                </Button>
              </div>

              <button
                type="button"
                onClick={() => navigate('/')}
                className="mt-5 text-[11.5px] font-semibold text-white/55 transition hover:text-white"
              >
                Back to dashboard
              </button>
            </motion.div>
          </motion.div>
        ) : null}
      </AnimatePresence>

      <AnimatePresence>
        {phase === 'success' && result ? (
          <motion.div
            key="success"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="absolute inset-0 z-30 flex flex-col overflow-y-auto bg-[#04110F]"
          >
            <div className="pointer-events-none absolute inset-0 mesh-teal opacity-90" />
            <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(75%_50%_at_50%_0%,rgba(45,212,191,0.28),transparent_70%)]" />
            <div className="noise pointer-events-none absolute inset-0" />

            <header className="safe-top relative z-10 flex items-center justify-between px-5">
              <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-black/20 px-3 py-1.5 text-[10px] font-semibold uppercase tracking-[0.16em] text-white/65 backdrop-blur-md">
                <ShieldCheck className="h-3.5 w-3.5 text-emerald-300" />
                FitDesk check-in
              </span>
              <button
                type="button"
                onClick={() => navigate('/', { replace: true })}
                aria-label="Close"
                className="flex h-10 w-10 items-center justify-center rounded-2xl border border-white/15 bg-black/20 text-white/80 backdrop-blur-md transition hover:bg-black/35"
              >
                <X className="h-[18px] w-[18px]" />
              </button>
            </header>

            <div className="relative z-10 flex flex-1 flex-col items-center justify-center px-5 py-10">
              <motion.div
                initial={{ scale: 0.5, opacity: 0 }}
                animate={{ scale: 1, opacity: 1 }}
                transition={{ type: 'spring', stiffness: 300, damping: 20 }}
                className="relative flex h-24 w-24 items-center justify-center rounded-[34px] border border-emerald-300/30 bg-emerald-400/15 text-emerald-200 shadow-[0_24px_70px_-24px_rgba(45,212,191,0.8)]"
              >
                <span className="absolute inset-0 animate-pulse-ring rounded-[34px] border border-emerald-300/30" />
                {checkedIn ? (
                  <Check className="h-11 w-11" strokeWidth={3} />
                ) : (
                  <CheckCircle2 className="h-11 w-11" strokeWidth={2.2} />
                )}
              </motion.div>

              <motion.div
                initial={{ opacity: 0, y: 14 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.12 }}
                className="mt-7 text-center"
              >
                <p className="text-[10.5px] font-semibold uppercase tracking-[0.2em] text-emerald-200/80">
                  {checkedIn ? 'You are in' : 'Already logged'}
                </p>
                <h1 className="mt-2 font-display text-[34px] font-semibold leading-[1.05] tracking-[-0.045em] text-white sm:text-[40px]">
                  {checkedIn ? 'Session started.' : 'You checked in today.'}
                </h1>
                <p className="mx-auto mt-3 max-w-[30ch] text-[13px] leading-relaxed text-white/60">
                  {result.message}
                </p>
              </motion.div>

              <motion.div
                initial={{ opacity: 0, y: 16 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.2 }}
                className="mt-8 w-full max-w-sm rounded-[26px] border border-white/10 bg-white/[0.055] p-5 backdrop-blur-xl"
              >
                <div className="flex items-center justify-between gap-4">
                  <div>
                    <p className="text-[9.5px] font-semibold uppercase tracking-[0.16em] text-white/40">
                      {result.gym_name}
                    </p>
                    <p className="mt-1.5 font-display text-[21px] font-semibold tracking-[-0.03em] text-white">
                      {formatKolkataTime(result.check_in_at)}
                      <span className="ml-1.5 text-[11px] font-semibold tracking-normal text-emerald-200/75">
                        IST
                      </span>
                    </p>
                    <p className="mt-0.5 text-[11.5px] text-white/50">
                      {formatKolkata(result.check_in_at, 'EEEE, d MMMM yyyy')}
                    </p>
                  </div>
                  <div className="flex h-12 w-12 items-center justify-center rounded-2xl border border-white/10 bg-white/5 text-emerald-200">
                    <Check className="h-5 w-5" strokeWidth={2.6} />
                  </div>
                </div>
                <div className="mt-4 flex items-center gap-2 border-t border-white/10 pt-3.5 text-[10.5px] text-white/45">
                  <Sparkles className="h-3.5 w-3.5 text-emerald-200/70" />
                  One check-in per IST day. Your streak updated instantly.
                </div>
              </motion.div>

              <motion.div
                initial={{ opacity: 0, y: 14 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ delay: 0.28 }}
                className="mt-5 flex w-full max-w-sm flex-col gap-2.5"
              >
                <Button
                  fullWidth
                  size="lg"
                  onClick={() => navigate('/', { replace: true })}
                  trailingIcon={<ArrowRight className="h-4 w-4" />}
                >
                  Done
                </Button>
                <Button
                  fullWidth
                  variant="secondary"
                  onClick={() => navigate('/attendance')}
                  className="border-white/15 bg-white/10 text-white hover:bg-white/15 hover:text-white"
                >
                  View my activity
                </Button>
              </motion.div>
            </div>
          </motion.div>
        ) : null}
      </AnimatePresence>

      {cameraVisible ? (
        <div className="absolute inset-x-0 bottom-0 z-40 px-5 pb-[max(env(safe-area-inset-bottom),1.25rem)] pt-10">
          <div className="pointer-events-none absolute inset-0 bg-gradient-to-t from-[#02100E] via-[#02100E]/80 to-transparent" />
          <div className="relative mx-auto flex w-full max-w-sm flex-col items-center gap-4">
            <div className="flex items-center justify-center gap-3">
              <button
                type="button"
                onClick={() => void toggleTorch()}
                disabled={!torchAvailable}
                aria-label={torchOn ? 'Turn torch off' : 'Turn torch on'}
                className={cn(
                  'flex h-12 w-12 items-center justify-center rounded-2xl border backdrop-blur-md transition disabled:opacity-30',
                  torchOn
                    ? 'border-amber-300/40 bg-amber-300/20 text-amber-200'
                    : 'border-white/15 bg-white/10 text-white/80 hover:bg-white/15',
                )}
              >
                {torchOn ? <Zap className="h-5 w-5" /> : <ZapOff className="h-5 w-5" />}
              </button>

              <button
                type="button"
                onClick={openManual}
                className="flex h-12 items-center gap-2 rounded-2xl border border-white/15 bg-white/10 px-5 text-[12.5px] font-semibold text-white backdrop-blur-md transition hover:bg-white/15"
              >
                <Keyboard className="h-[18px] w-[18px]" />
                Enter code
              </button>

              <button
                type="button"
                onClick={flipCamera}
                disabled={devices.length < 2}
                aria-label="Switch camera"
                className="flex h-12 w-12 items-center justify-center rounded-2xl border border-white/15 bg-white/10 text-white/80 backdrop-blur-md transition hover:bg-white/15 disabled:opacity-30"
              >
                <SwitchCamera className="h-5 w-5" />
              </button>
            </div>

            {isDemo ? (
              <div className="w-full rounded-2xl border border-dashed border-amber-300/25 bg-amber-300/[0.06] px-4 py-3 text-center backdrop-blur-md">
                <p className="text-[10.5px] leading-relaxed text-amber-100/80">
                  <span className="font-semibold text-amber-100">Demo mode.</span> Use the
                  manual code{' '}
                  <span className="font-mono font-semibold text-amber-100">
                    {DEMO_GYM_TOKEN}
                  </span>{' '}
                  or sign in as {DEMO_EMAIL}.
                </p>
              </div>
            ) : (
              <p className="text-center text-[10px] text-white/35">
                Only the gym's printed QR works. Codes are single-purpose and verified
                server-side.
              </p>
            )}
          </div>
        </div>
      ) : null}

      <Sheet
        open={manualOpen}
        onOpenChange={handleManualOpenChange}
        title="Enter gym code"
        description="Type the short code printed beneath the QR at the front desk."
        size="sm"
        footer={
          <div className="flex gap-2">
            <Button
              type="button"
              variant="ghost"
              fullWidth
              onClick={() => handleManualOpenChange(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              fullWidth
              onClick={submitManual}
              disabled={!manualValue.trim()}
              trailingIcon={<ArrowRight className="h-4 w-4" />}
            >
              Check in
            </Button>
          </div>
        }
      >
        <div className="space-y-4">
          <Input
            label="Gym code"
            placeholder={isDemo ? DEMO_GYM_TOKEN : 'e.g. FD-GYM-7K2P'}
            value={manualValue}
            onChange={(event) => {
              setManualValue(event.target.value)
              if (manualError) setManualError(null)
            }}
            onKeyDown={(event) => {
              if (event.key === 'Enter') submitManual()
            }}
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            autoFocus
            leading={<ScanLine className="h-[18px] w-[18px]" />}
            error={manualError}
            hint="Codes are case-sensitive. Ask the front desk if yours is unclear."
            className="font-mono uppercase tracking-wide"
          />

          {isDemo ? (
            <button
              type="button"
              onClick={() => {
                setManualValue(DEMO_GYM_TOKEN)
                setManualError(null)
              }}
              className="flex w-full items-center justify-between rounded-2xl border border-dashed border-warning/35 bg-warning/[0.05] px-4 py-3 text-left transition hover:bg-warning/[0.08]"
            >
              <span>
                <span className="block text-[11.5px] font-semibold text-ink">
                  Use the demo gym code
                </span>
                <span className="mt-0.5 block font-mono text-[10.5px] text-muted">
                  {DEMO_GYM_TOKEN}
                </span>
              </span>
              <Sparkles className="h-4 w-4 text-warning" />
            </button>
          ) : null}

          <div className="flex items-start gap-2.5 rounded-2xl border border-line/80 bg-elevated/50 p-3.5">
            <Camera className="mt-0.5 h-4 w-4 shrink-0 text-primary-strong" />
            <p className="text-[10.5px] leading-relaxed text-muted">
              You can also scan the printed QR with your camera. Only one check-in is
              allowed per day, in Asia/Kolkata time.
            </p>
          </div>
        </div>
      </Sheet>

      <p className="sr-only" aria-live="polite">
        {phase === 'success' && result
          ? `Checked in at ${formatKolkataTime(result.check_in_at)} IST on ${todayInKolkata()}.`
          : phase === 'failure' && failure
            ? failure.message
            : ''}
      </p>
    </div>
  )
}
