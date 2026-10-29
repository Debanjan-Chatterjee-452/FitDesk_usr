import { BrowserQRCodeReader } from '@zxing/browser'

/**
 * Loads a remote QR image and reads its payload with ZXing.
 *
 * Returns null when the image cannot be loaded or the code cannot be decoded.
 * Callers must treat null as "not verified", never as "fine to claim".
 */
export async function loadAndDecodeQrImage(url: string): Promise<{
  image: HTMLImageElement | null
  payload: string | null
}> {
  const image = await loadImage(url)
  if (!image) return { image: null, payload: null }

  try {
    const reader = new BrowserQRCodeReader()
    const result = await reader.decodeFromImageElement(image)
    return { image, payload: result.getText() }
  } catch {
    return { image, payload: null }
  }
}

function loadImage(url: string): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const image = new Image()
    // Supabase Storage serves `access-control-allow-origin: *`, which keeps the
    // canvas readable. If the browser still refuses, decoding fails softly and
    // the panel falls back to a QR generated from the gym's UPI ID.
    image.crossOrigin = 'anonymous'
    image.decoding = 'async'

    let settled = false
    const finish = (value: HTMLImageElement | null) => {
      if (settled) return
      settled = true
      window.clearTimeout(timeout)
      image.onload = null
      image.onerror = null
      resolve(value)
    }

    const timeout = window.setTimeout(() => finish(null), 15_000)
    image.onload = () => finish(image)
    image.onerror = () => finish(null)
    image.src = url
  })
}
