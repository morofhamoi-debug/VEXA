-- ============================================================
-- VEXA — Full Database Schema
-- Run in: Supabase → SQL Editor
-- ============================================================

create extension if not exists pgcrypto;

-- ============================================================
-- 0. UTILITIES
-- ============================================================
create or replace function public.tg_touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- ============================================================
-- 1. PROFILES
-- ============================================================
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text,
  phone        text,
  full_name    text,
  avatar_url   text,
  role         text not null default 'customer'
    check (role in ('customer','seller','pvz_employee','driver','warehouse_employee','admin')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index profiles_role_idx on public.profiles(role);

create trigger profiles_touch
  before update on public.profiles
  for each row execute function public.tg_touch_updated_at();

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(coalesce(new.email,''), '@', 1)),
    'customer'
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Prevent role self-escalation
create or replace function public.tg_profiles_prevent_role_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor_role text;
begin
  if new.role is distinct from old.role then
    select role into v_actor_role from public.profiles where id = auth.uid();
    if coalesce(v_actor_role,'') <> 'admin' and current_setting('request.jwt.claim.role', true) is distinct from 'service_role' then
      raise exception 'ROLE_CHANGE_NOT_ALLOWED';
    end if;
  end if;
  return new;
end $$;

create trigger profiles_prevent_role_change
  before update on public.profiles
  for each row execute function public.tg_profiles_prevent_role_change();

-- ============================================================
-- 2. SELLERS
-- ============================================================
create table public.sellers (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  store_name  text not null,
  description text,
  logo_url    text,
  status      text not null default 'active' check (status in ('active','suspended','archived')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id)
);
create index sellers_status_idx on public.sellers(status);

create trigger sellers_touch
  before update on public.sellers
  for each row execute function public.tg_touch_updated_at();

