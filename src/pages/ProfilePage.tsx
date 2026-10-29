import { useState, type ReactNode } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  AlertCircle,
  BadgeCheck,
  CalendarDays,
  ChevronRight,
  CreditCard,
  Droplets,
  ExternalLink,
  Eye,
  FileText,
  Fingerprint,
  KeyRound,
  Loader2,
  LogOut,
  Mail,
  Monitor,
  Moon,
  Pencil,
  RefreshCcw,
  RotateCcw,
  ShieldCheck,
  Smartphone,
  Sparkles,
  Sun,
  UserRound,
  Users,
} from 'lucide-react'
import { toast } from 'sonner'
import type { BloodGroup, Gender } from '@/types'
import { useAuth } from '@/context/AuthProvider'
import { useTheme, type ThemeMode } from '@/context/ThemeProvider'
import { useAttendanceStats, useMembershipSnapshot } from '@/hooks/queries'
import {
  getDocumentSignedUrl,
  saveDocumentReplacement,
  updateMyProfile,
  validateLegalDocument,
  type ProfileUpdate,
} from '@/lib/api/profile'
import { updatePassword } from '@/lib/api/auth'
import { appConfig, isDemo } from '@/lib/env'
import { toAppError } from '@/lib/errors'
import { ageFromDob, formatKolkata, todayInKolkata } from '@/lib/kolkata'
import { resetDemoDatabase } from '@/lib/demo/store'
import { cn, prettyPhone } from '@/lib/utils'
import { PageHeader } from '@/components/layout/PageHeader'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Avatar } from '@/components/ui/Avatar'
import { Badge } from '@/components/ui/Badge'
import { Button } from '@/components/ui/Button'
import { Input, PasswordInput } from '@/components/ui/Input'
import { FileDropzone } from '@/components/ui/FileDropzone'
import { SegmentedControl } from '@/components/ui/SegmentedControl'
import { Sheet } from '@/components/ui/Sheet'
import { FullScreenLoader } from '@/components/ui/FullScreenLoader'
import { ErrorState } from '@/components/ui/ErrorState'

const GENDER_OPTIONS: Array<{ value: Gender; label: string }> = [
  { value: 'male', label: 'Male' },
  { value: 'female', label: 'Female' },
  { value: 'other', label: 'Other' },
  { value: 'prefer_not_to_say', label: 'Prefer not to say' },
]

const GENDER_LABELS: Record<Gender, string> = {
  male: 'Male',
  female: 'Female',
  other: 'Other',
  prefer_not_to_say: 'Prefer not to say',
}

const BLOOD_GROUPS: BloodGroup[] = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-']

const THEME_OPTIONS: Array<{ value: ThemeMode; label: string; icon: ReactNode }> = [
  { value: 'light', label: 'Light', icon: <Sun className="h-3.5 w-3.5" /> },
  { value: 'dark', label: 'Dark', icon: <Moon className="h-3.5 w-3.5" /> },
  { value: 'system', label: 'System', icon: <Monitor className="h-3.5 w-3.5" /> },
]

interface DetailsForm {
  fullName: string
  dateOfBirth: string
  gender: Gender | null
  bloodGroup: BloodGroup | null
}

interface DetailsErrors {
  fullName?: string
  dateOfBirth?: string
  gender?: string
  bloodGroup?: string
}

