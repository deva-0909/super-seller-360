-- 0104: Scan-based receiving.
--  * barcodes can no longer repeat; a product can carry extra codes (supplier, carton, marketplace) that map to it
--  * lot / batch numbers can be recorded on receipts (per product switch: products.lot_tracked)
--  * goods can be received WITHOUT a purchase order ("stock in": direct purchase, free goods, sample, replacement, not-on-order)
--  * one call posts a scanned receipt: lines against the order, plus off-order items that each need a reason
-- Every stock change still goes through record_inventory_movement (immutable log with who / when / before / after).

-- ---------------------------------------------------------------- 1. barcodes
alter table products add column if not exists lot_tracked boolean not null default false;
update products set barcode = nullif(btrim(barcode), '') where barcode is distinct from nullif(btrim(barcode), '');
create unique index if not exists products_barcode_uq on products (lower(btrim(barcode))) where barcode is not null;

create table if not exists product_barcodes (
  code_id     uuid primary key default gen_random_uuid(),
  product_id  uuid not null references products(product_id) on delete cascade,
  code        text not null check (btrim(code) <> ''),
  kind        text not null default 'supplier' check (kind in ('own', 'supplier', 'carton', 'marketplace')),
  pack_qty    int  not null default 1 check (pack_qty between 1 and 100000),   -- a carton code counts as this many pieces
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create unique index if not exists product_barcodes_code_uq on product_barcodes (lower(btrim(code)));
create index if not exists product_barcodes_product on product_barcodes (product_id);
alter table product_barcodes enable row level security;
drop policy if exists "codes read" on product_barcodes;
create policy "codes read" on product_barcodes for select to authenticated using (true);
grant select on product_barcodes to authenticated;

-- a code may belong to only one product, across both places codes live
create or replace function trg_code_clash() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_table_name = 'product_barcodes' then
    if exists (select 1 from products p where lower(btrim(p.barcode)) = lower(btrim(new.code)) and p.product_id <> new.product_id) then
      raise exception 'The code % already belongs to another product', new.code;
    end if;
  else
    if new.barcode is not null and exists (select 1 from product_barcodes b where lower(btrim(b.code)) = lower(btrim(new.barcode)) and b.product_id <> new.product_id) then
      raise exception 'The code % is already linked to another product', new.barcode;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_code_clash_pb on product_barcodes;
create trigger trg_code_clash_pb before insert or update on product_barcodes for each row execute function trg_code_clash();
drop trigger if exists trg_code_clash_p on products;
create trigger trg_code_clash_p before insert or update of barcode on products for each row execute function trg_code_clash();

-- every code the scanner may meet: own barcode, SKU, and extra codes. One row per code; the screen keeps this in memory while scanning.
create or replace function scan_catalog()
returns table (code text, product_id uuid, sku text, product_name text, size text, colour text, lot_tracked boolean, status text, pack_qty int, kind text)
language sql stable set search_path = public, pg_temp as $$
  select lower(btrim(p.barcode)), p.product_id, p.sku, p.name, p.size, p.colour, p.lot_tracked, p.status, 1, 'barcode' from products p where p.barcode is not null
  union all
  select lower(btrim(p.sku)), p.product_id, p.sku, p.name, p.size, p.colour, p.lot_tracked, p.status, 1, 'sku' from products p
  union all
  select lower(btrim(b.code)), p.product_id, p.sku, p.name, p.size, p.colour, p.lot_tracked, p.status, b.pack_qty, b.kind
    from product_barcodes b join products p on p.product_id = b.product_id
  order by 1, 2, 10
$$;
revoke execute on function scan_catalog() from public, anon;
grant execute on function scan_catalog() to authenticated;

-- link a code met at the dock (supplier's own label, a carton code ...) to a product, once
create or replace function product_code_link(p_code text, p_product uuid, p_kind text default 'supplier', p_pack_qty int default 1) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_code text := btrim(coalesce(p_code, ''));
begin
  if not (has_grn_write() or current_role_name() in ('Super Admin', 'Operations Manager')) then raise exception 'Only Operations or Warehouse roles can link a barcode to a product'; end if;
  if v_code = '' then raise exception 'There is no code to link'; end if;
  if length(v_code) > 64 then raise exception 'That code is too long to be a barcode'; end if;
  if not exists (select 1 from products where product_id = p_product) then raise exception 'Choose the product this code belongs to'; end if;
  if p_kind not in ('own', 'supplier', 'carton', 'marketplace') then raise exception 'Unknown code type'; end if;
  if coalesce(p_pack_qty, 1) < 1 then raise exception 'Pieces per pack must be at least 1'; end if;
  if exists (select 1 from products where lower(btrim(barcode)) = lower(v_code) or lower(btrim(sku)) = lower(v_code)) then
    raise exception 'That code is already a barcode or SKU of a product';
  end if;
  insert into product_barcodes (product_id, code, kind, pack_qty) values (p_product, v_code, p_kind, coalesce(p_pack_qty, 1)) returning code_id into v_id;
  return v_id;
end $$;
revoke execute on function product_code_link(text, uuid, text, int) from public, anon;
grant execute on function product_code_link(text, uuid, text, int) to authenticated;

-- ---------------------------------------------------------------- 2. lots on order receipts
alter table goods_receipt_lines add column if not exists lot_no text;
alter table goods_receipt_lines add column if not exists lot_expiry date;
alter table goods_receipts add column if not exists via text not null default 'manual' check (via in ('manual', 'scan'));

create or replace function grn_create(p_po uuid, p_received_on date, p_challan text, p_lines jsonb, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; ln jsonb; v_g uuid; v_no text; l purchase_order_lines%rowtype; a numeric; r numeric; v_recv numeric; v_any boolean := false; v_open int;
  v_lot text; v_exp date; v_tracked boolean;
begin
  if not has_grn_write() then raise exception 'Only Operations or Warehouse roles can receive goods'; end if;
  select * into p from purchase_orders where po_id = p_po for update;
  if not found then raise exception 'Order not found'; end if;
  if p.status not in ('approved', 'part_received') then raise exception 'Goods can be received only against an approved order (this one is %)', p.status; end if;
  if not has_warehouse_scope(p.warehouse_id) then raise exception 'You are not assigned to this warehouse'; end if;
  if p_received_on is null or p_received_on > current_date then raise exception 'The receipt date cannot be empty or in the future'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Enter what was received'; end if;
  v_no := 'GRN-' || to_char(p_received_on, 'YYMM') || '-' || lpad(nextval('grn_seq')::text, 5, '0');
  insert into goods_receipts (grn_no, po_id, warehouse_id, received_on, challan_no, notes) values (v_no, p_po, p.warehouse_id, p_received_on, nullif(btrim(coalesce(p_challan, '')), ''), nullif(btrim(coalesce(p_notes, '')), ''))
    returning grn_id into v_g;
  for ln in select * from jsonb_array_elements(p_lines) loop
    a := coalesce(nullif(ln ->> 'accepted', '')::numeric, 0); r := coalesce(nullif(ln ->> 'rejected', '')::numeric, 0);
    if a = 0 and r = 0 then continue; end if;
    if a < 0 or r < 0 or a <> trunc(a) or r <> trunc(r) then raise exception 'Quantities must be whole numbers, zero or more'; end if;
    select * into l from purchase_order_lines where po_line_id = (ln ->> 'po_line_id')::uuid and po_id = p_po;
    if not found then raise exception 'A line does not belong to this order'; end if;
    select coalesce(sum(qty_accepted + qty_rejected), 0) into v_recv from goods_receipt_lines where po_line_id = l.po_line_id;
    if v_recv + a + r > l.quantity * 1.10 then
      raise exception 'Line %: that would be % received against % ordered. More than 10 percent over the order needs a new order.', l.line_no, v_recv + a + r, l.quantity;
    end if;
    v_lot := nullif(btrim(coalesce(ln ->> 'lot_no', '')), ''); v_exp := nullif(ln ->> 'lot_expiry', '')::date;
    select lot_tracked into v_tracked from products where product_id = l.product_id;
    if coalesce(v_tracked, false) and v_lot is null then raise exception 'Line %: this product is tracked by lot, so a lot number is needed', l.line_no; end if;
    insert into goods_receipt_lines (grn_id, po_line_id, product_id, qty_accepted, qty_rejected, lot_no, lot_expiry) values (v_g, l.po_line_id, l.product_id, a, r, v_lot, v_exp);
    if a > 0 then perform record_inventory_movement(l.product_id, p.warehouse_id, 'purchase_receipt', a, 'goods_receipt', v_g); end if;
    v_any := true;
  end loop;
  if not v_any then raise exception 'Enter the quantity received on at least one line'; end if;
  select count(*) into v_open from po_line_status s where s.po_id = p_po and s.received_qty + s.rejected_qty < s.quantity;
  update purchase_orders set status = case when v_open = 0 then 'received' else 'part_received' end where po_id = p_po;
  return v_g;
end $$;

-- ---------------------------------------------------------------- 3. stock in without an order
create sequence if not exists stock_in_seq;
create table if not exists stock_ins (
  stock_in_id  uuid primary key default gen_random_uuid(),
  si_no        text not null unique,
  warehouse_id uuid not null references warehouses(warehouse_id),
  supplier_id  uuid references suppliers(supplier_id),
  po_id        uuid references purchase_orders(po_id),     -- set when these items arrived with an order but were not on it
  grn_id       uuid references goods_receipts(grn_id),
  received_on  date not null default current_date,
  ref_no       text,                                        -- challan / delivery note
  reason       text not null check (reason in ('direct_purchase', 'free_goods', 'sample', 'supplier_replacement', 'not_on_order', 'other')),
  reason_note  text,
  via          text not null default 'manual' check (via in ('manual', 'scan', 'paste', 'upload')),
  notes        text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create table if not exists stock_in_lines (
  line_id      uuid primary key default gen_random_uuid(),
  stock_in_id  uuid not null references stock_ins(stock_in_id) on delete cascade,
  product_id   uuid not null references products(product_id),
  quantity     numeric(14,3) not null check (quantity > 0),
  lot_no       text,
  lot_expiry   date,
  scanned_code text,
  unit_cost    numeric(14,2) check (unit_cost is null or unit_cost >= 0),
  note         text
);
create index if not exists stock_in_lines_si on stock_in_lines (stock_in_id);
create index if not exists stock_ins_date on stock_ins (received_on desc);
alter table stock_ins enable row level security;
alter table stock_in_lines enable row level security;
drop policy if exists "stock in read" on stock_ins;       create policy "stock in read"   on stock_ins       for select to authenticated using (has_po_view());
drop policy if exists "stock in lines read" on stock_in_lines; create policy "stock in lines read" on stock_in_lines for select to authenticated using (has_po_view());
grant select on stock_ins, stock_in_lines to authenticated;

alter table inventory_transactions drop constraint if exists inventory_transactions_movement_type_check;
alter table inventory_transactions add constraint inventory_transactions_movement_type_check
  check (movement_type in ('return_restock', 'rto_restock', 'sale_dispatch', 'adjustment', 'initial_stock', 'purchase_receipt', 'direct_receipt'));

-- stock-age view: a direct receipt counts as inbound stock, like an order receipt
create or replace view sku_stock_aging with (security_invoker = true) as
with inbound as (
  select t.product_id, max(coalesce(g.received_on::timestamptz, t.created_at)) last_inbound_at
  from inventory_transactions t
  left join goods_receipts g on t.movement_type = 'purchase_receipt' and t.reference_type = 'goods_receipt' and g.grn_id = t.reference_id
  where t.movement_type in ('initial_stock', 'purchase_receipt', 'direct_receipt') or (t.movement_type = 'adjustment' and t.quantity > 0)
  group by t.product_id
), stock as (
  select product_id, sum(quantity) on_hand from inventory_balances group by product_id
)
select p.product_id, p.sku, p.name, p.category, p.status, p.cost_price, p.stock_timeout_days,
  coalesce(s.on_hand, 0) as on_hand, i.last_inbound_at,
  (i.last_inbound_at::date + p.stock_timeout_days) as timeout_date,
  ((i.last_inbound_at::date + p.stock_timeout_days) - current_date) as days_left,
  coalesce(s.on_hand, 0) * coalesce(p.cost_price, 0) as stock_cost_value,
  case when coalesce(s.on_hand,0) <= 0 then 'no_stock'
       when p.stock_timeout_days is null or i.last_inbound_at is null then 'no_limit'
       when ((i.last_inbound_at::date + p.stock_timeout_days) - current_date) < 0 then 'overdue'
       when ((i.last_inbound_at::date + p.stock_timeout_days) - current_date) <= 15 then 'nearing'
       else 'ok' end as timeout_state
from products p left join stock s using (product_id) left join inbound i using (product_id);
grant select on sku_stock_aging to authenticated;

-- shared posting step (not callable from the app)
create or replace function stock_in_post(p_warehouse uuid, p_supplier uuid, p_po uuid, p_grn uuid, p_received_on date, p_ref text, p_reason text, p_reason_note text, p_via text, p_lines jsonb, p_notes text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare w warehouses%rowtype; ln jsonb; v_id uuid; v_no text; q numeric; v_pid uuid; v_lot text; v_tracked boolean; v_n int := 0; v_note text; v_cost numeric;
begin
  if not has_grn_write() then raise exception 'Only Operations or Warehouse roles can receive goods'; end if;
  select * into w from warehouses where warehouse_id = p_warehouse;
  if not found or w.status <> 'active' then raise exception 'Choose an active warehouse'; end if;
  if not has_warehouse_scope(p_warehouse) then raise exception 'You are not assigned to this warehouse'; end if;
  if p_supplier is not null and not exists (select 1 from suppliers where supplier_id = p_supplier and status = 'active') then raise exception 'That supplier is not active'; end if;
  if p_received_on is null or p_received_on > current_date then raise exception 'The receipt date cannot be empty or in the future'; end if;
  if p_reason not in ('direct_purchase', 'free_goods', 'sample', 'supplier_replacement', 'not_on_order', 'other') then raise exception 'Choose why this stock is coming in'; end if;
  if p_reason in ('other', 'not_on_order') and nullif(btrim(coalesce(p_reason_note, '')), '') is null then raise exception 'Write the reason for this stock-in'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one item'; end if;
  if jsonb_array_length(p_lines) > 1000 then raise exception 'One stock-in can hold up to 1,000 lines. Split it into two.'; end if;
  v_no := 'SI-' || to_char(p_received_on, 'YYMM') || '-' || lpad(nextval('stock_in_seq')::text, 5, '0');
  insert into stock_ins (si_no, warehouse_id, supplier_id, po_id, grn_id, received_on, ref_no, reason, reason_note, via, notes)
    values (v_no, p_warehouse, p_supplier, p_po, p_grn, p_received_on, nullif(btrim(coalesce(p_ref, '')), ''), p_reason, nullif(btrim(coalesce(p_reason_note, '')), ''), coalesce(p_via, 'manual'), nullif(btrim(coalesce(p_notes, '')), ''))
    returning stock_in_id into v_id;
  for ln in select * from jsonb_array_elements(p_lines) loop
    v_n := v_n + 1;
    v_pid := nullif(ln ->> 'product_id', '')::uuid;
    q := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    if v_pid is null or not exists (select 1 from products where product_id = v_pid) then raise exception 'Line %: choose a product', v_n; end if;
    if q <= 0 or q <> trunc(q) or q > 100000 then raise exception 'Line %: quantity must be a whole number between 1 and 100000', v_n; end if;
    v_lot := nullif(btrim(coalesce(ln ->> 'lot_no', '')), '');
    select lot_tracked into v_tracked from products where product_id = v_pid;
    if coalesce(v_tracked, false) and v_lot is null then raise exception 'Line %: this product is tracked by lot, so a lot number is needed', v_n; end if;
    v_note := nullif(btrim(coalesce(ln ->> 'note', '')), '');
    if p_reason = 'not_on_order' and v_note is null then raise exception 'Line %: say why this item is not on the order', v_n; end if;
    v_cost := nullif(ln ->> 'unit_cost', '')::numeric;
    insert into stock_in_lines (stock_in_id, product_id, quantity, lot_no, lot_expiry, scanned_code, unit_cost, note)
      values (v_id, v_pid, q, v_lot, nullif(ln ->> 'lot_expiry', '')::date, nullif(btrim(coalesce(ln ->> 'code', '')), ''), v_cost, v_note);
    perform record_inventory_movement(v_pid, p_warehouse, 'direct_receipt', q, 'stock_in', v_id);
  end loop;
  return v_id;
end $$;

create or replace function stock_in_create(p_warehouse uuid, p_supplier uuid, p_received_on date, p_ref text, p_reason text, p_reason_note text, p_via text, p_lines jsonb, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_reason = 'not_on_order' then raise exception 'Items that arrive with an order are added from the order''s receiving screen'; end if;
  return stock_in_post(p_warehouse, p_supplier, null, null, p_received_on, p_ref, p_reason, p_reason_note, p_via, p_lines, p_notes);
end $$;

-- one submit for a scanned receipt: lines against the order, plus any item that was not on it (each needs a reason)
create or replace function grn_create_scanned(p_po uuid, p_received_on date, p_challan text, p_lines jsonb, p_extras jsonb default '[]'::jsonb, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_grn uuid; v_si uuid; p purchase_orders%rowtype; v_has_lines boolean;
begin
  if not has_grn_write() then raise exception 'Only Operations or Warehouse roles can receive goods'; end if;
  select * into p from purchase_orders where po_id = p_po;
  if not found then raise exception 'Order not found'; end if;
  v_has_lines := jsonb_typeof(p_lines) = 'array' and exists (
    select 1 from jsonb_array_elements(p_lines) e where coalesce(nullif(e ->> 'accepted', '')::numeric, 0) + coalesce(nullif(e ->> 'rejected', '')::numeric, 0) > 0);
  if v_has_lines then
    v_grn := grn_create(p_po, p_received_on, p_challan, p_lines, p_notes);
    update goods_receipts set via = 'scan' where grn_id = v_grn;
  end if;
  if jsonb_typeof(p_extras) = 'array' and jsonb_array_length(p_extras) > 0 then
    v_si := stock_in_post(p.warehouse_id, p.supplier_id, p_po, v_grn, p_received_on, p_challan, 'not_on_order', 'Arrived with ' || p.po_no || ' but not on the order', 'scan', p_extras, p_notes);
  end if;
  if v_grn is null and v_si is null then raise exception 'Scan or enter at least one item'; end if;
  return jsonb_build_object('grn_id', v_grn, 'stock_in_id', v_si);
end $$;

revoke execute on function stock_in_post(uuid, uuid, uuid, uuid, date, text, text, text, text, jsonb, text) from public, anon, authenticated;
revoke execute on function stock_in_create(uuid, uuid, date, text, text, text, text, jsonb, text), grn_create_scanned(uuid, date, text, jsonb, jsonb, text) from public, anon;
grant execute on function stock_in_create(uuid, uuid, date, text, text, text, text, jsonb, text), grn_create_scanned(uuid, date, text, jsonb, jsonb, text) to authenticated;
revoke execute on function grn_create(uuid, date, text, jsonb, text) from public, anon;
grant execute on function grn_create(uuid, date, text, jsonb, text) to authenticated;
