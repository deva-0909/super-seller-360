-- 0071: Purchase orders, goods receipt (GRN), three-way match to the supplier bill, and automatic re-order suggestions.
--
--   Flow: reorder suggestion -> purchase order (needs approval above the limit) -> goods received at a warehouse (stock goes up, shortfalls and
--   rejects recorded) -> supplier bill created FROM the order (only what was received and not yet billed; price differences are shown) -> payment.
--   Posted accounting is unchanged: the bill is what posts. Stock quantity moves on receipt; stock value in the books moves with the bill.

alter table products add column if not exists reorder_level   numeric(12,2) check (reorder_level is null or reorder_level >= 0);
alter table products add column if not exists reorder_qty     numeric(12,2) check (reorder_qty is null or reorder_qty > 0);
alter table products add column if not exists lead_time_days  int check (lead_time_days is null or lead_time_days between 0 and 365);
alter table products add column if not exists preferred_supplier_id uuid references suppliers(supplier_id) on delete set null;
alter table purchase_settings add column if not exists po_approval_limit numeric(14,2) not null default 50000 check (po_approval_limit >= 0);
alter table purchase_settings add column if not exists reorder_cover_days int not null default 15 check (reorder_cover_days between 1 and 180);

alter table inventory_transactions drop constraint if exists inventory_transactions_movement_type_check;
alter table inventory_transactions add constraint inventory_transactions_movement_type_check
  check (movement_type in ('return_restock', 'rto_restock', 'sale_dispatch', 'adjustment', 'initial_stock', 'purchase_receipt'));

create or replace function has_po_write() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Operations Manager', 'Finance Manager', 'Accountant'), false)
$$;
create or replace function has_grn_write() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Operations Manager', 'Warehouse Manager'), false)
$$;

create sequence if not exists purchase_order_seq;
create sequence if not exists grn_seq;

