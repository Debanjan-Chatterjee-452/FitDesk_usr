export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

export class HttpError extends Error {
  status: number
  code: string
  details?: unknown

  constructor(status: number, code: string, message: string, details?: unknown) {
    super(message)
    this.name = 'HttpError'
    this.status = status
    this.code = code
    this.details = details
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store',
    },
  })
}

export function errorResponse(
  code: string,
  message: string,
  status: number,
  details?: unknown,
): Response {
  return json({ error: code, message, ...(details === undefined ? {} : { details }) }, status)
}

export async function readJson<T>(request: Request): Promise<T> {
  try {
    return (await request.json()) as T
  } catch {
    throw new HttpError(400, 'INVALID_REQUEST', 'Send a valid JSON body.')
  }
}

export function handleError(error: unknown): Response {
  if (error instanceof HttpError) {
    return errorResponse(error.code, error.message, error.status, error.details)
  }

  console.error('[fitdesk] unhandled payment error', error)
  return errorResponse(
    'UNKNOWN',
    'The payment service hit an unexpected error. Please try again.',
    500,
  )
}

export function requirePost(request: Request): Response | null {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (request.method !== 'POST') {
    return errorResponse('METHOD_NOT_ALLOWED', 'Use POST for this endpoint.', 405)
  }
  return null
}
