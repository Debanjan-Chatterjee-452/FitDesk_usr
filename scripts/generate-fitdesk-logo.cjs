/**
 * Generates FitDeskLogo.tsx for both apps directly from the official SVG.
 * The path data is copied verbatim — never redraw or approximate it.
 *
 * Source: C:\Users\Lenovo\Downloads\FD LOGO.svg
 * Run:    node scripts/generate-fitdesk-logo.cjs
 */
const fs = require('fs')
const path = require('path')

const SOURCE = 'C:/Users/Lenovo/Downloads/FD LOGO.svg'
const svg = fs.readFileSync(SOURCE, 'utf8')

const viewBox = (svg.match(/viewBox="([^"]+)"/) || [])[1]
if (!viewBox) throw new Error('viewBox not found in source SVG')

const pathMatches = [...svg.matchAll(/<path\b([^>]*)>/g)]
const paths = pathMatches.map((match) => {
  const attrs = match[1]
  const fill = (attrs.match(/fill="([^"]*)"/) || [])[1]
  const d = (attrs.match(/d="([^"]*)"/) || [])[1]
  if (!d) throw new Error('A path has no d attribute')
  return { fill, d }
})

if (paths.length !== 10) throw new Error(`Expected 10 paths in source SVG, found ${paths.length}`)

// 0 = opaque black background. 1 = emblem. 2..8 = FITDESK letters.
// 9 = the D counter, drawn in the background colour; it becomes a mask hole.
const background = paths[0]
const emblem = paths[1]
const letters = paths.slice(2, 9)
const counter = paths[9]

if (!/^#09090A$/i.test(background.fill || '')) {
  throw new Error(`Unexpected background fill: ${background.fill}`)
}
if (!/^#0D0E0E$/i.test(counter.fill || '')) {
  throw new Error(`Unexpected D-counter fill: ${counter.fill}`)
}

// Emblem bounds computed from its absolute coordinates: x 268.6..647.1,
// y 177.4..568.8. A square crop centred on it gives the compact icon.
const iconViewBox = '242 158 430 430'

function reactComponent(cnImport) {
  return `/* Generated from FD LOGO.svg — exact path data, do not hand-edit. */
import { useId, type CSSProperties } from 'react'
import { cn } from '${cnImport}'

export const FITDESK_VIEW_BOX = '${viewBox}'
export const FITDESK_ICON_VIEW_BOX = '${iconViewBox}'

/** The emblem only, cropped from the original artwork. */
export const FITDESK_EMBLEM_PATH = ${JSON.stringify(emblem.d)}

/** Emblem + FITDESK wordmark, in their original positions. */
export const FITDESK_WORDMARK_PATHS = [
${letters.map((p) => '  ' + JSON.stringify(p.d) + ',').join('\n')}
]

/** The D counter, punched out so it stays transparent on any background. */
export const FITDESK_COUNTER_PATH = ${JSON.stringify(counter.d)}

export type FitDeskLogoVariant = 'full' | 'icon'

export interface FitDeskLogoProps {
  variant?: FitDeskLogoVariant
  className?: string
  title?: string
  style?: CSSProperties
}

/**
 * Exact FitDesk artwork. The black background rectangle from the source SVG
 * is deliberately omitted; every visible path uses 'currentColor', so the
 * logo inherits the active theme's primary colour.
 */
export function FitDeskLogo({
  variant = 'full',
  className,
  title = 'FitDesk',
  style,
}: FitDeskLogoProps) {
  const rawId = useId()
  const maskId = 'fitdesk-mask-' + rawId.replace(/[^a-zA-Z0-9_-]/g, '')
  const isIcon = variant === 'icon'
  const paths = isIcon
    ? [FITDESK_EMBLEM_PATH]
    : [FITDESK_EMBLEM_PATH, ...FITDESK_WORDMARK_PATHS]

  return (
    <svg
      viewBox={isIcon ? FITDESK_ICON_VIEW_BOX : FITDESK_VIEW_BOX}
      xmlns="http://www.w3.org/2000/svg"
      fill="currentColor"
      role="img"
      aria-label={title}
      className={cn(isIcon ? 'h-8 w-8' : 'h-10 w-auto', className)}
      style={style}
    >
      <title>{title}</title>
      <mask
        id={maskId}
        maskUnits="userSpaceOnUse"
        x="0"
        y="0"
        width="885"
        height="886"
      >
        <rect x="0" y="0" width="885" height="886" fill="#ffffff" />
        {isIcon ? null : <path d={FITDESK_COUNTER_PATH} fill="#000000" />}
      </mask>
      <g mask={\`url(#\${maskId})\`}>
        {paths.map((d, index) => (
          <path key={index} d={d} fill="currentColor" />
        ))}
      </g>
    </svg>
  )
}

/** Compact emblem for headers, avatars and favicons. */
export function FitDeskIcon(props: Omit<FitDeskLogoProps, 'variant'>) {
  return <FitDeskLogo {...props} variant="icon" />
}
`
}

function staticSvg(viewBoxValue, pathsToUse, includeCounter, color) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${viewBoxValue}" role="img" aria-label="FitDesk">
  <mask id="counter" maskUnits="userSpaceOnUse" x="0" y="0" width="885" height="886">
    <rect x="0" y="0" width="885" height="886" fill="#ffffff" />
${includeCounter ? `    <path d="${counter.d}" fill="#000000" />\n` : ''}  </mask>
  <g fill="${color}" mask="url(#counter)">
${pathsToUse.map((p) => `    <path d="${p.d}" />\n`).join('')}  </g>
</svg>
`
}

const memberRoot = path.resolve(__dirname, '..')
const adminRoot = path.resolve(memberRoot, '../Gym Admin Website')

const memberComponent = reactComponent('@/lib/utils')
const adminComponent = reactComponent('@/lib/format')

fs.mkdirSync(path.join(memberRoot, 'src/components/ui'), { recursive: true })
fs.mkdirSync(path.join(adminRoot, 'src/components/ui'), { recursive: true })
fs.writeFileSync(path.join(memberRoot, 'src/components/ui/FitDeskLogo.tsx'), memberComponent)
fs.writeFileSync(path.join(adminRoot, 'src/components/ui/FitDeskLogo.tsx'), adminComponent)

// Static favicon SVGs use the icon (emblem only) and the app's theme colour.
fs.writeFileSync(
  path.join(memberRoot, 'public/favicon.svg'),
  staticSvg(iconViewBox, [emblem], false, '#0F766E'),
)
fs.writeFileSync(
  path.join(adminRoot, 'public/favicon.svg'),
  staticSvg(iconViewBox, [emblem], false, '#123C31'),
)
fs.writeFileSync(
  path.join(memberRoot, 'public/fitdesk-logo.svg'),
  staticSvg(viewBox, [emblem, ...letters], true, 'currentColor'),
)
fs.writeFileSync(
  path.join(adminRoot, 'public/fitdesk-logo.svg'),
  staticSvg(viewBox, [emblem, ...letters], true, 'currentColor'),
)

console.log('Generated FitDeskLogo components and favicons from the exact source SVG.')
