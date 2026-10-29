import { describe, expect, it } from 'vitest'
import {
  UPI_STATE_LABELS,
  buildUpiUri,
  formatUpiAmount,
  interpretUpiQrPayload,
  isPaymentSettled,
  isValidUpiAmount,
  isValidUpiId,
  isValidUpiReference,
  normalizeUpiId,
  normalizeUpiReference,
  parseUpiUri,
  resolveUpiPayee,
} from './upi'

const GYM_UPI = 'fitdesk.gym@okhdfcbank'

describe('isValidUpiId', () => {
  it('accepts the shape the database trigger accepts', () => {
    expect(isValidUpiId('fitdesk.gym@okhdfcbank')).toBe(true)
    expect(isValidUpiId('  FITDESK@YBL  ')).toBe(true)
    expect(isValidUpiId('a1@pb')).toBe(true)
  })

  it('rejects anything that is not <handle>@<psp>', () => {
    expect(isValidUpiId('')).toBe(false)
    expect(isValidUpiId(null)).toBe(false)
    expect(isValidUpiId('fitdesk')).toBe(false)
    expect(isValidUpiId('fitdesk@')).toBe(false)
    expect(isValidUpiId('@okhdfcbank')).toBe(false)
    expect(isValidUpiId('fit desk@okhdfcbank')).toBe(false)
    expect(isValidUpiId('fitdesk@@okhdfcbank')).toBe(false)
    expect(isValidUpiId('+919000000000@upi')).toBe(false)
  })

  it('normalises case and surrounding whitespace', () => {
    expect(normalizeUpiId('  FitDesk.Gym@OKHDFCBANK ')).toBe('fitdesk.gym@okhdfcbank')
  })
})

describe('isValidUpiAmount', () => {
  it('accepts positive rupee amounts with at most two decimals', () => {
    expect(isValidUpiAmount(1499)).toBe(true)
    expect(isValidUpiAmount(0.5)).toBe(true)
    expect(isValidUpiAmount(1499.99)).toBe(true)
  })

  it('rejects zero, negatives, NaN and sub-paise values', () => {
    expect(isValidUpiAmount(0)).toBe(false)
    expect(isValidUpiAmount(-1)).toBe(false)
    expect(isValidUpiAmount(Number.NaN)).toBe(false)
    expect(isValidUpiAmount(null)).toBe(false)
    expect(isValidUpiAmount(10.001)).toBe(false)
  })

  it('formats with exactly two decimals for UPI apps', () => {
    expect(formatUpiAmount(1499)).toBe('1499.00')
    expect(formatUpiAmount(0.5)).toBe('0.50')
  })
})

describe('buildUpiUri', () => {
  it('builds a UPI intent with the recipient, amount and reference', () => {
    const uri = buildUpiUri({
      upiId: GYM_UPI,
      payeeName: 'FitDesk Performance Club',
      amountInr: 1499,
      reference: 'FD1A2B3C4D5E6F',
      note: 'FitDesk membership',
    })

    const parsed = new URL(uri)
    expect(parsed.protocol).toBe('upi:')
    expect(parsed.host).toBe('pay')
    expect(parsed.searchParams.get('pa')).toBe(GYM_UPI)
    expect(parsed.searchParams.get('pn')).toBe('FitDesk Performance Club')
    expect(parsed.searchParams.get('am')).toBe('1499.00')
    expect(parsed.searchParams.get('cu')).toBe('INR')
    expect(parsed.searchParams.get('tr')).toBe('FD1A2B3C4D5E6F')
    expect(parsed.searchParams.get('tn')).toBe('FitDesk membership')
  })

  it('percent-encodes spaces as %20 rather than +', () => {
    const uri = buildUpiUri({
      upiId: GYM_UPI,
      payeeName: 'Fit Desk & Co',
      amountInr: 500,
    })
    expect(uri).toContain('%20')
    expect(uri).not.toContain('+')
    // The raw query must not contain a literal space either.
    expect(uri.split('?')[1]).not.toContain(' ')
  })

  it('escapes characters that would break the query string', () => {
    const uri = buildUpiUri({
      upiId: GYM_UPI,
      payeeName: 'A&B=Club?',
      amountInr: 100,
      note: 'note #1 & more',
    })
    const parsed = new URL(uri)
    expect(parsed.searchParams.get('pn')).toBe('A&B=Club?')
    expect(parsed.searchParams.get('tn')).toBe('note #1 & more')
    // Only the separators we add ourselves may appear unescaped.
    expect(uri.split('?')[1]!.split('&').every((part) => part.includes('='))).toBe(true)
  })

  it('normalises the recipient before encoding it', () => {
    const uri = buildUpiUri({ upiId: '  FITDESK@YBL ', amountInr: 99 })
    expect(new URL(uri).searchParams.get('pa')).toBe('fitdesk@ybl')
  })

  it('refuses to build a URI from an invalid recipient or amount', () => {
    expect(() => buildUpiUri({ upiId: 'not-a-vpa', amountInr: 100 })).toThrow('INVALID_UPI_ID')
    expect(() => buildUpiUri({ upiId: '', amountInr: 100 })).toThrow('INVALID_UPI_ID')
    expect(() => buildUpiUri({ upiId: GYM_UPI, amountInr: 0 })).toThrow('INVALID_UPI_AMOUNT')
    expect(() => buildUpiUri({ upiId: GYM_UPI, amountInr: Number.NaN })).toThrow(
      'INVALID_UPI_AMOUNT',
    )
  })

  it('caps the note and reference at the NPCI limits', () => {
    const uri = buildUpiUri({
      upiId: GYM_UPI,
      amountInr: 100,
      note: 'x'.repeat(120),
      reference: 'R'.repeat(80),
    })
    const parsed = new URL(uri)
    expect(parsed.searchParams.get('tn')).toHaveLength(50)
    expect(parsed.searchParams.get('tr')).toHaveLength(35)
  })
})

