import { Suspense, lazy } from 'react'
import { Route, Routes } from 'react-router-dom'
import { Toaster } from 'sonner'
import { PublicOnly, RequireAdmin, RequireCompleteProfile, RequireSession } from '@/components/guards'
import { AppShell } from '@/components/layout/AppShell'
import { FullScreenLoader } from '@/components/ui/FullScreenLoader'
import { useTheme } from '@/context/ThemeProvider'
import { isDemo, isSupabaseConfigured } from '@/lib/env'
import { SetupPage } from '@/pages/SetupPage'

const LoginPage = lazy(() =>
  import('@/pages/auth/LoginPage').then((module) => ({ default: module.LoginPage })),
)
const SignupPage = lazy(() =>
  import('@/pages/auth/SignupPage').then((module) => ({ default: module.SignupPage })),
)
const CheckEmailPage = lazy(() =>
  import('@/pages/auth/CheckEmailPage').then((module) => ({
    default: module.CheckEmailPage,
  })),
)
const ConfirmEmailPage = lazy(() =>
  import('@/pages/auth/ConfirmEmailPage').then((module) => ({
    default: module.ConfirmEmailPage,
  })),
)
const ForgotPasswordPage = lazy(() =>
  import('@/pages/auth/ForgotPasswordPage').then((module) => ({
    default: module.ForgotPasswordPage,
  })),
)
const ResetPasswordPage = lazy(() =>
  import('@/pages/auth/ResetPasswordPage').then((module) => ({
    default: module.ResetPasswordPage,
  })),
)
const ProfileSetupPage = lazy(() =>
  import('@/pages/ProfileSetupPage').then((module) => ({ default: module.ProfileSetupPage })),
)
const HomePage = lazy(() =>
  import('@/pages/HomePage').then((module) => ({ default: module.HomePage })),
)
const MembershipPage = lazy(() =>
  import('@/pages/MembershipPage').then((module) => ({ default: module.MembershipPage })),
)
const AttendancePage = lazy(() =>
  import('@/pages/AttendancePage').then((module) => ({ default: module.AttendancePage })),
)
const ScanPage = lazy(() =>
  import('@/pages/ScanPage').then((module) => ({ default: module.ScanPage })),
)
const ProfilePage = lazy(() =>
  import('@/pages/ProfilePage').then((module) => ({ default: module.ProfilePage })),
)
const AdminApprovalsPage = lazy(() =>
  import('@/pages/AdminApprovalsPage').then((module) => ({
    default: module.AdminApprovalsPage,
  })),
)
const NotFoundPage = lazy(() =>
  import('@/pages/NotFoundPage').then((module) => ({ default: module.NotFoundPage })),
)

function AppToaster() {
  const { resolved } = useTheme()
  return (
    <Toaster
      theme={resolved}
      position="top-center"
      richColors
      closeButton
      offset={16}
      toastOptions={{
        style: {
          borderRadius: '18px',
          fontFamily: '"Manrope Variable", Manrope, system-ui, sans-serif',
        },
      }}
    />
  )
}

export default function App() {
  if (!isSupabaseConfigured && !isDemo) {
    return <SetupPage />
  }

  return (
    <>
      <AppToaster />
      <Suspense fallback={<FullScreenLoader label="Opening FitDesk" />}>
        <Routes>
          <Route element={<PublicOnly />}>
            <Route path="/login" element={<LoginPage />} />
            <Route path="/signup" element={<SignupPage />} />
            <Route path="/check-email" element={<CheckEmailPage />} />
            <Route path="/forgot-password" element={<ForgotPasswordPage />} />
          </Route>

          {/* Email links may switch from signed-out to signed-in while open. */}
          <Route path="/confirm-email" element={<ConfirmEmailPage />} />
          <Route path="/reset-password" element={<ResetPasswordPage />} />

          <Route element={<RequireSession />}>
            <Route path="/onboarding" element={<ProfileSetupPage />} />

            <Route element={<RequireCompleteProfile />}>
              <Route element={<AppShell />}>
                <Route index element={<HomePage />} />
                <Route path="/membership" element={<MembershipPage />} />
                <Route path="/attendance" element={<AttendancePage />} />
                <Route path="/profile" element={<ProfilePage />} />
                <Route path="/scan" element={<ScanPage />} />

                <Route element={<RequireAdmin />}>
                  <Route path="/admin/approvals" element={<AdminApprovalsPage />} />
                </Route>
              </Route>
            </Route>
          </Route>

          <Route path="*" element={<NotFoundPage />} />
        </Routes>
      </Suspense>
    </>
  )
}