-- ============================================================
-- 3. PRODUCTS
-- ============================================================
create table public.products (
  id                uuid primary key default gen_random_uuid(),
  seller_id         uuid not null references public.sellers(id) on delete cascade,
  name              text not null,
  description       text,
  price             numeric(12,2) not null check (price >= 0),
  old_price         numeric(12,2) check (old_price is null or old_price >= 0),
  category          text,
  sku               text,
  barcode           text,
  quantity          int not null default 0 check (quantity >= 0),
  reserved_quantity int not null default 0 check (reserved_quantity >= 0),
  sold_quantity     int not null default 0 check (sold_quantity >= 0),
  image_url         text,
  status            text not null default 'active'
    check (status in ('active','draft','out_of_stock','archived')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index products_seller_idx   on public.products(seller_id);
create index products_status_idx   on public.products(status);
create index products_category_idx on public.products(category);

create trigger products_touch
  before update on public.products
  for each row execute function public.tg_touch_updated_at();

-- ============================================================
-- 4. PVZ
-- ============================================================
create table public.pvz (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  address    text not null,
  city       text not null,
  latitude   double precision,
  longitude  double precision,
  phone      text,
  status     text not null default 'active' check (status in ('active','paused','closed')),
  created_at timestamptz not null default now()
);

create table public.pvz_employees (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  pvz_id     uuid not null references public.pvz(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_id)
);
create index pvz_emp_pvz_idx on public.pvz_employees(pvz_id);

-- ============================================================
-- 5. WAREHOUSES
-- ============================================================
create table public.warehouses (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  address    text not null,
  city       text not null,
  latitude   double precision,
  longitude  double precision,
  phone      text,
  status     text not null default 'active' check (status in ('active','paused','closed')),
  created_at timestamptz not null default now()
);

create table public.warehouse_employees (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id) on delete cascade,
  created_at   timestamptz not null default now(),
  unique (user_id)
);
create index wh_emp_wh_idx on public.warehouse_employees(warehouse_id);

-- ============================================================
-- 6. DRIVERS
-- ============================================================
create table public.drivers (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  name           text not null,
  phone          text,
  vehicle_number text,
  status         text not null default 'offline' check (status in ('offline','available','busy')),
  created_at     timestamptz not null default now(),
  unique (user_id)
);

create table public.driver_tasks (
  id                       uuid primary key default gen_random_uuid(),
  driver_id                uuid not null references public.drivers(id) on delete cascade,
  type                     text not null check (type in ('pvz_to_warehouse','warehouse_to_pvz')),
  source_pvz_id            uuid references public.pvz(id),
  destination_warehouse_id uuid references public.warehouses(id),
  source_warehouse_id      uuid references public.warehouses(id),
  destination_pvz_id       uuid references public.pvz(id),
  status                   text not null default 'assigned'
    check (status in ('assigned','in_progress','completed','cancelled')),
  created_at               timestamptz not null default now(),
  started_at               timestamptz,
  completed_at             timestamptz
);
create index dt_driver_idx on public.driver_tasks(driver_id);
create index dt_status_idx on public.driver_tasks(status);

-- ============================================================
-- 7. ORDERS
-- ============================================================
create sequence public.order_number_seq start 10000;

create table public.orders (
  id                     uuid primary key default gen_random_uuid(),
  order_number           text not null unique
    default ('VX-' || nextval('public.order_number_seq')),
  customer_id            uuid not null references auth.users(id) on delete restrict,
  seller_id              uuid not null references public.sellers(id) on delete restrict,
  pvz_id                 uuid references public.pvz(id),
  driver_id              uuid references public.drivers(id),
  warehouse_id           uuid references public.warehouses(id),
  driver_task_id         uuid references public.driver_tasks(id),
  total_amount           numeric(12,2) not null default 0,
  delivery_price         numeric(12,2) not null default 0,
  status                 text not null default 'pending',
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  accepted_at            timestamptz,
  assembled_at           timestamptz,
  pvz_received_at        timestamptz,
  driver_received_at     timestamptz,
  warehouse_received_at  timestamptz
);

alter table public.orders add constraint orders_status_chk
  check (status in (
    'pending','seller_accepted','seller_cancelled','assembling',
    'ready_for_pvz','received_at_pvz','ready_for_driver','picked_up_by_driver',
    'in_transit_to_warehouse','received_at_warehouse','processing_at_warehouse',
    'ready_for_delivery','in_transit_to_destination_pvz','received_at_destination_pvz',
    'ready_for_customer','completed','returned','cancelled'
  ));

create index orders_customer_idx on public.orders(customer_id);
create index orders_seller_idx   on public.orders(seller_id);
create index orders_status_idx   on public.orders(status);
create index orders_pvz_idx      on public.orders(pvz_id);

create trigger orders_touch
  before update on public.orders
  for each row execute function public.tg_touch_updated_at();

-- ============================================================
-- 8. ORDER ITEMS (with snapshots)
-- ============================================================
create table public.order_items (
  id                     uuid primary key default gen_random_uuid(),
  order_id               uuid not null references public.orders(id) on delete cascade,
  product_id             uuid references public.products(id) on delete set null,
  seller_id              uuid not null references public.sellers(id),
  product_name_snapshot  text not null,
  product_price_snapshot numeric(12,2) not null,
  quantity               int not null check (quantity > 0),
  total_price            numeric(12,2) not null,
  created_at             timestamptz not null default now()
);
create index oi_order_idx on public.order_items(order_id);

-- ============================================================
-- 9. PVZ CELLS (references orders now that it exists)
-- ============================================================
create table public.pvz_cells (
  id               uuid primary key default gen_random_uuid(),
  pvz_id           uuid not null references public.pvz(id) on delete cascade,
  cell_number      text not null,
  status           text not null default 'free' check (status in ('free','occupied','reserved','maintenance')),
  current_order_id uuid references public.orders(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (pvz_id, cell_number)
);

create trigger pvz_cells_touch
  before update on public.pvz_cells
  for each row execute function public.tg_touch_updated_at();

-- ============================================================
-- 10. QR CODES
-- ============================================================
create table public.shipment_qr_codes (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null unique references public.orders(id) on delete cascade,
  qr_token        text not null unique,
  status          text not null default 'active' check (status in ('active','used','revoked','expired')),
  created_at      timestamptz not null default now(),
  activated_at    timestamptz default now(),
  last_scanned_at timestamptz
);
create index qr_token_idx on public.shipment_qr_codes(qr_token);

-- ============================================================
-- 11. STATUS HISTORY
-- ============================================================
create table public.order_status_history (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id) on delete cascade,
  old_status  text,
  new_status  text not null,
  changed_by  uuid references auth.users(id),
  comment     text,
  created_at  timestamptz not null default now()
);
create index osh_order_idx on public.order_status_history(order_id, created_at);

-- ============================================================
-- 12. NOTIFICATIONS
-- ============================================================
create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  type       text not null,
  title      text not null,
  message    text,
  order_id   uuid references public.orders(id) on delete set null,
  is_read    boolean not null default false,
  created_at timestamptz not null default now()
);
create index notif_user_idx on public.notifications(user_id, is_read, created_at desc);

