import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { isSupabaseConfigured, supabaseAnonKey, supabaseUrl } from './env'
import { AppError } from './errors'

const PERSIST_KEY = 'fitdesk.persist'
const STORAGE_KEY = 'fitdesk.auth.session'

/**
 * "Keep me signed in" uses localStorage; otherwise the session lives only in
 * sessionStorage and disappears when the tab closes. The preference is read
 * lazily on every read/write so it can be changed before signing in.
 */
export function setSessionPersistence(persist: boolean): void {
  try {
    localStorage.setItem(PERSIST_KEY, persist ? '1' : '0')
    if (!persist) {
      localStorage.removeItem(STORAGE_KEY)
      sessionStorage.removeItem(STORAGE_KEY)
    }
  } catch {
    // Storage can be unavailable in private browsing; fail soft.
  }
}

export function getSessionPersistence(): boolean {
  try {
    return localStorage.getItem(PERSIST_KEY) !== '0'
  } catch {
    return true
  }
}

const hybridStorage = {
  getItem(key: string): string | null {
    try {
      return getSessionPersistence()
        ? localStorage.getItem(key)
        : sessionStorage.getItem(key)
    } catch {
      return null
    }
  },
  setItem(key: string, value: string): void {
    try {
      if (getSessionPersistence()) {
        localStorage.setItem(key, value)
        sessionStorage.removeItem(key)
      } else {
        sessionStorage.setItem(key, value)
        localStorage.removeItem(key)
      }
    } catch {
      // Ignore quota / privacy-mode errors.
    }
  },
  removeItem(key: string): void {
    try {
      localStorage.removeItem(key)
      sessionStorage.removeItem(key)
    } catch {
      // no-op
    }
  },
}

let client: SupabaseClient | null = null

export function getSupabase(): SupabaseClient {
  if (!isSupabaseConfigured) {
    throw new AppError(
      'UNKNOWN',
      'Supabase is not configured. Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to your environment.',
    )
  }
  if (!client) {
    client = createClient(supabaseUrl, supabaseAnonKey, {
      auth: {
        storage: hybridStorage,
        storageKey: STORAGE_KEY,
        persistSession: true,
        autoRefreshToken: true,
        // Email confirmation/recovery links are exchanged explicitly by the
        // /confirm-email and /reset-password screens so we can show clear
        // expired-link and wrong-browser errors.
        detectSessionInUrl: false,
        flowType: 'pkce',
      },
      global: {
        headers: { 'x-application-name': 'fitdesk-member' },
      },
    })
  }
  return client
}

export async function getCurrentUserId(): Promise<string> {
  const { data, error } = await getSupabase().auth.getUser()
  if (error || !data.user) {
    throw new AppError('AUTH_REQUIRED', 'Please sign in again to continue.')
  }
  return data.user.id
}

export function clearAuthStorage(): void {
  try {
    localStorage.removeItem(STORAGE_KEY)
    sessionStorage.removeItem(STORAGE_KEY)
  } catch {
    // no-op
  }
}
