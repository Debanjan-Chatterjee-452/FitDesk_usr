import type { BloodGroup, Gender, Profile } from '@/types'
import { isDemo } from '@/lib/env'
import { AppError, toAppError } from '@/lib/errors'
import { getSupabase } from '@/lib/supabase'
import { getFileExtension } from '@/lib/utils'
import { loadDemoDatabase, saveDemoDatabase } from '@/lib/demo/store'
import { requireUserId } from './session'

export interface ProfileUpdate {
  full_name?: string
  date_of_birth?: string
  blood_group?: BloodGroup
  gender?: Gender
  legal_document_path?: string
  legal_document_name?: string
  legal_document_type?: string
}

export interface UploadedDocument {
  path: string
  name: string
  type: string
}

const ALLOWED_MIME = [
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
  'image/heif',
  'application/pdf',
]
const MAX_FILE_BYTES = 10 * 1024 * 1024

/** Single source of truth for the private identity-document bucket. */
const DOCUMENT_BUCKET = 'legal-documents'

const PROFILE_SAVE_BLOCKED_MESSAGE =
  'Your profile could not be saved because the gym database refused the update. Nothing was changed. This usually means the profile access rules (RLS policies) are missing in Supabase - ask the gym admin to apply the profiles policies, then try again.'

export function validateLegalDocument(file: File): string | null {
  if (!ALLOWED_MIME.includes(file.type) && !/\.(jpe?g|png|webp|heic|heif|pdf)$/i.test(file.name)) {
    return 'Upload a JPG, PNG, WEBP, HEIC, or PDF file.'
  }
  if (file.size > MAX_FILE_BYTES) {
    return 'That file is over 10 MB. Please upload a smaller scan or photo.'
  }
  if (file.size === 0) {
    return 'That file looks empty. Try another one.'
  }
  return null
}

export async function getMyProfile(): Promise<Profile> {
  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')
    return user.profile
  }

  try {
    const userId = await requireUserId()
    const client = getSupabase()
    const { data, error } = await client
      .from('profiles')
      .select('*')
      .eq('id', userId)
      .maybeSingle()
    if (error) throw error
    if (data) return attachSessionEmail(data as Profile)

    const { data: ensured, error: ensureError } = await client.rpc('ensure_my_profile')
    if (ensureError) throw ensureError
    if (!ensured) {
      throw new AppError('UNKNOWN', 'Your profile could not be loaded. Please sign in again.')
    }
    return attachSessionEmail(ensured as Profile)
  } catch (error) {
    throw toAppError(error)
  }
}

/**
 * The profiles table intentionally stores no email column. The authenticated
 * email is read from the Supabase session so existing phone-only profiles stay
 * untouched while email sign-in still has an identity to display.
 */
async function attachSessionEmail(profile: Profile): Promise<Profile> {
  const { data } = await getSupabase().auth.getSession()
  return { ...profile, email: data.session?.user.email ?? profile.email ?? '' }
}

/**
 * The only columns a member may write. Anything else - id, phone,
 * profile_completed, is_admin, created_at, updated_at - is owned by the
 * database and is rejected here before a request is ever sent. The column
 * grants in Supabase enforce the same set server-side.
 */
const EDITABLE_PROFILE_FIELDS: ReadonlyArray<keyof ProfileUpdate> = [
  'full_name',
  'date_of_birth',
  'blood_group',
  'gender',
  'legal_document_path',
  'legal_document_name',
  'legal_document_type',
]

export async function updateMyProfile(patch: ProfileUpdate): Promise<Profile> {
  const safePatch = assertEditablePatch(patch)

  if (isDemo) {
    const userId = await requireUserId()
    const db = loadDemoDatabase()
    const user = db.users.find((item) => item.id === userId)
    if (!user) throw new AppError('AUTH_REQUIRED', 'Please sign in again.')
    const next = { ...user.profile, ...safePatch }
    const completed = Boolean(
      next.full_name?.trim() &&
        next.date_of_birth &&
        next.blood_group &&
        next.gender &&
        next.legal_document_path,
    )
    user.profile = {
      ...next,
      profile_completed: completed,
      updated_at: new Date().toISOString(),
    }
    saveDemoDatabase(db)
    return user.profile
  }

  try {
    const userId = await requireUserId()

    // PostgREST cannot return a "single" row here. An UPDATE that RLS filters
    // out matches zero rows, and an UPDATE whose row is invisible to the
    // SELECT policy writes successfully but still returns zero rows. Asking
    // for an array plus an exact count lets us tell those two cases apart
    // instead of surfacing a misleading coercion error.
    const first = await attemptProfileUpdate(userId, safePatch)
    if (first.profile) return first.profile

    // Zero rows came back. Either the UPDATE was blocked by RLS, or the row
    // did not exist when it ran. ensure_my_profile() is SECURITY DEFINER, so
    // it can report the truth without the caller holding a SELECT policy, and
    // it creates the row (id = auth.uid()) when it is genuinely missing.
    const authoritative = await readProfileAuthoritative()
    if (authoritative && patchIsApplied(authoritative, safePatch)) {
      return authoritative
    }

    // The row existed but the write was refused, or ensure_my_profile() has
    // just created it. Retry exactly once: a freshly created row is now
    // updatable, while a refused write stays refused and still fails below.
    const retry = await attemptProfileUpdate(userId, safePatch)
    if (retry.profile) return retry.profile

    const settled = await readProfileAuthoritative()
    if (settled && patchIsApplied(settled, safePatch)) {
      return settled
    }

    throw new AppError('PROFILE_SAVE_BLOCKED', PROFILE_SAVE_BLOCKED_MESSAGE, {
      matchedRows: retry.matchedRows ?? first.matchedRows,
    })
  } catch (error) {
    throw toAppError(error)
  }
}

