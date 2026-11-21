begin;
create or replace function public.enforce_two_admins_per_gym()
returns trigger
language plpgsql
security definer
set search_path to public, pg_temp
as $$
declare
  v_count integer;
begin
  if new.is_admin is not true or new.gym_id is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.is_admin is true and old.gym_id = new.gym_id then
    return new;
  end if;

  select count(*) into v_count
    from public.profiles
   where gym_id = new.gym_id
     and is_admin is true
     and id <> new.id;

  if v_count >= 2 then
    raise exception 'GYM_ADMIN_LIMIT_REACHED' using errcode = '22023';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_enforce_two_admins on public.profiles;
create trigger profiles_enforce_two_admins
  before insert or update on public.profiles
  for each row
  execute function public.enforce_two_admins_per_gym();

commit;