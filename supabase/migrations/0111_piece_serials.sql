-- 0111: A unique serial on every individual piece (Round 28).
--   * Goods received (against an order or directly) get one serial per piece, created at the moment of receipt. The serial is an EAN-13
--     starting "21" (our own range; product codes start "20"), so it prints as a normal barcode / QR and cannot clash with anything.
--   * The piece is followed through its life: in stock -> in transit (store transfer) -> in stock, packed -> sold, back after a customer
--     return / RTO, returned to supplier, or written off. Every step is written to an unchangeable log (who, when, where, which document).
--   * Stock that was received before this round has no serials and keeps working by quantity. A rule keeps the two honest: while a store
--     holds labelled pieces, those pieces cannot be sent or returned to a supplier by counting; they have to be scanned.
--   * Marketplace orders ship on the marketplace's own timing, so a shipped order whose pieces were not scanned is never blocked. It is
--     put on the exceptions list ("shipped without scanning") and is cleared by scanning the pieces that left.

alter table purchase_settings add column if not exists serial_tracking boolean not null default true;

create sequence if not exists unit_serial_seq;
create or replace function gen_unit_serial() returns text language plpgsql set search_path = public, pg_temp as $$
declare b text;
begin
  b := '21' || lpad(nextval('unit_serial_seq')::text, 10, '0');
  return b || ean13_check(b);
end $$;

create table if not exists item_units (
  unit_id           uuid primary key default gen_random_uuid(),
  serial            text not null unique,
  product_id        uuid not null references products(product_id),
  state             text not null default 'in_stock' check (state in ('in_stock', 'in_transit', 'packed', 'sold', 'returned_to_supplier', 'lost')),
  warehouse_id      uuid references warehouses(warehouse_id),    -- where it is, or last was
  received_ref_type text,
  received_ref_id   uuid,
  order_id          uuid references orders(order_id),            -- while packed / sold
  transfer_id       uuid references stock_transfers(transfer_id),-- while in transit
  rtv_id            uuid references vendor_returns(rtv_id),
  created_at        timestamptz not null default now(),
  state_at          timestamptz not null default now(),
  label_printed_at  timestamptz
);
create index if not exists iu_product_state on item_units (product_id, warehouse_id, state);
create index if not exists iu_order on item_units (order_id) where order_id is not null;
create index if not exists iu_transfer on item_units (transfer_id) where transfer_id is not null;
create index if not exists iu_received on item_units (received_ref_id) where received_ref_id is not null;

create table if not exists unit_events (
  event_id     uuid primary key default gen_random_uuid(),
  unit_id      uuid not null references item_units(unit_id),
  event        text not null,
  from_state   text,
  to_state     text,
  warehouse_id uuid references warehouses(warehouse_id),
  ref_type     text,
  ref_id       uuid,
  note         text,
  by_user      uuid default auth.uid(),
  at           timestamptz not null default now()
);
create index if not exists ue_unit on unit_events (unit_id, at);

create or replace function trg_unit_events_immutable() returns trigger language plpgsql as $$
begin raise exception 'The history of a piece cannot be changed'; end $$;
drop trigger if exists trg_ue_immutable on unit_events;
create trigger trg_ue_immutable before update or delete on unit_events for each row execute function trg_unit_events_immutable();

alter table item_units enable row level security;
alter table unit_events enable row level security;
drop policy if exists "iu read" on item_units;   create policy "iu read" on item_units  for select to authenticated using ((select has_po_view()) or (select has_orders_write()) or (select has_returns_view()));
drop policy if exists "ue read" on unit_events;  create policy "ue read" on unit_events for select to authenticated using ((select has_po_view()) or (select has_orders_write()) or (select has_returns_view()));
grant select on item_units, unit_events to authenticated;

