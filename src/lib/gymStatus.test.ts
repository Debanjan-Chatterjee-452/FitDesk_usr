import { describe, expect, it } from 'vitest'
import type { Announcement, GymSettings } from '@/types'
import { deriveGymStatus } from './gymStatus'

const settings: GymSettings = {
  id: 1,
  name: 'FitDesk Performance Club',
  address: '12, 100 Feet Road, Indiranagar, Bengaluru 560038',
  open_time: '05:00',
  close_time: '23:00',
  closed_weekdays: [0],
  contact_phone: '+91 90000 00000',
  updated_at: '2026-10-01T00:00:00.000Z',
}

function atIst(iso: string): Date {
  return new Date(`${iso}+05:30`)
}

function announcement(patch: Partial<Announcement>): Announcement {
  return {
    id: 'a1',
    title: 'Maintenance',
    body: 'Closed for maintenance.',
    kind: 'closure',
    starts_on: '2026-10-27',
    ends_on: '2026-10-27',
    is_active: true,
    created_at: '2026-10-01T00:00:00.000Z',
    ...patch,
  }
}

describe('deriveGymStatus', () => {
  it('reports open during published hours', () => {
    const status = deriveGymStatus(settings, [], atIst('2026-10-27T10:00:00'))
    expect(status.state).toBe('open')
    expect(status.isOpenNow).toBe(true)
    expect(status.detail).toBe('Closes at 11:00 PM')
    expect(status.hours).toBe('5:00 AM – 11:00 PM')
  })

  it('closes before opening and points at today\'s opening', () => {
    const status = deriveGymStatus(settings, [], atIst('2026-10-27T04:00:00'))
    expect(status.state).toBe('closed')
    expect(status.isOpenNow).toBe(false)
    expect(status.detail).toBe('Opens today at 5:00 AM')
  })

  it('closes after published hours and points at tomorrow', () => {
    const status = deriveGymStatus(settings, [], atIst('2026-10-27T23:30:00'))
    expect(status.state).toBe('closed')
    expect(status.detail).toBe('Opens tomorrow at 5:00 AM')
  })

  it('respects the weekly off day in IST', () => {
    const status = deriveGymStatus(settings, [], atIst('2026-10-25T10:00:00'))
    expect(status.state).toBe('closed')
    expect(status.detail).toContain('Sunday is the weekly off')
    expect(status.detail).toContain('Opens tomorrow at 5:00 AM')
  })

  it('lets an active closure announcement win over opening hours', () => {
    const status = deriveGymStatus(
      settings,
      [announcement({ title: 'Deep clean', starts_on: '2026-10-26', ends_on: '2026-10-28' })],
      atIst('2026-10-27T10:00:00'),
    )
    expect(status.state).toBe('closed')
    expect(status.isOpenNow).toBe(false)
    expect(status.label).toBe('Closed')
    expect(status.detail).toBe('Deep clean')
    expect(status.announcement?.title).toBe('Deep clean')
  })

  it('labels a holiday differently from a closure', () => {
    const status = deriveGymStatus(
      settings,
      [announcement({ kind: 'holiday', title: 'Diwali' })],
      atIst('2026-10-27T10:00:00'),
    )
    expect(status.state).toBe('holiday')
    expect(status.label).toBe('Holiday')
    expect(status.detail).toBe('Diwali')
  })

  it('ignores inactive or out-of-range announcements', () => {
    const ignored = [
      announcement({ is_active: false }),
      announcement({ starts_on: '2026-10-28', ends_on: '2026-10-29' }),
      announcement({ starts_on: '2026-10-20', ends_on: '2026-10-24' }),
    ]
    const status = deriveGymStatus(settings, ignored, atIst('2026-10-27T10:00:00'))
    expect(status.state).toBe('open')
  })

  it('supports hours that cross midnight', () => {
    const overnight: GymSettings = { ...settings, open_time: '22:00', close_time: '02:00' }
    expect(deriveGymStatus(overnight, [], atIst('2026-10-27T23:30:00')).state).toBe('open')
    expect(deriveGymStatus(overnight, [], atIst('2026-10-27T01:30:00')).state).toBe('open')
    expect(deriveGymStatus(overnight, [], atIst('2026-10-27T12:00:00')).state).toBe('closed')
  })

  it('degrades safely when hours are missing', () => {
    const status = deriveGymStatus(null, [], atIst('2026-10-27T10:00:00'))
    expect(status.state).toBe('closed')
    expect(status.isOpenNow).toBe(false)
    expect(status.detail).toBe('Gym hours have not been published yet.')
  })
})
