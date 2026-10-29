import { useEffect, useState } from 'react'
import {
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query'
import { toast } from 'sonner'
import { checkInWithQr, computeAttendanceStats, getMyAttendance } from '@/lib/api/attendance'
import { getGymOverview } from '@/lib/api/gym'
import {
  buildMembershipSnapshot,
  getMyMembershipOverview,
  getMyRenewalQuote,
  getPackages,
} from '@/lib/api/memberships'
import {
  createRenewalOrder,
  getMyPayments,
  getMyPendingPayment,
  verifyRenewalPayment,
} from '@/lib/api/payments'
import {
  getUpiPaymentInstructions,
  reserveUpiCheckout,
  submitUpiReference,
} from '@/lib/api/upi'
import {
  listPendingPayments,
  listRefundPayments,
  markPaymentRefunded,
  reviewPayment,
} from '@/lib/api/adminPayments'
import { toAppError } from '@/lib/errors'
import type { PaymentVerification } from '@/types'
import { useAuth } from '@/context/AuthProvider'

export const queryKeys = {
  membership: (userId: string) => ['membership', userId] as const,
  packages: ['packages'] as const,
  attendance: (userId: string) => ['attendance', userId] as const,
  gym: ['gym-overview'] as const,
  payments: (userId: string) => ['payments', userId] as const,
  pendingPayment: (userId: string) => ['pending-payment', userId] as const,
  adminPayments: ['admin-pending-payments'] as const,
  adminRefunds: ['admin-refund-payments'] as const,
  quote: (packageId: string, durationDays: number | null) =>
    ['renewal-quote', packageId, durationDays] as const,
  upiPayment: (paymentId: string | null) => ['upi-payment', paymentId ?? 'none'] as const,
}

export function useMembershipSnapshot() {
  const { userId } = useAuth()
  const query = useQuery({
    queryKey: queryKeys.membership(userId ?? 'anonymous'),
    queryFn: getMyMembershipOverview,
    enabled: Boolean(userId),
    staleTime: 30_000,
  })
  return {
    ...query,
    snapshot: buildMembershipSnapshot(query.data?.current ?? null),
    upcoming: query.data?.upcoming ?? null,
  }
}

export function usePackages() {
  return useQuery({
    queryKey: queryKeys.packages,
    queryFn: getPackages,
    staleTime: 10 * 60_000,
  })
}

export function useAttendance() {
  const { userId } = useAuth()
  return useQuery({
    queryKey: queryKeys.attendance(userId ?? 'anonymous'),
    queryFn: () => getMyAttendance(),
    enabled: Boolean(userId),
    staleTime: 30_000,
  })
}

export function useAttendanceStats() {
  const query = useAttendance()
  const records = query.data ?? []
  return {
    ...query,
    stats: computeAttendanceStats(records),
  }
}

export function useGymOverview() {
  return useQuery({
    queryKey: queryKeys.gym,
    queryFn: getGymOverview,
    staleTime: 60_000,
  })
}

export function usePayments() {
  const { userId } = useAuth()
  return useQuery({
    queryKey: queryKeys.payments(userId ?? 'anonymous'),
    queryFn: getMyPayments,
    enabled: Boolean(userId),
    staleTime: 30_000,
  })
}

/** Submitted payment currently waiting for gym approval. */
export function usePendingPayment() {
  const { userId } = useAuth()
  return useQuery({
    queryKey: queryKeys.pendingPayment(userId ?? 'anonymous'),
    queryFn: getMyPendingPayment,
    enabled: Boolean(userId),
    staleTime: 15_000,
  })
}

export function useAdminPendingPayments() {
  const { userId, profile } = useAuth()
  return useQuery({
    queryKey: queryKeys.adminPayments,
    queryFn: listPendingPayments,
    enabled: Boolean(userId) && Boolean(profile?.is_admin),
    staleTime: 10_000,
  })
}

export function useAdminRefundPayments() {
  const { userId, profile } = useAuth()
  return useQuery({
    queryKey: queryKeys.adminRefunds,
    queryFn: listRefundPayments,
    enabled: Boolean(userId) && Boolean(profile?.is_admin),
    staleTime: 10_000,
  })
}

export function useReviewPayment() {
  const queryClient = useQueryClient()
  const { userId } = useAuth()
  return useMutation({
    mutationFn: ({
      paymentId,
      decision,
      note,
    }: {
      paymentId: string
      decision: 'approved' | 'declined'
      note?: string | null
    }) => reviewPayment(paymentId, decision, note),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.adminPayments })
      void queryClient.invalidateQueries({ queryKey: queryKeys.adminRefunds })
      void queryClient.invalidateQueries({
        queryKey: queryKeys.membership(userId ?? 'anonymous'),
      })
      void queryClient.invalidateQueries({ queryKey: queryKeys.payments(userId ?? 'anonymous') })
      void queryClient.invalidateQueries({
        queryKey: queryKeys.pendingPayment(userId ?? 'anonymous'),
      })
    },
    onError: (error) => {
      const appError = toAppError(error)
      toast.error(appError.message)
    },
  })
}

