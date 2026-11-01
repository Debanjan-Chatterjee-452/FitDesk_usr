const sharp = require('sharp')
const fs = require('fs')
const path = require('path')

const root = 'D:/Gym App'
const svg = fs.readFileSync(path.join(root, 'public/favicon.svg'))

async function main() {
  // 1024x1024 icon
  await sharp(svg, { density: 512 })
    .resize(1024, 1024, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(path.join(root, 'assets/icon-only.png'))

  // splash: 2732x2732 brand background with centered logo
  const logo = await sharp(svg, { density: 512 }).resize(720, 720).png().toBuffer()
  await sharp({
    create: {
      width: 2732,
      height: 2732,
      channels: 4,
      background: { r: 7, g: 21, b: 18, alpha: 1 },
    },
  })
    .composite([{ input: logo, gravity: 'center' }])
    .png()
    .toFile(path.join(root, 'assets/splash.png'))

  console.log('icon-only.png and splash.png generated')
}

main().catch((e) => { console.error(e); process.exit(1) })
