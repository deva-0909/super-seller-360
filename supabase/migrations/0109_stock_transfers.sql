-- 0109: Store-to-store stock transfers (Round 25).
--   Dispatch at the sending store (stock leaves it at once and shows as "in transit"), receive at the other store (stock is added only for
--   what actually arrived). The person receiving cannot be the one who sent. A shortfall must be explained and then settled by a manager:
--   send the missing goods back to the sending store, or write them off.

alter table inventory_transactions drop constraint if exists inventory_transactions_movement_type_check;
alter table inventory_transactions add constraint inventory_transactions_movement_type_check
  check (movement_type in ('return_restock', 'rto_restock', 'sale_dispatch', 'adjustment', 'initial_stock', 'purchase_receipt', 'direct_receipt', 'purchase_return',
                           'transfer_out', 'transfer_in', 'transfer_return'));

create sequence if not exists stock_transfer_seq;
create table if not exists stock_transfers (
  transfer_id   uuid primary key default gen_random_uuid(),
  transfer_no   text not null unique,
  from_wh       uuid not null references warehouses(warehouse_id),
  to_wh         uuid not null references warehouses(warehouse_id),
  status        text not null default 'in_transit' check (status in ('in_transit', 'received', 'received_short', 'resolved', 'cancelled')),
  ref_no        text,                       -- gate pass / challan
  notes         text,
  dispatched_by uuid default auth.uid(),
  dispatched_at timestamptz not null default now(),
  received_by   uuid,
  received_at   timestamptz,
  receive_note  text,
  resolution    text check (resolution in ('returned', 'written_off')),
  resolved_by   uuid,
  resolved_at   timestamptz,
  resolve_note  text,
  check (from_wh <> to_wh)
);
create table if not exists stock_transfer_lines (
  line_id      uuid primary key default gen_random_uuid(),
  transfer_id  uuid not null references stock_transfers(transfer_id) on delete cascade,
  product_id   uuid not null references products(product_id),
  lot_no       text,
  qty_sent     numeric(14,3) not null check (qty_sent > 0),
  qty_received numeric(14,3) check (qty_received is null or qty_received >= 0)
);
create index if not exists stl_transfer on stock_transfer_lines (transfer_id);
alter table stock_transfers enable row level security;
alter table stock_transfer_lines enable row level security;
drop policy if exists "st read" on stock_transfers;       create policy "st read"  on stock_transfers       for select to authenticated using ((select has_po_view()));
drop policy if exists "stl read" on stock_transfer_lines; create policy "stl read" on stock_transfer_lines  for select to authenticated using ((select has_po_view()));
grant select on stock_transfers, stock_transfer_lines to authenticated;

create or replace view stock_in_transit with (security_invoker = true) as
select l.product_id, t.to_wh as warehouse_id, t.from_wh, sum(l.qty_sent) as qty
from stock_transfer_lines l join stock_transfers t on t.transfer_id = l.transfer_id
where t.status = 'in_transit' group by l.product_id, t.to_wh, t.from_wh;
grant select on stock_in_transit to authenticated;

