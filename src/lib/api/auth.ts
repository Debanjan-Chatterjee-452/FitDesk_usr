import type { AuthChangeEvent, Session } from '@supabase/supabase-js'
import { isDemo, isSupabaseConfigured } from '@/lib/env'
import { AppError, toAppError } from '@/lib/errors'
import { getSupabase, setSessionPersistence } from '@/lib/supabase'
import { sleep } from '@/lib/utils'
import {
  clearDemoSession,
  getDemoSessionUserId,
  loadDemoDatabase,
  saveDemoDatabase,
  setDemoSessionUserId,
  type DemoUser,
} from '@/lib/demo/store'

export interface SignInResult {
  userId: string
}

export interface SignUpResult {
  needsConfirmation: boolean
  userId: string | null
}

const CONFIRM_EMAIL_PATH = '/confirm-email'
const RESET_PASSWORD_PATH = '/reset-password'

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase()
}

/**
 * Builds an absolute URL for Supabase email links. The same URLs must be
 * allow-listed under Authentication → URL Configuration in the Supabase
 * dashboard (Site URL + Redirect URLs).
 */
export function emailRedirectTo(path: string): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '')
  return `${window.location.origin}${base}${path}`
}

function findDemoUser(email: string, db = loadDemoDatabase()): DemoUser | undefined {
  const normalized = normalizeEmail(email)
  return db.users.find((user) => normalizeEmail(user.email) === normalized)
}

function demoNeedsProfile(user: DemoUser): boolean {
  return !user.profile.profile_completed
}

export async function signIn(
  email: string,
  password: string,
  persist: boolean,
): Promise<SignInResult> {
  if (isDemo) {
    await sleep(550)
    setSessionPersistence(persist)
    const db = loadDemoDatabase()
    const user = findDemoUser(email, db)
    if (!user || user.password !== password) {
      throw new AppError(
        'INVALID_CREDENTIALS',
        "That email and password don't match. Please try again.",
      )
    }
    if (!user.email_confirmed) {
      throw new AppError(
        'EMAIL_NOT_CONFIRMED',
        'Confirm your email address before signing in. Check your inbox for the link.',
      )
    }
    setDemoSessionUserId(user.id, persist)
    return { userId: user.id }
  }

  try {
    setSessionPersistence(persist)
    const { data, error } = await getSupabase().auth.signInWithPassword({
      email: normalizeEmail(email),
      password,
    })
    if (error) throw error
    if (!data.user) {
      throw new AppError('INVALID_CREDENTIALS', 'Sign in failed. Please try again.')
    }
    return { userId: data.user.id }
  } catch (error) {
    throw toAppError(error)
  }
}

export async function signUp(
  email: string,
  password: string,
  persist: boolean,
): Promise<SignUpResult> {
  const normalized = normalizeEmail(email)

  if (isDemo) {
    await sleep(650)
    setSessionPersistence(persist)
    const db = loadDemoDatabase()
    if (findDemoUser(normalized, db)) {
      throw new AppError(
        'USER_EXISTS',
        'An account already exists with this email. Try signing in instead.',
      )
    }
    const id = crypto.randomUUID()
    const now = new Date().toISOString()
    const user: DemoUser = {
      id,
      email: normalized,
      email_confirmed: false,
      phone: '',
      password,
      profile: {
        id,
        email: normalized,
        phone: '',
        full_name: null,
        date_of_birth: null,
        blood_group: null,
        gender: null,
        legal_document_path: null,
        legal_document_name: null,
        legal_document_type: null,
        profile_completed: false,
        is_admin: false,
        created_at: now,
        updated_at: now,
      },
      memberships: [],
      attendance: [],
      payments: [],
    }
    db.users.push(user)
    saveDemoDatabase(db)
    return { needsConfirmation: true, userId: null }
  }

  try {
    setSessionPersistence(persist)
    const { data, error } = await getSupabase().auth.signUp({
      email: normalized,
      password,
      options: {
        emailRedirectTo: emailRedirectTo(CONFIRM_EMAIL_PATH),
        data: { signup_source: 'fitdesk_member' },
      },
    })
    if (error) throw error
    return {
      needsConfirmation: !data.session,
      userId: data.user?.id ?? null,
    }
  } catch (error) {
    throw toAppError(error)
  }
}

/** Re-sends the Supabase sign-up confirmation email. */
export async function resendConfirmationEmail(email: string): Promise<void> {
  if (isDemo) {
    await sleep(400)
    return
  }

  try {
    const { error } = await getSupabase().auth.resend({
      type: 'signup',
      email: normalizeEmail(email),
      options: { emailRedirectTo: emailRedirectTo(CONFIRM_EMAIL_PATH) },
    })
    if (error) throw error
  } catch (error) {
    throw toAppError(error)
  }
}

