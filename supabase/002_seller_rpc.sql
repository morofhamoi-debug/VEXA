-- ============================================================
-- VEXA — Migration 002: seller registration RPC
-- Run in Supabase → SQL Editor (после schema.sql)
-- ============================================================

create or replace function public.tg_profiles_prevent_role_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor_role text;
begin
  if new.role is distinct from old.role then
    if current_setting('vexa.allow_role_change', true) = '1' then
      return new;
    end if;
    select role into v_actor_role from public.profiles where id = auth.uid();
    if coalesce(v_actor_role,'') <> 'admin'
       and current_setting('request.jwt.claim.role', true) is distinct from 'service_role' then
      raise exception 'ROLE_CHANGE_NOT_ALLOWED';
    end if;
  end if;
  return new;
end $$;

create or replace function public.fn_register_seller(
  p_store_name text,
  p_description text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_existing uuid;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if coalesce(trim(p_store_name), '') = '' then
    raise exception 'STORE_NAME_REQUIRED';
  end if;

  select id into v_existing from public.sellers where user_id = v_uid;
  if v_existing is not null then
    return jsonb_build_object('ok', true, 'seller_id', v_existing, 'existing', true);
  end if;

  perform set_config('vexa.allow_role_change', '1', true);

  update public.profiles
    set role = 'seller', updated_at = now()
    where id = v_uid and role in ('customer');

  insert into public.sellers (user_id, store_name, description, status)
    values (v_uid, trim(p_store_name), nullif(trim(p_description), ''), 'active')
    returning id into v_existing;

  perform set_config('vexa.allow_role_change', '0', true);

  return jsonb_build_object('ok', true, 'seller_id', v_existing, 'existing', false);
end $$;
