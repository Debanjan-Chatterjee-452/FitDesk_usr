/**
 * Generates Android launcher icons and PWA icons from the exact FitDesk emblem.
 * Run: node scripts/generate-android-icons.cjs
 */
const fs = require('fs')
const path = require('path')
const sharp = require('sharp')

const ROOT = path.resolve(__dirname, '..')
const SOURCE = 'C:/Users/Lenovo/Downloads/FD LOGO.svg'
const svg = fs.readFileSync(SOURCE, 'utf8')
const pathMatches = [...svg.matchAll(/<path\b([^>]*)>/g)]
const emblem = (pathMatches[1][1].match(/d="([^"]*)"/) || [])[1]
if (!emblem) throw new Error('Emblem path not found')

const ICON_VIEW_BOX = '242 158 430 430'
const EMBLEM_COLOR = '#2DD4BF'
const DARK_BG = '#0B1F1C'

function emblemSvg(size, safeScale = 1) {
  const scale = 100 / 430
  const inner = safeScale === 1 ? 100 : 100 * safeScale
  const tx = (100 - inner) / 2
  const ty = (100 - inner) / 2
  const transform = safeScale === 1
    ? `translate(${(-242).toFixed(4)} ${(-158).toFixed(4)}) scale(${scale.toFixed(6)})`
    : `translate(${(tx - 242 * scale * safeScale).toFixed(4)} ${(ty - 158 * scale * safeScale).toFixed(4)}) scale(${(scale * safeScale).toFixed(6)})`
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 100 100">
  <g transform="${transform}" fill="${EMBLEM_COLOR}">
    <path d="${emblem}" />
  </g>
</svg>`
}

function backgroundSvg(size) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}"><rect width="100%" height="100%" fill="${DARK_BG}"/></svg>`
}

async function composite(size, safeScale, circle) {
  let output = await sharp({ create: { width: size, height: size, channels: 4, background: '#00000000' } })
    .composite([
      { input: Buffer.from(backgroundSvg(size)) },
      { input: Buffer.from(emblemSvg(size, safeScale)) },
    ])
    .png()
    .toBuffer()
  if (circle) {
    const mask = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}"><circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}" fill="#fff"/></svg>`,
    )
    output = await sharp(output)
      .composite([{ input: mask, blend: 'dest-in' }])
      .png()
      .toBuffer()
  }
  return output
}

async function main() {
  const densities = [
    ['mdpi', 48],
    ['hdpi', 72],
    ['xhdpi', 96],
    ['xxhdpi', 144],
    ['xxxhdpi', 192],
  ]
  for (const [density, size] of densities) {
    const dir = path.join(ROOT, 'android/app/src/main/res', `mipmap-${density}`)
    fs.mkdirSync(dir, { recursive: true })

    // Legacy launcher: emblem at ~80% of the canvas on the dark theme colour.
    fs.writeFileSync(path.join(dir, 'ic_launcher.png'), await composite(size, 0.8, false))
    fs.writeFileSync(path.join(dir, 'ic_launcher_round.png'), await composite(size, 0.8, true))

    // Adaptive layers: background is solid; foreground stays inside the
    // 66% safe zone already declared by the existing inset XML.
    fs.writeFileSync(path.join(dir, 'ic_launcher_background.png'), await sharp(Buffer.from(backgroundSvg(size))).png().toBuffer())
    fs.writeFileSync(
      path.join(dir, 'ic_launcher_foreground.png'),
      await sharp(Buffer.from(emblemSvg(size, 0.66))).png().toBuffer(),
    )
  }

  const colorFile = path.join(ROOT, 'android/app/src/main/res/values/ic_launcher_background.xml')
  fs.writeFileSync(
    colorFile,
    `<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">${DARK_BG}</color>\n</resources>\n`,
  )

  const iconDir = path.join(ROOT, 'public/icons')
  fs.mkdirSync(iconDir, { recursive: true })
  fs.writeFileSync(path.join(iconDir, 'icon-192.png'), await composite(192, 0.8, false))
  fs.writeFileSync(path.join(iconDir, 'icon-512.png'), await composite(512, 0.8, false))
  fs.writeFileSync(path.join(iconDir, 'apple-touch-icon.png'), await composite(180, 0.8, false))
  fs.writeFileSync(path.join(iconDir, 'icon-maskable-512.png'), await composite(512, 0.66, false))

  console.log('Android + PWA icons generated from the exact FitDesk emblem. ICON_VIEW_BOX=' + ICON_VIEW_BOX)
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