-- ============================================================
-- 13. HELPER FUNCTIONS (used inside RLS)
-- ============================================================
create or replace function public.current_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.current_seller_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.sellers where user_id = auth.uid();
$$;

create or replace function public.current_pvz_id()
returns uuid language sql stable security definer set search_path = public as $$
  select pvz_id from public.pvz_employees where user_id = auth.uid();
$$;

create or replace function public.current_warehouse_id()
returns uuid language sql stable security definer set search_path = public as $$
  select warehouse_id from public.warehouse_employees where user_id = auth.uid();
$$;

create or replace function public.current_driver_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.drivers where user_id = auth.uid();
$$;

-- ============================================================
-- 14. RLS
-- ============================================================
alter table public.profiles              enable row level security;
alter table public.sellers               enable row level security;
alter table public.products              enable row level security;
alter table public.orders                enable row level security;
alter table public.order_items           enable row level security;
alter table public.shipment_qr_codes     enable row level security;
alter table public.order_status_history  enable row level security;
alter table public.pvz                   enable row level security;
alter table public.pvz_employees         enable row level security;
alter table public.pvz_cells             enable row level security;
alter table public.warehouses            enable row level security;
alter table public.warehouse_employees   enable row level security;
alter table public.drivers               enable row level security;
alter table public.driver_tasks          enable row level security;
alter table public.notifications         enable row level security;

-- ---- PROFILES ----
create policy profiles_select on public.profiles
  for select to authenticated using (true);

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid() or public.current_role() = 'admin')
  with check (id = auth.uid() or public.current_role() = 'admin');

-- ---- SELLERS ----
create policy sellers_select on public.sellers
  for select to authenticated using (true);

create policy sellers_insert_own on public.sellers
  for insert to authenticated with check (user_id = auth.uid());

create policy sellers_update_own on public.sellers
  for update to authenticated
  using (user_id = auth.uid() or public.current_role() = 'admin')
  with check (user_id = auth.uid() or public.current_role() = 'admin');

-- ---- PRODUCTS ----
create policy products_select on public.products
  for select to authenticated using (
    status = 'active'
    or seller_id = public.current_seller_id()
    or public.current_role() = 'admin'
  );

create policy products_insert_own on public.products
  for insert to authenticated
  with check (seller_id = public.current_seller_id());

create policy products_update_own on public.products
  for update to authenticated
  using (seller_id = public.current_seller_id() or public.current_role() = 'admin')
  with check (seller_id = public.current_seller_id() or public.current_role() = 'admin');

create policy products_delete_own on public.products
  for delete to authenticated
  using (seller_id = public.current_seller_id() or public.current_role() = 'admin');

-- ---- ORDERS ----
create policy orders_select on public.orders
  for select to authenticated using (
    customer_id = auth.uid()
    or seller_id = public.current_seller_id()
    or pvz_id = public.current_pvz_id()
    or warehouse_id = public.current_warehouse_id()
    or driver_id = public.current_driver_id()
    or public.current_role() = 'admin'
  );
-- NO update / insert / delete via direct table. Only via RPC.

-- ---- ORDER ITEMS ----
create policy order_items_select on public.order_items
  for select to authenticated using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and (
        o.customer_id = auth.uid()
        or o.seller_id = public.current_seller_id()
        or o.pvz_id = public.current_pvz_id()
        or o.warehouse_id = public.current_warehouse_id()
        or o.driver_id = public.current_driver_id()
        or public.current_role() = 'admin'
      )
    )
  );

-- ---- QR ----
create policy qr_select on public.shipment_qr_codes
  for select to authenticated using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and (
        o.customer_id = auth.uid()
        or o.seller_id = public.current_seller_id()
        or public.current_role() = 'admin'
      )
    )
  );
-- RPC only for mutations

-- ---- HISTORY ----
create policy osh_select on public.order_status_history
  for select to authenticated using (
    exists (
      select 1 from public.orders o
      where o.id = order_id and (
        o.customer_id = auth.uid()
        or o.seller_id = public.current_seller_id()
        or o.pvz_id = public.current_pvz_id()
        or o.warehouse_id = public.current_warehouse_id()
        or o.driver_id = public.current_driver_id()
        or public.current_role() = 'admin'
      )
    )
  );
