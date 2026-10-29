import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'

export type ThemeMode = 'light' | 'dark' | 'system'

interface ThemeContextValue {
  mode: ThemeMode
  resolved: 'light' | 'dark'
  setMode: (mode: ThemeMode) => void
  cycleMode: () => void
}

const STORAGE_KEY = 'fitdesk.theme'
const ThemeContext = createContext<ThemeContextValue | null>(null)

function systemTheme(): 'light' | 'dark' {
  if (typeof window === 'undefined') return 'light'
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

function readStoredMode(): ThemeMode {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (raw === 'light' || raw === 'dark' || raw === 'system') return raw
  } catch {
    // no-op
  }
  return 'system'
}

function applyTheme(mode: ThemeMode): 'light' | 'dark' {
  const resolved = mode === 'system' ? systemTheme() : mode
  const root = document.documentElement
  root.setAttribute('data-theme', resolved)
  root.classList.toggle('dark', resolved === 'dark')
  root.style.colorScheme = resolved
  const meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')
  if (meta) meta.content = resolved === 'dark' ? '#05100E' : '#F4F7F7'
  return resolved
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [mode, setModeState] = useState<ThemeMode>(readStoredMode)
  const [resolved, setResolved] = useState<'light' | 'dark'>(() =>
    typeof document === 'undefined'
      ? 'light'
      : document.documentElement.getAttribute('data-theme') === 'dark'
        ? 'dark'
        : 'light',
  )

  useEffect(() => {
    setResolved(applyTheme(mode))
  }, [mode])

  useEffect(() => {
    if (mode !== 'system') return
    const query = window.matchMedia('(prefers-color-scheme: dark)')
    const handle = () => setResolved(applyTheme('system'))
    query.addEventListener('change', handle)
    return () => query.removeEventListener('change', handle)
  }, [mode])

  const setMode = useCallback((next: ThemeMode) => {
    setModeState(next)
    try {
      localStorage.setItem(STORAGE_KEY, next)
    } catch {
      // no-op
    }
  }, [])

  const cycleMode = useCallback(() => {
    setMode(mode === 'light' ? 'dark' : 'light')
  }, [mode, setMode])

  const value = useMemo<ThemeContextValue>(
    () => ({ mode, resolved, setMode, cycleMode }),
    [mode, resolved, setMode, cycleMode],
  )

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}

export function useTheme(): ThemeContextValue {
  const context = useContext(ThemeContext)
  if (!context) throw new Error('useTheme must be used inside ThemeProvider')
  return context
}
