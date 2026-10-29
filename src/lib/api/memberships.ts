import type { GymPackage, Membership, MembershipSnapshot, RenewalQuote } from '@/types'
import { isDemo } from '@/lib/env'
import { toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { clamp } from '@/lib/utils'
import { daysBetween, daysUntil, todayInKolkata } from '@/lib/kolkata'
import { calculateDemoQuote, loadDemoDatabase } from '@/lib/demo/store'
import { requireUserId } from './session'

interface RawQuote {
  package_id: string
  package_name: string
  description: string | null
  pricing_mode: 'fixed' | 'per_day'
  duration_days: number | string
  base_amount: number | string
  fine_amount: number | string
  total_amount: number | string
  days_past_expiry: number | string
  grace_days: number | string
  starts_on: string
  ends_on: string
  current_ends_on: string | null
  is_stacked: boolean
  fine_reason: string | null
  breakdown?: Array<{ label: string; amount: number | string }>
}

function normalizeQuote(raw: RawQuote): RenewalQuote {
  const base = Number(raw.base_amount) || 0
  const fine = Number(raw.fine_amount) || 0
  return {
    package_id: raw.package_id,
    package_name: raw.package_name,
    description: raw.description ?? null,
    pricing_mode: raw.pricing_mode,
    duration_days: Number(raw.duration_days) || 0,
    base_amount: base,
    fine_amount: fine,
    total_amount: Number(raw.total_amount) || base + fine,
    days_past_expiry: Number(raw.days_past_expiry) || 0,
    grace_days: Number(raw.grace_days) || 0,
    starts_on: raw.starts_on,
    ends_on: raw.ends_on,
    current_ends_on: raw.current_ends_on ?? null,
    is_stacked: Boolean(raw.is_stacked),
    fine_reason: raw.fine_reason ?? null,
    breakdown:
      raw.breakdown?.map((item) => ({
        label: item.label,
        amount: Number(item.amount) || 0,
      })) ?? [
        { label: `${raw.package_name} · ${raw.duration_days} days`, amount: base },
        ...(fine > 0 ? [{ label: 'Late renewal fee', amount: fine }] : []),
      ],
  }
}

function attachPackage(
  row: Record<string, unknown>,
): Membership {
  const pkg = row.package as GymPackage | null | undefined
  return { ...(row as unknown as Membership), package: pkg ?? null }
}

export async function getPackages(): Promise<GymPackage[]> {
  if (isDemo) {
    return loadDemoDatabase()
      .packages.filter((pkg) => pkg.is_active)
      .sort((a, b) => a.sort_order - b.sort_order)
  }
  try {
    const { data, error } = await getSupabase()
      .from('packages')
      .select('*')
      .eq('is_active', true)
      .order('sort_order', { ascending: true })
    if (error) throw error
    return (data ?? []) as GymPackage[]
  } catch (error) {
    throw toAppError(error)
  }
}

export interface MembershipOverview {
  /** Plan covering today, or the most recently expired plan. */
  current: Membership | null
  /** A paid renewal that starts after today (stacked plan). */
  upcoming: Membership | null
}

export async function getMyMembershipOverview(): Promise<MembershipOverview> {
  if (isDemo) {
    const userId = await requireUserId()
    const user = loadDemoDatabase().users.find((item) => item.id === userId)
    if (!user) return { current: null, upcoming: null }
    return pickMembershipOverview(user.memberships)
  }

  try {
    const userId = await requireUserId()
    const { data, error } = await getSupabase()
      .from('memberships')
      .select('*, package:packages(*)')
      .eq('user_id', userId)
      .neq('status', 'cancelled')
      .order('starts_on', { ascending: true })
    if (error) throw error
    return pickMembershipOverview(
      (data ?? []).map((row) => attachPackage(row as Record<string, unknown>)),
    )
  } catch (error) {
    throw toAppError(error)
  }
}

export async function getMyMembership(): Promise<Membership | null> {
  return (await getMyMembershipOverview()).current
}

/**
 * Selects the plan that grants access today (or the latest expired plan for
 * outstanding-fee messaging) separately from a paid renewal queued after the
 * current plan. This keeps the dashboard's "current plan" truthful after a
 * stacked renewal instead of showing a future plan as already active.
 */
export function pickMembershipOverview(
  memberships: Membership[],
  now: Date = new Date(),
): MembershipOverview {
  const today = todayInKolkata(now)
  const live = memberships
    .filter((item) => item.status !== 'cancelled')
    .sort((a, b) => (a.ends_on < b.ends_on ? 1 : -1))

  const current =
    live.find((item) => item.starts_on <= today && item.ends_on >= today) ??
    live.find((item) => item.ends_on < today) ??
    null

  const upcoming =
    [...live]
      .filter((item) => item.starts_on > today && item.id !== current?.id)
      .sort((a, b) => (a.starts_on > b.starts_on ? 1 : -1))[0] ?? null

  return { current, upcoming }
}

export async function getMyRenewalQuote(
  packageId: string,
  durationDays?: number | null,
): Promise<RenewalQuote> {
  if (isDemo) {
    try {
      const userId = await requireUserId()
      return calculateDemoQuote(userId, packageId, durationDays ?? null)
    } catch (error) {
      throw toAppError(error)
    }
  }

  try {
    const { data, error } = await getSupabase().rpc('get_my_renewal_quote', {
      p_package_id: packageId,
      p_duration_days: durationDays ?? null,
    })
    if (error) throw error
    if (!data) throw new Error('PACKAGE_NOT_FOUND')
    return normalizeQuote(data as RawQuote)
  } catch (error) {
    throw toAppError(error)
  }
}

export function buildMembershipSnapshot(
  membership: Membership | null,
  now: Date = new Date(),
): MembershipSnapshot {
  if (!membership) {
    return {
      membership: null,
      isActive: false,
      daysLeft: 0,
      isExpired: false,
      daysPastExpiry: 0,
      progress: 0,
    }
  }

  const today = todayInKolkata(now)
  const isCancelled = membership.status === 'cancelled'
  const isActive = !isCancelled && membership.ends_on >= today
  const isExpired = !isCancelled && membership.ends_on < today
  const daysLeft = Math.max(0, daysUntil(membership.ends_on, now))
  const daysPastExpiry = isExpired ? Math.max(0, daysBetween(membership.ends_on, today)) : 0
  const totalDays = Math.max(1, daysBetween(membership.starts_on, membership.ends_on) + 1)
  const elapsedDays = clamp(daysBetween(membership.starts_on, today) + 1, 0, totalDays)
  const progress = clamp(elapsedDays / totalDays, 0, 1)

  return {
    membership,
    isActive,
    daysLeft,
    isExpired,
    daysPastExpiry,
    progress,
  }
}
