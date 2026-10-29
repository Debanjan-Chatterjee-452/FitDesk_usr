/** Clipboard access with a legacy fallback for browsers without the async API. */

export type TextWriter = (text: string) => Promise<boolean> | boolean

export async function copyText(text: string, writer?: TextWriter): Promise<boolean> {
  const value = text.trim()
  if (!value) return false

  if (writer) {
    return Boolean(await writer(value))
  }

  try {
    if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(value)
      return true
    }
  } catch {
    // fall through to the legacy path
  }

  return legacyCopy(value)
}

function legacyCopy(value: string): boolean {
  if (typeof document === 'undefined') return false
  try {
    const area = document.createElement('textarea')
    area.value = value
    area.setAttribute('readonly', '')
    area.style.position = 'fixed'
    area.style.top = '-1000px'
    area.style.opacity = '0'
    document.body.appendChild(area)
    area.select()
    const copied = document.execCommand('copy')
    document.body.removeChild(area)
    return copied
  } catch {
    return false
  }
}