-- RPC only for mutations

-- ---- PVZ ----
create policy pvz_select on public.pvz
  for select to authenticated using (true);

create policy pvz_emp_select on public.pvz_employees
  for select to authenticated using (
    user_id = auth.uid() or public.current_role() = 'admin'
  );

create policy pvz_cells_select on public.pvz_cells
  for select to authenticated using (
    pvz_id = public.current_pvz_id() or public.current_role() = 'admin'
  );

-- ---- WAREHOUSES ----
create policy wh_select on public.warehouses
  for select to authenticated using (true);

create policy wh_emp_select on public.warehouse_employees
  for select to authenticated using (
    user_id = auth.uid() or public.current_role() = 'admin'
  );

-- ---- DRIVERS ----
create policy drivers_select on public.drivers
  for select to authenticated using (
    user_id = auth.uid() or public.current_role() = 'admin'
  );

create policy dt_select on public.driver_tasks
  for select to authenticated using (
    driver_id = public.current_driver_id() or public.current_role() = 'admin'
  );

-- ---- NOTIFICATIONS ----
create policy notif_select on public.notifications
  for select to authenticated using (user_id = auth.uid());

create policy notif_update on public.notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ============================================================
-- 15. RPC FUNCTIONS — critical operations
-- ============================================================

-- 15.1 CREATE ORDER (customer)
create or replace function public.fn_create_order(
  p_items jsonb,
  p_pvz_id uuid,
  p_delivery_price numeric default 0
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_order_id uuid;
  v_order_number text;
  v_seller_id uuid;
  v_seller_user_id uuid;
  v_seller_name text;
  v_total numeric := 0;
  v_item jsonb;
  v_product public.products;
  v_delivery numeric := coalesce(p_delivery_price, 0);
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then raise exception 'EMPTY_CART'; end if;
  if p_pvz_id is null then raise exception 'PVZ_REQUIRED'; end if;
  if not exists (select 1 from public.pvz where id = p_pvz_id and status = 'active') then
    raise exception 'PVZ_NOT_AVAILABLE';
  end if;

  select seller_id into v_seller_id
    from public.products
    where id = (p_items->0->>'product_id')::uuid;
  if v_seller_id is null then raise exception 'PRODUCT_NOT_FOUND'; end if;

  select user_id, store_name into v_seller_user_id, v_seller_name
    from public.sellers where id = v_seller_id;

  insert into public.orders (customer_id, seller_id, pvz_id, total_amount, delivery_price, status)
    values (v_uid, v_seller_id, p_pvz_id, 0, v_delivery, 'pending')
    returning id, order_number into v_order_id, v_order_number;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid for update;
    if v_product is null then
      raise exception 'PRODUCT_NOT_FOUND:%', v_item->>'product_id';
    end if;
    if v_product.seller_id <> v_seller_id then
      raise exception 'MULTI_SELLER_NOT_SUPPORTED';
    end if;
    if v_product.status <> 'active' then
      raise exception 'PRODUCT_NOT_AVAILABLE:%', v_product.name;
    end if;
    if (v_product.quantity - v_product.reserved_quantity) < (v_item->>'quantity')::int then
      raise exception 'INSUFFICIENT_STOCK:%', v_product.name;
    end if;

    update public.products
      set reserved_quantity = reserved_quantity + (v_item->>'quantity')::int,
          updated_at = now()
      where id = v_product.id;

    insert into public.order_items (
      order_id, product_id, seller_id,
      product_name_snapshot, product_price_snapshot,
      quantity, total_price
    ) values (
      v_order_id, v_product.id, v_seller_id,
      v_product.name, v_product.price,
      (v_item->>'quantity')::int,
      v_product.price * (v_item->>'quantity')::int
    );

    v_total := v_total + v_product.price * (v_item->>'quantity')::int;
  end loop;

  update public.orders set total_amount = v_total + v_delivery, updated_at = now()
    where id = v_order_id;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by)
    values (v_order_id, null, 'pending', v_uid);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_seller_user_id, 'order_created', 'Новый заказ',
            'Поступил заказ ' || v_order_number || ' от ' || coalesce((select full_name from public.profiles where id = v_uid), 'покупателя'),
            v_order_id);

  return jsonb_build_object('order_id', v_order_id, 'order_number', v_order_number, 'total', v_total + v_delivery);
end $$;