-- p_lines: [{product_id, quantity, lot_no}]
create or replace function transfer_dispatch(p_from uuid, p_to uuid, p_lines jsonb, p_ref text default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare ln jsonb; v_id uuid; n int := 0; q numeric; v_pid uuid; v_lot text; v_tracked boolean;
begin
  if not has_grn_write() then raise exception 'Only Operations or Warehouse roles can send stock to another store'; end if;
  if p_from is null or p_to is null or p_from = p_to then raise exception 'Choose two different stores'; end if;
  if (select count(*) from warehouses where warehouse_id in (p_from, p_to) and status = 'active') < 2 then raise exception 'Both stores must be active'; end if;
  if not has_warehouse_scope(p_from) then raise exception 'You are not assigned to the sending store'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one item'; end if;
  insert into stock_transfers (transfer_no, from_wh, to_wh, ref_no, notes)
    values ('TR-' || to_char(current_date, 'YYMM') || '-' || lpad(nextval('stock_transfer_seq')::text, 5, '0'), p_from, p_to, nullif(btrim(coalesce(p_ref, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''))
    returning transfer_id into v_id;
  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_pid := nullif(ln ->> 'product_id', '')::uuid;
    q := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    if v_pid is null or not exists (select 1 from products where product_id = v_pid) then raise exception 'Line %: choose a product', n; end if;
    if q <= 0 or q <> trunc(q) or q > 100000 then raise exception 'Line %: quantity must be a whole number between 1 and 100000', n; end if;
    v_lot := nullif(btrim(coalesce(ln ->> 'lot_no', '')), '');
    select lot_tracked into v_tracked from products where product_id = v_pid;
    if coalesce(v_tracked, false) and v_lot is null then raise exception 'Line %: this product is tracked by lot, so a lot number is needed', n; end if;
    insert into stock_transfer_lines (transfer_id, product_id, lot_no, qty_sent) values (v_id, v_pid, v_lot, q);
    perform record_inventory_movement(v_pid, p_from, 'transfer_out', -q, 'stock_transfer', v_id);
  end loop;
  return v_id;
end $$;

-- p_lines: [{line_id, received}]  (a line not listed counts as nothing received)
create or replace function transfer_receive(p_id uuid, p_lines jsonb, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t stock_transfers%rowtype; l stock_transfer_lines%rowtype; v_self boolean; r numeric; v_short boolean := false;
begin
  if not has_grn_write() then raise exception 'Only Operations or Warehouse roles can receive stock'; end if;
  select * into t from stock_transfers where transfer_id = p_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  if t.status <> 'in_transit' then raise exception 'This transfer is already %', t.status; end if;
  if not has_warehouse_scope(t.to_wh) then raise exception 'You are not assigned to the receiving store'; end if;
  select allow_self_approval into v_self from purchase_settings where id = 1;
  if t.dispatched_by = auth.uid() and not coalesce(v_self, false) then raise exception 'You sent this stock, so someone at the receiving store has to receive it'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Enter what arrived'; end if;
  for l in select * from stock_transfer_lines where transfer_id = p_id loop
    r := coalesce((select nullif(e ->> 'received', '')::numeric from jsonb_array_elements(p_lines) e where (e ->> 'line_id')::uuid = l.line_id limit 1), 0);
    if r < 0 or r <> trunc(r) or r > l.qty_sent then raise exception 'Received quantity must be a whole number from 0 to the % sent', l.qty_sent; end if;
    update stock_transfer_lines set qty_received = r where line_id = l.line_id;
    if r > 0 then perform record_inventory_movement(l.product_id, t.to_wh, 'transfer_in', r, 'stock_transfer', p_id); end if;
    if r < l.qty_sent then v_short := true; end if;
  end loop;
  if v_short and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Some stock did not arrive - write what happened'; end if;
  update stock_transfers set status = case when v_short then 'received_short' else 'received' end, received_by = auth.uid(), received_at = now(), receive_note = nullif(btrim(coalesce(p_note, '')), '') where transfer_id = p_id;
  return jsonb_build_object('short', v_short);
end $$;

-- a manager settles a shortfall: p_action 'return' (missing goods go back to the sending store's stock) or 'write_off'
create or replace function transfer_resolve(p_id uuid, p_action text, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t stock_transfers%rowtype; l stock_transfer_lines%rowtype; v_self boolean;
begin
  if not has_req_decide() then raise exception 'Only a manager can settle a shortfall'; end if;
  if p_action not in ('return', 'write_off') then raise exception 'Choose return or write-off'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Write what was found'; end if;
  select * into t from stock_transfers where transfer_id = p_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  if t.status <> 'received_short' then raise exception 'Only a transfer received short can be settled'; end if;
  select allow_self_approval into v_self from purchase_settings where id = 1;
  if auth.uid() in (t.dispatched_by, t.received_by) and not coalesce(v_self, false) then raise exception 'You sent or received this transfer, so another manager has to settle it'; end if;
  if p_action = 'return' then
    for l in select * from stock_transfer_lines where transfer_id = p_id and qty_received < qty_sent loop
      perform record_inventory_movement(l.product_id, t.from_wh, 'transfer_return', l.qty_sent - l.qty_received, 'stock_transfer', p_id);
    end loop;
  end if;
  update stock_transfers set status = 'resolved', resolution = case when p_action = 'return' then 'returned' else 'written_off' end,
         resolved_by = auth.uid(), resolved_at = now(), resolve_note = btrim(p_note) where transfer_id = p_id;
end $$;

-- called off before it arrived: the stock goes back to the sending store
create or replace function transfer_cancel(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t stock_transfers%rowtype; l stock_transfer_lines%rowtype;
begin
  select * into t from stock_transfers where transfer_id = p_id for update;
  if not found then raise exception 'Transfer not found'; end if;
  if t.status <> 'in_transit' then raise exception 'Only a transfer still on its way can be cancelled'; end if;
  if not (t.dispatched_by = auth.uid() or has_req_decide()) then raise exception 'Only the sender or a manager can cancel it'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  for l in select * from stock_transfer_lines where transfer_id = p_id loop
    perform record_inventory_movement(l.product_id, t.from_wh, 'transfer_return', l.qty_sent, 'stock_transfer', p_id);
  end loop;
  update stock_transfers set status = 'cancelled', resolve_note = btrim(p_reason), resolved_by = auth.uid(), resolved_at = now() where transfer_id = p_id;
end $$;

revoke execute on function transfer_dispatch(uuid, uuid, jsonb, text, text), transfer_receive(uuid, jsonb, text), transfer_resolve(uuid, text, text), transfer_cancel(uuid, text) from public, anon;
grant execute on function transfer_dispatch(uuid, uuid, jsonb, text, text), transfer_receive(uuid, jsonb, text), transfer_resolve(uuid, text, text), transfer_cancel(uuid, text) to authenticated;
