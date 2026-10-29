import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { Profile } from '@/types'

const state = vi.hoisted(() => ({
  client: null as unknown,
  userId: 'user-1',
}))

vi.mock('@/lib/env', () => ({ isDemo: false }))

vi.mock('./session', () => ({
  requireUserId: async () => state.userId,
}))

vi.mock('@/lib/supabase', () => ({
  getSupabase: () => state.client,
}))

import {
  deleteLegalDocument,
  saveDocumentReplacement,
  updateMyProfile,
  uploadLegalDocument,
} from './profile'
import { AppError } from '@/lib/errors'

interface UpdateResult {
  data: Profile[] | null
  error: unknown
  count: number | null
}

interface RpcResult {
  data: unknown
  error: unknown
}

interface ClientHooks {
  /** Consumed in order; the last entry repeats for any further calls. */
  updates?: UpdateResult[]
  rpcs?: RpcResult[]
  upload?: { error: unknown }
  onUpdate?: (patch: Record<string, unknown>, options: unknown) => void
  onEq?: (column: string, value: unknown) => void
  onSelect?: (columns: string) => void
  onRpc?: (name: string) => void
  onRemove?: (paths: string[]) => void
  onBucket?: (bucket: string) => void
  onUploadPath?: (path: string) => void
  failRemove?: boolean
}

function makeClient(hooks: ClientHooks = {}) {
  let updateIndex = 0
  let rpcIndex = 0

  const nextUpdate = (): UpdateResult =>
    hooks.updates?.[Math.min(updateIndex++, hooks.updates.length - 1)] ?? {
      data: null,
      error: null,
      count: 0,
    }

  const nextRpc = (): RpcResult =>
    hooks.rpcs?.[Math.min(rpcIndex++, hooks.rpcs.length - 1)] ?? { data: null, error: null }

  return {
    from() {
      return {
        update(patch: Record<string, unknown>, options: unknown) {
          hooks.onUpdate?.(patch, options)
          return {
            eq(column: string, value: unknown) {
              hooks.onEq?.(column, value)
              return {
                select(columns: string) {
                  hooks.onSelect?.(columns)
                  return Promise.resolve(nextUpdate())
                },
              }
            },
          }
        },
      }
    },
    async rpc(name: string) {
      hooks.onRpc?.(name)
      return nextRpc()
    },
    storage: {
      from(bucket: string) {
        hooks.onBucket?.(bucket)
        return {
          async upload(path: string) {
            hooks.onUploadPath?.(path)
            return { path, error: hooks.upload?.error ?? null }
          },
          async remove(paths: string[]) {
            hooks.onRemove?.(paths)
            if (hooks.failRemove) throw new Error('storage unavailable')
            return { data: null, error: null }
          },
          async createSignedUrl() {
            return { data: { signedUrl: 'https://example.test/object' }, error: null }
          },
        }
      },
    },
  }
}

function makeProfile(overrides: Partial<Profile> = {}): Profile {
  return {
    id: 'user-1',
    email: 'asha@example.test',
    phone: '9876543210',
    full_name: 'Asha Rao',
    date_of_birth: '1994-05-12',
    blood_group: 'O+',
    gender: 'female',
    legal_document_path: null,
    legal_document_name: null,
    legal_document_type: null,
    profile_completed: false,
    is_admin: false,
    created_at: '2026-01-01T00:00:00.000Z',
    updated_at: '2026-01-01T00:00:00.000Z',
    ...overrides,
  }
}

const patch = {
  full_name: 'Asha Rao',
  date_of_birth: '1994-05-12',
  blood_group: 'O+' as const,
  gender: 'female' as const,
}

beforeEach(() => {
  state.client = null
  state.userId = 'user-1'
})

