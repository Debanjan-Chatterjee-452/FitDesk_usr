import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('@/lib/env', () => ({
  isDemo: true,
  isDemoMode: true,
  isSupabaseConfigured: false,
  supabaseUrl: '',
  supabaseAnonKey: '',
  razorpayPublicKeyId: '',
  TIMEZONE: 'Asia/Kolkata',
  CURRENCY: 'INR',
  appConfig: {},
}))

vi.mock('@/lib/utils', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/lib/utils')>()
  return { ...actual, sleep: () => Promise.resolve() }
})

import {
  confirmDemoEmail,
  normalizeEmail,
  requestPasswordReset,
  signIn,
  signUp,
  signOut,
  startDemoPasswordReset,
  updatePassword,
} from './auth'
import {
  DEMO_EMAIL,
  DEMO_PASSWORD,
  createSeedDatabase,
  resetDemoDatabase,
  type DemoUser,
} from '@/lib/demo/store'
import { toAppError } from '@/lib/errors'

function createStorage(): Storage {
  const data = new Map<string, string>()
  return {
    get length() {
      return data.size
    },
    clear() {
      data.clear()
    },
    getItem(key: string) {
      return data.get(key) ?? null
    },
    key(index: number) {
      return [...data.keys()][index] ?? null
    },
    removeItem(key: string) {
      data.delete(key)
    },
    setItem(key: string, value: string) {
      data.set(key, value)
    },
  }
}

function seededUser(): DemoUser {
  return createSeedDatabase().users[0]!
}

describe('email normalization', () => {
  it('trims and lowercases addresses', () => {
    expect(normalizeEmail('  Aarav@Example.COM ')).toBe('aarav@example.com')
  })
})

describe('demo email authentication', () => {
  beforeEach(() => {
    vi.stubGlobal('localStorage', createStorage())
    vi.stubGlobal('sessionStorage', createStorage())
    resetDemoDatabase()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('signs in the seeded member with email and password', async () => {
    const result = await signIn(DEMO_EMAIL, DEMO_PASSWORD, false)
    expect(result.userId).toBe(seededUser().id)
  })

  it('registers with email and requires confirmation before sign-in', async () => {
    const result = await signUp('  New.Member@Example.COM ', 'fitdesk123', true)
    expect(result).toEqual({ needsConfirmation: true, userId: null })

    await expect(signIn('new.member@example.com', 'fitdesk123', true)).rejects.toMatchObject({
      code: 'EMAIL_NOT_CONFIRMED',
    })

    const confirmed = await confirmDemoEmail('NEW.MEMBER@example.com', true)
    const login = await signIn('new.member@example.com', 'fitdesk123', true)
    expect(login.userId).toBe(confirmed.userId)
  })

  it('treats email addresses case-insensitively for duplicate accounts', async () => {
    await expect(signUp(DEMO_EMAIL.toUpperCase(), 'fitdesk123', false)).rejects.toMatchObject({
      code: 'USER_EXISTS',
    })
  })

  it('resets the demo password through a recovery session', async () => {
    await requestPasswordReset(DEMO_EMAIL)
    await startDemoPasswordReset(DEMO_EMAIL, false)
    await updatePassword('newfitdesk123')
    await signOut()

    await expect(signIn(DEMO_EMAIL, DEMO_PASSWORD, false)).rejects.toMatchObject({
      code: 'INVALID_CREDENTIALS',
    })
    await expect(signIn(DEMO_EMAIL, 'newfitdesk123', false)).resolves.toBeTruthy()
  })

  it('keeps the seeded phone as optional contact data', async () => {
    const user = seededUser()
    expect(user.phone).toMatch(/^\d{10}$/)
    expect(user.profile.email).toBe(DEMO_EMAIL)
    expect(user.profile.phone).toBe(`+91${user.phone}`)
  })
})

describe('email auth error messages', () => {
  it('maps unconfirmed email errors', () => {
    const error = toAppError({ message: 'Email not confirmed' })
    expect(error.code).toBe('EMAIL_NOT_CONFIRMED')
    expect(error.message).toContain('Confirm your email')
  })

  it('mentions email in invalid credential errors', () => {
    const error = toAppError({ message: 'Invalid login credentials' })
    expect(error.code).toBe('INVALID_CREDENTIALS')
    expect(error.message).toContain('email')
  })

  it('maps expired email links', () => {
    const error = toAppError({ message: 'Email link is invalid or has expired' })
    expect(error.code).toBe('EMAIL_LINK_INVALID')
    expect(error.message).toContain('Request a new one')
  })
})
