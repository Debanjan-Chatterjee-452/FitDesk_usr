import { isDemo } from '@/lib/env'
import { AppError, toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { requireUserId } from './session'

export async function verifyCashOtp(paymentId: string, otp: string): Promise<{
  status: string
  payment_id: string
  membership_id: string | null
  starts_on: string | null
  ends_on: string | null
  package_name: string
  total_amount_inr: number
}> {
  if (isDemo) {
    throw new AppError('UNKNOWN', 'Cash OTP verification is not available in demo mode.')
  }
  try {
    await requireUserId()
    const { data, error } = await getSupabase().rpc('verify_cash_otp', {
      p_payment_id: paymentId,
      p_otp: otp.trim(),
    })
    if (error) throw error
    if (!data) throw new AppError('UNKNOWN', 'Verification failed.')
    return data as {
      status: string
      payment_id: string
      membership_id: string | null
      starts_on: string | null
      ends_on: string | null
      package_name: string
      total_amount_inr: number
    }
  } catch (error) {
    throw toAppError(error)
  }
}