describe('updateMyProfile', () => {
  it('returns the stored row when PostgREST can return it', async () => {
    const saved = makeProfile({ ...patch, profile_completed: true })
    state.client = makeClient({
      updates: [{ data: [saved], error: null, count: 1 }],
      onRpc: () => {
        throw new Error('should not need the fallback RPC')
      },
    })

    await expect(updateMyProfile(patch)).resolves.toEqual(saved)
  })

  it('always filters on the authenticated id, never on a caller-supplied one', async () => {
    const eqCalls: Array<[string, unknown]> = []
    const sent: Array<Record<string, unknown>> = []
    const saved = makeProfile({ ...patch, profile_completed: true })

    state.userId = 'session-user-42'
    state.client = makeClient({
      updates: [{ data: [saved], error: null, count: 1 }],
      onEq: (column, value) => eqCalls.push([column, value]),
      onUpdate: (body) => sent.push(body),
    })

    await updateMyProfile(patch)

    expect(eqCalls).toEqual([['id', 'session-user-42']])
    expect(sent[0]).not.toHaveProperty('id')
  })

  it('asks for an exact count instead of relying on .single()', async () => {
    const options: unknown[] = []
    state.client = makeClient({
      updates: [{ data: [makeProfile(patch)], error: null, count: 1 }],
      onUpdate: (_body, opts) => options.push(opts),
    })

    await updateMyProfile(patch)

    expect(options[0]).toEqual({ count: 'exact' })
  })

  it('reports success when the write landed but RETURNING is empty', async () => {
    // Real case: UPDATE applied, but no SELECT policy hides the returned row.
    const saved = makeProfile({ ...patch, profile_completed: true })
    state.client = makeClient({
      updates: [{ data: [], error: null, count: 1 }],
      rpcs: [{ data: saved, error: null }],
    })

    await expect(updateMyProfile(patch)).resolves.toEqual(saved)
  })

  it('creates a missing profile row and retries the save once', async () => {
    // Real case: the auth trigger never ran, so the UPDATE matched zero rows.
    const saved = makeProfile({ ...patch, profile_completed: true })
    const fresh = makeProfile({
      full_name: null,
      date_of_birth: null,
      blood_group: null,
      gender: null,
      legal_document_path: null,
    })

    state.client = makeClient({
      updates: [
        { data: [], error: null, count: 0 },
        { data: [saved], error: null, count: 1 },
      ],
      rpcs: [{ data: fresh, error: null }],
    })

    await expect(updateMyProfile(patch)).resolves.toEqual(saved)
  })

  it('fails with an actionable error when the write is genuinely blocked', async () => {
    // Real case: no UPDATE policy, so every statement matched zero rows.
    const stale = makeProfile({
      full_name: null,
      blood_group: null,
      gender: null,
      date_of_birth: null,
    })

    state.client = makeClient({
      updates: [{ data: [], error: null, count: 0 }],
      rpcs: [{ data: stale, error: null }],
    })

    const error = await updateMyProfile(patch).catch((value: unknown) => value)
    expect(error).toBeInstanceOf(AppError)
    expect((error as AppError).code).toBe('PROFILE_SAVE_BLOCKED')
    expect((error as AppError).message).toContain('RLS policies')
  })

  it('does not treat a partially matching row as a completed save', async () => {
    const stale = makeProfile({ full_name: 'Old Name' })
    state.client = makeClient({
      updates: [{ data: [], error: null, count: 0 }],
      rpcs: [{ data: stale, error: null }],
    })

    await expect(updateMyProfile({ ...patch, full_name: 'New Name' })).rejects.toMatchObject({
      code: 'PROFILE_SAVE_BLOCKED',
    })
  })

  it('maps a raw row-level security error to the profile error code', async () => {
    state.client = makeClient({
      updates: [
        {
          data: null,
          error: { code: '42501', message: 'new row violates row-level security policy' },
          count: null,
        },
      ],
    })

    await expect(updateMyProfile(patch)).rejects.toMatchObject({
      code: 'PROFILE_SAVE_BLOCKED',
    })
  })

  it('refuses a multi-row match instead of picking one', async () => {
    state.client = makeClient({
      updates: [{ data: [makeProfile(), makeProfile({ id: 'user-2' })], error: null, count: 2 }],
    })

    await expect(updateMyProfile(patch)).rejects.toMatchObject({
      code: 'PROFILE_SAVE_BLOCKED',
    })
  })

  it('still fails clearly when the verification RPC is unavailable', async () => {
    state.client = makeClient({
      updates: [{ data: [], error: null, count: 0 }],
      rpcs: [{ data: null, error: { message: 'function does not exist' } }],
    })

    await expect(updateMyProfile(patch)).rejects.toMatchObject({
      code: 'PROFILE_SAVE_BLOCKED',
    })
  })

  it.each([
    ['id', 'someone-else'],
    ['phone', '9999999999'],
    ['profile_completed', true],
    ['is_admin', true],
    ['created_at', '2020-01-01T00:00:00.000Z'],
    ['updated_at', '2020-01-01T00:00:00.000Z'],
  ])('rejects the protected field %s without sending a request', async (field, value) => {
    const sent: unknown[] = []
    state.client = makeClient({
      updates: [{ data: [makeProfile()], error: null, count: 1 }],
      onUpdate: (body) => sent.push(body),
    })

    const payload = { ...patch, [field]: value } as unknown as typeof patch
    const error = await updateMyProfile(payload).catch((value: unknown) => value)

    expect(error).toBeInstanceOf(AppError)
    expect((error as AppError).code).toBe('PROFILE_FIELD_NOT_EDITABLE')
    expect(sent).toHaveLength(0)
  })
})

