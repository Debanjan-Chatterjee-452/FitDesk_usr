import { describe, expect, it, vi } from 'vitest'
import { copyText } from './clipboard'

describe('copyText', () => {
  it('copies a trimmed value through the supplied writer', async () => {
    const writer = vi.fn().mockResolvedValue(true)
    await expect(copyText('  fitdesk@ybl  ', writer)).resolves.toBe(true)
    expect(writer).toHaveBeenCalledWith('fitdesk@ybl')
  })

  it('supports a synchronous writer', async () => {
    await expect(copyText('1499', () => true)).resolves.toBe(true)
  })

  it('reports failure when the writer fails', async () => {
    await expect(copyText('1499', () => false)).resolves.toBe(false)
    await expect(copyText('1499', async () => false)).resolves.toBe(false)
  })

  it('refuses to copy an empty value', async () => {
    const writer = vi.fn().mockResolvedValue(true)
    await expect(copyText('   ', writer)).resolves.toBe(false)
    expect(writer).not.toHaveBeenCalled()
  })

  it('falls back to failure when no clipboard API exists', async () => {
    // The node test environment has neither navigator.clipboard nor a DOM.
    await expect(copyText('fitdesk@ybl')).resolves.toBe(false)
  })
})
