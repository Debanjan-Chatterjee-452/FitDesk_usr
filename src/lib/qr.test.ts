import { describe, expect, it } from 'vitest'
import { maskToken, parseGymQrPayload } from './qr'

describe('parseGymQrPayload', () => {
  it('accepts a raw front-desk token', () => {
    expect(parseGymQrPayload('  FITDESK-DEMO-GYM  ')).toEqual({
      token: 'FITDESK-DEMO-GYM',
      source: 'raw',
    })
  })

  it('extracts the token from a printed deep link', () => {
    expect(parseGymQrPayload('https://app.fitdesk.in/scan?gym=FRONT-DESK-2026')).toEqual({
      token: 'FRONT-DESK-2026',
      source: 'url',
    })
    expect(parseGymQrPayload('https://app.fitdesk.in/scan?token=FRONT-DESK-2026')).toEqual({
      token: 'FRONT-DESK-2026',
      source: 'url',
    })
    expect(parseGymQrPayload('https://app.fitdesk.in/scan?code=FRONT-DESK-2026')).toEqual({
      token: 'FRONT-DESK-2026',
      source: 'url',
    })
  })

  it('accepts a small JSON payload', () => {
    expect(parseGymQrPayload('{"token":"FRONT-DESK-2026"}')).toEqual({
      token: 'FRONT-DESK-2026',
      source: 'json',
    })
    expect(parseGymQrPayload('{"gym":"FRONT-DESK-2026"}')).toEqual({
      token: 'FRONT-DESK-2026',
      source: 'json',
    })
  })

  it('rejects malformed or incomplete payloads', () => {
    expect(parseGymQrPayload('')).toBeNull()
    expect(parseGymQrPayload('   ')).toBeNull()
    expect(parseGymQrPayload('abc')).toBeNull()
    expect(parseGymQrPayload('{not json')).toBeNull()
    expect(parseGymQrPayload('{"token":""}')).toBeNull()
    expect(parseGymQrPayload('https://app.fitdesk.in/scan')).toBeNull()
    expect(parseGymQrPayload('https://app.fitdesk.in/scan?gym=abc')).toBeNull()
    expect(parseGymQrPayload('FIT DESK GYM')).toBeNull()
    expect(parseGymQrPayload('x'.repeat(513))).toBeNull()
  })
})

describe('maskToken', () => {
  it('keeps short tokens intact and masks long ones', () => {
    expect(maskToken('SHORT')).toBe('SHORT')
    expect(maskToken('FITDESK-DEMO-GYM')).toBe('FITD••••-GYM')
  })
})