-- a supplier code may not equal one of our piece serials
create or replace function trg_code_clash() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_table_name = 'product_barcodes' then
    if exists (select 1 from products p where lower(btrim(p.barcode)) = lower(btrim(new.code)) and p.product_id <> new.product_id) then
      raise exception 'The code % already belongs to another product', new.code;
    end if;
    if exists (select 1 from products p where p.internal_code = btrim(new.code)) then
      raise exception 'The code % is one of our own generated barcodes', new.code;
    end if;
    if exists (select 1 from item_units u where u.serial = btrim(new.code)) then
      raise exception 'The code % is the serial of one of our pieces', new.code;
    end if;
  else
    if new.barcode is not null and exists (select 1 from product_barcodes b where lower(btrim(b.code)) = lower(btrim(new.barcode)) and b.product_id <> new.product_id) then
      raise exception 'The code % is already linked to another product', new.barcode;
    end if;
    if new.barcode is not null and exists (select 1 from products p where p.internal_code = btrim(new.barcode) and p.product_id <> new.product_id) then
      raise exception 'The code % is one of our own generated barcodes', new.barcode;
    end if;
    if new.barcode is not null and exists (select 1 from item_units u where u.serial = btrim(new.barcode)) then
      raise exception 'The code % is the serial of one of our pieces', new.barcode;
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------- helpers (not callable by users)
create or replace function unit_move(p_unit uuid, p_state text, p_wh uuid, p_ref_type text, p_ref uuid, p_event text,
                                     p_note text default null, p_order uuid default null, p_transfer uuid default null, p_rtv uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_from text; v_wh uuid;
begin
  select state, coalesce(p_wh, warehouse_id) into v_from, v_wh from item_units where unit_id = p_unit;
  update item_units set state = p_state, warehouse_id = v_wh, order_id = p_order, transfer_id = p_transfer, rtv_id = p_rtv, state_at = now() where unit_id = p_unit;
  insert into unit_events (unit_id, event, from_state, to_state, warehouse_id, ref_type, ref_id, note) values (p_unit, p_event, v_from, p_state, v_wh, p_ref_type, p_ref, p_note);
end $$;

-- the pieces named by a list of scanned serials, locked; refuses unknown or repeated serials
create or replace function unit_take(p_serials text[]) returns setof item_units
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_list text[]; v_n int; v_found int; v_bad text;
begin
  select coalesce(array_agg(s order by s), '{}') into v_list from (select lower(btrim(x)) s from unnest(coalesce(p_serials, '{}')) x where btrim(x) <> '') q;
  v_n := coalesce(array_length(v_list, 1), 0);
  if (select count(distinct s) from unnest(v_list) s) <> v_n then raise exception 'The same piece was scanned twice'; end if;
  select count(*) into v_found from item_units where serial = any(v_list);
  if v_found <> v_n then
    select s into v_bad from unnest(v_list) s where not exists (select 1 from item_units u where u.serial = s) limit 1;
    raise exception 'Serial % is not one of our pieces', v_bad;
  end if;
  return query select * from item_units where serial = any(v_list) order by serial for update;
end $$;

-- labelled pieces in stock at a store can never outnumber the stock counted there
create or replace function unit_assert(p_product uuid, p_wh uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_units int; v_bal numeric;
begin
  select count(*) into v_units from item_units where product_id = p_product and warehouse_id = p_wh and state = 'in_stock';
  select coalesce(quantity, 0) into v_bal from inventory_balances where product_id = p_product and warehouse_id = p_wh;
  if v_units > coalesce(v_bal, 0) then
    raise exception 'Pieces of % carry serial labels (% labelled in stock, % counted). Scan the pieces that are leaving instead of counting them, or fix the difference under Inventory > Piece labels and tracking first.',
      (select sku from products where product_id = p_product), v_units, coalesce(v_bal, 0);
  end if;
end $$;
revoke execute on function unit_move(uuid, text, uuid, text, uuid, text, text, uuid, uuid, uuid), unit_take(text[]), unit_assert(uuid, uuid), gen_unit_serial() from public, anon, authenticated;

-- ---------------------------------------------------------------- pieces appear / change automatically with stock movements
create or replace function trg_units_on_movement() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare n int; q int; k int; v_ord uuid;
begin
  if new.movement_type in ('purchase_receipt', 'direct_receipt') and new.quantity > 0 then
    if coalesce((select serial_tracking from purchase_settings where id = 1), true) then
      n := least(floor(new.quantity), 20000)::int;
      with ins as (
        insert into item_units (serial, product_id, state, warehouse_id, received_ref_type, received_ref_id)
        select gen_unit_serial(), new.product_id, 'in_stock', new.warehouse_id, new.reference_type, new.reference_id from generate_series(1, n)
        returning unit_id)
      insert into unit_events (unit_id, event, to_state, warehouse_id, ref_type, ref_id, note)
      select unit_id, 'created', 'in_stock', new.warehouse_id, new.reference_type, new.reference_id, 'Received into stock' from ins;
    end if;

  elsif new.movement_type = 'sale_dispatch' and new.reference_type = 'order' and new.quantity < 0 then
    q := floor(-new.quantity)::int;
    with pk as (
      select unit_id from item_units where order_id = new.reference_id and product_id = new.product_id and state = 'packed' order by serial limit q for update),
    up as (update item_units u set state = 'sold', state_at = now() from pk where u.unit_id = pk.unit_id returning u.unit_id, u.warehouse_id),
    ev as (insert into unit_events (unit_id, event, from_state, to_state, warehouse_id, ref_type, ref_id, note)
           select unit_id, 'sold', 'packed', 'sold', warehouse_id, 'order', new.reference_id, 'Order shipped' from up returning 1)
    select count(*) into k from ev;
    if k < q and exists (select 1 from item_units where product_id = new.product_id and warehouse_id = new.warehouse_id and state = 'in_stock') then
      perform auto_issue_open('serial_unscanned', 'order', new.reference_id,
        'Shipped without scanning every piece: ' || (q - k) || ' of ' || (select sku from products where product_id = new.product_id) || ' have no serial recorded. Scan the pieces that left (Inventory > Pack an order).');
    end if;

  elsif new.movement_type in ('return_restock', 'rto_restock') and new.quantity > 0 and new.reference_type in ('return', 'rto') then
    v_ord := case new.reference_type when 'return' then (select order_id from returns where return_id = new.reference_id)
                                     else (select order_id from rtos where rto_id = new.reference_id) end;
    if v_ord is not null then
      q := floor(new.quantity)::int;
      with pk as (
        select unit_id from item_units where order_id = v_ord and product_id = new.product_id and state = 'sold' order by serial limit q for update),
      up as (update item_units u set state = 'in_stock', warehouse_id = new.warehouse_id, order_id = null, state_at = now() from pk where u.unit_id = pk.unit_id returning u.unit_id)
      insert into unit_events (unit_id, event, from_state, to_state, warehouse_id, ref_type, ref_id, note)
      select unit_id, 'restocked', 'sold', 'in_stock', new.warehouse_id, new.reference_type, new.reference_id, 'Came back from the customer and restocked' from up;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_inv_units on inventory_transactions;
create trigger trg_inv_units after insert on inventory_transactions for each row execute function trg_units_on_movement();

-- ---------------------------------------------------------------- store transfers: scan the pieces that go and the pieces that arrive
alter function transfer_dispatch(uuid, uuid, jsonb, text, text) rename to _transfer_dispatch_q;
alter function transfer_receive(uuid, jsonb, text) rename to _transfer_receive_q;
alter function transfer_resolve(uuid, text, text) rename to _transfer_resolve_q;
alter function transfer_cancel(uuid, text) rename to _transfer_cancel_q;
revoke execute on function _transfer_dispatch_q(uuid, uuid, jsonb, text, text), _transfer_receive_q(uuid, jsonb, text), _transfer_resolve_q(uuid, text, text), _transfer_cancel_q(uuid, text) from public, anon, authenticated;

create or replace function transfer_dispatch(p_from uuid, p_to uuid, p_lines jsonb, p_ref text default null, p_notes text default null, p_serials text[] default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; u item_units%rowtype; l record; v_cnt int;
begin
  v_id := _transfer_dispatch_q(p_from, p_to, p_lines, p_ref, p_notes);
  for u in select * from unit_take(p_serials) loop
    if u.state <> 'in_stock' or u.warehouse_id is distinct from p_from then
      raise exception 'Piece % is not in stock at the sending store (it is %)', u.serial, replace(u.state, '_', ' ');
    end if;
    if not exists (select 1 from stock_transfer_lines where transfer_id = v_id and product_id = u.product_id) then
      raise exception 'Piece % (%) is not on this transfer', u.serial, (select sku from products where product_id = u.product_id);
    end if;
    perform unit_move(u.unit_id, 'in_transit', null, 'stock_transfer', v_id, 'sent', null, null, v_id);
  end loop;
  for l in select product_id, sum(qty_sent) q from stock_transfer_lines where transfer_id = v_id group by product_id loop
    select count(*) into v_cnt from item_units where transfer_id = v_id and product_id = l.product_id;
    if v_cnt > l.q then raise exception 'More pieces of % were scanned (%) than are being sent (%)', (select sku from products where product_id = l.product_id), v_cnt, l.q; end if;
    perform unit_assert(l.product_id, p_from);
  end loop;
  return v_id;
end $$;

create or replace function transfer_receive(p_id uuid, p_lines jsonb, p_note text default null, p_serials text[] default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t stock_transfers%rowtype; r jsonb; u item_units%rowtype; l record;
begin
  select * into t from stock_transfers where transfer_id = p_id;
  r := _transfer_receive_q(p_id, p_lines, p_note);
  for u in select * from unit_take(p_serials) loop
    if u.state <> 'in_transit' or u.transfer_id is distinct from p_id then
      raise exception 'Piece % is not part of this transfer', u.serial;
    end if;
    perform unit_move(u.unit_id, 'in_stock', t.to_wh, 'stock_transfer', p_id, 'received');
  end loop;
  -- every labelled piece that was sent must be either scanned in, or counted as part of the shortfall
  for l in select product_id, sum(qty_sent) sent, sum(coalesce(qty_received, 0)) got from stock_transfer_lines where transfer_id = p_id group by product_id loop
    if (select count(*) from unit_events e join item_units i on i.unit_id = e.unit_id where e.event = 'received' and e.ref_id = p_id and i.product_id = l.product_id) > l.got then
      raise exception 'More labelled pieces of % were scanned than the quantity counted as arrived', (select sku from products where product_id = l.product_id);
    end if;
    if (select count(*) from item_units where transfer_id = p_id and product_id = l.product_id and state = 'in_transit') > l.sent - l.got then
      raise exception 'Scan the labelled pieces of % that arrived. % labelled pieces are still unscanned, but only % are short.',
        (select sku from products where product_id = l.product_id),
        (select count(*) from item_units where transfer_id = p_id and product_id = l.product_id and state = 'in_transit'), (l.sent - l.got)::int;
    end if;
  end loop;
  return r;
end $$;

create or replace function transfer_resolve(p_id uuid, p_action text, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t stock_transfers%rowtype; u record;
begin
  select * into t from stock_transfers where transfer_id = p_id;
  perform _transfer_resolve_q(p_id, p_action, p_note);
  for u in select unit_id from item_units where transfer_id = p_id and state = 'in_transit' loop
    if p_action = 'return' then perform unit_move(u.unit_id, 'in_stock', t.from_wh, 'stock_transfer', p_id, 'returned_to_sender', btrim(p_note));
    else perform unit_move(u.unit_id, 'lost', null, 'stock_transfer', p_id, 'written_off', btrim(p_note)); end if;
  end loop;
end $$;

create or replace function transfer_cancel(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare t stock_transfers%rowtype; u record;
begin
  select * into t from stock_transfers where transfer_id = p_id;
  perform _transfer_cancel_q(p_id, p_reason);
  for u in select unit_id from item_units where transfer_id = p_id and state = 'in_transit' loop
    perform unit_move(u.unit_id, 'in_stock', t.from_wh, 'stock_transfer', p_id, 'transfer_cancelled', btrim(p_reason));
  end loop;
end $$;

-- ---------------------------------------------------------------- return to supplier
alter function rtv_create(uuid, date, text, text, jsonb) rename to _rtv_create_q;
revoke execute on function _rtv_create_q(uuid, date, text, text, jsonb) from public, anon, authenticated;
create or replace function rtv_create(p_po uuid, p_returned_on date, p_reason text, p_ref text, p_lines jsonb, p_serials text[] default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb; v_id uuid; u item_units%rowtype; l record; v_wh uuid;
begin
  r := _rtv_create_q(p_po, p_returned_on, p_reason, p_ref, p_lines);
  v_id := (r ->> 'rtv_id')::uuid;
  select warehouse_id into v_wh from purchase_orders where po_id = p_po;
  for u in select * from unit_take(p_serials) loop
    if u.state <> 'in_stock' or u.warehouse_id is distinct from v_wh then
      raise exception 'Piece % is not in stock at this warehouse (it is %)', u.serial, replace(u.state, '_', ' ');
    end if;
    if not exists (select 1 from vendor_return_lines where rtv_id = v_id and product_id = u.product_id) then
      raise exception 'Piece % (%) is not on this return', u.serial, (select sku from products where product_id = u.product_id);
    end if;
    perform unit_move(u.unit_id, 'returned_to_supplier', null, 'vendor_return', v_id, 'returned_to_supplier', btrim(p_reason), null, null, v_id);
  end loop;
  for l in select product_id, sum(quantity) q from vendor_return_lines where rtv_id = v_id group by product_id loop
    if (select count(*) from item_units where rtv_id = v_id and product_id = l.product_id) > l.q then
      raise exception 'More pieces of % were scanned than are being returned', (select sku from products where product_id = l.product_id);
    end if;
    perform unit_assert(l.product_id, v_wh);
  end loop;
  return r;
end $$;

-- ---------------------------------------------------------------- packing an order: scan the pieces that go in the parcel
create or replace function order_pack_units(p_order uuid, p_serials text[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o orders%rowtype; u item_units%rowtype; v_need numeric; v_have int; v_disp boolean; v_wh uuid; v_done int := 0; v_open boolean;
begin
  if not (has_orders_write() or has_grn_write()) then raise exception 'Your role cannot pack orders'; end if;
  select * into o from orders where order_id = p_order;
  if not found then raise exception 'Order not found'; end if;
  v_wh := pick_dispatch_warehouse(p_order);
  for u in select * from unit_take(p_serials) loop
    if u.state = 'packed' and u.order_id = p_order then continue; end if;
    if u.state <> 'in_stock' then raise exception 'Piece % cannot be packed: it is %', u.serial, replace(u.state, '_', ' '); end if;
    if not has_warehouse_scope(u.warehouse_id) then raise exception 'Piece % is in a store you are not assigned to', u.serial; end if;
    select coalesce(sum(quantity), 0) into v_need from order_lines where order_id = p_order and product_id = u.product_id;
    if v_need = 0 then raise exception 'Piece % (%) is not on this order', u.serial, (select sku from products where product_id = u.product_id); end if;
    select count(*) into v_have from item_units where order_id = p_order and product_id = u.product_id and state in ('packed', 'sold');
    if v_have >= v_need then raise exception 'All % of % are already scanned for this order', v_need, (select sku from products where product_id = u.product_id); end if;
    v_disp := exists (select 1 from order_dispatch d where d.order_id = p_order and d.product_id = u.product_id);
    if v_disp then
      if u.warehouse_id is distinct from (select d.warehouse_id from order_dispatch d where d.order_id = p_order and d.product_id = u.product_id limit 1) then
        raise exception 'Piece % is at a different store from the one this order shipped from', u.serial; end if;
    elsif u.warehouse_id is distinct from v_wh then
      raise exception 'Piece % is at %, but this order ships from %', u.serial, (select name from warehouses where warehouse_id = u.warehouse_id), (select name from warehouses where warehouse_id = v_wh);
    end if;
    perform unit_move(u.unit_id, case when v_disp then 'sold' else 'packed' end, null, 'order', p_order, case when v_disp then 'sold_after_shipping' else 'packed' end, null, p_order);
    v_done := v_done + 1;
  end loop;
  -- clear the "shipped without scanning" flag once every shipped line is covered
  select exists (select 1 from order_lines ol where ol.order_id = p_order and ol.product_id is not null
                   and exists (select 1 from order_dispatch d where d.order_line_id = ol.order_line_id)
                   and (select count(*) from item_units x where x.order_id = p_order and x.product_id = ol.product_id and x.state = 'sold') < ol.quantity) into v_open;
  if not v_open then perform auto_issue_close('serial_unscanned', 'order', p_order); end if;
  return jsonb_build_object('packed', v_done);
end $$;

create or replace function order_unpack_unit(p_serial text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u item_units%rowtype;
begin
  if not (has_orders_write() or has_grn_write()) then raise exception 'Your role cannot pack orders'; end if;
  select * into u from item_units where serial = lower(btrim(p_serial)) for update;
  if not found then raise exception 'Serial % is not one of our pieces', p_serial; end if;
  if u.state <> 'packed' then raise exception 'Only a packed piece that has not shipped can be taken out of the parcel'; end if;
  perform unit_move(u.unit_id, 'in_stock', null, 'order', u.order_id, 'unpacked');
end $$;

-- ---------------------------------------------------------------- a lost / damaged labelled piece: manager writes it off (stock goes down by one too)
create or replace function unit_write_off(p_serial text, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u item_units%rowtype; v_self boolean;
begin
  if not has_req_decide() then raise exception 'Only a manager can write off a piece'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Write what happened to it'; end if;
  select * into u from item_units where serial = lower(btrim(p_serial)) for update;
  if not found then raise exception 'Serial % is not one of our pieces', p_serial; end if;
  if u.state <> 'in_stock' then raise exception 'Only a piece in stock can be written off (it is %)', replace(u.state, '_', ' '); end if;
  perform record_inventory_movement(u.product_id, u.warehouse_id, 'adjustment', -1, 'unit_write_off', u.unit_id);
  perform unit_move(u.unit_id, 'lost', null, 'unit_write_off', u.unit_id, 'written_off', btrim(p_note));
end $$;

-- ---------------------------------------------------------------- scanner lookup (serials are not kept in the in-memory catalog)
create or replace function unit_lookup(p_codes text[]) returns table (serial text, unit_id uuid, product_id uuid, sku text, product_name text, size text, colour text, state text, warehouse_id uuid, order_id uuid, transfer_id uuid)
language sql stable set search_path = public, pg_temp as $$
  select u.serial, u.unit_id, u.product_id, p.sku, p.name, p.size, p.colour, u.state, u.warehouse_id, u.order_id, u.transfer_id
  from item_units u join products p on p.product_id = u.product_id
  where u.serial = any (select lower(btrim(x)) from unnest(p_codes) x)
$$;

-- stamp serial labels as printed (so the print list shows only what still needs a label)
create or replace function unit_labels_printed(p_units uuid[]) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if not has_grn_write() then raise exception 'Your role cannot print labels'; end if;
  with u as (update item_units set label_printed_at = coalesce(label_printed_at, now()) where unit_id = any(p_units) returning unit_id)
  select count(*) into n from u;
  return n;
end $$;
revoke execute on function unit_labels_printed(uuid[]) from public, anon;
grant execute on function unit_labels_printed(uuid[]) to authenticated;

-- ---------------------------------------------------------------- views
create or replace view unit_stock_check with (security_invoker = true) as
select b.product_id, b.warehouse_id, b.quantity as counted,
       coalesce(c.labelled, 0) as labelled, b.quantity - coalesce(c.labelled, 0) as unlabelled
from inventory_balances b
left join (select product_id, warehouse_id, count(*) labelled from item_units where state = 'in_stock' group by 1, 2) c on c.product_id = b.product_id and c.warehouse_id = b.warehouse_id
where coalesce(c.labelled, 0) > 0;
grant select on unit_stock_check to authenticated;

revoke execute on function transfer_dispatch(uuid, uuid, jsonb, text, text, text[]), transfer_receive(uuid, jsonb, text, text[]), transfer_resolve(uuid, text, text), transfer_cancel(uuid, text),
  rtv_create(uuid, date, text, text, jsonb, text[]), order_pack_units(uuid, text[]), order_unpack_unit(text), unit_write_off(text, text), unit_lookup(text[]) from public, anon;
grant execute on function transfer_dispatch(uuid, uuid, jsonb, text, text, text[]), transfer_receive(uuid, jsonb, text, text[]), transfer_resolve(uuid, text, text), transfer_cancel(uuid, text),
  rtv_create(uuid, date, text, text, jsonb, text[]), order_pack_units(uuid, text[]), order_unpack_unit(text), unit_write_off(text, text), unit_lookup(text[]) to authenticated;
