export type AuthFlow = 'signup' | 'reset'

export interface PendingAuth {
  email: string
  flow: AuthFlow
  createdAt: number
}

const KEY = 'fitdesk.pending-auth'
const RECOVERY_KEY = 'fitdesk.recovery.active'

export function setPendingAuth(email: string, flow: AuthFlow): void {
  try {
    const pending: PendingAuth = {
      email: email.trim().toLowerCase(),
      flow,
      createdAt: Date.now(),
    }
    sessionStorage.setItem(KEY, JSON.stringify(pending))
  } catch {
    // no-op
  }
}

export function getPendingAuth(): PendingAuth | null {
  try {
    const raw = sessionStorage.getItem(KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as PendingAuth
    if (!parsed?.email || (parsed.flow !== 'signup' && parsed.flow !== 'reset')) return null
    // Email links are short-lived; drop stale context after 30 minutes.
    if (Date.now() - parsed.createdAt > 30 * 60 * 1000) {
      clearPendingAuth()
      return null
    }
    return parsed
  } catch {
    return null
  }
}

export function clearPendingAuth(): void {
  try {
    sessionStorage.removeItem(KEY)
  } catch {
    // no-op
  }
}

/**
 * Marks the current tab as an active password-recovery session. Supabase
 * recovery links create a normal session, so this flag prevents a signed-in
 * member from opening /reset-password without following a reset link.
 */
export function markRecoverySession(): void {
  try {
    sessionStorage.setItem(RECOVERY_KEY, '1')
  } catch {
    // no-op
  }
}

export function hasRecoverySession(): boolean {
  try {
    return sessionStorage.getItem(RECOVERY_KEY) === '1'
  } catch {
    return false
  }
}

export function clearRecoverySession(): void {
  try {
    sessionStorage.removeItem(RECOVERY_KEY)
  } catch {
    // no-op
  }
}
