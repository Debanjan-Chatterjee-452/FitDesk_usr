import QRCode from 'qrcode'

/**
 * Renders a UPI intent as a QR data URL.
 *
 * Only ever called with a URI built from the server-verified UPI ID and the
 * server-side amount, never with a browser-supplied recipient.
 */
export async function buildUpiQrDataUrl(uri: string): Promise<string> {
  return QRCode.toDataURL(uri, {
    errorCorrectionLevel: 'M',
    margin: 2,
    width: 640,
    color: {
      dark: '#071512FF',
      light: '#FFFFFFFF',
    },
  })
}
