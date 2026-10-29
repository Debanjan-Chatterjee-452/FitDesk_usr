import type { Config } from 'tailwindcss'
import animate from 'tailwindcss-animate'

const config: Config = {
  darkMode: ['class', '[data-theme="dark"]'],
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    container: {
      center: true,
      padding: {
        DEFAULT: '1.25rem',
        sm: '1.5rem',
        lg: '2rem',
      },
      screens: {
        '2xl': '1280px',
      },
    },
    extend: {
      colors: {
        bg: 'rgb(var(--bg) / <alpha-value>)',
        surface: 'rgb(var(--surface) / <alpha-value>)',
        elevated: 'rgb(var(--elevated) / <alpha-value>)',
        line: 'rgb(var(--line) / <alpha-value>)',
        ink: 'rgb(var(--ink) / <alpha-value>)',
        muted: 'rgb(var(--muted) / <alpha-value>)',
        faint: 'rgb(var(--faint) / <alpha-value>)',
        primary: {
          DEFAULT: 'rgb(var(--primary) / <alpha-value>)',
          soft: 'rgb(var(--primary-soft) / <alpha-value>)',
          strong: 'rgb(var(--primary-strong) / <alpha-value>)',
          ink: 'rgb(var(--primary-ink) / <alpha-value>)',
        },
        success: 'rgb(var(--success) / <alpha-value>)',
        warning: 'rgb(var(--warning) / <alpha-value>)',
        danger: 'rgb(var(--danger) / <alpha-value>)',
        info: 'rgb(var(--info) / <alpha-value>)',
      },
      fontFamily: {
        // Matches the Progym reference: Montserrat for headings/UI,
        // Pontano Sans for paragraphs, links, buttons and form controls.
        sans: ['"Montserrat Variable"', 'Montserrat', 'system-ui', 'sans-serif'],
        display: ['"Montserrat Variable"', 'Montserrat', 'system-ui', 'sans-serif'],
        body: ['"Pontano Sans Variable"', '"Pontano Sans"', 'system-ui', 'sans-serif'],
        // Free SIL OFL alternative to Cook Conthic, used only for prominent
        // display headings and selected large metrics.
        accent: [
          '"Big Shoulders Display Variable"',
          '"Big Shoulders Display"',
          '"Montserrat Variable"',
          'system-ui',
          'sans-serif',
        ],
      },
      borderRadius: {
        '4xl': '2rem',
        '5xl': '2.5rem',
      },
      boxShadow: {
        card: '0 1px 2px rgb(10 30 28 / 0.04), 0 12px 32px -12px rgb(10 30 28 / 0.12)',
        'card-lg': '0 2px 4px rgb(10 30 28 / 0.04), 0 24px 60px -24px rgb(10 30 28 / 0.24)',
        glow: '0 0 0 1px rgb(var(--primary) / 0.18), 0 18px 50px -12px rgb(var(--primary) / 0.45)',
        nav: '0 -8px 30px -12px rgb(4 20 18 / 0.18)',
        inset: 'inset 0 1px 0 0 rgb(255 255 255 / 0.08)',
      },
      backgroundImage: {
        'grid-faint':
          'linear-gradient(to right, rgb(var(--line) / 0.55) 1px, transparent 1px), linear-gradient(to bottom, rgb(var(--line) / 0.55) 1px, transparent 1px)',
        'hero-teal':
          'radial-gradient(120% 120% at 100% 0%, rgb(45 212 191 / 0.35) 0%, transparent 55%), linear-gradient(135deg, #0B2B28 0%, #071512 55%, #06100E 100%)',
      },
      backgroundSize: {
        grid: '48px 48px',
        'grid-sm': '24px 24px',
      },
      keyframes: {
        'fade-up': {
          '0%': { opacity: '0', transform: 'translateY(14px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
        'fade-in': {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
        scanline: {
          '0%': { top: '8%', opacity: '0.2' },
          '12%': { opacity: '1' },
          '88%': { opacity: '1' },
          '100%': { top: '92%', opacity: '0.2' },
        },
        'pulse-ring': {
          '0%': { transform: 'scale(0.85)', opacity: '0.7' },
          '80%, 100%': { transform: 'scale(1.5)', opacity: '0' },
        },
        shimmer: {
          '100%': { transform: 'translateX(100%)' },
        },
        float: {
          '0%, 100%': { transform: 'translate3d(0, 0, 0)' },
          '50%': { transform: 'translate3d(0, -12px, 0)' },
        },
        'check-draw': {
          '0%': { strokeDashoffset: '48' },
          '100%': { strokeDashoffset: '0' },
        },
        'spin-slow': {
          to: { transform: 'rotate(360deg)' },
        },
      },
      animation: {
        'fade-up': 'fade-up 0.55s cubic-bezier(0.22, 1, 0.36, 1) both',
        'fade-in': 'fade-in 0.35s ease-out both',
        scanline: 'scanline 2.4s cubic-bezier(0.45, 0, 0.55, 1) infinite',
        'pulse-ring': 'pulse-ring 2s cubic-bezier(0.2, 0.6, 0.35, 1) infinite',
        shimmer: 'shimmer 1.8s infinite',
        float: 'float 7s ease-in-out infinite',
        'check-draw': 'check-draw 0.6s 0.2s ease-out forwards',
        'spin-slow': 'spin-slow 14s linear infinite',
      },
      transitionTimingFunction: {
        spring: 'cubic-bezier(0.22, 1, 0.36, 1)',
      },
    },
  },
  plugins: [animate],
}

export default config
