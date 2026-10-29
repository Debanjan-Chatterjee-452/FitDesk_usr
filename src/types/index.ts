export type Gender = 'male' | 'female' | 'other' | 'prefer_not_to_say'
export type BloodGroup =
  | 'A+'
  | 'A-'
  | 'B+'
  | 'B-'
  | 'AB+'
  | 'AB-'
  | 'O+'
  | 'O-'

export type MembershipStatus = 'pending' | 'active' | 'expired' | 'cancelled'
export type PaymentStatus = 'pending' | 'approved' | 'declined'
export type CheckoutState =
  | 'open'
  | 'verifying'
  | 'submitted'
  | 'reconciliation_required'
  | 'abandoned'
export type RefundStatus = 'not_required' | 'pending_manual_refund' | 'refunded'
export type PricingMode = 'fixed' | 'per_day'
export type AnnouncementKind = 'info' | 'holiday' | 'closure'

/**
 * Member-facing payment state. Derived from the existing rows rather than a
 * second status system:
 *   NOT_STARTED          -> pending, checkout open
 *   PENDING_VERIFICATION -> pending, reference submitted, awaiting gym review
 *   VERIFIED             -> approved
 *   FAILED               -> declined
 *   CANCELLED            -> checkout abandoned
 */
export type UpiPaymentState =
  | 'NOT_STARTED'
  | 'PENDING_VERIFICATION'
  | 'VERIFIED'
  | 'FAILED'
  | 'CANCELLED'

/** The gym's configured direct-UPI recipient, as returned for one payment. */
export interface UpiPayee {
  available: boolean
  reason: 'NOT_CONFIGURED' | 'AMOUNT_INVALID' | 'INVALID_UPI_ID' | null
  upi_id: string | null
  name: string | null
  qr_path: string | null
  qr_bucket: string | null
}

export interface Profile {
  id: string
  /** Auth email for the signed-in member. Read from the Supabase session. */
  email: string
  /** Optional contact number. Existing members keep their saved number. */
  phone: string
  full_name: string | null
  date_of_birth: string | null
  blood_group: BloodGroup | null
  gender: Gender | null
  legal_document_path: string | null
  legal_document_name: string | null
  legal_document_type: string | null
  profile_completed: boolean
  /** Admin role flag. Set by staff/SQL tooling; members cannot change it. */
  is_admin: boolean
  /** Gym this member belongs to. Assignment is server-side only. */
  gym_id?: string | null
  created_at: string
  updated_at: string
}

export interface GymPackage {
  id: string
  name: string
  description: string | null
  duration_days: number
  price_inr: number
  pricing_mode: PricingMode
  min_days: number | null
  max_days: number | null
  is_active: boolean
  is_recommended: boolean
  sort_order: number
  /** Gym that owns this plan. Plan prices are per gym. */
  gym_id?: string | null
  created_at: string
  updated_at: string
}

export interface Membership {
  id: string
  user_id: string
  package_id: string
  starts_on: string
  ends_on: string
  price_paid_inr: number
  fine_paid_inr: number
  status: MembershipStatus
  created_at: string
  updated_at: string
  package?: GymPackage | null
}

export interface AttendanceRecord {
  id: string
  user_id: string
  check_in_at: string
  check_in_date: string
  source: 'qr' | 'manual' | 'admin'
  gym_qr_id: string | null
  created_at: string
}

export interface Payment {
  id: string
  user_id: string
  membership_id: string | null
  package_id: string
  duration_days: number
  base_amount_inr: number
  fine_amount_inr: number
  total_amount_inr: number
  status: PaymentStatus
  provider: string
  provider_order_id: string | null
  provider_payment_id: string | null
  failure_reason: string | null
  quote: RenewalQuote | null
  paid_at: string | null
  reviewed_at: string | null
  reviewed_by: string | null
  review_note?: string | null
  checkout_state: CheckoutState
  reconciliation_required: boolean
  reconciliation_reason: string | null
  /** Original pre-approval status (failed/refunded/cancelled), preserved. */
  legacy_status: string | null
  refund_status: RefundStatus
  refund_note: string | null
  refunded_at: string | null
  refunded_by: string | null
  /** Gym the money is owed to. Present on every row after the UPI migration. */
  gym_id?: string | null
  /** UTR / transaction reference claimed by the member (not proof of payment). */
  upi_reference?: string | null
  upi_submitted_at?: string | null
  /** UPI ID recorded when the reference was submitted, for manual verification. */
  payee_upi_id?: string | null
  created_at: string
  updated_at: string
  package?: Pick<GymPackage, 'id' | 'name' | 'duration_days'> | null
}

export interface Announcement {
  id: string
  title: string
  body: string | null
  kind: AnnouncementKind
  starts_on: string
  ends_on: string | null
  is_active: boolean
  created_at: string
}