create table if not exists purchase_orders (
  po_id         uuid primary key default gen_random_uuid(),
  po_no         text not null unique,
  supplier_id   uuid not null references suppliers(supplier_id),
  warehouse_id  uuid not null references warehouses(warehouse_id),
  order_date    date not null default current_date,
  expected_date date,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'part_received', 'received', 'closed', 'rejected', 'cancelled')),
  taxable_value numeric(14,2) not null default 0,
  tax_value     numeric(14,2) not null default 0,
  total         numeric(14,2) not null default 0,
  notes         text,
  decision_note text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  decided_by    uuid,
  decided_at    timestamptz
);
create table if not exists purchase_order_lines (
  po_line_id uuid primary key default gen_random_uuid(),
  po_id      uuid not null references purchase_orders(po_id) on delete cascade,
  line_no    int not null,
  product_id uuid not null references products(product_id),
  quantity   numeric(14,3) not null check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  gst_rate   numeric(5,2) not null default 0,
  unique (po_id, line_no)
);
create table if not exists goods_receipts (
  grn_id       uuid primary key default gen_random_uuid(),
  grn_no       text not null unique,
  po_id        uuid not null references purchase_orders(po_id),
  warehouse_id uuid not null references warehouses(warehouse_id),
  received_on  date not null default current_date,
  challan_no   text,
  notes        text,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create table if not exists goods_receipt_lines (
  grn_line_id  uuid primary key default gen_random_uuid(),
  grn_id       uuid not null references goods_receipts(grn_id) on delete cascade,
  po_line_id   uuid not null references purchase_order_lines(po_line_id),
  product_id   uuid not null references products(product_id),
  qty_accepted numeric(14,3) not null check (qty_accepted >= 0),
  qty_rejected numeric(14,3) not null default 0 check (qty_rejected >= 0),
  check (qty_accepted + qty_rejected > 0)
);
alter table purchase_bills      add column if not exists po_id uuid references purchase_orders(po_id);
alter table purchase_bill_lines add column if not exists po_line_id uuid references purchase_order_lines(po_line_id);
create index if not exists po_lines_po on purchase_order_lines (po_id);
create index if not exists grn_lines_pol on goods_receipt_lines (po_line_id);

alter table purchase_orders      enable row level security;
alter table purchase_order_lines enable row level security;
alter table goods_receipts       enable row level security;
alter table goods_receipt_lines  enable row level security;
create or replace function has_po_view() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Accountant', 'Warehouse Manager', 'Auditor'), false)
$$;
drop policy if exists "po read" on purchase_orders;      create policy "po read"   on purchase_orders      for select to authenticated using (has_po_view());
drop policy if exists "pol read" on purchase_order_lines; create policy "pol read"  on purchase_order_lines for select to authenticated using (has_po_view());
drop policy if exists "grn read" on goods_receipts;      create policy "grn read"  on goods_receipts      for select to authenticated using (has_po_view());
drop policy if exists "grnl read" on goods_receipt_lines; create policy "grnl read" on goods_receipt_lines for select to authenticated using (has_po_view());
grant select on purchase_orders, purchase_order_lines, goods_receipts, goods_receipt_lines to authenticated;

-- ---------------------------------------------------------------- what is received / billed per order line
create or replace view po_line_status with (security_invoker = true) as
select l.po_line_id, l.po_id, l.line_no, l.product_id, l.quantity, l.unit_price, l.gst_rate,
       coalesce((select sum(g.qty_accepted) from goods_receipt_lines g where g.po_line_id = l.po_line_id), 0) as received_qty,
       coalesce((select sum(g.qty_rejected) from goods_receipt_lines g where g.po_line_id = l.po_line_id), 0) as rejected_qty,
       coalesce((select sum(bl.quantity) from purchase_bill_lines bl join purchase_bills b on b.bill_id = bl.bill_id
                  where bl.po_line_id = l.po_line_id and b.status in ('pending', 'approved')), 0) as billed_qty
from purchase_order_lines l;
grant select on po_line_status to authenticated;

create or replace view po_unbilled with (security_invoker = true) as
select s.po_id, p.po_no, p.supplier_id, sum(greatest(s.received_qty - s.billed_qty, 0)) as unbilled_qty,
       (select min(g.received_on) from goods_receipts g where g.po_id = s.po_id) as received_on
from po_line_status s join purchase_orders p on p.po_id = s.po_id
where p.status in ('approved', 'part_received', 'received')
group by s.po_id, p.po_no, p.supplier_id;
grant select on po_unbilled to authenticated;

-- ---------------------------------------------------------------- create
create or replace function po_create(p_supplier uuid, p_warehouse uuid, p_lines jsonb, p_expected date default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype; ln jsonb; n int := 0; v_id uuid; v_no text; q numeric; pr numeric; rt numeric; v_tx numeric := 0; v_tax numeric := 0; v_lim numeric; v_status text;
  v_rates numeric[] := array[0, 0.25, 3, 5, 12, 18, 28, 40]; v_pid uuid;
begin
  if not has_po_write() then raise exception 'Only Operations, Finance or Accounts roles can raise a purchase order'; end if;
  select * into s from suppliers where supplier_id = p_supplier;
  if not found then raise exception 'Choose a supplier'; end if;
  if s.status <> 'active' then raise exception 'This supplier is % - it must be approved before orders can be raised', s.status; end if;
  if not exists (select 1 from warehouses where warehouse_id = p_warehouse) then raise exception 'Choose the warehouse the goods will come to'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one line'; end if;
  if p_expected is not null and p_expected < current_date then raise exception 'The expected date cannot be in the past'; end if;
  v_no := 'PO-' || to_char(current_date, 'YYMM') || '-' || lpad(nextval('purchase_order_seq')::text, 5, '0');
  insert into purchase_orders (po_no, supplier_id, warehouse_id, expected_date, notes, status) values (v_no, p_supplier, p_warehouse, p_expected, nullif(btrim(coalesce(p_notes, '')), ''), 'pending')
    returning po_id into v_id;
  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_pid := nullif(ln ->> 'product_id', '')::uuid;
    q := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    pr := coalesce(nullif(ln ->> 'unit_price', '')::numeric, -1);
    rt := coalesce(nullif(ln ->> 'gst_rate', '')::numeric, coalesce((select gst_rate from products where product_id = v_pid), 0));
    if v_pid is null or not exists (select 1 from products where product_id = v_pid) then raise exception 'Line %: choose a product', n; end if;
    if q <= 0 then raise exception 'Line %: quantity must be more than zero', n; end if;
    if q <> trunc(q) then raise exception 'Line %: quantity must be a whole number', n; end if;
    if pr < 0 then raise exception 'Line %: enter the price', n; end if;
    if not (rt = any (v_rates)) then raise exception 'Line %: GST rate % is not one of 0, 0.25, 3, 5, 12, 18, 28, 40', n, rt; end if;
    insert into purchase_order_lines (po_id, line_no, product_id, quantity, unit_price, gst_rate) values (v_id, n, v_pid, q, pr, rt);
    v_tx := v_tx + round(q * pr, 2); v_tax := v_tax + round(round(q * pr, 2) * rt / 100, 2);
  end loop;
  select po_approval_limit into v_lim from purchase_settings where id = 1;
  -- small orders by someone who can approve go straight through; others wait for a second pair of eyes
  v_status := case when v_tx + v_tax <= coalesce(v_lim, 0) and has_purchase_approve() then 'approved' else 'pending' end;
  update purchase_orders set taxable_value = v_tx, tax_value = v_tax, total = v_tx + v_tax, status = v_status,
         decided_by = case when v_status = 'approved' then auth.uid() end, decided_at = case when v_status = 'approved' then now() end where po_id = v_id;
  return v_id;
end $$;

create or replace function po_decide(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; v_self boolean;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve a purchase order'; end if;
  select * into p from purchase_orders where po_id = p_id for update;
  if not found then raise exception 'Order not found'; end if;
  if p.status <> 'pending' then raise exception 'This order is already %', p.status; end if;
  select allow_self_approval into v_self from purchase_settings where id = 1;
  if p.created_by = auth.uid() and not coalesce(v_self, false) then raise exception 'You raised this order, so someone else has to approve it'; end if;
  if not p_approve and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say why the order is rejected'; end if;
  update purchase_orders set status = case when p_approve then 'approved' else 'rejected' end, decision_note = nullif(btrim(coalesce(p_note, '')), ''), decided_by = auth.uid(), decided_at = now() where po_id = p_id;
end $$;

create or replace function po_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype;
begin
  if not has_po_write() then raise exception 'Not authorized'; end if;
  select * into p from purchase_orders where po_id = p_id for update;
  if not found then raise exception 'Order not found'; end if;
  if p.status not in ('pending', 'approved') then raise exception 'Only an order with nothing received can be cancelled. Close it instead.'; end if;
  if exists (select 1 from goods_receipts where po_id = p_id) then raise exception 'Goods were already received against this order. Close it instead.'; end if;
  if p.status = 'approved' and not has_purchase_approve() and p.created_by is distinct from auth.uid() then raise exception 'Only the person who raised it or an approver can cancel an approved order'; end if;
  update purchase_orders set status = 'cancelled' where po_id = p_id;
end $$;

-- close what is still open (supplier will not send the rest)
create or replace function po_close(p_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype;
begin
  if not has_po_write() then raise exception 'Not authorized'; end if;
  select * into p from purchase_orders where po_id = p_id for update;
  if not found then raise exception 'Order not found'; end if;
  if p.status not in ('approved', 'part_received', 'received') then raise exception 'This order is %', p.status; end if;
  update purchase_orders set status = 'closed', decision_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), decision_note) where po_id = p_id;
end $$;

-- ---------------------------------------------------------------- goods receipt
-- p_lines: [{po_line_id, accepted, rejected}]
create or replace function grn_create(p_po uuid, p_received_on date, p_challan text, p_lines jsonb, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; ln jsonb; v_g uuid; v_no text; l purchase_order_lines%rowtype; a numeric; r numeric; v_recv numeric; v_any boolean := false; v_open int;
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
    insert into goods_receipt_lines (grn_id, po_line_id, product_id, qty_accepted, qty_rejected) values (v_g, l.po_line_id, l.product_id, a, r);
    if a > 0 then perform record_inventory_movement(l.product_id, p.warehouse_id, 'purchase_receipt', a, 'goods_receipt', v_g); end if;
    v_any := true;
  end loop;
  if not v_any then raise exception 'Enter the quantity received on at least one line'; end if;
  select count(*) into v_open from po_line_status s where s.po_id = p_po and s.received_qty + s.rejected_qty < s.quantity;
  update purchase_orders set status = case when v_open = 0 then 'received' else 'part_received' end where po_id = p_po;
  return v_g;
end $$;

-- ---------------------------------------------------------------- bill from the order (only received, not yet billed)
create or replace function po_create_bill(p_po uuid, p_invoice_no text, p_invoice_date date, p_bill_date date, p_prices jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; s record; v_lines jsonb := '[]'::jsonb; v_bill uuid; v_ledger uuid; v_var jsonb := '[]'::jsonb; v_price numeric; n int := 0; v_map jsonb := '[]'::jsonb;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can enter a purchase bill'; end if;
  select * into p from purchase_orders where po_id = p_po;
  if not found then raise exception 'Order not found'; end if;
  if p.status not in ('approved', 'part_received', 'received', 'closed') then raise exception 'This order is %', p.status; end if;
  select ledger_id into v_ledger from ledgers where name = 'Inventory - Stock-in-Trade';
  for s in select st.*, pr.name, pr.hsn from po_line_status st join products pr on pr.product_id = st.product_id where st.po_id = p_po order by st.line_no loop
    if s.received_qty - s.billed_qty <= 0 then continue; end if;
    v_price := coalesce(nullif(p_prices ->> s.po_line_id::text, '')::numeric, s.unit_price);
    if v_price <> s.unit_price then
      v_var := v_var || jsonb_build_object('line', s.line_no, 'product', s.name, 'ordered_price', s.unit_price, 'billed_price', v_price);
    end if;
    n := n + 1;
    v_lines := v_lines || jsonb_build_object('description', s.name, 'hsn_code', s.hsn, 'quantity', s.received_qty - s.billed_qty, 'unit_price', v_price, 'gst_rate', s.gst_rate, 'ledger_id', v_ledger);
    v_map := v_map || jsonb_build_object('line_no', n, 'po_line_id', s.po_line_id);
  end loop;
  if n = 0 then raise exception 'Nothing has been received and left unbilled on this order'; end if;
  v_bill := create_purchase_bill(p.supplier_id, p_invoice_no, p_invoice_date, p_bill_date, v_lines, true, null, 'Raised from ' || p.po_no);
  update purchase_bills set po_id = p_po where bill_id = v_bill;
  update purchase_bill_lines bl set po_line_id = (m ->> 'po_line_id')::uuid
    from jsonb_array_elements(v_map) m where bl.bill_id = v_bill and bl.line_no = (m ->> 'line_no')::int;
  return jsonb_build_object('bill_id', v_bill, 'lines', n, 'price_differences', v_var);
end $$;

-- ---------------------------------------------------------------- re-order suggestions
create or replace view reorder_suggestions with (security_invoker = true) as
with stock as (select product_id, sum(quantity) as on_hand from inventory_balances group by product_id),
     res as (select product_id, sum(reserved) as reserved from inventory_reserved group by product_id),
     onord as (select s.product_id, sum(greatest(s.quantity - s.received_qty - s.rejected_qty, 0)) as on_order
               from po_line_status s join purchase_orders p on p.po_id = s.po_id where p.status in ('approved', 'part_received') group by s.product_id),
     sold as (select ol.product_id, sum(ol.quantity) / 30.0 as per_day
              from order_lines ol join orders o on o.order_id = ol.order_id
              where o.order_date >= now() - interval '30 days' and o.fulfilment_status not in ('cancelled', 'rto') and ol.product_id is not null group by ol.product_id)
select p.product_id, p.sku, p.name, p.preferred_supplier_id,
       coalesce(st.on_hand, 0) as on_hand, coalesce(r.reserved, 0) as reserved, coalesce(o.on_order, 0) as on_order,
       round(coalesce(sd.per_day, 0), 2) as sold_per_day,
       coalesce(st.on_hand, 0) - coalesce(r.reserved, 0) + coalesce(o.on_order, 0) as available_after_orders,
       p.reorder_level, p.lead_time_days, p.cost_price,
       case when coalesce(sd.per_day, 0) > 0 then round((coalesce(st.on_hand, 0) - coalesce(r.reserved, 0)) / sd.per_day, 1) end as days_cover,
       (p.status = 'active' and (
          (p.reorder_level is not null and coalesce(st.on_hand, 0) - coalesce(r.reserved, 0) + coalesce(o.on_order, 0) <= p.reorder_level)
          or (p.reorder_level is null and coalesce(sd.per_day, 0) > 0 and p.lead_time_days is not null
              and (coalesce(st.on_hand, 0) - coalesce(r.reserved, 0) + coalesce(o.on_order, 0)) / sd.per_day <= p.lead_time_days)
       )) as needs_reorder,
       greatest(coalesce(p.reorder_qty, ceil(coalesce(sd.per_day, 0) * (coalesce(p.lead_time_days, 7) + (select reorder_cover_days from purchase_settings where id = 1)))
                          - (coalesce(st.on_hand, 0) - coalesce(r.reserved, 0) + coalesce(o.on_order, 0))), 0) as suggested_qty
from products p
left join stock st on st.product_id = p.product_id left join res r on r.product_id = p.product_id
left join onord o on o.product_id = p.product_id left join sold sd on sd.product_id = p.product_id;
grant select on reorder_suggestions to authenticated;

create or replace function po_set_reorder(p_product uuid, p_level numeric, p_qty numeric, p_lead int, p_supplier uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_po_write() then raise exception 'Not authorized'; end if;
  update products set reorder_level = p_level, reorder_qty = p_qty, lead_time_days = p_lead, preferred_supplier_id = p_supplier where product_id = p_product;
end $$;

-- one click: a draft order from the products that need re-ordering for one supplier
create or replace function po_from_reorder(p_supplier uuid, p_warehouse uuid, p_products uuid[]) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_lines jsonb := '[]'::jsonb; r record;
begin
  if not has_po_write() then raise exception 'Not authorized'; end if;
  for r in select rs.product_id, rs.suggested_qty, coalesce(rs.cost_price, 0) as price, pr.gst_rate from reorder_suggestions rs join products pr on pr.product_id = rs.product_id
           where rs.product_id = any (p_products) and rs.suggested_qty > 0 loop
    v_lines := v_lines || jsonb_build_object('product_id', r.product_id, 'quantity', r.suggested_qty, 'unit_price', r.price, 'gst_rate', coalesce(r.gst_rate, 0));
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'None of the chosen products has a quantity to order'; end if;
  return po_create(p_supplier, p_warehouse, v_lines, null, 'Created from re-order suggestions');
end $$;

create or replace view work_queue with (security_invoker = true) as
-- failed automatic steps (stock-out, invoice, cancelled after dispatch)
select 'issue:' || i.issue_id as item_key, 'Automation' as category, case when i.kind = 'cancelled_after_dispatch' then 'medium' else 'high' end as severity,
       case i.kind when 'dispatch_failed' then 'Stock could not be taken out' when 'invoice_failed' then 'Invoice could not be posted' when 'cancelled_after_dispatch' then 'Cancelled after dispatch' else i.kind end as title,
       i.message as detail, '/orders/' || i.entity_id as href, array['Operations Manager', 'Accountant']::text[] as for_roles,
       i.kind as action_kind, i.issue_id as action_id, 1 as n, i.created_at as since
from automation_issues i where i.status = 'open'
union all
select 'rule-errors', 'Accounting', 'high', 'Entries that did not post automatically', count(*) || ' event(s) failed to create their journal entry in the last 30 days. Open the rule activity to see why.',
       '/accounting/rule-book/activity', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from journal_rule_log where status = 'error' and created_at > now() - interval '30 days' having count(*) > 0
union all
select 'bank-unreconciled', 'Bank', case when min(txn_date) < current_date - 7 then 'high' else 'medium' end, 'Bank lines not reconciled', count(*) || ' bank line(s) are waiting to be matched. Oldest: ' || min(txn_date) || '.',
       '/bank/reconcile', array['Accountant']::text[], null, null, count(*)::int, min(txn_date)::timestamptz
from bank_transactions where recon_status in ('unreconciled', 'suggested') and txn_date < current_date - 1 having count(*) > 0
union all
select 'bills-pending', 'Purchases', 'medium', 'Supplier bills waiting for approval', count(*) || ' bill(s) pending. Oldest raised ' || min(created_at)::date || '.',
       '/purchases/bills', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from purchase_bills where status = 'pending' having count(*) > 0 and has_purchase_approve()
union all
select 'bills-overdue', 'Purchases', 'high', 'Supplier bills past their due date', count(*) || ' approved bill(s) are overdue. Oldest due ' || min(due_date) || '.',
       '/purchases/ageing', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(due_date)::timestamptz
from purchase_bills where status = 'approved' and due_date < current_date and net_payable > 0
  and net_payable > coalesce((select sum(a.amount) from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id where a.bill_id = purchase_bills.bill_id and p.status = 'approved'), 0)
having count(*) > 0 and has_accounting_write()
union all
select 'claims-expense', 'Expenses', 'medium', 'Expense claims waiting for a decision', count(*) || ' claim(s) are waiting. Oldest submitted ' || min(submitted_at)::date || '.',
       '/expenses', array['Operations Manager', 'Finance Manager']::text[], null, null, count(*)::int, min(submitted_at)
from expense_claims where status in ('submitted', 'manager_approved') having count(*) > 0 and (has_expense_review() or has_accounting_write())
union all
select 'returns-inspect', 'Returns', case when min(received_date) < current_date - 4 then 'high' else 'medium' end, 'Returns received but not inspected', count(*) || ' return(s) are sitting in the warehouse. Oldest received ' || min(received_date) || '.',
       '/returns', array['Warehouse Manager']::text[], null, null, count(*)::int, min(received_date)::timestamptz
from returns where status = 'received' and has_returns_view() having count(*) > 0
union all
select 'rto-inspect', 'RTO', case when min(received_date) < current_date - 4 then 'high' else 'medium' end, 'RTO parcels received but not inspected', count(*) || ' RTO parcel(s) are waiting. Oldest received ' || min(received_date) || '.',
       '/rto', array['Warehouse Manager']::text[], null, null, count(*)::int, min(received_date)::timestamptz
from rtos where status = 'received' and has_returns_view() having count(*) > 0
union all
select 'settlements-late', 'Settlements', 'high', 'Settlements not received or reconciled', count(*) || ' settlement(s) are still pending a week after their period ended.',
       '/settlements', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, min(period_end)::timestamptz
from settlements where status = 'pending' and period_end < current_date - 7 and has_settlements_view() having count(*) > 0
union all
select 'settlements-short', 'Settlements', 'high', 'Settlements paid short or in excess', count(*) || ' settlement(s) did not match what was expected.',
       '/settlements', array['Finance Manager', 'Claims Manager']::text[], null, null, count(*)::int, min(created_at)
from settlements where status in ('short_pay', 'excess') and has_settlements_view() having count(*) > 0
union all
select 'cod-late', 'COD', 'high', 'COD cash not remitted by the courier', count(*) || ' COD collection(s) are over 7 days without a remittance.',
       '/cod', array['Accountant']::text[], null, null, count(*)::int, min(collected_date)::timestamptz
from cod_collections where status in ('collected', 'short_remit') and collected_date < current_date - 7 and has_bankcod_view() having count(*) > 0
union all
select 'claims-deadline', 'Claims', case when min(deadline) < current_date then 'high' else 'medium' end, 'Claims close to their deadline', count(*) || ' claim(s) are due within 7 days or already past the deadline.',
       '/claims', array['Claims Manager']::text[], null, null, count(*)::int, min(deadline)::timestamptz
from claims where status in ('potential', 'claimed') and deadline is not null and deadline <= current_date + 7 and has_claims_view() having count(*) > 0
union all
select 'period-close', 'Accounting', 'medium', 'Accounting periods ready to close', count(*) || ' period(s) ended more than 5 days ago and are still open (' || string_agg(period_name, ', ' order by start_date) || ').',
       '/accounting/periods', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(end_date)::timestamptz
from accounting_periods where status = 'open' and end_date < current_date - 5 having count(*) > 0 and has_accounting_view()
union all
select 'recurring-error', 'Accounting', 'high', 'Recurring entries that could not post', count(*) || ' recurring journal(s) are waiting because of an error (for example a closed period).',
       '/accounting/journal', array['Accountant']::text[], null, null, count(*)::int, min(next_run_date)::timestamptz
from recurring_journals where status = 'active' and last_error is not null having count(*) > 0 and has_accounting_view()
union all
select 'gstr1-due', 'GST', case when extract(day from current_date) > 11 then 'high' else 'medium' end, 'GSTR-1 not recorded as filed', 'GSTR-1 for ' || to_char(date_trunc('month', current_date) - interval '1 month', 'Mon YYYY') || ' has no filing record yet (due about the 11th; confirm with your CA).',
       '/gst/gstr1', array['Tax Manager', 'Accountant']::text[], null, null, 1, date_trunc('month', current_date)
where extract(day from current_date) >= 5 and has_gst_view()
  and not gst_period_filed(to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM'), 'GSTR1')
union all
select 'gstr3b-due', 'GST', case when extract(day from current_date) > 20 then 'high' else 'medium' end, 'GSTR-3B not recorded as filed', 'GSTR-3B for ' || to_char(date_trunc('month', current_date) - interval '1 month', 'Mon YYYY') || ' has no filing record yet (due about the 20th; confirm with your CA).',
       '/gst', array['Tax Manager', 'Accountant']::text[], null, null, 1, date_trunc('month', current_date)
where extract(day from current_date) >= 12 and has_gst_view()
  and not gst_period_filed(to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM'), 'GSTR3B')
union all
select 'stock-timeout', 'Inventory', 'medium', 'SKUs past their stock time-out', count(*) || ' SKU(s) have stock older than their time-out.',
       '/insights', array['Operations Manager']::text[], null, null, count(*)::int, now()
from sku_stock_aging where timeout_state = 'overdue' having count(*) > 0
union all
select 'job-failed:' || j.job_key, 'System', 'high', 'Scheduled job failed: ' || j.label, coalesce(j.last_message, 'The last run failed.'),
       '/admin/automation', array['Super Admin']::text[], null, null, 1, j.last_run_at
from scheduled_jobs j where j.enabled and j.last_status = 'error'
union all
select 'po-pending', 'Purchases', 'medium', 'Purchase orders waiting for approval', count(*) || ' purchase order(s) need approval.',
       '/purchases/orders', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from purchase_orders where status = 'pending' having count(*) > 0 and has_purchase_approve()
union all
select 'po-late', 'Purchases', 'medium', 'Purchase orders past their expected date', count(*) || ' order(s) not fully received. Oldest was due ' || min(expected_date) || '.',
       '/purchases/orders', array['Operations Manager', 'Warehouse Manager']::text[], null, null, count(*)::int, min(expected_date)::timestamptz
from purchase_orders where status in ('approved', 'part_received') and expected_date < current_date
having count(*) > 0 and (has_po_write() or has_grn_write())
union all
select 'grn-unbilled', 'Purchases', 'medium', 'Goods received but no supplier bill entered', count(*) || ' receipt(s) have no bill yet. Oldest ' || min(received_on) || '.',
       '/purchases/orders', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(received_on)::timestamptz
from po_unbilled where unbilled_qty > 0 having count(*) > 0 and has_accounting_write()
union all
select 'reorder-low', 'Inventory', 'medium', 'Products below their reorder level', count(*) || ' product(s) need re-ordering.',
       '/purchases/reorder', array['Operations Manager']::text[], null, null, count(*)::int, now()
from reorder_suggestions where needs_reorder having count(*) > 0 and has_po_write()
;

-- the scheduler checks nothing extra: the work queue reads these live.
create or replace function my_nav_access() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'all', true,
    'accounting_view', has_accounting_view(),
    'accounting_write', has_accounting_write(),
    'bankcod_view', has_bankcod_view(),
    'settlements_view', has_settlements_view(),
    'returns_view', has_returns_view(),
    'claims_view', has_claims_view(),
    'tax_view', has_tax_view(),
    'gst_view', has_gst_view(),
    'inventory_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Claims Manager',
                                                          'Marketplace Manager', 'Auditor', 'Warehouse Manager'), false),
    'users_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner'), false),
    'roles_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Auditor'), false),
    'audit_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Auditor'), false),
    'integrations_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager'), false),
    'channels_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Marketplace Manager', 'Auditor'), false),
    'warehouses_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Warehouse Manager', 'Auditor'), false),
    'connectors_manage', coalesce(current_role_name() = 'Super Admin', false),
    'purchasing_view', has_po_view(),
    'automation_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager'), false),
    'uploads', import_can('products') or import_can('opening_stock') or import_can('listing_map') or import_can('ledger_opening') or import_can('orders')
  )
$$;

revoke execute on function po_create(uuid, uuid, jsonb, date, text), po_decide(uuid, boolean, text), po_cancel(uuid), po_close(uuid, text), grn_create(uuid, date, text, jsonb, text),
  po_create_bill(uuid, text, date, date, jsonb), po_set_reorder(uuid, numeric, numeric, int, uuid), po_from_reorder(uuid, uuid, uuid[]),
  has_po_write(), has_grn_write(), has_po_view(), my_nav_access() from public, anon, authenticated;
grant execute on function po_create(uuid, uuid, jsonb, date, text), po_decide(uuid, boolean, text), po_cancel(uuid), po_close(uuid, text), grn_create(uuid, date, text, jsonb, text),
  po_create_bill(uuid, text, date, date, jsonb), po_set_reorder(uuid, numeric, numeric, int, uuid), po_from_reorder(uuid, uuid, uuid[]),
  has_po_write(), has_grn_write(), has_po_view(), my_nav_access() to authenticated;