-- 15.2 ACCEPT ORDER (seller)
create or replace function public.fn_accept_seller_order(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_seller_id uuid := public.current_seller_id();
  v_order public.orders;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_seller_id is null then raise exception 'NOT_A_SELLER'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.seller_id <> v_seller_id then raise exception 'NOT_YOUR_ORDER'; end if;
  if v_order.status <> 'pending' then
    raise exception 'INVALID_STATUS:%', v_order.status;
  end if;

  update public.orders set status='seller_accepted', accepted_at=now(), updated_at=now()
    where id = p_order_id;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by)
    values (p_order_id, 'pending', 'seller_accepted', v_uid);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_order.customer_id, 'order_accepted', 'Заказ принят',
            'Продавец принял ваш заказ ' || v_order.order_number, p_order_id);

  return jsonb_build_object('ok', true);
end $$;

-- 15.3 CANCEL ORDER (seller)
create or replace function public.fn_cancel_seller_order(p_order_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_seller_id uuid := public.current_seller_id();
  v_order public.orders;
  v_item record;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_seller_id is null then raise exception 'NOT_A_SELLER'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.seller_id <> v_seller_id then raise exception 'NOT_YOUR_ORDER'; end if;
  if v_order.status not in ('pending','seller_accepted','assembling') then
    raise exception 'CANNOT_CANCEL_IN_STATUS:%', v_order.status;
  end if;

  -- release reserved stock
  for v_item in select * from public.order_items where order_id = p_order_id loop
    update public.products
      set reserved_quantity = greatest(0, reserved_quantity - v_item.quantity),
          updated_at = now()
      where id = v_item.product_id;
  end loop;

  update public.orders set status='seller_cancelled', updated_at=now() where id=p_order_id;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by, comment)
    values (p_order_id, v_order.status, 'seller_cancelled', v_uid, p_reason);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_order.customer_id, 'order_cancelled', 'Заказ отменён',
            'Продавец отменил заказ ' || v_order.order_number, p_order_id);

  return jsonb_build_object('ok', true);
end $$;

-- 15.4 START ASSEMBLY
create or replace function public.fn_start_assembly(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_seller_id uuid := public.current_seller_id();
  v_order public.orders;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_seller_id is null then raise exception 'NOT_A_SELLER'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.seller_id <> v_seller_id then raise exception 'NOT_YOUR_ORDER'; end if;
  if v_order.status <> 'seller_accepted' then
    raise exception 'INVALID_STATUS:%', v_order.status;
  end if;

  update public.orders set status='assembling', updated_at=now() where id=p_order_id;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by)
    values (p_order_id, 'seller_accepted', 'assembling', v_uid);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_order.customer_id, 'order_assembling', 'Сборка заказа',
            'Ваш заказ ' || v_order.order_number || ' собирается', p_order_id);

  return jsonb_build_object('ok', true);
end $$;

-- 15.5 MARK ASSEMBLED → creates QR token
create or replace function public.fn_mark_order_assembled(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_seller_id uuid := public.current_seller_id();
  v_order public.orders;
  v_token text;
  v_item record;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_seller_id is null then raise exception 'NOT_A_SELLER'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.seller_id <> v_seller_id then raise exception 'NOT_YOUR_ORDER'; end if;
  if v_order.status <> 'assembling' then
    raise exception 'INVALID_STATUS:%', v_order.status;
  end if;

  -- move reserved → sold, decrement quantity
  for v_item in select * from public.order_items where order_id = p_order_id loop
    update public.products
      set quantity = greatest(0, quantity - v_item.quantity),
          reserved_quantity = greatest(0, reserved_quantity - v_item.quantity),
          sold_quantity = sold_quantity + v_item.quantity,
          updated_at = now()
      where id = v_item.product_id;
  end loop;

  update public.orders set status='ready_for_pvz', assembled_at=now(), updated_at=now()
    where id = p_order_id;

  -- create or reuse QR token
  select qr_token into v_token from public.shipment_qr_codes where order_id = p_order_id;
  if v_token is null then
    v_token := 'VXQR-' || encode(gen_random_bytes(16), 'hex');
    insert into public.shipment_qr_codes(order_id, qr_token, status)
      values (p_order_id, v_token, 'active');
  else
    update public.shipment_qr_codes set status='active', activated_at=now() where order_id=p_order_id;
  end if;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by)
    values (p_order_id, 'assembling', 'ready_for_pvz', v_uid);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_order.customer_id, 'order_ready', 'Заказ собран',
            'Заказ ' || v_order.order_number || ' передан в логистику', p_order_id);

  return jsonb_build_object('ok', true, 'qr_token', v_token);
