import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { registerSW } from 'virtual:pwa-register'
import '@fontsource-variable/montserrat'
import '@fontsource-variable/pontano-sans'
import '@fontsource-variable/big-shoulders-display'
import './index.css'
import App from './App'
import { ErrorBoundary } from '@/components/ErrorBoundary'
import { ThemeProvider } from '@/context/ThemeProvider'
import { AuthProvider } from '@/context/AuthProvider'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      gcTime: 10 * 60_000,
      retry: 1,
      refetchOnWindowFocus: true,
    },
    mutations: {
      retry: 0,
    },
  },
})

registerSW({ immediate: true })

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
      <ErrorBoundary>
        <QueryClientProvider client={queryClient}>
          <BrowserRouter>
            <AuthProvider>
              <App />
            </AuthProvider>
          </BrowserRouter>
        </QueryClientProvider>
      </ErrorBoundary>
    </ThemeProvider>
  </StrictMode>,
)
