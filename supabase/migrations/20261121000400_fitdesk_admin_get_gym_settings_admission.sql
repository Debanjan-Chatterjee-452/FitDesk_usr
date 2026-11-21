-- 20261121000400_fitdesk_admin_get_gym_settings_admission.sql
-- Expose admission_fee_inr in admin_get_gym_settings.

create or replace function public.admin_get_gym_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_row jsonb;
begin
  select jsonb_build_object(
    'gym_id', g.id,
    'slug', g.slug,
    'name', g.name,
    'upi_id', g.upi_id,
    'upi_payee_name', g.upi_payee_name,
    'payment_qr_path', g.payment_qr_path,
    'is_open', g.is_open,
    'shutter_changed_at', g.shutter_changed_at,
    'attendance_qr_months', g.attendance_qr_months,
    'attendance_qr_rotated_at', g.attendance_qr_rotated_at,
    'admission_fee_inr', g.admission_fee_inr,
    'updated_at', g.updated_at
  )
    into v_row
    from public.gyms g
   where g.id = v_gym_id;

  if v_row is null then
    raise exception 'GYM_NOT_FOUND' using errcode = 'P0001';
  end if;

  return v_row;
end;
$$;