export function useMarkPaymentRefunded() {
  const queryClient = useQueryClient()
  const { userId } = useAuth()
  return useMutation({
    mutationFn: ({
      paymentId,
      note,
    }: {
      paymentId: string
      note?: string | null
    }) => markPaymentRefunded(paymentId, note),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.adminRefunds })
      void queryClient.invalidateQueries({ queryKey: queryKeys.adminPayments })
      void queryClient.invalidateQueries({ queryKey: queryKeys.payments(userId ?? 'anonymous') })
    },
    onError: (error) => {
      const appError = toAppError(error)
      toast.error(appError.message)
    },
  })
}

export function useRenewalQuote(packageId: string | null, durationDays: number | null) {
  return useQuery({
    queryKey: queryKeys.quote(packageId ?? 'none', durationDays),
    queryFn: () => getMyRenewalQuote(packageId!, durationDays),
    enabled: Boolean(packageId),
    staleTime: 15_000,
  })
}

export function useCheckIn() {
  const queryClient = useQueryClient()
  const { userId } = useAuth()
  return useMutation({
    mutationFn: (token: string) => checkInWithQr(token),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.attendance(userId ?? 'anonymous') })
    },
    onError: (error) => {
      const appError = toAppError(error)
      toast.error(appError.message)
    },
  })
}

export function useCreateRenewalOrder() {
  const queryClient = useQueryClient()
  const { userId } = useAuth()
  return useMutation({
    mutationFn: ({
      packageId,
      durationDays,
    }: {
      packageId: string
      durationDays?: number | null
    }) => createRenewalOrder(packageId, durationDays),
    onError: () => {
      // The reservation may have found an existing pending/reconciliation row.
      // Refresh the member's banners even though no order was returned.
      void queryClient.invalidateQueries({ queryKey: queryKeys.payments(userId ?? 'anonymous') })
      void queryClient.invalidateQueries({
        queryKey: queryKeys.pendingPayment(userId ?? 'anonymous'),
      })
    },
  })
}

export function useVerifyPayment() {
  const queryClient = useQueryClient()
  const { userId, refreshProfile } = useAuth()
  return useMutation({
    mutationFn: (payload: {
      razorpay_order_id: string
      razorpay_payment_id: string
      razorpay_signature: string
    }) => verifyRenewalPayment(payload),
    onSuccess: (_result: PaymentVerification) => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.membership(userId ?? 'anonymous') })
      void queryClient.invalidateQueries({ queryKey: queryKeys.payments(userId ?? 'anonymous') })
      void queryClient.invalidateQueries({
        queryKey: queryKeys.pendingPayment(userId ?? 'anonymous'),
      })
      void refreshProfile()
    },
  })
}

/**
 * Direct-UPI instructions for one payment. Refetched on mount so a payee the
 * gym just configured shows up, and so a stale amount is never reused.
 */
export function useUpiPaymentInstructions(paymentId: string | null) {
  return useQuery({
    queryKey: queryKeys.upiPayment(paymentId),
    queryFn: () => getUpiPaymentInstructions(paymentId!),
    enabled: Boolean(paymentId),
    staleTime: 0,
    gcTime: 5 * 60_000,
    retry: 1,
  })
}

/** Reserves the pending payment row. The amount is computed by the server. */
export function useReserveUpiCheckout() {
  const queryClient = useQueryClient()
  const { userId } = useAuth()
  return useMutation({
    mutationFn: ({
      packageId,
      durationDays,
    }: {
      packageId: string
      durationDays?: number | null
    }) => reserveUpiCheckout(packageId, durationDays),
    onError: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.payments(userId ?? 'anonymous') })
      void queryClient.invalidateQueries({
        queryKey: queryKeys.pendingPayment(userId ?? 'anonymous'),
      })
    },
  })
}

/** Records the member's claimed UTR and leaves the payment pending review. */
export function useSubmitUpiReference() {
  const queryClient = useQueryClient()
  const { userId } = useAuth()
  return useMutation({
    mutationFn: ({ paymentId, reference }: { paymentId: string; reference: string }) =>
      submitUpiReference(paymentId, reference),
    onSuccess: (result) => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.upiPayment(result.payment_id) })
      void queryClient.invalidateQueries({ queryKey: queryKeys.payments(userId ?? 'anonymous') })
      void queryClient.invalidateQueries({
        queryKey: queryKeys.pendingPayment(userId ?? 'anonymous'),
      })
      void queryClient.invalidateQueries({ queryKey: queryKeys.membership(userId ?? 'anonymous') })
    },
  })
}

/** Re-renders on an interval — used for live validity countdowns. */
export function useNow(intervalMs = 60_000): Date {
  const [now, setNow] = useState(() => new Date())
  useEffect(() => {
    const id = window.setInterval(() => setNow(new Date()), intervalMs)
    return () => window.clearInterval(id)
  }, [intervalMs])
  return now
}