describe('parseUpiUri', () => {
  it('round-trips a URI produced by buildUpiUri', () => {
    const uri = buildUpiUri({
      upiId: GYM_UPI,
      payeeName: 'FitDesk Performance Club',
      amountInr: 1499,
      reference: 'FD123456789012',
      note: 'FitDesk membership',
    })

    expect(parseUpiUri(uri)).toEqual({
      upiId: GYM_UPI,
      payeeName: 'FitDesk Performance Club',
      amountInr: 1499,
      reference: 'FD123456789012',
      note: 'FitDesk membership',
    })
  })

  it('reads a statically generated QR that has no amount', () => {
    expect(parseUpiUri('upi://pay?pa=fitdesk@ybl&pn=FitDesk')).toEqual({
      upiId: 'fitdesk@ybl',
      payeeName: 'FitDesk',
      amountInr: null,
      reference: null,
      note: null,
    })
  })

  it('returns null for anything that is not a UPI intent', () => {
    expect(parseUpiUri(null)).toBeNull()
    expect(parseUpiUri('')).toBeNull()
    expect(parseUpiUri('https://example.com/?pa=fitdesk@ybl')).toBeNull()
    expect(parseUpiUri('UPI')).toBeNull()
    expect(parseUpiUri('upi://pay?pn=NoPayee')).toBeNull()
    expect(parseUpiUri('upi://pay?pa=not a vpa')).toBeNull()
  })
})

describe('interpretUpiQrPayload', () => {
  it('accepts a QR that points at the same recipient and amount', () => {
    const payload = buildUpiUri({
      upiId: GYM_UPI,
      payeeName: 'FitDesk',
      amountInr: 1499,
    })
    expect(interpretUpiQrPayload(payload, { upiId: GYM_UPI, amountInr: 1499 }).status).toBe(
      'verified',
    )
  })

  it('rejects a QR that points at a different recipient', () => {
    const payload = buildUpiUri({ upiId: 'someone.else@ybl', amountInr: 1499 })
    const verdict = interpretUpiQrPayload(payload, { upiId: GYM_UPI, amountInr: 1499 })
    expect(verdict).toEqual({ status: 'payee_mismatch', foundUpiId: 'someone.else@ybl' })
  })

  it('rejects a QR for a different amount', () => {
    const payload = buildUpiUri({ upiId: GYM_UPI, amountInr: 1 })
    expect(interpretUpiQrPayload(payload, { upiId: GYM_UPI, amountInr: 1499 })).toEqual({
      status: 'amount_mismatch',
      foundAmount: 1,
    })
  })

  it('does not call a static QR ready for an exact amount', () => {
    const payload = buildUpiUri({ upiId: GYM_UPI, amountInr: 1499 })
    const staticQr = payload.replace('&am=1499.00', '')
    expect(interpretUpiQrPayload(staticQr, { upiId: GYM_UPI, amountInr: 1499 })).toEqual({
      status: 'missing_amount',
    })
  })

  it('rejects an image that is not a UPI QR at all', () => {
    expect(interpretUpiQrPayload('https://gym.example/promo', { upiId: GYM_UPI })).toEqual({
      status: 'not_upi',
    })
    expect(interpretUpiQrPayload(null, { upiId: GYM_UPI })).toEqual({ status: 'not_upi' })
    expect(interpretUpiQrPayload('', { upiId: GYM_UPI })).toEqual({ status: 'not_upi' })
  })

  it('compares recipients case-insensitively', () => {
    const payload = buildUpiUri({ upiId: GYM_UPI, amountInr: 1499 })
    expect(
      interpretUpiQrPayload(payload, { upiId: 'FITDESK.GYM@OKHDFCBANK', amountInr: 1499 }).status,
    ).toBe('verified')
  })
})