/** Demo-only: marks the pending account as confirmed and signs it in. */
export async function confirmDemoEmail(
  email: string,
  persist = true,
): Promise<SignInResult> {
  if (!isDemo) {
    throw new AppError('UNKNOWN', 'Demo confirmation is not available in this build.')
  }
  await sleep(500)
  setSessionPersistence(persist)
  const db = loadDemoDatabase()
  const user = findDemoUser(email, db)
  if (!user) {
    throw new AppError('INVALID_CREDENTIALS', 'No demo account found with that email.')
  }
  user.email_confirmed = true
  user.profile.email = normalizeEmail(email)
  saveDemoDatabase(db)
  setDemoSessionUserId(user.id, persist)
  return { userId: user.id }
}

/**
 * Sends a Supabase password-recovery link. The response is intentionally
 * uniform so the screen cannot be used to discover registered emails.
 */
export async function requestPasswordReset(email: string): Promise<void> {
  if (isDemo) {
    await sleep(550)
    return
  }

  try {
    const { error } = await getSupabase().auth.resetPasswordForEmail(
      normalizeEmail(email),
      { redirectTo: emailRedirectTo(RESET_PASSWORD_PATH) },
    )
    if (error) throw error
  } catch (error) {
    throw toAppError(error)
  }
}

/** Demo-only: opens the recovery link for an existing demo account. */
export async function startDemoPasswordReset(
  email: string,
  persist = true,
): Promise<SignInResult> {
  if (!isDemo) {
    throw new AppError('UNKNOWN', 'Demo recovery is not available in this build.')
  }
  await sleep(450)
  setSessionPersistence(persist)
  const db = loadDemoDatabase()
  const user = findDemoUser(email, db)
  if (!user) {
    throw new AppError(
      'INVALID_CREDENTIALS',
      'No demo account exists with that email. Use the demo account or register first.',
    )
  }
  user.email_confirmed = true
  user.profile.email = normalizeEmail(email)
  saveDemoDatabase(db)
  setDemoSessionUserId(user.id, persist)
  return { userId: user.id }
}

const exchangePromises = new Map<string, Promise<void>>()

/**
 * Completes a PKCE email link (confirmation or recovery). Supabase returns a
 * one-time `code` in the redirect URL; exchanging it creates the session.
 *
 * React StrictMode mounts effects twice in development, so exchanges are
 * de-duplicated by code.
 */
export function exchangeEmailLink(code: string): Promise<void> {
  const trimmed = code.trim()
  if (!trimmed) {
    return Promise.reject(
      new AppError('EMAIL_LINK_INVALID', 'This email link is incomplete. Request a new one.'),
    )
  }

  const existing = exchangePromises.get(trimmed)
  if (existing) return existing

  const promise = (async () => {
    try {
      const { error } = await getSupabase().auth.exchangeCodeForSession(trimmed)
      if (error) throw error
    } catch (error) {
      exchangePromises.delete(trimmed)
      throw toAppError(error)
    }
  })()

  exchangePromises.set(trimmed, promise)
  return promise
}

export async function updatePassword(password: string): Promise<void> {
  if (isDemo) {
    await sleep(550)
    const userId = getDemoSessionUserId()
    if (!userId) {
      throw new AppError('AUTH_REQUIRED', 'Open the reset link again to change your password.')
    }
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Account not found. Please start again.')
    user.password = password
    saveDemoDatabase(db)
    return
  }

  try {
    const { error } = await getSupabase().auth.updateUser({ password })
    if (error) throw error
  } catch (error) {
    throw toAppError(error)
  }
}

export async function signOut(): Promise<void> {
  if (isDemo) {
    await sleep(200)
    clearDemoSession()
    return
  }
  try {
    await getSupabase().auth.signOut({ scope: 'local' })
  } catch (error) {
    throw toAppError(error)
  }
}

/** Boot-time session lookup. */
export async function getStoredUserId(): Promise<string | null> {
  if (isDemo) {
    const id = getDemoSessionUserId()
    if (!id) return null
    const db = loadDemoDatabase()
    const exists = db.users.some((user) => user.id === id)
    if (!exists) {
      clearDemoSession()
      return null
    }
    return id
  }
  try {
    const { data } = await getSupabase().auth.getSession()
    return data.session?.user.id ?? null
  } catch {
    return null
  }
}

export async function getNeedsProfile(userId: string): Promise<boolean> {
  if (isDemo) {
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    return user ? demoNeedsProfile(user) : true
  }
  const { data } = await getSupabase()
    .from('profiles')
    .select('profile_completed')
    .eq('id', userId)
    .maybeSingle()
  const row = data as { profile_completed: boolean } | null
  return row ? !row.profile_completed : true
}

export function subscribeToAuthChanges(
  handler: (userId: string | null) => void,
): () => void {
  if (isDemo) return () => undefined
  if (!isSupabaseConfigured) return () => undefined
  const { data } = getSupabase().auth.onAuthStateChange(
    (_event: AuthChangeEvent, session: Session | null) => {
      handler(session?.user.id ?? null)
    },
  )
  return () => data.subscription.unsubscribe()
}
