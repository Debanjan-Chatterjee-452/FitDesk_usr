-- 20261121000300_fitdesk_admission_fee_admin_rpc.sql
-- Lets an admin set the gym's admission fee.

create or replace function public.admin_set_admission_fee(p_amount integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_gym_id uuid := public.admin_assert();
begin
  if p_amount is null or p_amount < 0 then
    raise exception 'INVALID_AMOUNT' using errcode = 'P0001';
  end if;

  update public.gyms
     set admission_fee_inr = p_amount,
         updated_at = now()
   where id = v_gym_id;

  return jsonb_build_object('gym_id', v_gym_id, 'admission_fee_inr', p_amount);
end;
$$;

revoke all on function public.admin_set_admission_fee(integer) from public, anon;
grant execute on function public.admin_set_admission_fee(integer) to authenticated;

-- Expose admission_fee_inr via member_gym_overview? The member app reads it
-- through the quote RPC (already admission-fee aware). No extra grant needed.
