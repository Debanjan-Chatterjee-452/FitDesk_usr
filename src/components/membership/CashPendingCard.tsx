import { useMemo, useState } from 'react'
import { AlertCircle, Banknote, CheckCircle2, Clock3, RefreshCw, ShieldCheck } from 'lucide-react'
import { toast } from 'sonner'
import type { Payment, PaymentVerification } from '@/types'
import { Button } from '@/components/ui/Button'
import { OtpInput } from '@/components/ui/OtpInput'
import { useCashPayment, useNow, useRequestCashPayment, useVerifyCashOtp } from '@/hooks/queries'
import { toAppError } from '@/lib/errors'
import { formatINR } from '@/lib/utils'

/**
 * Persistent cash entry point on the Membership page.
 *
 * The renewal sheet is modal, so a member who closes it must still be able to
 * finish a cash payment. This card keeps the 6-digit entry and the 5-minute
 * code window visible until the gym confirms the cash.
 */
export function CashPendingCard({
  payment,
  onVerified,
}: {
  payment: Payment
  onVerified: (verification: PaymentVerification) => void
}) {
  const cashQuery = useCashPayment(payment.id)
  const verifyOtp = useVerifyCashOtp()
  const requestCash = useRequestCashPayment()
  const now = useNow(1000)
  const [otp, setOtp] = useState('')
  const [error, setError] = useState<string | null>(null)

  const data = cashQuery.data

  const secondsLeft = useMemo(() => {
    if (!data?.otp_expires_at) return 0
    return Math.max(0, Math.ceil((new Date(data.otp_expires_at).getTime() - now.getTime()) / 1000))
  }, [data?.otp_expires_at, now])

  const expired = Boolean(data?.otp_expires_at) && secondsLeft <= 0

  const handleVerify = async () => {
    if (otp.length !== 6) return
    setError(null)
    try {
      const result = await verifyOtp.mutateAsync({ paymentId: payment.id, otp })
      setOtp('')
      toast.success('Cash payment confirmed', { description: `${result.package_name} is now active.` })
      onVerified(result)
    } catch (verifyError) {
      setError(toAppError(verifyError).message)
    }
  }

  const handleNewCode = async () => {
    setError(null)
    try {
      await requestCash.mutateAsync({
        packageId: payment.package_id,
        durationDays: payment.duration_days,
        isNewAdmission: payment.is_new_admission,
      })
      setOtp('')
      toast.success('New code requested', {
        description: 'Ask the front desk to read out the new 6-digit code.',
      })
      void cashQuery.refetch()
    } catch (requestError) {
      setError(toAppError(requestError).message)
    }
  }

  if (data?.payment_state === 'VERIFIED') {
    return null
  }

  return (
    <section className="mt-3 rounded-2xl border border-warning/25 bg-warning/[0.05] p-4">
      <div className="flex items-start gap-2.5">
        <Banknote className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
        <div className="min-w-0 flex-1">
          <p className="text-[12px] font-semibold text-ink">
            Cash payment waiting for confirmation
          </p>
          <p className="mt-0.5 text-[10.5px] leading-relaxed text-muted">
            Pay {formatINR(payment.total_amount_inr)} in cash at the front desk, then enter the
            6-digit code they read out. Your plan starts as soon as the code is accepted.
          </p>

          {data?.otp_expires_at && !expired ? (
            <p className="mt-2 flex items-center gap-1.5 text-[10px] text-muted">
              <Clock3 className="h-3 w-3" />
              Code from the desk expires in
              <span className="font-mono font-semibold text-ink">
                {Math.floor(secondsLeft / 60)}:{String(secondsLeft % 60).padStart(2, '0')}
              </span>
            </p>
          ) : expired ? (
            <p className="mt-2 flex items-center gap-1.5 text-[10px] text-warning">
              <Clock3 className="h-3 w-3" />
              The last code expired. Request a new one.
            </p>
          ) : null}

          <div className="mt-3">
            <OtpInput
              value={otp}
              onChange={(value) => {
                setOtp(value)
                if (error) setError(null)
              }}
              length={6}
              disabled={verifyOtp.isPending}
            />
          </div>

          <div className="mt-2.5 flex flex-wrap gap-2">
            <Button
              type="button"
              size="sm"
              onClick={() => void handleVerify()}
              loading={verifyOtp.isPending}
              disabled={otp.length !== 6}
              leadingIcon={!verifyOtp.isPending ? <ShieldCheck className="h-3.5 w-3.5" /> : undefined}
            >
              Confirm payment
            </Button>
            {!data?.otp_expires_at || expired ? (
              <Button
                type="button"
                size="sm"
                variant="ghost"
                onClick={() => void handleNewCode()}
                loading={requestCash.isPending}
                leadingIcon={!requestCash.isPending ? <RefreshCw className="h-3.5 w-3.5" /> : undefined}
              >
                Request new code
              </Button>
            ) : null}
          </div>

          {error ? (
            <p className="mt-2 flex items-start gap-1.5 text-[10px] leading-relaxed text-danger">
              <AlertCircle className="mt-0.5 h-3 w-3 shrink-0" />
              {error}
            </p>
          ) : null}

          <p className="mt-2 flex items-center gap-1.5 text-[9.5px] text-faint">
            <CheckCircle2 className="h-3 w-3" />
            Nothing is charged from the app. The gym collects the cash in person.
          </p>
        </div>
      </div>
    </section>
  )
}
