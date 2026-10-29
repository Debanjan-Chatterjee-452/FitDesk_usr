import { AppError } from '@/lib/errors'
import { getStoredUserId } from './auth'

export async function requireUserId(): Promise<string> {
  const userId = await getStoredUserId()
  if (!userId) {
    throw new AppError('AUTH_REQUIRED', 'Please sign in again to continue.')
  }
  return userId
}
