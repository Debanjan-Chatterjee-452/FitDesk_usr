import { useEffect, useMemo, useRef, useState } from 'react'
import { Navigate, useNavigate } from 'react-router-dom'
import {
  AlertCircle,
  ArrowLeft,
  ArrowRight,
  BadgeCheck,
  CalendarDays,
  Check,
  FileText,
  HeartPulse,
  IdCard,
  LogOut,
  ShieldCheck,
  Sparkles,
  UserRound,
} from 'lucide-react'
import { toast } from 'sonner'
import { Logo } from '@/components/ui/Logo'
import { ThemeToggle } from '@/components/ui/ThemeToggle'
import { Input } from '@/components/ui/Input'
import { FileDropzone } from '@/components/ui/FileDropzone'
import { Button } from '@/components/ui/Button'
import { FullScreenLoader } from '@/components/ui/FullScreenLoader'
import { ErrorState } from '@/components/ui/ErrorState'
import { GeometricBackground } from '@/components/layout/GeometricBackground'
import { useAuth } from '@/context/AuthProvider'
import {
  isProfileComplete,
  saveDocumentReplacement,
  updateMyProfile,
  validateLegalDocument,
} from '@/lib/api/profile'
import { toAppError } from '@/lib/errors'
import { ageFromDob, formatKolkata, todayInKolkata } from '@/lib/kolkata'
import { cn, prettyPhone } from '@/lib/utils'
import type { BloodGroup, Gender } from '@/types'

const STEPS = [
  {
    title: 'Your details',
    short: 'Details',
    description: 'The basics the club needs to know you.',
    icon: UserRound,
  },
  {
    title: 'Health & ID',
    short: 'Health',
    description: 'Safety information and a government-issued ID.',
    icon: HeartPulse,
  },
  {
    title: 'Review',
    short: 'Review',
    description: 'One last look before you step inside.',
    icon: BadgeCheck,
  },
] as const

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

interface FormState {
  fullName: string
  dateOfBirth: string
  gender: Gender | null
  bloodGroup: BloodGroup | null
}

interface FieldErrors {
  fullName?: string
  dateOfBirth?: string
  gender?: string
  bloodGroup?: string
  document?: string
  consent?: string
}

