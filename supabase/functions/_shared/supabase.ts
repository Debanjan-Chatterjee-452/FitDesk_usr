import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { HttpError } from './http.ts'

export function requireEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) {
    throw new HttpError(
      500,
      'SERVER_MISCONFIGURED',
      `The server is missing the ${name} secret.`,
    )
  }
  return value
}

export function supabaseUrl(): string {
  return requireEnv('SUPABASE_URL')
}

export function supabaseAnonKey(): string {
  return requireEnv('SUPABASE_ANON_KEY')
}

export function supabaseAdmin(): SupabaseClient {
  return createClient(supabaseUrl(), requireEnv('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  })
}

export interface AuthenticatedRequest {
  user: { id: string; phone?: string | null }
  client: SupabaseClient
}

/**
 * Validates the caller's Supabase access token. The returned client carries the
 * caller's JWT so RLS still applies to any RPC or query made with it.
 */
export async function requireUser(request: Request): Promise<AuthenticatedRequest> {
  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) {
    throw new HttpError(401, 'AUTH_REQUIRED', 'Please sign in again to continue.')
  }

  const client = createClient(supabaseUrl(), supabaseAnonKey(), {
    global: { headers: { Authorization: authorization } },
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  })

  const { data, error } = await client.auth.getUser()
  if (error || !data.user) {
    throw new HttpError(401, 'AUTH_REQUIRED', 'Your session expired. Please sign in again.')
  }

  return { user: data.user, client }
}
