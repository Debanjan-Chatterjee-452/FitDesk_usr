import { getSupabase } from '@/lib/supabase'
import type { QueryClient } from '@tanstack/react-query'
import { queryKeys } from '@/hooks/queries'

/**
 * Member-side Supabase Realtime bridge.
 *
 * All channels are scoped to the signed-in user's id and the tables involved
 * carry RLS policies that restrict rows to the owning user, so no private
 * data can leak through these subscriptions even if a channel is opened by
 * another client.
 */
export function installMemberRealtime(
  queryClient: QueryClient,
  userId: string,
): () => void {
  const supabase = getSupabase()
  const channel = supabase
    .channel(`fitdesk-member:${userId}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'payments', filter: `user_id=eq.${userId}` },
      () => {
        void queryClient.invalidateQueries({ queryKey: queryKeys.payments(userId) })
        void queryClient.invalidateQueries({ queryKey: queryKeys.pendingPayment(userId) })
        void queryClient.invalidateQueries({ queryKey: queryKeys.membership(userId) })
        void queryClient.invalidateQueries({ queryKey: ['upi-payment'] })
        void queryClient.invalidateQueries({ queryKey: ['cash-payment'] })
      },
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'memberships', filter: `user_id=eq.${userId}` },
      () => {
        void queryClient.invalidateQueries({ queryKey: queryKeys.membership(userId) })
      },
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'gyms' },
      () => {
        // Shutter toggles live on public.gyms. RLS limits delivered events to
        // the member's own gym, so no cross-gym filter is needed here.
        void queryClient.invalidateQueries({ queryKey: queryKeys.gym })
      },
    )
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'announcements' },
      () => {
        // Closures are stored as announcements. Both the status card and the
        // Activity calendar cache this data under these keys.
        void queryClient.invalidateQueries({ queryKey: queryKeys.gym })
        void queryClient.invalidateQueries({ queryKey: queryKeys.gymClosures })
      },
    )
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'attendance', filter: `user_id=eq.${userId}` },
      () => {
        void queryClient.invalidateQueries({ queryKey: queryKeys.attendance(userId) })
      },
    )
    .subscribe()

  return () => {
    void supabase.removeChannel(channel)
  }
}