export interface GymSettings {
  id: number
  name: string
  address: string | null
  open_time: string
  close_time: string
  closed_weekdays: number[]
  contact_phone: string | null
  updated_at: string
}

export interface RenewalQuote {
  package_id: string
  package_name: string
  description: string | null
  pricing_mode: PricingMode
  duration_days: number
  base_amount: number
  fine_amount: number
  total_amount: number
  days_past_expiry: number
  grace_days: number
  starts_on: string
  ends_on: string
  current_ends_on: string | null
  is_stacked: boolean
  fine_reason: string | null
  breakdown: Array<{ label: string; amount: number }>
}

export interface PaymentOrder {
  payment_id: string
  order_id: string
  amount: number
  currency: string
  key_id: string
  quote: RenewalQuote
  prefill: { name: string; contact: string }
}

export interface PaymentVerification {
  status:
    | 'pending_approval'
    | 'already_pending'
    | 'already_approved'
    | 'reconciliation_required'
  payment_id: string
  membership_id: string | null
  starts_on: string | null
  ends_on: string | null
  package_name: string
  total_amount_inr: number
  provider_payment_id?: string | null
  provider_order_id?: string | null
  reconciliation_reason?: string | null
}

/** Result of reserving a direct-UPI checkout. Amount/gym are server-side. */
export interface UpiCheckoutReservation {
  status: 'reserved' | 'resume_checkout' | 'already_pending' | 'reconciliation_required'
  payment_id: string
  quote: RenewalQuote | null
  package_name?: string
  amount_inr?: number
  gym_id?: string
  upi_reference?: string | null
  reconciliation_reason?: string | null
  created_at?: string
}

/** Everything the payment screen is allowed to render, for one payment. */
export interface UpiPaymentInstructions {
  payment_id: string
  payment_state: UpiPaymentState
  status: PaymentStatus
  checkout_state: CheckoutState
  payment_method: string
  amount_inr: number
  currency: 'INR'
  reference: string
  gym_id: string | null
  gym_name: string
  package_name: string
  duration_days: number
  starts_on: string | null
  ends_on: string | null
  upi_reference: string | null
  submitted_at: string | null
  payee: UpiPayee
}

export interface AdminPaymentRow {
  payment_id: string
  user_id: string
  member_name: string
  member_email: string | null
  member_phone: string | null
  package_name: string
  duration_days: number
  base_amount_inr: number
  fine_amount_inr: number
  total_amount_inr: number
  status: PaymentStatus
  provider_order_id: string | null
  provider_payment_id: string | null
  failure_reason: string | null
  quote: RenewalQuote | null
  created_at: string
  paid_at: string | null
  reviewed_at: string | null
  reviewed_by: string | null
  checkout_state: CheckoutState
  reconciliation_required: boolean
  reconciliation_reason: string | null
  legacy_status: string | null
  refund_status: RefundStatus
  refund_note: string | null
  refunded_at: string | null
  refunded_by: string | null
}

export interface PaymentReviewResult {
  status: 'approved' | 'declined'
  payment_id: string
  membership_id: string | null
  starts_on: string | null
  ends_on: string | null
  package_name: string
  total_amount_inr: number
  refund_status?: RefundStatus | null
}

export interface AdminRefundRow {
  payment_id: string
  user_id: string
  member_name: string
  member_email: string | null
  member_phone: string | null
  package_name: string
  total_amount_inr: number
  provider_payment_id: string | null
  review_note: string | null
  refund_status: RefundStatus
  refund_note: string | null
  reviewed_at: string | null
  refunded_at: string | null
  refunded_by: string | null
  created_at: string
}

export interface RefundResult {
  status: 'refunded'
  payment_id: string
  refund_status: RefundStatus
}

export type CheckInStatus = 'checked_in' | 'already_checked_in'

export interface CheckInResult {
  status: CheckInStatus
  attendance_id: string
  check_in_at: string
  check_in_date: string
  gym_name: string
  message: string
}

export type GymState = 'open' | 'closed' | 'holiday'

export interface GymStatusInfo {
  state: GymState
  isOpenNow: boolean
  label: string
  detail: string
  hours: string
  announcement: Announcement | null
  settings: GymSettings | null
}

export interface MembershipSnapshot {
  membership: Membership | null
  isActive: boolean
  daysLeft: number
  isExpired: boolean
  daysPastExpiry: number
  progress: number
}

export interface AttendanceStats {
  total: number
  thisMonth: number
  streak: number
  lastCheckIn: AttendanceRecord | null
  checkedInToday: boolean
}

export interface DashboardData {
  profile: Profile
  membership: MembershipSnapshot
  gym: GymStatusInfo
  announcements: Announcement[]
  attendance: AttendanceStats
  payments: Payment[]
}
