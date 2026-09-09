-- ============================================================================
-- Super Seller 360 — Phase 3: Returns, RTO, Inventory
--
-- BR-002: Return must reference original order.
-- BR-003: Saleable stock changes only after physical receipt AND inspection
--         with a "good" disposition — never on refund/return-initiation.
-- BR-004: RTO is tracked as a distinct entity from customer returns, never
--         conflated (separate tables, separate movement_type values).
-- WF-003: Requested -> Approved -> Pickup -> In Transit -> Received ->
--         Inspection -> Restock/Quarantine/Claim
-- WF-004: Failed delivery -> RTO initiated -> In Transit -> Received ->
--         Inspection -> Restock/Quarantine/Claim
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. RETURNS
-- ---------------------------------------------------------------------------
create table returns (
  return_id          uuid primary key default gen_random_uuid(),
  order_id           uuid not null references orders(order_id),
  return_reason      text,
  status             text not null default 'requested'
                       check (status in ('requested','approved','pickup','in_transit','received','inspected','restocked','quarantined','claimed','rejected')),
  pickup_date        date,
  received_date      date,
  inspection_result  text check (inspection_result in ('good','damaged','wrong_item','missing')),
  restock_status     text not null default 'pending'
                       check (restock_status in ('pending','restocked','quarantined','claimed')),
  refund_status      text not null default 'pending'
                       check (refund_status in ('pending','processing','refunded','rejected')),
  warehouse_id       uuid references warehouses(warehouse_id),
  created_by         uuid references user_profiles(user_id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. RTO  (kept fully separate from returns — BR-004)
-- ---------------------------------------------------------------------------
create table rtos (
  rto_id             uuid primary key default gen_random_uuid(),
  order_id           uuid not null references orders(order_id),
  awb                text,
  reason             text,
  status             text not null default 'initiated'
                       check (status in ('initiated','in_transit','received','inspected','restocked','quarantined','claimed')),
  received_date      date,
  inspection_result  text check (inspection_result in ('good','damaged','wrong_item','missing')),
  warehouse_id       uuid references warehouses(warehouse_id),
  created_by         uuid references user_profiles(user_id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. INVENTORY — transactions (immutable log) + balances (derived, fast-read)
-- ---------------------------------------------------------------------------
create table inventory_transactions (
  inventory_txn_id  uuid primary key default gen_random_uuid(),
  product_id        uuid not null references products(product_id),
  warehouse_id      uuid not null references warehouses(warehouse_id),
  movement_type     text not null
                      check (movement_type in ('return_restock','rto_restock','sale_dispatch','adjustment','initial_stock')),
  quantity          numeric(10,2) not null,  -- positive = stock in, negative = stock out
  reference_type    text,
  reference_id      uuid,
  before_qty        numeric(10,2) not null,
  after_qty         numeric(10,2) not null,
  created_by        uuid references user_profiles(user_id),
  created_at        timestamptz not null default now()
);

create table inventory_balances (
  product_id    uuid not null references products(product_id),
  warehouse_id  uuid not null references warehouses(warehouse_id),
  quantity      numeric(10,2) not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (product_id, warehouse_id)
);

create trigger trg_returns_updated_at before update on returns
  for each row execute function set_updated_at();
create trigger trg_rtos_updated_at before update on rtos
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. record_inventory_movement — the ONLY path that changes inventory_balances.
--    Every call is logged in inventory_transactions with before/after, so
--    every stock change is traceable to source, owner, and timestamp.
-- ---------------------------------------------------------------------------
create or replace function record_inventory_movement(
  p_product_id uuid, p_warehouse_id uuid, p_movement_type text,
  p_quantity numeric, p_reference_type text, p_reference_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_before numeric;
  v_after numeric;
  v_txn_id uuid;
begin
  insert into inventory_balances (product_id, warehouse_id, quantity)
  values (p_product_id, p_warehouse_id, 0)
  on conflict (product_id, warehouse_id) do nothing;

  select quantity into v_before from inventory_balances
    where product_id = p_product_id and warehouse_id = p_warehouse_id
    for update;

  v_after := v_before + p_quantity;
  if v_after < 0 then
    raise exception 'Insufficient stock: % available, % requested', v_before, -p_quantity;
  end if;

  update inventory_balances set quantity = v_after, updated_at = now()
    where product_id = p_product_id and warehouse_id = p_warehouse_id;

  insert into inventory_transactions
    (product_id, warehouse_id, movement_type, quantity, reference_type, reference_id, before_qty, after_qty, created_by)
  values
    (p_product_id, p_warehouse_id, p_movement_type, p_quantity, p_reference_type, p_reference_id, v_before, v_after, auth.uid())
  returning inventory_txn_id into v_txn_id;

  return v_txn_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. disposition_return / disposition_rto — the single controlled path that
--    records an inspection result and its disposition. This is where BR-003
--    is actually enforced: stock is credited ONLY when disposition='restock'
--    AND inspection_result='good'. Quarantine/claim never touch stock.
--    (Whole-order return, matching the BRD's Return entity — no ReturnLine
--    table is specified, so a return credits every line of its order.)
-- ---------------------------------------------------------------------------
create or replace function disposition_return(
  p_return_id uuid, p_inspection_result text, p_disposition text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_return returns%rowtype;
  v_line record;
begin
  if not (has_returns_write()) then
    raise exception 'Not authorized to disposition returns';
  end if;
  if p_disposition not in ('restocked','quarantined','claimed') then
    raise exception 'Invalid disposition: %', p_disposition;
  end if;

  select * into v_return from returns where return_id = p_return_id;
  if not found then
    raise exception 'Return % not found', p_return_id;
  end if;
  if v_return.status not in ('received','inspected') then
    raise exception 'Return must be received before it can be dispositioned (current status: %)', v_return.status;
  end if;
  if p_disposition = 'restocked' and v_return.warehouse_id is null then
    raise exception 'A destination warehouse must be set before restocking';
  end if;

  update returns
    set inspection_result = p_inspection_result,
        status = p_disposition,
        restock_status = p_disposition
    where return_id = p_return_id;

  if p_disposition = 'restocked' and p_inspection_result = 'good' then
    for v_line in select product_id, quantity from order_lines where order_id = v_return.order_id loop
      perform record_inventory_movement(
        v_line.product_id, v_return.warehouse_id, 'return_restock',
        v_line.quantity, 'return', p_return_id
      );
    end loop;
  end if;
end;
$$;

create or replace function disposition_rto(
  p_rto_id uuid, p_inspection_result text, p_disposition text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rto rtos%rowtype;
  v_line record;
begin
  if not (has_returns_write()) then
    raise exception 'Not authorized to disposition RTOs';
  end if;
  if p_disposition not in ('restocked','quarantined','claimed') then
    raise exception 'Invalid disposition: %', p_disposition;
  end if;

  select * into v_rto from rtos where rto_id = p_rto_id;
  if not found then
    raise exception 'RTO % not found', p_rto_id;
  end if;
  if v_rto.status not in ('received','inspected') then
    raise exception 'RTO must be received before it can be dispositioned (current status: %)', v_rto.status;
  end if;
  if p_disposition = 'restocked' and v_rto.warehouse_id is null then
    raise exception 'A destination warehouse must be set before restocking';
  end if;

  update rtos
    set inspection_result = p_inspection_result,
        status = p_disposition
    where rto_id = p_rto_id;

  if p_disposition = 'restocked' and p_inspection_result = 'good' then
    for v_line in select product_id, quantity from order_lines where order_id = v_rto.order_id loop
      perform record_inventory_movement(
        v_line.product_id, v_rto.warehouse_id, 'rto_restock',
        v_line.quantity, 'rto', p_rto_id
      );
    end loop;
  end if;
end;
$$;

revoke execute on function record_inventory_movement(uuid,uuid,text,numeric,text,uuid) from anon, authenticated, public;
revoke execute on function disposition_return(uuid,text,text) from anon, public;
grant execute on function disposition_return(uuid,text,text) to authenticated;
revoke execute on function disposition_rto(uuid,text,text) from anon, public;
grant execute on function disposition_rto(uuid,text,text) to authenticated;