interface UpdateAttempt {
  profile: Profile | null
  matchedRows: number | null
}

/**
 * One UPDATE scoped to the authenticated id from the session. The caller's
 * patch can never carry `id`; assertEditablePatch already rejected it.
 */
async function attemptProfileUpdate(
  userId: string,
  patch: ProfileUpdate,
): Promise<UpdateAttempt> {
  const { data, error, count } = await getSupabase()
    .from('profiles')
    .update(patch, { count: 'exact' })
    .eq('id', userId)
    .select('*')

  if (error) throw mapProfileWriteError(error)

  const rows = (data ?? []) as Profile[]
  if (rows.length === 1) return { profile: rows[0], matchedRows: count }
  if (rows.length > 1) {
    throw new AppError(
      'PROFILE_SAVE_BLOCKED',
      'Your profile could not be saved safely because more than one profile row matched. Please contact the gym so this can be fixed.',
    )
  }
  return { profile: null, matchedRows: count }
}

function assertEditablePatch(patch: ProfileUpdate): ProfileUpdate {
  const keys = Object.keys(patch ?? {}) as Array<keyof ProfileUpdate>
  const blocked = keys.filter((key) => !EDITABLE_PROFILE_FIELDS.includes(key))
  if (blocked.length > 0) {
    throw new AppError(
      'PROFILE_FIELD_NOT_EDITABLE',
      'That profile change is not allowed. Only your name, date of birth, blood group, gender and identity document can be edited.',
      { fields: blocked as string[] },
    )
  }
  return patch
}

function errorField(error: unknown, field: string): string | undefined {
  if (error && typeof error === 'object' && field in error) {
    const value = (error as Record<string, unknown>)[field]
    if (typeof value === 'string') return value
  }
  return undefined
}

function normaliseValue(value: unknown): string | null {
  if (value === null || value === undefined) return null
  const text = String(value).trim()
  return text === '' ? null : text
}

/** True when every field the caller asked for is already stored on the row. */
function patchIsApplied(profile: Profile, patch: ProfileUpdate): boolean {
  const row = profile as unknown as Record<string, unknown>
  return (Object.keys(patch) as Array<keyof ProfileUpdate>).every((key) => {
    const expected = patch[key]
    if (expected === undefined) return true
    const actual = row[key as string]
    if (typeof expected === 'string') {
      return normaliseValue(actual) === normaliseValue(expected)
    }
    return actual === expected
  })
}

/**
 * Reads the caller's own profile through a SECURITY DEFINER RPC, so it works
 * even when public.profiles has no SELECT policy for the member.
 */
async function readProfileAuthoritative(): Promise<Profile | null> {
  try {
    const { data, error } = await getSupabase().rpc('ensure_my_profile')
    if (error || !data) return null
    const row = Array.isArray(data) ? data[0] : data
    return (row as Profile) ?? null
  } catch {
    return null
  }
}

function mapProfileWriteError(error: unknown): unknown {
  const message = (errorField(error, 'message') ?? '').toLowerCase()
  const code = errorField(error, 'code') ?? ''
  if (
    code === '42501' ||
    message.includes('row-level security') ||
    message.includes('permission denied')
  ) {
    return new AppError('PROFILE_SAVE_BLOCKED', PROFILE_SAVE_BLOCKED_MESSAGE, error)
  }
  return error
}

export async function uploadLegalDocument(file: File): Promise<UploadedDocument> {
  const validationError = validateLegalDocument(file)
  if (validationError) throw new AppError('UNKNOWN', validationError)

  if (isDemo) {
    const userId = await requireUserId()
    return {
      path: `${userId}/demo-${Date.now()}.${getFileExtension(file.name) || 'pdf'}`,
      name: file.name,
      type: file.type || 'application/octet-stream',
    }
  }

  try {
    const userId = await requireUserId()
    const extension = getFileExtension(file.name) || (file.type === 'application/pdf' ? 'pdf' : 'jpg')
    // Content-addressed name: retrying the same file resolves to the same
    // object instead of leaving a duplicate upload behind.
    const fingerprint = await documentFingerprint(file)
    const path = `${userId}/legal-${fingerprint}.${extension}`

    const { error } = await getSupabase()
      .storage.from(DOCUMENT_BUCKET)
      .upload(path, file, {
        cacheControl: '3600',
        upsert: false,
        contentType: file.type || 'application/octet-stream',
      })

    // A duplicate means the identical bytes are already stored at this exact
    // path, so the retry is already satisfied.
    if (error && !isDuplicateObjectError(error)) throw mapUploadError(error)

    return { path, name: file.name, type: file.type || 'application/octet-stream' }
  } catch (error) {
    throw toAppError(error)
  }
}