end $$;

-- 15.6 PVZ RECEIVES ORDER
create or replace function public.fn_receive_order_at_pvz(p_qr_token text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_pvz_id uuid := public.current_pvz_id();
  v_qr public.shipment_qr_codes;
  v_order public.orders;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_pvz_id is null then raise exception 'NOT_PVZ_EMPLOYEE'; end if;

  select * into v_qr from public.shipment_qr_codes where qr_token = p_qr_token;
  if v_qr is null then raise exception 'QR_NOT_FOUND'; end if;

  select * into v_order from public.orders where id = v_qr.order_id for update;
  if v_order is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.pvz_id <> v_pvz_id then raise exception 'WRONG_PVZ'; end if;
  if v_order.status <> 'ready_for_pvz' then
    raise exception 'INVALID_STATUS:%', v_order.status;
  end if;

  update public.orders set status='received_at_pvz', pvz_received_at=now(), updated_at=now()
    where id = v_order.id;

  update public.shipment_qr_codes set last_scanned_at = now() where id = v_qr.id;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by)
    values (v_order.id, 'ready_for_pvz', 'received_at_pvz', v_uid);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_order.customer_id, 'pvz_received', 'Отправление в ПВЗ',
            'Заказ ' || v_order.order_number || ' прибыл в ПВЗ', v_order.id);

  return jsonb_build_object('ok', true, 'order_id', v_order.id, 'order_number', v_order.order_number);
end $$;

-- 15.7 DRIVER PICKUP
create or replace function public.fn_driver_pickup_order(p_qr_token text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_driver_id uuid := public.current_driver_id();
  v_qr public.shipment_qr_codes;
  v_order public.orders;
  v_task_id uuid;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_driver_id is null then raise exception 'NOT_A_DRIVER'; end if;

  select * into v_qr from public.shipment_qr_codes where qr_token = p_qr_token;
  if v_qr is null then raise exception 'QR_NOT_FOUND'; end if;

  select * into v_order from public.orders where id = v_qr.order_id for update;
  if v_order is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.status <> 'received_at_pvz' then
    raise exception 'INVALID_STATUS:%', v_order.status;
  end if;

  select id into v_task_id from public.driver_tasks
    where driver_id = v_driver_id
      and type = 'pvz_to_warehouse'
      and source_pvz_id = v_order.pvz_id
      and status in ('assigned','in_progress')
    order by created_at
    limit 1;

  update public.orders set
    status='picked_up_by_driver',
    driver_id=v_driver_id,
    driver_task_id=v_task_id,
    driver_received_at=now(),
    updated_at=now()
    where id = v_order.id;

  if v_task_id is not null then
    update public.driver_tasks
      set status='in_progress', started_at=coalesce(started_at, now())
      where id = v_task_id and status = 'assigned';
  end if;

  update public.shipment_qr_codes set last_scanned_at = now() where id = v_qr.id;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by)
    values (v_order.id, 'received_at_pvz', 'picked_up_by_driver', v_uid);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_order.customer_id, 'driver_pickup', 'Водитель забрал заказ',
            'Заказ ' || v_order.order_number || ' в пути', v_order.id);

  return jsonb_build_object('ok', true, 'order_id', v_order.id, 'order_number', v_order.order_number);
end $$;

-- 15.8 WAREHOUSE RECEIVES ORDER
create or replace function public.fn_warehouse_receive_order(p_qr_token text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_wh_id uuid := public.current_warehouse_id();
  v_qr public.shipment_qr_codes;
  v_order public.orders;
  v_task public.driver_tasks;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_wh_id is null then raise exception 'NOT_WAREHOUSE_EMPLOYEE'; end if;

  select * into v_qr from public.shipment_qr_codes where qr_token = p_qr_token;
  if v_qr is null then raise exception 'QR_NOT_FOUND'; end if;

  select * into v_order from public.orders where id = v_qr.order_id for update;
  if v_order is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.status <> 'picked_up_by_driver' then
    raise exception 'INVALID_STATUS:%', v_order.status;
  end if;

  if v_order.driver_task_id is not null then
    select * into v_task from public.driver_tasks where id = v_order.driver_task_id;
    if v_task is not null and v_task.destination_warehouse_id is not null
       and v_task.destination_warehouse_id <> v_wh_id then
      raise exception 'WRONG_WAREHOUSE';
    end if;
  end if;

  update public.orders set
    status='received_at_warehouse',
    warehouse_id=v_wh_id,
    warehouse_received_at=now(),
    updated_at=now()
    where id = v_order.id;

  update public.shipment_qr_codes set last_scanned_at = now() where id = v_qr.id;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by)
    values (v_order.id, 'picked_up_by_driver', 'received_at_warehouse', v_uid);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_order.customer_id, 'warehouse_received', 'Заказ на складе',
            'Заказ ' || v_order.order_number || ' прибыл на склад', v_order.id);

  return jsonb_build_object('ok', true, 'order_id', v_order.id, 'order_number', v_order.order_number);