describe('uploadLegalDocument', () => {
  it('uses the legal-documents bucket and a path inside the member folder', async () => {
    const buckets: string[] = []
    const paths: string[] = []
    state.client = makeClient({
      onBucket: (bucket) => buckets.push(bucket),
      onUploadPath: (path) => paths.push(path),
    })

    const file = new File([new Uint8Array([1, 2, 3, 4])], 'id.png', { type: 'image/png' })
    const result = await uploadLegalDocument(file)

    expect(buckets).toEqual(['legal-documents'])
    expect(paths).toEqual([result.path])
    expect(result.path.startsWith('user-1/legal-')).toBe(true)
    expect(result.path.endsWith('.png')).toBe(true)
  })

  it('re-resolves the same path for the same file, so retries do not duplicate', async () => {
    const paths: string[] = []
    state.client = makeClient({ onUploadPath: (path) => paths.push(path) })

    const bytes = new Uint8Array([9, 9, 9, 9])
    const first = await uploadLegalDocument(new File([bytes], 'id.png', { type: 'image/png' }))
    const second = await uploadLegalDocument(new File([bytes], 'id.png', { type: 'image/png' }))

    expect(second.path).toBe(first.path)
    expect(paths).toHaveLength(2)
    expect(new Set(paths).size).toBe(1)
  })

  it('gives different content a different path', async () => {
    state.client = makeClient()

    const first = await uploadLegalDocument(
      new File([new Uint8Array([1, 1, 1])], 'id.png', { type: 'image/png' }),
    )
    const second = await uploadLegalDocument(
      new File([new Uint8Array([2, 2, 2])], 'id.png', { type: 'image/png' }),
    )

    expect(second.path).not.toBe(first.path)
  })

  it('treats an existing identical object as success', async () => {
    state.client = makeClient({
      upload: {
        error: { statusCode: '409', error: 'Duplicate', message: 'The resource already exists' },
      },
    })

    const file = new File([new Uint8Array([5, 5])], 'id.pdf', { type: 'application/pdf' })
    await expect(uploadLegalDocument(file)).resolves.toMatchObject({ name: 'id.pdf' })
  })

  it('explains a missing bucket instead of surfacing the raw storage error', async () => {
    state.client = makeClient({
      upload: { error: { statusCode: '404', message: 'Bucket not found' } },
    })

    await expect(
      uploadLegalDocument(new File([new Uint8Array([1])], 'id.png', { type: 'image/png' })),
    ).rejects.toMatchObject({
      code: 'STORAGE_BLOCKED',
      message: expect.stringContaining('legal-documents'),
    })
  })

  it('explains a storage policy rejection', async () => {
    state.client = makeClient({
      upload: {
        error: { statusCode: '403', message: 'new row violates row-level security policy' },
      },
    })

    await expect(
      uploadLegalDocument(new File([new Uint8Array([1])], 'id.png', { type: 'image/png' })),
    ).rejects.toMatchObject({ code: 'STORAGE_BLOCKED' })
  })
})