async function documentFingerprint(file: File): Promise<string> {
  try {
    const subtle = typeof crypto !== 'undefined' ? crypto.subtle : undefined
    if (subtle) {
      const digest = await subtle.digest('SHA-256', await file.arrayBuffer())
      const hex = Array.from(new Uint8Array(digest), (byte) =>
        byte.toString(16).padStart(2, '0'),
      ).join('')
      return hex.slice(0, 32)
    }
  } catch {
    // Hashing is unavailable or the file could not be read; fall back to a
    // unique name so the upload still works.
  }
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 10)}`
}

function isDuplicateObjectError(error: unknown): boolean {
  const status = errorField(error, 'statusCode')
  const message = (errorField(error, 'message') ?? '').toLowerCase()
  const name = (errorField(error, 'error') ?? '').toLowerCase()
  return status === '409' || name === 'duplicate' || message.includes('already exists')
}

function mapUploadError(error: unknown): unknown {
  const status = errorField(error, 'statusCode')
  const message = (errorField(error, 'message') ?? '').toLowerCase()

  if (message.includes('bucket not found')) {
    return new AppError(
      'STORAGE_BLOCKED',
      'The private document bucket (legal-documents) is missing in the gym database. Your file was not uploaded. Ask the gym admin to create it, then try again.',
      error,
    )
  }
  if (message.includes('row-level security') || message.includes('permission')) {
    return new AppError(
      'STORAGE_BLOCKED',
      'The document upload was blocked by the storage access rules. Your file was not saved. Ask the gym admin to check the legal-documents policies, then try again.',
      error,
    )
  }
  if (status === '413' || message.includes('too large') || message.includes('maximum allowed size')) {
    return new AppError(
      'UNKNOWN',
      'That document is larger than the 10 MB limit. Please upload a smaller scan or photo.',
      error,
    )
  }
  if (message.includes('mime') || message.includes('content type')) {
    return new AppError(
      'UNKNOWN',
      'That file type is not accepted. Upload a JPG, PNG, WEBP, HEIC, or PDF file.',
      error,
    )
  }
  return error
}

/**
 * Uploads a replacement identity document and points the profile row at it.
 *
 * Ordering is deliberate: the new object is uploaded first, the metadata is
 * saved second, and the superseded object is removed last. If the save fails,
 * the previous document is still the one referenced by the profile row, so a
 * failed replacement can never lose the document already on file. A new upload
 * that never gets referenced is an unreferenced object, which is harmless.
 */
export async function saveDocumentReplacement(
  file: File,
  patch: ProfileUpdate,
  previousPath: string | null,
  onUploaded?: () => void,
): Promise<Profile> {
  const uploaded = await uploadLegalDocument(file)
  onUploaded?.()

  const saved = await updateMyProfile({
    ...patch,
    legal_document_path: uploaded.path,
    legal_document_name: uploaded.name,
    legal_document_type: uploaded.type,
  })

  // Only now does the row point at the replacement.
  if (previousPath && previousPath !== uploaded.path) {
    await deleteLegalDocument(previousPath)
  }

  return saved
}

/**
 * Best-effort removal of a superseded document. Only called after the profile
 * row points at the replacement, so a failure here can never lose data.
 */
export async function deleteLegalDocument(path: string): Promise<void> {
  if (isDemo || !path) return
  try {
    await getSupabase().storage.from(DOCUMENT_BUCKET).remove([path])
  } catch {
    // Orphaned objects are harmless; never fail the save because of cleanup.
  }
}

export async function getDocumentSignedUrl(path: string): Promise<string | null> {
  if (isDemo) return null
  try {
    const { data, error } = await getSupabase()
      .storage.from(DOCUMENT_BUCKET)
      .createSignedUrl(path, 60)
    if (error) throw error
    return data.signedUrl
  } catch (error) {
    throw toAppError(error)
  }
}

export function isProfileComplete(profile: Profile | null): boolean {
  if (!profile) return false
  return Boolean(
    profile.profile_completed &&
      profile.full_name?.trim() &&
      profile.date_of_birth &&
      profile.blood_group &&
      profile.gender &&
      profile.legal_document_path,
  )
}

export function missingProfileFields(profile: Profile | null): string[] {
  if (!profile) return ['Profile']
  const missing: string[] = []
  if (!profile.full_name?.trim()) missing.push('Full name')
  if (!profile.date_of_birth) missing.push('Date of birth')
  if (!profile.blood_group) missing.push('Blood group')
  if (!profile.gender) missing.push('Gender')
  if (!profile.legal_document_path) missing.push('Legal document')
  return missing
}