describe('UPI reference handling', () => {
  it('strips spaces and hyphens and uppercases', () => {
    expect(normalizeUpiReference(' utr-1234 5678 ')).toBe('UTR12345678')
  })

  it('accepts 6–40 letters or digits', () => {
    expect(isValidUpiReference('123456')).toBe(true)
    expect(isValidUpiReference('utr-1234-5678')).toBe(true)
    expect(isValidUpiReference('A'.repeat(40))).toBe(true)
  })

  it('rejects too-short, too-long and symbolic references', () => {
    expect(isValidUpiReference('12345')).toBe(false)
    expect(isValidUpiReference('A'.repeat(41))).toBe(false)
    expect(isValidUpiReference('1234/5678')).toBe(false)
    expect(isValidUpiReference('')).toBe(false)
    expect(isValidUpiReference(null)).toBe(false)
  })
})

describe('resolveUpiPayee', () => {
  it('keeps a configured, well-formed payee', () => {
    expect(
      resolveUpiPayee(
        {
          available: true,
          reason: null,
          upi_id: ' FitDesk.Gym@OKHDFCBANK ',
          name: 'FitDesk Performance Club',
          qr_path: 'gym/qr.png',
          qr_bucket: 'gym-payment-qr',
        },
        1499,
      ),
    ).toEqual({
      available: true,
      reason: null,
      upi_id: GYM_UPI,
      name: 'FitDesk Performance Club',
      qr_path: 'gym/qr.png',
      qr_bucket: 'gym-payment-qr',
    })
  })

  it('never invents a payee when the gym has not configured one', () => {
    expect(resolveUpiPayee(null, 1499)).toEqual({
      available: false,
      reason: 'NOT_CONFIGURED',
      upi_id: null,
      name: null,
      qr_path: null,
      qr_bucket: null,
    })
    expect(
      resolveUpiPayee({ available: false, reason: 'NOT_CONFIGURED', upi_id: null }, 1499),
    ).toMatchObject({ available: false, reason: 'NOT_CONFIGURED', upi_id: null })
  })

  it('drops a payee that the server marked unavailable even if a UPI ID is present', () => {
    expect(
      resolveUpiPayee({ available: false, upi_id: GYM_UPI, name: 'FitDesk' }, 1499),
    ).toMatchObject({ available: false, upi_id: null, name: null })
  })

  it('drops a malformed UPI ID instead of showing it', () => {
    expect(
      resolveUpiPayee({ available: true, upi_id: 'not a vpa', name: 'FitDesk' }, 1499),
    ).toEqual({
      available: false,
      reason: 'INVALID_UPI_ID',
      upi_id: null,
      name: null,
      qr_path: null,
      qr_bucket: null,
    })
  })

  it('blocks payment when the amount is unusable', () => {
    for (const amount of [0, -100, Number.NaN]) {
      expect(
        resolveUpiPayee({ available: true, upi_id: GYM_UPI, name: 'FitDesk' }, amount),
      ).toMatchObject({ available: false, reason: 'AMOUNT_INVALID', upi_id: null })
    }
  })
})

describe('payment state presentation', () => {
  it('labels every state', () => {
    expect(UPI_STATE_LABELS.NOT_STARTED).toBe('Awaiting payment')
    expect(UPI_STATE_LABELS.PENDING_VERIFICATION).toBe('Pending verification')
    expect(UPI_STATE_LABELS.VERIFIED).toBe('Verified')
    expect(UPI_STATE_LABELS.FAILED).toBe('Failed')
    expect(UPI_STATE_LABELS.CANCELLED).toBe('Cancelled')
  })

  it('treats only verified/failed/cancelled as settled', () => {
    expect(isPaymentSettled('NOT_STARTED')).toBe(false)
    expect(isPaymentSettled('PENDING_VERIFICATION')).toBe(false)
    expect(isPaymentSettled('VERIFIED')).toBe(true)
    expect(isPaymentSettled('FAILED')).toBe(true)
    expect(isPaymentSettled('CANCELLED')).toBe(true)
  })
})