end $$;

-- 15.9 ASSIGN PVZ CELL
create or replace function public.fn_assign_pvz_cell(p_order_id uuid, p_cell_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_pvz_id uuid := public.current_pvz_id();
  v_order public.orders;
  v_cell public.pvz_cells;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_pvz_id is null then raise exception 'NOT_PVZ_EMPLOYEE'; end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_order.pvz_id <> v_pvz_id then raise exception 'WRONG_PVZ'; end if;

  select * into v_cell from public.pvz_cells where id = p_cell_id for update;
  if v_cell is null then raise exception 'CELL_NOT_FOUND'; end if;
  if v_cell.pvz_id <> v_pvz_id then raise exception 'WRONG_PVZ_CELL'; end if;
  if v_cell.status <> 'free' then raise exception 'CELL_NOT_FREE'; end if;

  update public.pvz_cells
    set status='occupied', current_order_id=p_order_id, updated_at=now()
    where id = p_cell_id;

  update public.orders set status='ready_for_customer', updated_at=now() where id = p_order_id;

  insert into public.order_status_history(order_id, old_status, new_status, changed_by, comment)
    values (p_order_id, v_order.status, 'ready_for_customer', v_uid, 'Ячейка: ' || v_cell.cell_number);

  insert into public.notifications(user_id, type, title, message, order_id)
    values (v_order.customer_id, 'ready_for_customer', 'Заказ готов к выдаче',
            'Заказ ' || v_order.order_number || ' ждёт вас в ПВЗ', p_order_id);

  return jsonb_build_object('ok', true, 'cell_number', v_cell.cell_number);
end $$;

-- 15.10 ADMIN: set role
create or replace function public.fn_admin_set_role(p_user_id uuid, p_role text)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if public.current_role() <> 'admin' then raise exception 'NOT_ADMIN'; end if;
  if p_role not in ('customer','seller','pvz_employee','driver','warehouse_employee','admin') then
    raise exception 'INVALID_ROLE';
  end if;
  update public.profiles set role = p_role, updated_at = now() where id = p_user_id;
  return jsonb_build_object('ok', true);
end $$;

-- ============================================================
-- 16. STORAGE
-- ============================================================
insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

drop policy if exists "product_images_read"   on storage.objects;
drop policy if exists "product_images_insert" on storage.objects;
drop policy if exists "product_images_update" on storage.objects;
drop policy if exists "product_images_delete" on storage.objects;

create policy "product_images_read" on storage.objects
  for select to public using (bucket_id = 'product-images');

create policy "product_images_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = public.current_seller_id()::text
  );

create policy "product_images_update" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = public.current_seller_id()::text
  );

create policy "product_images_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = public.current_seller_id()::text
  );

-- ============================================================
-- 17. REALTIME
-- ============================================================
do $$
begin
  begin
    alter publication supabase_realtime add table public.orders;
  exception when duplicate_object then null; end;
  begin
    alter publication supabase_realtime add table public.order_status_history;
  exception when duplicate_object then null; end;
  begin
    alter publication supabase_realtime add table public.notifications;
  exception when duplicate_object then null; end;
  begin
    alter publication supabase_realtime add table public.driver_tasks;
  exception when duplicate_object then null; end;
  begin
    alter publication supabase_realtime add table public.products;
  exception when duplicate_object then null; end;
end $$;

-- ============================================================
-- 18. BOOTSTRAP FIRST ADMIN (run manually)
-- ============================================================
-- 1) Register your admin account via marketplace.html (or signup form)
-- 2) Run this in SQL Editor (replace email):
-- update public.profiles set role='admin' where email='admin@example.com';
-- ============================================================
-- END
-- ============================================================
