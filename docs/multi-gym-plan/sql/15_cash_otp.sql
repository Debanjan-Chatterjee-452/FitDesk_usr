begin;
alter table public.payments add column if not exists cash_otp text;
alter table public.payments add column if not exists cash_otp_expires_at timestamptz;
alter table public.payments add column if not exists cash_otp_used_at timestamptz;

create or replace function public.admin_generate_cash_otp(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
  v_payment public.payments;
  v_otp text;
begin
  select * into v_payment from public.payments
   where id = p_payment_id and gym_id = v_gym_id;

  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_payment.status <> 'pending' then
    raise exception 'PAYMENT_ALREADY_REVIEWED' using errcode = 'P0001';
  end if;

  v_otp := lpad((floor(random() * 100000))::text, 5, '0');

  update public.payments
     set cash_otp = v_otp,
         cash_otp_expires_at = now() + interval '10 minutes',
         cash_otp_used_at = null,
         updated_at = now()
   where id = p_payment_id;

  return jsonb_build_object('otp', v_otp, 'expires_at', now() + interval '10 minutes', 'payment_id', p_payment_id);
end;
$$;

revoke all on function public.admin_generate_cash_otp(uuid) from public, anon, authenticated;
grant execute on function public.admin_generate_cash_otp(uuid) to authenticated;

commit;