export function ProfilePage() {
  const navigate = useNavigate()
  const {
    profile,
    refreshProfile,
    signOutMember,
    isProfileComplete: completed,
  } = useAuth()
  const { mode, setMode } = useTheme()
  const membershipQuery = useMembershipSnapshot()
  const { stats } = useAttendanceStats()

  const [editOpen, setEditOpen] = useState(false)
  const [form, setForm] = useState<DetailsForm>({
    fullName: '',
    dateOfBirth: '',
    gender: null,
    bloodGroup: null,
  })
  const [errors, setErrors] = useState<DetailsErrors>({})
  const [editError, setEditError] = useState<string | null>(null)
  const [savingDetails, setSavingDetails] = useState(false)

  const [docOpen, setDocOpen] = useState(false)
  const [docFile, setDocFile] = useState<File | null>(null)
  const [docError, setDocError] = useState<string | null>(null)
  const [savingDoc, setSavingDoc] = useState(false)

  const [previewOpen, setPreviewOpen] = useState(false)
  const [previewUrl, setPreviewUrl] = useState<string | null>(null)
  const [previewLoading, setPreviewLoading] = useState(false)
  const [previewError, setPreviewError] = useState<string | null>(null)

  const [passwordOpen, setPasswordOpen] = useState(false)
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [passwordError, setPasswordError] = useState<string | null>(null)
  const [savingPassword, setSavingPassword] = useState(false)

  const [signOutOpen, setSignOutOpen] = useState(false)
  const [signingOut, setSigningOut] = useState(false)

  const [resetOpen, setResetOpen] = useState(false)
  const [resetting, setResetting] = useState(false)

  if (!profile) return <FullScreenLoader label="Loading your profile" />

  const snapshot = membershipQuery.snapshot
  const membership = snapshot.membership
  const planName = membership?.package?.name ?? 'No plan yet'
  const age = profile.date_of_birth ? ageFromDob(profile.date_of_birth) : null
  const today = todayInKolkata()
  const maxDob = `${Number(today.slice(0, 4)) - 12}${today.slice(4)}`
  const minDob = `${Number(today.slice(0, 4)) - 100}${today.slice(4)}`
  const isImageDocument =
    profile.legal_document_type?.startsWith('image/') ||
    /\.(jpe?g|png|webp|heic|heif)$/i.test(profile.legal_document_name ?? '')

  const openEdit = () => {
    setForm({
      fullName: profile.full_name ?? '',
      dateOfBirth: profile.date_of_birth ?? '',
      gender: profile.gender,
      bloodGroup: profile.blood_group,
    })
    setErrors({})
    setEditError(null)
    setEditOpen(true)
  }

  const saveDetails = async () => {
    const nextErrors: DetailsErrors = {}
    if (form.fullName.trim().length < 2) {
      nextErrors.fullName = 'Enter your full name as it appears on your ID.'
    }
    if (!form.dateOfBirth) {
      nextErrors.dateOfBirth = 'Select your date of birth.'
    } else {
      const nextAge = ageFromDob(form.dateOfBirth)
      if (nextAge < 12) nextErrors.dateOfBirth = 'Members must be at least 12 years old.'
      if (nextAge > 100) nextErrors.dateOfBirth = 'Please check your date of birth.'
    }
    if (!form.gender) nextErrors.gender = 'Select a gender option.'
    if (!form.bloodGroup) nextErrors.bloodGroup = 'Select your blood group.'

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    setSavingDetails(true)
    setEditError(null)
    try {
      const patch: ProfileUpdate = {
        full_name: form.fullName.trim(),
        date_of_birth: form.dateOfBirth,
        gender: form.gender ?? undefined,
        blood_group: form.bloodGroup ?? undefined,
      }
      await updateMyProfile(patch)
      await refreshProfile()
      setEditOpen(false)
      toast.success('Details updated', {
        description: 'Your member record is up to date.',
      })
    } catch (error) {
      setEditError(toAppError(error).message)
    } finally {
      setSavingDetails(false)
    }
  }

  const openDocumentSheet = () => {
    setDocFile(null)
    setDocError(null)
    setDocOpen(true)
  }

  const saveDocument = async () => {
    if (!docFile) {
      setDocError('Choose a new document to upload.')
      return
    }
    const validation = validateLegalDocument(docFile)
    if (validation) {
      setDocError(validation)
      return
    }

    setSavingDoc(true)
    setDocError(null)
    try {
      await saveDocumentReplacement(docFile, {}, profile.legal_document_path)
      await refreshProfile()
      setDocOpen(false)
      setDocFile(null)
      toast.success('Document replaced', {
        description: 'The front desk can verify your updated ID.',
      })
    } catch (error) {
      setDocError(toAppError(error).message)
    } finally {
      setSavingDoc(false)
    }
  }

  const openPreview = async () => {
    setPreviewOpen(true)
    setPreviewError(null)
    setPreviewUrl(null)
    if (!profile.legal_document_path) {
      setPreviewError('No legal document is on file yet.')
      return
    }
    if (isDemo) return

    setPreviewLoading(true)
    try {
      const url = await getDocumentSignedUrl(profile.legal_document_path)
      if (!url) throw new Error('The document preview could not be generated.')
      setPreviewUrl(url)
    } catch (error) {
      setPreviewError(toAppError(error).message)
    } finally {
      setPreviewLoading(false)
    }
  }

  const openPasswordSheet = () => {
    setPassword('')
    setConfirmPassword('')
    setPasswordError(null)
    setPasswordOpen(true)
  }

  const savePassword = async () => {
    if (password.length < 8) {
      setPasswordError('Use at least 8 characters.')
      return
    }
    if (!/[A-Za-z]/.test(password)) {
      setPasswordError('Include at least one letter.')
      return
    }
    if (!/\d/.test(password)) {
      setPasswordError('Include at least one number.')
      return
    }
    if (password !== confirmPassword) {
      setPasswordError('The two passwords do not match.')
      return
    }

    setSavingPassword(true)
    setPasswordError(null)
    try {
      await updatePassword(password)
      setPasswordOpen(false)
      setPassword('')
      setConfirmPassword('')
      toast.success('Password updated', {
        description: 'Use your new password the next time you sign in.',
      })
    } catch (error) {
      setPasswordError(toAppError(error).message)
    } finally {
      setSavingPassword(false)
    }
  }

  const handleSignOut = async () => {
    setSigningOut(true)
    try {
      await signOutMember()
      toast.success('Signed out')
      navigate('/login', { replace: true })
    } finally {
      setSigningOut(false)
    }
  }

  const handleDemoReset = async () => {
    setResetting(true)
    try {
      resetDemoDatabase()
      await signOutMember()
      toast.success('Demo data reset', {
        description: 'The seed member, plans and activity are back.',
      })
      navigate('/login', { replace: true })
    } finally {
      setResetting(false)
    }
  }

  return (
    <div className="page-x">
      <PageHeader
        title="Profile"
        subtitle="Your member identity, privacy and app preferences."
        action={<ThemeToggle />}
      />

      <div className="mt-3 grid gap-5 lg:grid-cols-[minmax(0,1fr)_320px] lg:items-start lg:gap-6">
        <div className="space-y-5">
          <section className="noise relative overflow-hidden rounded-[30px] mesh-teal p-5 text-white shadow-card-lg sm:p-6">
            <div className="pointer-events-none absolute -right-12 -top-14 h-44 w-44 rounded-full border border-white/10" />
            <div className="pointer-events-none absolute -bottom-20 -left-10 h-52 w-52 rounded-full bg-emerald-400/10 blur-2xl" />
            <div className="relative z-10 flex flex-col gap-5 sm:flex-row sm:items-center sm:justify-between">
              <div className="flex min-w-0 items-center gap-4">
                <Avatar
                  name={profile.full_name}
                  size="xl"
                  className="ring-2 ring-white/20"
                />
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <h1 className="truncate display-accent text-[24px] text-white sm:text-[28px]">
                      {profile.full_name ?? 'FitDesk member'}
                    </h1>
                    {completed ? (
                      <Badge tone="success" className="border-emerald-300/25 bg-emerald-300/15 text-emerald-100">
                        Verified
                      </Badge>
                    ) : null}
                    {isDemo ? (
                      <Badge tone="warning" className="border-amber-300/30 bg-amber-300/15 text-amber-100">
                        Demo
                      </Badge>
                    ) : null}
                  </div>
                  <p className="mt-1 text-[12.5px] font-medium text-white/60">
                    {profile.email || prettyPhone(profile.phone)}
                  </p>
                  <p className="mt-0.5 text-[10.5px] text-white/40">
                    Member since {formatKolkata(profile.created_at, 'MMMM yyyy')}
                  </p>
                </div>
              </div>

              <div className="flex shrink-0 gap-2">
                <Button
                  type="button"
                  size="sm"
                  onClick={openEdit}
                  leadingIcon={<Pencil className="h-3.5 w-3.5" />}
                  className="border-white/15 bg-white/10 text-white shadow-none hover:bg-white/15"
                >
                  Edit details
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  onClick={() => void openPreview()}
                  leadingIcon={<Eye className="h-3.5 w-3.5" />}
                  className="text-white/75 hover:bg-white/10 hover:text-white"
                >
                  View ID
                </Button>
              </div>
            </div>

            <div className="relative z-10 mt-5 grid grid-cols-3 gap-2 border-t border-white/10 pt-4">
              <MemberStat label="Plan" value={planName} />
              <MemberStat
                label="Status"
                value={
                  bookingStatusLabel(snapshot.isActive, snapshot.daysLeft, snapshot.isExpired)
                }
              />
              <MemberStat label="Sessions" value={String(stats.total)} />
            </div>
          </section>

          <section className="card overflow-hidden">
            <div className="flex items-start justify-between gap-3 border-b border-line/70 px-5 py-4">
              <div>
                <h2 className="text-[15px] font-semibold text-ink">Personal details</h2>
                <p className="mt-0.5 text-[11.5px] text-muted">
                  Kept private and shared only with club staff.
                </p>
              </div>
              <button
                type="button"
                onClick={openEdit}
                className="inline-flex items-center gap-1 rounded-xl px-2 py-1 text-[11px] font-semibold text-primary-strong transition hover:bg-primary-soft/50"
              >
                <Pencil className="h-3 w-3" />
                Edit
              </button>
            </div>
            <div className="divide-y divide-line/60 px-5">
              <DetailRow
                icon={<CalendarDays className="h-[17px] w-[17px]" />}
                label="Date of birth"
                value={
                  profile.date_of_birth
                    ? `${formatKolkata(profile.date_of_birth, 'd MMMM yyyy')}${age !== null ? ` · ${age} years` : ''}`
                    : 'Not set'
                }
              />
              <DetailRow
                icon={<Users className="h-[17px] w-[17px]" />}
                label="Gender"
                value={profile.gender ? GENDER_LABELS[profile.gender] : 'Not set'}
              />
              <DetailRow
                icon={<Droplets className="h-[17px] w-[17px]" />}
                label="Blood group"
                value={profile.blood_group ?? 'Not set'}
                hint="Shared with emergency responders only if needed."
              />
              <DetailRow
                icon={<Mail className="h-[17px] w-[17px]" />}
                label="Email address"
                value={profile.email || 'Not set'}
                hint="Used to sign in. Contact the front desk to change it."
              />
              {profile.phone ? (
                <DetailRow
                  icon={<Smartphone className="h-[17px] w-[17px]" />}
                  label="Mobile (optional)"
                  value={prettyPhone(profile.phone)}
                  hint="Contact number on file. Update it at the front desk."
                />
              ) : null}
            </div>
          </section>

          <section className="card p-5">
            <div className="flex items-start gap-3.5">
              <div className="flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl bg-primary-soft text-primary-strong">
                <FileText className="h-5 w-5" />
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="text-[15px] font-semibold text-ink">Legal document</h2>
                  <Badge tone="success" dot>
                    On file
                  </Badge>
                </div>
                <p className="mt-1 truncate text-[12.5px] font-semibold text-ink">
                  {profile.legal_document_name ?? 'Verification document'}
                </p>
                <p className="mt-0.5 text-[11px] text-muted">
                  {profile.legal_document_type === 'application/pdf'
                    ? 'PDF'
                    : isImageDocument
                      ? 'Image'
                      : 'Document'}{' '}
                  · stored in a private bucket
                </p>
              </div>
            </div>

            <div className="mt-4 flex flex-wrap gap-2">
              <Button
                type="button"
                variant="secondary"
                size="sm"
                onClick={() => void openPreview()}
                leadingIcon={<Eye className="h-3.5 w-3.5" />}
              >
                View document
              </Button>
              <Button
                type="button"
                variant="soft"
                size="sm"
                onClick={openDocumentSheet}
                leadingIcon={<RefreshCcw className="h-3.5 w-3.5" />}
              >
                Replace
              </Button>
            </div>

            <div className="mt-4 flex items-start gap-2.5 rounded-2xl border border-line/75 bg-elevated/50 p-3.5">
              <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-primary-strong" />
              <p className="text-[10.5px] leading-relaxed text-muted">
                Your ID is never shown publicly. Signed links expire after 60 seconds
                and only you and authorised club staff can open them.
              </p>
            </div>
          </section>

          <section className="card overflow-hidden">
            <div className="border-b border-line/70 px-5 py-4">
              <h2 className="text-[15px] font-semibold text-ink">Security</h2>
              <p className="mt-0.5 text-[11.5px] text-muted">
                Keep your FitDesk account protected.
              </p>
            </div>
            <div className="divide-y divide-line/60 px-5">
              <DetailRow
                icon={<KeyRound className="h-[17px] w-[17px]" />}
                label="Password"
                value="Password protected"
                hint="Use at least 8 characters with letters and numbers."
                trailing={
                  <button
                    type="button"
                    onClick={openPasswordSheet}
                    className="rounded-xl border border-line bg-surface px-3 py-1.5 text-[11px] font-semibold text-ink transition hover:border-primary/30 hover:text-primary-strong"
                  >
                    Change
                  </button>
                }
              />
              <DetailRow
                icon={<Fingerprint className="h-[17px] w-[17px]" />}
                label="Email verification"
                value="Confirmed email"
                hint="Your email is used for sign-in and account recovery."
              />
              <DetailRow
                icon={<BadgeCheck className="h-[17px] w-[17px]" />}
                label="Member record"
                value={completed ? 'Complete and verified' : 'Needs attention'}
                hint="Required before the gym can admit you."
              />
            </div>
          </section>
        </div>

        <aside className="space-y-5">
          <section className="card p-5">
            <div className="flex items-center justify-between gap-2">
              <p className="eyebrow">Membership</p>
              <CreditCard className="h-4 w-4 text-faint" />
            </div>
            <h2 className="mt-1.5 display-accent text-[21px] text-ink">
              {planName}
            </h2>
            {membership ? (
              <>
                <div className="mt-2">
                  <Badge
                    tone={snapshot.isActive ? (snapshot.daysLeft <= 3 ? 'warning' : 'success') : 'danger'}
                    dot
                  >
                    {snapshot.isActive
                      ? snapshot.daysLeft === 0
                        ? 'Expires today'
                        : `${snapshot.daysLeft} days left`
                      : `${snapshot.daysPastExpiry} days past expiry`}
                  </Badge>
                </div>
                <p className="mt-3 text-[11.5px] leading-relaxed text-muted">
                  {formatKolkata(membership.starts_on, 'd MMM yyyy')} –{' '}
                  {formatKolkata(membership.ends_on, 'd MMM yyyy')}
                </p>
              </>
            ) : (
              <p className="mt-2 text-[11.5px] leading-relaxed text-muted">
                No membership is attached to this account yet.
              </p>
            )}
            <Button
              type="button"
              variant="secondary"
              fullWidth
              className="mt-4"
              onClick={() => navigate('/membership')}
              trailingIcon={<ChevronRight className="h-4 w-4" />}
            >
              {snapshot.isActive ? 'Manage plan' : 'Choose a plan'}
            </Button>
          </section>

          <section className="card p-5">
            <div className="flex items-center justify-between gap-2">
              <div>
                <p className="eyebrow">Appearance</p>
                <h2 className="mt-1 text-[15px] font-semibold text-ink">Theme</h2>
              </div>
              {mode === 'system' ? <Monitor className="h-4 w-4 text-faint" /> : null}
            </div>
            <div className="mt-3">
              <SegmentedControl
                options={THEME_OPTIONS}
                value={mode}
                onChange={setMode}
                size="sm"
                ariaLabel="Choose app theme"
              />
            </div>
            <p className="mt-2.5 text-[10.5px] leading-relaxed text-muted">
              System follows your device's light or dark setting automatically.
            </p>
          </section>

          <section className="card overflow-hidden">
            <div className="px-5 py-4">
              <p className="eyebrow">Account</p>
              <h2 className="mt-1 text-[15px] font-semibold text-ink">Your session</h2>
            </div>
            <div className="border-t border-line/60">
              <button
                type="button"
                onClick={openPasswordSheet}
                className="flex w-full items-center gap-3 px-5 py-3.5 text-left transition hover:bg-elevated/60"
              >
                <KeyRound className="h-[17px] w-[17px] text-muted" />
                <span className="min-w-0 flex-1">
                  <span className="block text-[12.5px] font-semibold text-ink">
                    Change password
                  </span>
                  <span className="block text-[10.5px] text-muted">
                    Set a new password for sign-in
                  </span>
                </span>
                <ChevronRight className="h-4 w-4 text-faint" />
              </button>

              <button
                type="button"
                onClick={() => setSignOutOpen(true)}
                className="flex w-full items-center gap-3 border-t border-line/60 px-5 py-3.5 text-left transition hover:bg-danger/[0.04]"
              >
                <LogOut className="h-[17px] w-[17px] text-danger" />
                <span className="min-w-0 flex-1">
                  <span className="block text-[12.5px] font-semibold text-danger">
                    Sign out
                  </span>
                  <span className="block text-[10.5px] text-muted">
                    End this session on this device
                  </span>
                </span>
                <ChevronRight className="h-4 w-4 text-faint" />
              </button>
            </div>
          </section>

          {isDemo ? (
            <section className="rounded-3xl border border-dashed border-warning/35 bg-warning/[0.05] p-4">
              <div className="flex items-start gap-2.5">
                <Sparkles className="mt-0.5 h-4 w-4 shrink-0 text-warning" />
                <div className="min-w-0 flex-1">
                  <p className="text-[12px] font-semibold text-ink">Demo workspace</p>
                  <p className="mt-1 text-[10.5px] leading-relaxed text-muted">
                    Everything here runs locally in your browser. Reset to restore the
                    seeded member, plans and activity.
                  </p>
                  <Button
                    type="button"
                    variant="secondary"
                    size="sm"
                    className="mt-3"
                    onClick={() => setResetOpen(true)}
                    leadingIcon={<RotateCcw className="h-3.5 w-3.5" />}
                  >
                    Reset demo data
                  </Button>
                </div>
              </div>
            </section>
          ) : null}

          <div className="px-1 text-center">
            <p className="text-[10px] text-faint">
              {appConfig.name} v{appConfig.version} · Asia/Kolkata
            </p>
            <p className="mt-1 text-[10px] text-faint">
              Need help? Speak to the front desk or call {appConfig.supportPhone}.
            </p>
          </div>
        </aside>
      </div>

      <Sheet
        open={editOpen}
        onOpenChange={(open) => {
          if (!savingDetails) setEditOpen(open)
        }}
        title="Edit your details"
        description="Keep this accurate — the club uses it for safety and verification."
        footer={
          <div className="flex gap-2">
            <Button
              type="button"
              variant="ghost"
              fullWidth
              disabled={savingDetails}
              onClick={() => setEditOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              fullWidth
              loading={savingDetails}
              onClick={() => void saveDetails()}
            >
              Save changes
            </Button>
          </div>
        }
      >
        <div className="space-y-5">
          <Input
            label="Full name"
            value={form.fullName}
            onChange={(event) => {
              setForm((current) => ({ ...current, fullName: event.target.value }))
              setErrors((current) => ({ ...current, fullName: undefined }))
            }}
            autoComplete="name"
            leading={<UserRound className="h-[18px] w-[18px]" />}
            error={errors.fullName}
          />

          <Input
            label="Date of birth"
            type="date"
            value={form.dateOfBirth}
            min={minDob}
            max={maxDob}
            onChange={(event) => {
              setForm((current) => ({ ...current, dateOfBirth: event.target.value }))
              setErrors((current) => ({ ...current, dateOfBirth: undefined }))
            }}
            leading={<CalendarDays className="h-[18px] w-[18px]" />}
            error={errors.dateOfBirth}
            className="[color-scheme:light] dark:[color-scheme:dark]"
          />

          <div>
            <p className="mb-2 text-[13px] font-semibold text-ink">Gender</p>
            <div className="grid grid-cols-2 gap-2">
              {GENDER_OPTIONS.map((option) => {
                const selected = form.gender === option.value
                return (
                  <button
                    key={option.value}
                    type="button"
                    onClick={() => {
                      setForm((current) => ({ ...current, gender: option.value }))
                      setErrors((current) => ({ ...current, gender: undefined }))
                    }}
                    aria-pressed={selected}
                    className={cn(
                      'h-11 rounded-xl border px-2 text-[12px] font-semibold transition',
                      selected
                        ? 'border-primary bg-primary text-primary-ink'
                        : 'border-line bg-surface text-muted hover:border-primary/35 hover:text-ink',
                    )}
                  >
                    {option.label}
                  </button>
                )
              })}
            </div>
            {errors.gender ? (
              <p className="mt-2 text-xs font-medium text-danger">{errors.gender}</p>
            ) : null}
          </div>

          <div>
            <p className="mb-2 text-[13px] font-semibold text-ink">Blood group</p>
            <div className="grid grid-cols-4 gap-2">
              {BLOOD_GROUPS.map((group) => {
                const selected = form.bloodGroup === group
                return (
                  <button
                    key={group}
                    type="button"
                    onClick={() => {
                      setForm((current) => ({ ...current, bloodGroup: group }))
                      setErrors((current) => ({ ...current, bloodGroup: undefined }))
                    }}
                    aria-pressed={selected}
                    className={cn(
                      'h-11 rounded-xl border text-[12.5px] font-semibold transition',
                      selected
                        ? 'border-primary bg-primary text-primary-ink'
                        : 'border-line bg-surface text-muted hover:border-primary/35 hover:text-ink',
                    )}
                  >
                    {group}
                  </button>
                )
              })}
            </div>
            {errors.bloodGroup ? (
              <p className="mt-2 text-xs font-medium text-danger">{errors.bloodGroup}</p>
            ) : null}
          </div>

          {editError ? (
            <div
              role="alert"
              className="flex items-start gap-2.5 rounded-2xl border border-danger/15 bg-danger/[0.05] px-3.5 py-3"
            >
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
              <p className="text-[12px] leading-relaxed text-danger">{editError}</p>
            </div>
          ) : null}
        </div>
      </Sheet>

      <Sheet
        open={docOpen}
        onOpenChange={(open) => {
          if (!savingDoc) setDocOpen(open)
        }}
        title="Replace legal document"
        description="Upload a clear photo or scan of a government-issued ID."
        footer={
          <div className="flex gap-2">
            <Button
              type="button"
              variant="ghost"
              fullWidth
              disabled={savingDoc}
              onClick={() => setDocOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              fullWidth
              loading={savingDoc}
              disabled={!docFile}
              onClick={() => void saveDocument()}
            >
              Upload document
            </Button>
          </div>
        }
      >
        <div className="space-y-4">
          <FileDropzone
            file={docFile}
            onFile={(file) => {
              setDocFile(file)
              setDocError(null)
            }}
            error={docError}
            existingName={profile.legal_document_name}
            disabled={savingDoc}
          />
          <div className="flex items-start gap-2.5 rounded-2xl border border-line/80 bg-elevated/50 p-3.5">
            <ShieldCheck className="mt-0.5 h-4 w-4 shrink-0 text-primary-strong" />
            <p className="text-[10.5px] leading-relaxed text-muted">
              Accepted: Aadhaar, passport, driving licence or voter ID. JPG, PNG, WEBP
              or PDF up to 10 MB. The previous file is replaced once the upload
              completes.
            </p>
          </div>
        </div>
      </Sheet>

      <Sheet
        open={previewOpen}
        onOpenChange={setPreviewOpen}
        title="Legal document"
        description="Private preview. Links expire after 60 seconds."
        size="lg"
        footer={
          previewUrl ? (
            <a
              href={previewUrl}
              target="_blank"
              rel="noreferrer"
              className="flex h-11 w-full items-center justify-center gap-2 rounded-2xl border border-line bg-elevated text-[13px] font-semibold text-ink transition hover:border-primary/30 hover:text-primary-strong"
            >
              <ExternalLink className="h-4 w-4" />
              Open in a new tab
            </a>
          ) : (
            <Button
              type="button"
              variant="secondary"
              fullWidth
              onClick={() => void openPreview()}
              leadingIcon={<RefreshCcw className="h-4 w-4" />}
            >
              Refresh preview
            </Button>
          )
        }
      >
        {previewLoading ? (
          <div className="flex flex-col items-center justify-center py-16">
            <Loader2 className="h-6 w-6 animate-spin text-primary-strong" />
            <p className="mt-3 text-[12px] text-muted">Creating a secure preview…</p>
          </div>
        ) : previewError ? (
          <ErrorState
            compact
            title="Preview unavailable"
            message={previewError}
            onRetry={() => void openPreview()}
          />
        ) : isDemo ? (
          <div className="rounded-3xl border border-dashed border-warning/35 bg-warning/[0.05] p-6 text-center">
            <FileText className="mx-auto h-8 w-8 text-warning" />
            <p className="mt-3 text-[13px] font-semibold text-ink">Demo placeholder</p>
            <p className="mx-auto mt-1 max-w-[34ch] text-[11.5px] leading-relaxed text-muted">
              Demo mode keeps only a filename. In production this opens a short-lived
              signed URL from the private <code>legal-documents</code> bucket.
            </p>
          </div>
        ) : previewUrl ? (
          isImageDocument ? (
            <img
              src={previewUrl}
              alt="Legal document preview"
              className="mx-auto max-h-[60vh] w-auto rounded-2xl border border-line bg-elevated object-contain"
            />
          ) : (
            <iframe
              src={`${previewUrl}#toolbar=1&view=FitH`}
              title="Legal document preview"
              className="h-[60vh] w-full rounded-2xl border border-line bg-white"
            />
          )
        ) : (
          <div className="flex flex-col items-center justify-center py-16 text-center">
            <Eye className="h-6 w-6 text-faint" />
            <p className="mt-3 text-[12px] text-muted">
              Select refresh to create a secure preview.
            </p>
          </div>
        )}
      </Sheet>

      <Sheet
        open={passwordOpen}
        onOpenChange={(open) => {
          if (!savingPassword) setPasswordOpen(open)
        }}
        title="Change password"
        description="Choose something you don't use anywhere else."
        footer={
          <div className="flex gap-2">
            <Button
              type="button"
              variant="ghost"
              fullWidth
              disabled={savingPassword}
              onClick={() => setPasswordOpen(false)}
            >
              Cancel
            </Button>
            <Button
              type="button"
              fullWidth
              loading={savingPassword}
              onClick={() => void savePassword()}
            >
              Update password
            </Button>
          </div>
        }
      >
        <div className="space-y-4">
          <PasswordInput
            label="New password"
            value={password}
            onChange={(event) => {
              setPassword(event.target.value)
              if (passwordError) setPasswordError(null)
            }}
            autoComplete="new-password"
            placeholder="At least 8 characters"
            leading={<KeyRound className="h-[18px] w-[18px]" />}
            hint="Use a mix of letters and numbers. Avoid your email address."
          />
          <PasswordInput
            label="Confirm new password"
            value={confirmPassword}
            onChange={(event) => {
              setConfirmPassword(event.target.value)
              if (passwordError) setPasswordError(null)
            }}
            autoComplete="new-password"
            placeholder="Re-enter your new password"
            leading={<ShieldCheck className="h-[18px] w-[18px]" />}
          />

          {passwordError ? (
            <div
              role="alert"
              className="flex items-start gap-2.5 rounded-2xl border border-danger/15 bg-danger/[0.05] px-3.5 py-3"
            >
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
              <p className="text-[12px] leading-relaxed text-danger">{passwordError}</p>
            </div>
          ) : null}
        </div>
      </Sheet>

      <Sheet
        open={signOutOpen}
        onOpenChange={(open) => {
          if (!signingOut) setSignOutOpen(open)
        }}
        title="Sign out of FitDesk?"
        description="You'll need your email address and password to sign back in."
        size="sm"
        footer={
          <div className="flex gap-2">
            <Button
              type="button"
              variant="ghost"
              fullWidth
              disabled={signingOut}
              onClick={() => setSignOutOpen(false)}
            >
              Stay signed in
            </Button>
            <Button
              type="button"
              variant="danger"
              fullWidth
              loading={signingOut}
              onClick={() => void handleSignOut()}
            >
              Sign out
            </Button>
          </div>
        }
      >
        <div className="flex items-center gap-3 rounded-2xl border border-line/80 bg-elevated/50 p-4">
          <Avatar name={profile.full_name} size="md" />
          <div className="min-w-0">
            <p className="truncate text-[12.5px] font-semibold text-ink">
              {profile.full_name ?? 'FitDesk member'}
            </p>
            <p className="truncate text-[10.5px] text-muted">
              {profile.email || prettyPhone(profile.phone)}
            </p>
          </div>
        </div>
      </Sheet>

      <Sheet
        open={resetOpen}
        onOpenChange={(open) => {
          if (!resetting) setResetOpen(open)
        }}
        title="Reset demo data?"
        description="This clears changes made in this browser and restores the seed member, plans and activity."
        size="sm"
        footer={
          <div className="flex gap-2">
            <Button
              type="button"
              variant="ghost"
              fullWidth
              disabled={resetting}
              onClick={() => setResetOpen(false)}
            >
              Keep my data
            </Button>
            <Button
              type="button"
              variant="danger"
              fullWidth
              loading={resetting}
              onClick={() => void handleDemoReset()}
            >
              Reset demo
            </Button>
          </div>
        }
      >
        <p className="text-[12px] leading-relaxed text-muted">
          You'll be signed out and can sign back in with{' '}
          <span className="font-semibold text-ink">98765 43210</span> and the demo
          password.
        </p>
      </Sheet>
    </div>
  )
}

function MemberStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <p className="text-[8.5px] font-semibold uppercase tracking-[0.16em] text-white/40">
        {label}
      </p>
      <p className="mt-1 truncate text-[11.5px] font-semibold text-white/90">{value}</p>
    </div>
  )
}

function DetailRow({
  icon,
  label,
  value,
  hint,
  trailing,
}: {
  icon: ReactNode
  label: string
  value: string
  hint?: string
  trailing?: ReactNode
}) {
  return (
    <div className="flex items-center gap-3.5 py-3.5">
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-elevated text-muted">
        {icon}
      </div>
      <div className="min-w-0 flex-1">
        <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">
          {label}
        </p>
        <p className="mt-0.5 truncate text-[12.5px] font-semibold text-ink">{value}</p>
        {hint ? <p className="mt-0.5 text-[10.5px] text-muted">{hint}</p> : null}
      </div>
      {trailing ? <div className="shrink-0">{trailing}</div> : null}
    </div>
  )
}

function bookingStatusLabel(isActive: boolean, daysLeft: number, isExpired: boolean): string {
  if (isActive) return daysLeft === 0 ? 'Expires today' : `${daysLeft} days left`
  if (isExpired) return 'Expired'
  return 'Not active'
}