export function ProfileSetupPage() {
  const navigate = useNavigate()
  const {
    profile,
    profileLoading,
    profileError,
    refreshProfile,
    signOutMember,
    clearProfileError,
    isProfileComplete: completed,
  } = useAuth()

  const [step, setStep] = useState(0)
  const [form, setForm] = useState<FormState>({
    fullName: '',
    dateOfBirth: '',
    gender: null,
    bloodGroup: null,
  })
  const [file, setFile] = useState<File | null>(null)
  const [consent, setConsent] = useState(false)
  const [errors, setErrors] = useState<FieldErrors>({})
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [phase, setPhase] = useState<'idle' | 'uploading' | 'saving'>('idle')
  const initializedRef = useRef(false)

  useEffect(() => {
    if (!profile || initializedRef.current) return
    initializedRef.current = true
    setForm({
      fullName: profile.full_name ?? '',
      dateOfBirth: profile.date_of_birth ?? '',
      gender: profile.gender ?? null,
      bloodGroup: profile.blood_group ?? null,
    })
  }, [profile])

  const age = useMemo(
    () => (form.dateOfBirth ? ageFromDob(form.dateOfBirth) : 0),
    [form.dateOfBirth],
  )

  const existingDocument = profile?.legal_document_path
    ? {
        name: profile.legal_document_name ?? 'Legal document',
        type: profile.legal_document_type ?? 'application/pdf',
      }
    : null

  if (profileLoading && !profile) return <FullScreenLoader label="Loading your profile" />

  if (profileError && !profile) {
    return (
      <div className="flex min-h-[100svh] items-center justify-center px-5">
        <ErrorState
          title="We couldn't load your profile"
          message={profileError}
          onRetry={() => {
            clearProfileError()
            void refreshProfile()
          }}
        />
      </div>
    )
  }

  if (completed && phase === 'idle' && step === 0 && !file) {
    return <Navigate to="/" replace />
  }

  const today = todayInKolkata()
  const maxDob = `${Number(today.slice(0, 4)) - 12}${today.slice(4)}`
  const minDob = `${Number(today.slice(0, 4)) - 100}${today.slice(4)}`

  const validateStep = (index: number): boolean => {
    const next: FieldErrors = {}
    if (index === 0) {
      const name = form.fullName.trim()
      if (name.length < 2) next.fullName = 'Enter your full name as it appears on your ID.'
      if (name.length > 80) next.fullName = 'That name is a little too long.'
      if (!form.dateOfBirth) {
        next.dateOfBirth = 'Select your date of birth.'
      } else {
        const ageValue = ageFromDob(form.dateOfBirth)
        if (ageValue < 12) next.dateOfBirth = 'Members must be at least 12 years old.'
        if (ageValue > 100) next.dateOfBirth = 'Please check your date of birth.'
      }
      if (!form.gender) next.gender = 'Select a gender option.'
    }
    if (index === 1) {
      if (!form.bloodGroup) next.bloodGroup = 'Select your blood group.'
      if (!file && !existingDocument) next.document = 'Upload a legal document to continue.'
      if (file) {
        const fileError = validateLegalDocument(file)
        if (fileError) next.document = fileError
      }
    }
    if (index === 2 && !consent) {
      next.consent = 'Please confirm the details and accept the declaration.'
    }
    setErrors(next)
    return Object.keys(next).length === 0
  }

  const goNext = () => {
    if (!validateStep(step)) return
    setStep((value) => Math.min(STEPS.length - 1, value + 1))
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  const goBack = () => {
    setErrors({})
    setStep((value) => Math.max(0, value - 1))
  }

  const handleSubmit = async () => {
    if (!validateStep(2)) return
    setSubmitError(null)
    try {
      const details = {
        full_name: form.fullName.trim(),
        date_of_birth: form.dateOfBirth,
        blood_group: form.bloodGroup ?? undefined,
        gender: form.gender ?? undefined,
      }

      setPhase(file ? 'uploading' : 'saving')
      const updated = file
        ? await saveDocumentReplacement(
            file,
            details,
            profile?.legal_document_path ?? null,
            () => setPhase('saving'),
          )
        : await updateMyProfile(details)

      await refreshProfile()

      if (!isProfileComplete(updated)) {
        throw new Error('Some required details are still missing. Please review and try again.')
      }

      toast.success('Profile complete', {
        description: 'Welcome to FitDesk. Your member desk is ready.',
      })
      navigate('/', { replace: true })
    } catch (error) {
      setSubmitError(toAppError(error).message)
      setPhase('idle')
    }
  }

  const StepIcon = STEPS[step].icon

  return (
    <div className="relative min-h-[100svh] overflow-hidden">
      <GeometricBackground />
      <div className="relative mx-auto w-full max-w-5xl px-5 pb-12 sm:px-6">
        <header className="safe-top flex items-center justify-between py-3">
          <Logo subtitle="Profile setup" />
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <button
              type="button"
              onClick={() => void signOutMember()}
              className="flex h-10 w-10 items-center justify-center rounded-2xl border border-line/80 bg-surface/70 text-muted transition hover:text-danger"
              aria-label="Sign out"
            >
              <LogOut className="h-[17px] w-[17px]" />
            </button>
          </div>
        </header>

        <div className="mt-6 grid gap-6 lg:mt-10 lg:grid-cols-[300px_minmax(0,1fr)] lg:gap-10">
          <aside className="lg:pt-4">
            <div className="mb-6">
              <p className="eyebrow mb-2">Almost there</p>
              <h1 className="display-accent text-[27px] leading-[1.15] text-ink sm:text-[32px]">
                Finish your member profile.
              </h1>
              <p className="mt-2 text-[12.5px] leading-relaxed text-muted">
                This is required by the club before you can check in. It takes about a
                minute.
              </p>
            </div>

            <div className="hidden space-y-1 lg:block">
              {STEPS.map((item, index) => {
                const Icon = item.icon
                const active = index === step
                const done = index < step
                return (
                  <div
                    key={item.title}
                    className={cn(
                      'flex items-start gap-3 rounded-2xl px-3 py-3 transition',
                      active ? 'bg-surface shadow-sm' : '',
                    )}
                  >
                    <span
                      className={cn(
                        'mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-xl border text-[11px] font-bold',
                        done
                          ? 'border-primary/20 bg-primary text-primary-ink'
                          : active
                            ? 'border-primary/30 bg-primary-soft text-primary-strong'
                            : 'border-line bg-elevated text-muted',
                      )}
                    >
                      {done ? <Check className="h-3.5 w-3.5" strokeWidth={3} /> : <Icon className="h-4 w-4" />}
                    </span>
                    <div>
                      <p className={cn('text-[13px] font-semibold', active ? 'text-ink' : 'text-muted')}>
                        {item.title}
                      </p>
                      <p className="mt-0.5 text-[11px] leading-relaxed text-faint">
                        {item.description}
                      </p>
                    </div>
                  </div>
                )
              })}
            </div>

            <div className="mt-6 hidden rounded-2xl border border-line/70 bg-surface/70 p-4 lg:block">
              <div className="flex items-center gap-2 text-primary-strong">
                <ShieldCheck className="h-4 w-4" />
                <p className="text-[11.5px] font-semibold">Private by design</p>
              </div>
              <p className="mt-1.5 text-[11px] leading-relaxed text-muted">
                Your ID document is stored in a private bucket. Only you and authorised
                club staff can access it.
              </p>
            </div>
          </aside>

          <section className="card overflow-hidden">
            <div className="border-b border-line/70 px-5 py-4 sm:px-7">
              <div className="flex items-center justify-between text-[11px] font-semibold text-muted">
                <span className="uppercase tracking-[0.14em]">
                  Step {step + 1} of {STEPS.length}
                </span>
                <span className="text-primary-strong">{Math.round(((step + 1) / STEPS.length) * 100)}%</span>
              </div>
              <div className="mt-2.5 h-1.5 overflow-hidden rounded-full bg-elevated">
                <div
                  className="h-full rounded-full bg-primary transition-all duration-500 ease-spring"
                  style={{ width: `${((step + 1) / STEPS.length) * 100}%` }}
                />
              </div>
              <div className="mt-4 flex items-center gap-2.5">
                <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-primary-soft text-primary-strong">
                  <StepIcon className="h-[18px] w-[18px]" />
                </span>
                <div>
                  <h2 className="text-[16px] font-semibold text-ink">{STEPS[step].title}</h2>
                  <p className="text-[11.5px] text-muted">{STEPS[step].description}</p>
                </div>
              </div>
            </div>

            <div className="px-5 py-6 sm:px-7">
              {step === 0 ? (
                <div className="space-y-5">
                  <Input
                    label="Full name"
                    placeholder="As printed on your ID"
                    value={form.fullName}
                    onChange={(event) => {
                      setForm((value) => ({ ...value, fullName: event.target.value }))
                      setErrors((value) => ({ ...value, fullName: undefined }))
                    }}
                    autoComplete="name"
                    error={errors.fullName}
                    leading={<UserRound className="h-[18px] w-[18px]" />}
                  />

                  <div>
                    <Input
                      label="Date of birth"
                      type="date"
                      value={form.dateOfBirth}
                      onChange={(event) => {
                        setForm((value) => ({ ...value, dateOfBirth: event.target.value }))
                        setErrors((value) => ({ ...value, dateOfBirth: undefined }))
                      }}
                      min={minDob}
                      max={maxDob}
                      error={errors.dateOfBirth}
                      leading={<CalendarDays className="h-[18px] w-[18px]" />}
                      className="[color-scheme:light] dark:[color-scheme:dark]"
                    />
                    {age >= 12 && !errors.dateOfBirth ? (
                      <p className="mt-2 text-[11px] font-medium text-muted">
                        You'll be {age} years old. We use this only for safety records.
                      </p>
                    ) : null}
                  </div>

                  <div>
                    <p className="mb-2 text-[13px] font-semibold text-ink">Gender</p>
                    <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
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
                            className={cn(
                              'h-11 rounded-xl border px-2 text-[12px] font-semibold transition',
                              selected
                                ? 'border-primary bg-primary text-primary-ink shadow-[0_8px_18px_-10px_rgb(var(--primary)/0.8)]'
                                : 'border-line bg-surface text-muted hover:border-primary/35 hover:text-ink',
                            )}
                            aria-pressed={selected}
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

                  <div className="rounded-2xl border border-line/70 bg-elevated/50 p-3.5">
                    <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-faint">
                      Registered email
                    </p>
                    <p className="mt-1 break-all text-[13px] font-semibold text-ink">
                      {profile?.email || '—'}
                    </p>
                    <p className="mt-0.5 text-[10.5px] text-muted">
                      Used to sign in. Contact the front desk to change it.
                    </p>
                  </div>

                  {profile?.phone ? (
                    <div className="rounded-2xl border border-line/70 bg-elevated/50 p-3.5">
                      <p className="text-[10px] font-semibold uppercase tracking-[0.14em] text-faint">
                        Mobile (optional)
                      </p>
                      <p className="mt-1 text-[13px] font-semibold text-ink">
                        {prettyPhone(profile.phone)}
                      </p>
                      <p className="mt-0.5 text-[10.5px] text-muted">
                        Contact number on file for gym updates.
                      </p>
                    </div>
                  ) : null}
                </div>
              ) : null}

              {step === 1 ? (
                <div className="space-y-6">
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
                              setForm((value) => ({ ...value, bloodGroup: group }))
                              setErrors((value) => ({ ...value, bloodGroup: undefined }))
                            }}
                            className={cn(
                              'h-12 rounded-xl border text-[13px] font-semibold transition',
                              selected
                                ? 'border-primary bg-primary text-primary-ink shadow-[0_8px_18px_-10px_rgb(var(--primary)/0.8)]'
                                : 'border-line bg-surface text-muted hover:border-primary/35 hover:text-ink',
                            )}
                            aria-pressed={selected}
                          >
                            {group}
                          </button>
                        )
                      })}
                    </div>
                    {errors.bloodGroup ? (
                      <p className="mt-2 text-xs font-medium text-danger">{errors.bloodGroup}</p>
                    ) : (
                      <p className="mt-2 text-[11px] text-muted">
                        Shared with emergency responders only if needed.
                      </p>
                    )}
                  </div>

                  <div>
                    <p className="mb-2 text-[13px] font-semibold text-ink">
                      Legal document <span className="text-danger">*</span>
                    </p>
                    <FileDropzone
                      file={file}
                      onFile={(nextFile) => {
                        setFile(nextFile)
                        setErrors((value) => ({ ...value, document: undefined }))
                      }}
                      error={errors.document}
                      existingName={existingDocument?.name}
                      disabled={phase !== 'idle'}
                    />
                    <p className="mt-2.5 flex items-start gap-1.5 text-[10.5px] leading-relaxed text-muted">
                      <IdCard className="mt-0.5 h-3.5 w-3.5 shrink-0 text-primary-strong" />
                      Accepted: Aadhaar, passport, driving licence, or voter ID. Your document
                      is stored privately and never shown on your public profile.
                    </p>
                  </div>
                </div>
              ) : null}

              {step === 2 ? (
                <div className="space-y-5">
                  <div className="rounded-2xl border border-line/80 bg-elevated/40 p-4">
                    <div className="grid gap-3 sm:grid-cols-2">
                      <ReviewRow label="Full name" value={form.fullName} />
                      <ReviewRow
                        label="Date of birth"
                        value={form.dateOfBirth ? formatKolkata(form.dateOfBirth, 'd MMM yyyy') : '—'}
                      />
                      <ReviewRow
                        label="Gender"
                        value={form.gender ? GENDER_LABELS[form.gender] : '—'}
                      />
                      <ReviewRow label="Blood group" value={form.bloodGroup ?? '—'} />
                      <ReviewRow label="Email" value={profile?.email || '—'} />
                      {profile?.phone ? (
                        <ReviewRow label="Mobile (optional)" value={prettyPhone(profile.phone)} />
                      ) : null}
                      <ReviewRow
                        label="Membership"
                        value={profile?.created_at ? `Joined ${formatKolkata(profile.created_at, 'MMM yyyy')}` : 'New member'}
                      />
                    </div>
                  </div>

                  <div className="rounded-2xl border border-line/80 bg-surface p-4">
                    <div className="flex items-center gap-3">
                      <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-primary-soft text-primary-strong">
                        <FileText className="h-[18px] w-[18px]" />
                      </div>
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-[12.5px] font-semibold text-ink">
                          {file?.name ?? existingDocument?.name ?? 'No document selected'}
                        </p>
                        <p className="mt-0.5 text-[10.5px] text-muted">
                          {file
                            ? `${(file.size / (1024 * 1024)).toFixed(2)} MB · ready to upload`
                            : existingDocument
                              ? 'Already securely stored'
                              : 'Upload required'}
                        </p>
                      </div>
                      <BadgeCheck className="h-5 w-5 shrink-0 text-success" />
                    </div>
                    <button
                      type="button"
                      onClick={() => setStep(1)}
                      className="mt-3 text-[11px] font-semibold text-primary-strong underline decoration-primary/25 underline-offset-4"
                    >
                      Change document
                    </button>
                  </div>

                  <div>
                    <button
                      type="button"
                      onClick={() => {
                        setConsent((value) => !value)
                        setErrors((current) => ({ ...current, consent: undefined }))
                      }}
                      className="flex w-full items-start gap-3 rounded-2xl border border-line/80 bg-surface p-4 text-left"
                      aria-pressed={consent}
                    >
                      <span
                        className={cn(
                          'mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-md border transition',
                          consent
                            ? 'border-primary bg-primary text-primary-ink'
                            : 'border-line bg-elevated',
                        )}
                      >
                        {consent ? <Check className="h-3.5 w-3.5" strokeWidth={3} /> : null}
                      </span>
                      <span className="text-[11.5px] leading-relaxed text-muted">
                        I confirm these details are accurate, I'm medically fit to train, and
                        I accept the club's rules and privacy policy. I understand FitDesk
                        stores my ID document privately for verification.
                      </span>
                    </button>
                    {errors.consent ? (
                      <p className="mt-2 text-xs font-medium text-danger">{errors.consent}</p>
                    ) : null}
                  </div>

                  <div className="flex items-start gap-2.5 rounded-2xl border border-primary/15 bg-primary-soft/50 p-3.5">
                    <Sparkles className="mt-0.5 h-4 w-4 shrink-0 text-primary-strong" />
                    <p className="text-[11px] leading-relaxed text-primary-strong">
                      Next step: choose a membership plan. You can explore plans right after
                      this — nothing is charged until you confirm.
                    </p>
                  </div>
                </div>
              ) : null}

              {submitError ? (
                <div
                  role="alert"
                  className="mt-5 flex items-start gap-2.5 rounded-2xl border border-danger/15 bg-danger/[0.05] px-3.5 py-3"
                >
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-danger" />
                  <p className="text-[12px] leading-relaxed text-danger">{submitError}</p>
                </div>
              ) : null}
            </div>

            <div className="flex items-center justify-between gap-3 border-t border-line/70 bg-elevated/30 px-5 py-4 sm:px-7">
              <Button
                type="button"
                variant="ghost"
                onClick={step === 0 ? () => void signOutMember() : goBack}
                disabled={phase !== 'idle'}
                leadingIcon={<ArrowLeft className="h-4 w-4" />}
                className="text-muted"
              >
                {step === 0 ? 'Sign out' : 'Back'}
              </Button>
              {step < STEPS.length - 1 ? (
                <Button
                  type="button"
                  onClick={goNext}
                  trailingIcon={<ArrowRight className="h-4 w-4" />}
                >
                  Continue
                </Button>
              ) : (
                <Button
                  type="button"
                  onClick={() => void handleSubmit()}
                  loading={phase !== 'idle'}
                  trailingIcon={<BadgeCheck className="h-4 w-4" />}
                >
                  {phase === 'uploading'
                    ? 'Uploading ID…'
                    : phase === 'saving'
                      ? 'Saving profile…'
                      : 'Complete profile'}
                </Button>
              )}
            </div>
          </section>
        </div>

        <p className="mt-6 text-center text-[10px] text-faint">
          Need help? Speak to the front desk · Takes about a minute ·{' '}
          {profile?.email || prettyPhone(profile?.phone)}
        </p>
      </div>
    </div>
  )
}

function ReviewRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-faint">{label}</p>
      <p className="mt-0.5 truncate text-[12.5px] font-semibold text-ink">{value}</p>
    </div>
  )
}