describe('saveDocumentReplacement', () => {
  const previousPath = 'user-1/legal-previous.png'
  const bytes = new Uint8Array([7, 7, 7])

  it('removes the superseded object only after the row points at the replacement', async () => {
    const removed: string[][] = []
    const saved = makeProfile({ legal_document_path: 'user-1/legal-new.png' })

    state.client = makeClient({
      updates: [{ data: [saved], error: null, count: 1 }],
      onRemove: (paths) => removed.push(paths),
    })

    await expect(
      saveDocumentReplacement(
        new File([bytes], 'id.png', { type: 'image/png' }),
        { full_name: 'Asha Rao' },
        previousPath,
      ),
    ).resolves.toEqual(saved)

    expect(removed).toEqual([[previousPath]])
  })

  it('keeps the previous document when the save fails', async () => {
    const removed: string[][] = []
    const stale = makeProfile({ legal_document_path: previousPath })

    state.client = makeClient({
      updates: [{ data: [], error: null, count: 0 }],
      rpcs: [{ data: stale, error: null }],
      onRemove: (paths) => removed.push(paths),
    })

    await expect(
      saveDocumentReplacement(
        new File([bytes], 'id.png', { type: 'image/png' }),
        { full_name: 'Asha Rao' },
        previousPath,
      ),
    ).rejects.toMatchObject({ code: 'PROFILE_SAVE_BLOCKED' })

    // Nothing deleted, and the row still references the original object.
    expect(removed).toEqual([])
    expect(stale.legal_document_path).toBe(previousPath)
  })

  it('does not delete anything when the file resolves to the same object', async () => {
    const removed: string[][] = []
    state.client = makeClient({ onRemove: (paths) => removed.push(paths) })

    const file = new File([bytes], 'id.png', { type: 'image/png' })
    const uploaded = await uploadLegalDocument(file)

    state.client = makeClient({
      updates: [{ data: [makeProfile({ legal_document_path: uploaded.path })], error: null, count: 1 }],
      onRemove: (paths) => removed.push(paths),
    })

    await saveDocumentReplacement(file, {}, uploaded.path)

    expect(removed).toEqual([])
  })

  it('signals the upload/save phase boundary exactly once', async () => {
    const events: string[] = []
    state.client = makeClient({
      updates: [{ data: [makeProfile()], error: null, count: 1 }],
      onUploadPath: () => events.push('upload'),
      onUpdate: () => events.push('save'),
    })

    await saveDocumentReplacement(
      new File([bytes], 'id.png', { type: 'image/png' }),
      {},
      null,
      () => events.push('phase:saving'),
    )

    expect(events).toEqual(['upload', 'phase:saving', 'save'])
  })
})

describe('deleteLegalDocument', () => {
  it('removes the superseded object from the same bucket', async () => {
    const buckets: string[] = []
    const removed: string[][] = []
    state.client = makeClient({
      onBucket: (bucket) => buckets.push(bucket),
      onRemove: (paths) => removed.push(paths),
    })

    await deleteLegalDocument('user-1/legal-old.png')

    expect(buckets).toEqual(['legal-documents'])
    expect(removed).toEqual([['user-1/legal-old.png']])
  })

  it('never throws when cleanup fails', async () => {
    state.client = makeClient({ failRemove: true })
    await expect(deleteLegalDocument('user-1/legal-old.png')).resolves.toBeUndefined()
  })

  it('ignores an empty path', async () => {
    state.client = makeClient({
      onRemove: () => {
        throw new Error('should not be called')
      },
    })

    await expect(deleteLegalDocument('')).resolves.toBeUndefined()
  })
})
