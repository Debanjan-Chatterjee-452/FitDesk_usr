import type { LegalDocumentType } from '@/types'

export const LEGAL_DOCUMENT_TYPES: LegalDocumentType[] = [
  'Aadhaar Card',
  'PAN Card',
  'Driving Licence',
  'Passport',
  'Voter ID',
]

/**
 * Cleans input as the member types so the field only ever contains characters
 * that can appear on the selected document. Aadhaar keeps digits only (spaces
 * are stripped), PAN and the other IDs are upper-cased and stripped to
 * alphanumerics.
 */
export function sanitizeDocumentNumber(
  type: LegalDocumentType | null | undefined,
  value: string,
): string {
  if (type === 'Aadhaar Card') {
    return value.replace(/\D/g, '').slice(0, 12)
  }
  const cleaned = value.toUpperCase().replace(/[^A-Z0-9]/g, '')
  if (type === 'PAN Card') return cleaned.slice(0, 10)
  return cleaned.slice(0, 20)
}

/** Returns a user-facing error, or null when the number is valid. */
export function validateLegalDocumentNumber(
  type: LegalDocumentType | null | undefined,
  value: string,
): string | null {
  if (!type) return 'Select the type of document you uploaded.'
  const number = sanitizeDocumentNumber(type, value)

  if (!number) return 'Enter the number printed on your document.'

  switch (type) {
    case 'Aadhaar Card':
      return /^[0-9]{12}$/.test(number)
        ? null
        : 'Aadhaar number must be exactly 12 digits.'
    case 'PAN Card':
      return /^[A-Z]{5}[0-9]{4}[A-Z]$/.test(number)
        ? null
        : 'Enter a valid PAN, for example ABCDE1234F.'
    default:
      return /^[A-Z0-9]{5,20}$/.test(number)
        ? null
        : 'Enter a valid document number (at least 5 letters or numbers).'
  }
}

export function documentNumberPlaceholder(
  type: LegalDocumentType | null | undefined,
): string {
  switch (type) {
    case 'Aadhaar Card':
      return '12-digit Aadhaar number'
    case 'PAN Card':
      return 'ABCDE1234F'
    case 'Driving Licence':
      return 'e.g. DL0420110149646'
    case 'Passport':
      return 'e.g. A1234567'
    case 'Voter ID':
      return 'e.g. ABC1234567'
    default:
      return 'Document number'
  }
}

export function documentNumberHint(
  type: LegalDocumentType | null | undefined,
): string {
  switch (type) {
    case 'Aadhaar Card':
      return 'Enter the 12 digits exactly as printed. Spaces are removed automatically.'
    case 'PAN Card':
      return '10 characters: five letters, four digits, then one letter.'
    case 'Driving Licence':
      return 'Enter the licence number printed on the document (at least 5 characters).'
    case 'Passport':
      return 'Enter the passport number printed on the document (at least 5 characters).'
    case 'Voter ID':
      return 'Enter the EPIC number printed on the voter ID (at least 5 characters).'
    default:
      return 'Enter the number printed on the document you upload.'
  }
}
