#!/usr/bin/env node
/**
 * Generates a printable front-desk QR from a raw token produced by
 * `select public.create_gym_qr_code('Front desk');`.
 *
 * Usage:
 *   node scripts/generate-gym-qr.mjs "FITDESK-..." gym-qr.png
 *   GYM_QR_TOKEN="FITDESK-..." node scripts/generate-gym-qr.mjs
 */
import { writeFile } from 'node:fs/promises'
import QRCode from 'qrcode'

const token = (process.argv[2] ?? process.env.GYM_QR_TOKEN ?? '').trim()
const output = process.argv[3] ?? 'gym-qr.png'

if (!token) {
  console.error('Usage: node scripts/generate-gym-qr.mjs "FITDESK-..." [output.png]')
  process.exit(1)
}

const dataUrl = await QRCode.toDataURL(token, {
  errorCorrectionLevel: 'H',
  margin: 3,
  width: 1024,
  color: {
    dark: '#052E2A',
    light: '#FFFFFF',
  },
})

await writeFile(output, Buffer.from(dataUrl.split(',')[1], 'base64'))
console.log(`Wrote ${output}`)
console.log('Keep this image private until it is printed and placed at the front desk.')
