import { clsx, type ClassValue } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs))
}

export function initials(name: string | null | undefined): string {
  if (!name) return 'FD'
  const parts = name.trim().split(/\s+/).filter(Boolean)
  if (parts.length === 0) return 'FD'
  if (parts.length === 1) return parts[0]!.slice(0, 2).toUpperCase()
  return `${parts[0]![0]}${parts[parts.length - 1]![0]}`.toUpperCase()
}

export function formatINR(value: number | string | null | undefined): string {
  const amount = typeof value === 'string' ? Number(value) : (value ?? 0)
  if (!Number.isFinite(amount)) return '₹0'
  const hasPaise = Math.abs(amount % 1) > 0.001
  return new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: hasPaise ? 2 : 0,
    maximumFractionDigits: hasPaise ? 2 : 0,
  }).format(amount)
}

export function formatNumber(value: number): string {
  return new Intl.NumberFormat('en-IN').format(value)
}

export function pluralize(count: number, singular: string, plural = `${singular}s`): string {
  return count === 1 ? singular : plural
}

export function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max)
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    window.setTimeout(resolve, ms)
  })
}

export function getErrorMessage(error: unknown, fallback = 'Something went wrong. Please try again.'): string {
  if (error instanceof Error && error.message) return error.message
  if (typeof error === 'string' && error) return error
  if (error && typeof error === 'object' && 'message' in error) {
    const message = (error as { message?: unknown }).message
    if (typeof message === 'string' && message) return message
  }
  return fallback
}

export function normalizePhoneInput(value: string): string {
  const digits = value.replace(/\D/g, '')
  if (digits.length > 10 && digits.startsWith('91')) return digits.slice(2, 12)
  return digits.slice(0, 10)
}

export function toE164(phone: string): string {
  const digits = phone.replace(/\D/g, '')
  if (digits.startsWith('91') && digits.length >= 12) return `+${digits.slice(0, 12)}`
  return `+91${digits.slice(-10)}`
}

export function prettyPhone(phone: string | null | undefined): string {
  if (!phone) return '—'
  const digits = phone.replace(/\D/g, '').slice(-10)
  if (digits.length !== 10) return phone
  return `+91 ${digits.slice(0, 5)} ${digits.slice(5)}`
}

export function formatDuration(days: number): string {
  if (days % 365 === 0) return days === 365 ? '1 year' : `${days / 365} years`
  if (days % 30 === 0) return days === 30 ? '1 month' : `${days / 30} months`
  if (days % 7 === 0) return days === 7 ? '1 week' : `${days / 7} weeks`
  return `${days} days`
}

export function svgToDataUrl(svg: string): string {
  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`
}

export function getFileExtension(name: string): string {
  const parts = name.split('.')
  return parts.length > 1 ? (parts.pop()?.toLowerCase() ?? '') : ''
}

export function isIos(): boolean {
  if (typeof navigator === 'undefined') return false
  return /iphone|ipad|ipod/i.test(navigator.userAgent)
}

export function isStandalone(): boolean {
  if (typeof window === 'undefined') return false
  return (
    window.matchMedia('(display-mode: standalone)').matches ||
    (window.navigator as Navigator & { standalone?: boolean }).standalone === true
  )
}
