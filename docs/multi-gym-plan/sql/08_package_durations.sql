begin;
alter table public.packages drop constraint if exists packages_duration_months_valid;
alter table public.packages add constraint packages_duration_months_valid check (duration_months is null or (duration_months >= 0 and duration_months <= 24));
create or replace function public.admin_upsert_package(
  p_months integer,
  p_price_inr integer,
  p_name text default null,
  p_description text default null,
  p_id uuid default null,
  p_is_recommended boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_temp
as $$ 
declare
  v_gym_id uuid := public.admin_assert();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_description text := nullif(btrim(coalesce(p_description, '')), '');
  v_days integer;
  v_row public.packages;
begin
  if p_months is null or p_months < 0 or p_months > 24 then
    raise exception 'INVALID_PACKAGE_MONTHS' using errcode = '22023';
  end if;

  if p_price_inr is null or p_price_inr < 1 then
    raise exception 'INVALID_PACKAGE_PRICE' using errcode = '22023';
  end if;

  if p_months = 0 then
    v_days := 1;
    if v_name is null then v_name := '1 Day'; end if;
  else
    v_days := case p_months
      when 1 then 30
      when 3 then 90
      when 6 then 180
      when 12 then 365
      else p_months * 30
    end;
    if v_name is null then
      v_name := case p_months
        when 1 then 'Monthly'
        when 3 then 'Quarterly'
        when 6 then 'Half-yearly'
        when 12 then 'Annual'
        else p_months::text || ' Month Plan'
      end;
    end if;
  end if;

  if p_id is null then
    insert into public.packages (
      name, description, duration_days, duration_months, price_inr, pricing_mode, is_active, is_recommended, sort_order, gym_id
    ) values (
      v_name, v_description, v_days, p_months, p_price_inr, 'fixed', true, p_is_recommended,
      case when p_months = 0 then 0 else p_months * 10 end, v_gym_id
    ) returning * into v_row;
  else
    update public.packages
       set name = v_name,
           description = v_description,
           duration_days = v_days,
           duration_months = p_months,
           price_inr = p_price_inr,
           pricing_mode = 'fixed',
           min_days = null,
           max_days = null,
           is_recommended = p_is_recommended,
           sort_order = case when p_months = 0 then 0 else p_months * 10 end,
           updated_at = now()
     where id = p_id and gym_id = v_gym_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'PACKAGE_NOT_FOUND' using errcode = 'P0001';
    end if;
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'name', v_row.name,
    'duration_months', v_row.duration_months,
    'duration_days', v_row.duration_days,
    'price_inr', v_row.price_inr,
    'is_active', v_row.is_active
  );
end;
$$;
commit;