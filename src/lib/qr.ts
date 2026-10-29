export interface GymQrPayload {
  token: string
  source: 'raw' | 'url' | 'json'
}

const MIN_TOKEN_LENGTH = 6
const MAX_TOKEN_LENGTH = 512

/**
 * The printed gym QR can contain a raw token, a deep link
 * (`https://app.fitdesk.in/scan?gym=TOKEN`) or a small JSON object.
 * All three forms are normalised to the opaque token sent to the server.
 */
export function parseGymQrPayload(raw: string): GymQrPayload | null {
  const value = raw.trim()
  if (!value) return null

  if (value.startsWith('{')) {
    try {
      const parsed: unknown = JSON.parse(value)
      if (parsed && typeof parsed === 'object') {
        const record = parsed as Record<string, unknown>
        const token =
          (typeof record.token === 'string' && record.token) ||
          (typeof record.gym === 'string' && record.gym) ||
          (typeof record.code === 'string' && record.code) ||
          ''
        if (isValidToken(token)) return { token, source: 'json' }
      }
    } catch {
      return null
    }
  }

  if (/^https?:\/\//i.test(value)) {
    try {
      const url = new URL(value)
      const candidate =
        url.searchParams.get('gym') ??
        url.searchParams.get('token') ??
        url.searchParams.get('code') ??
        ''
      if (isValidToken(candidate)) return { token: candidate, source: 'url' }
      return null
    } catch {
      return null
    }
  }

  if (isValidToken(value)) return { token: value, source: 'raw' }
  return null
}

function isValidToken(token: string): boolean {
  return (
    token.length >= MIN_TOKEN_LENGTH &&
    token.length <= MAX_TOKEN_LENGTH &&
    /^[A-Za-z0-9._~:/?#[\]@!$&'()*+,;=%-]+$/.test(token)
  )
}

export function maskToken(token: string): string {
  if (token.length <= 8) return token
  return `${token.slice(0, 4)}••••${token.slice(-4)}`
}
