-- 0106: Receiving controls (Round 22).
--   1. A goods receipt needs the supplier's challan number, and its photo can be attached as proof (new attachment type 'goods_receipt').
--   2. Receipts cannot be backdated by more than a few days (setting); the Owner can override.
--   3. Segregation of duties: whoever raised or approved a purchase order cannot receive its goods (unless "allow self approval" is on).
--   4. Damaged / rejected quantity needs a written reason (receipt note).
--   5. Return to vendor (RTV): takes stock back out with a reason and reference, and lowers what can be billed. If it was already billed, the
--      result says a supplier credit note is needed.

alter table purchase_settings add column if not exists grn_backdate_days int not null default 2 check (grn_backdate_days between 0 and 30);

alter table inventory_transactions drop constraint if exists inventory_transactions_movement_type_check;
alter table inventory_transactions add constraint inventory_transactions_movement_type_check
  check (movement_type in ('return_restock', 'rto_restock', 'sale_dispatch', 'adjustment', 'initial_stock', 'purchase_receipt', 'direct_receipt', 'purchase_return'));

-- ---------------------------------------------------------------- return to vendor
create sequence if not exists vendor_return_seq;
create table if not exists vendor_returns (
  rtv_id       uuid primary key default gen_random_uuid(),
  rtv_no       text not null unique,
  po_id        uuid not null references purchase_orders(po_id),
  warehouse_id uuid not null references warehouses(warehouse_id),
  returned_on  date not null default current_date,
  reason       text not null check (btrim(reason) <> ''),
  ref_no       text,                      -- gate pass / debit note number given to the supplier
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now()
);
create table if not exists vendor_return_lines (
  line_id    uuid primary key default gen_random_uuid(),
  rtv_id     uuid not null references vendor_returns(rtv_id) on delete cascade,
  po_line_id uuid not null references purchase_order_lines(po_line_id),
  product_id uuid not null references products(product_id),
  quantity   numeric(14,3) not null check (quantity > 0)
);
create index if not exists vrl_pol on vendor_return_lines (po_line_id);
alter table vendor_returns enable row level security;
alter table vendor_return_lines enable row level security;
drop policy if exists "rtv read" on vendor_returns;      create policy "rtv read"  on vendor_returns      for select to authenticated using ((select has_po_view()));
drop policy if exists "rtvl read" on vendor_return_lines; create policy "rtvl read" on vendor_return_lines for select to authenticated using ((select has_po_view()));
grant select on vendor_returns, vendor_return_lines to authenticated;

-- received_qty is now NET of returns to the supplier
create or replace view po_line_status with (security_invoker = true) as
select l.po_line_id, l.po_id, l.line_no, l.product_id, l.quantity, l.unit_price, l.gst_rate,
       coalesce((select sum(g.qty_accepted) from goods_receipt_lines g where g.po_line_id = l.po_line_id), 0)
         - coalesce((select sum(v.quantity) from vendor_return_lines v where v.po_line_id = l.po_line_id), 0) as received_qty,
       coalesce((select sum(g.qty_rejected) from goods_receipt_lines g where g.po_line_id = l.po_line_id), 0) as rejected_qty,
       coalesce((select sum(bl.quantity) from purchase_bill_lines bl join purchase_bills b on b.bill_id = bl.bill_id
                  where bl.po_line_id = l.po_line_id and b.status in ('pending', 'approved')), 0) as billed_qty,
       coalesce((select sum(v.quantity) from vendor_return_lines v where v.po_line_id = l.po_line_id), 0) as returned_qty
from purchase_order_lines l;
grant select on po_line_status to authenticated;

-- p_lines: [{po_line_id, quantity}]
create or replace function rtv_create(p_po uuid, p_returned_on date, p_reason text, p_ref text, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; ln jsonb; v_id uuid; v_no text; st record; q numeric; n int := 0; v_credit boolean := false;
begin
  if not has_grn_write() then raise exception 'Only Operations or Warehouse roles can return goods to a supplier'; end if;
  select * into p from purchase_orders where po_id = p_po for update;
  if not found then raise exception 'Order not found'; end if;
  if not has_warehouse_scope(p.warehouse_id) then raise exception 'You are not assigned to this warehouse'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Say why the goods are going back to the supplier'; end if;
  if p_returned_on is null or p_returned_on > current_date then raise exception 'The return date cannot be empty or in the future'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Enter what is being returned'; end if;
  v_no := 'RTV-' || to_char(p_returned_on, 'YYMM') || '-' || lpad(nextval('vendor_return_seq')::text, 5, '0');
  insert into vendor_returns (rtv_no, po_id, warehouse_id, returned_on, reason, ref_no)
    values (v_no, p_po, p.warehouse_id, p_returned_on, btrim(p_reason), nullif(btrim(coalesce(p_ref, '')), '')) returning rtv_id into v_id;
  for ln in select * from jsonb_array_elements(p_lines) loop
    q := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    if q = 0 then continue; end if;
    if q < 0 or q <> trunc(q) then raise exception 'Quantities must be whole numbers'; end if;
    select * into st from po_line_status where po_line_id = (ln ->> 'po_line_id')::uuid and po_id = p_po;
    if not found then raise exception 'A line does not belong to this order'; end if;
    if q > st.received_qty then raise exception 'Line %: only % are held from this order, so % cannot go back', st.line_no, st.received_qty, q; end if;
    insert into vendor_return_lines (rtv_id, po_line_id, product_id, quantity) values (v_id, st.po_line_id, st.product_id, q);
    perform record_inventory_movement(st.product_id, p.warehouse_id, 'purchase_return', -q, 'vendor_return', v_id);
    n := n + 1;
    -- already billed for more than what is now held?
    if st.billed_qty > st.received_qty - q then v_credit := true; end if;
  end loop;
  if n = 0 then raise exception 'Enter a quantity on at least one line'; end if;
  return jsonb_build_object('rtv_id', v_id, 'rtv_no', v_no, 'needs_credit_note', v_credit);
end $$;

-- ---------------------------------------------------------------- proof (challan photo) on a goods receipt
alter table attachments drop constraint if exists attachments_entity_type_check;
alter table attachments add constraint attachments_entity_type_check check (entity_type in
  ('voucher', 'cash_settlement_report', 'bank_transaction', 'cod_collection', 'settlement', 'claim', 'return', 'rto', 'tax_transaction',
   'supplier_bill', 'supplier_payment', 'expense_claim', 'tds_challan', 'supplier_credit_note', 'goods_receipt'));

create or replace function attachment_parent_visible(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select case p_type
    when 'voucher'                then exists (select 1 from vouchers where voucher_id = p_id)
    when 'cash_settlement_report'  then exists (select 1 from cash_settlement_reports where report_id = p_id)
    when 'bank_transaction'        then exists (select 1 from bank_transactions where bank_txn_id = p_id)
    when 'cod_collection'          then exists (select 1 from cod_collections where cod_id = p_id)
    when 'settlement'              then exists (select 1 from settlements where settlement_id = p_id)
    when 'claim'                   then exists (select 1 from claims where claim_id = p_id)
    when 'return'                  then exists (select 1 from returns where return_id = p_id)
    when 'rto'                     then exists (select 1 from rtos where rto_id = p_id)
    when 'tax_transaction'         then exists (select 1 from tax_transactions where tax_txn_id = p_id)
    when 'supplier_bill'           then exists (select 1 from purchase_bills where bill_id = p_id)
    when 'supplier_payment'        then exists (select 1 from supplier_payments where payment_id = p_id)
    when 'expense_claim'           then exists (select 1 from expense_claims where claim_id = p_id)
    when 'tds_challan'            then exists (select 1 from tds_challans where challan_id = p_id)
    when 'supplier_credit_note'   then exists (select 1 from supplier_credit_notes where note_id = p_id)
    when 'goods_receipt'          then exists (select 1 from goods_receipts where grn_id = p_id)
    else false end
$$;

create or replace function can_attach(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select (case p_type
    when 'voucher'                then has_accounting_write()
    when 'cash_settlement_report'  then has_bankcod_write()
    when 'bank_transaction'        then has_bankcod_write()
    when 'cod_collection'          then has_bankcod_write()
    when 'settlement'              then has_settlements_reconcile()
    when 'claim'                   then has_claims_create() or has_claims_manage()
    when 'return'                  then has_returns_write()
    when 'rto'                     then has_returns_write()
    when 'tax_transaction'         then has_tax_write()
    when 'supplier_bill'           then has_accounting_write()
    when 'supplier_payment'        then has_accounting_write()
    when 'expense_claim'           then is_active_user() and (p_id is null
                                        or exists (select 1 from expense_claims c where c.claim_id = p_id and c.claimant_id = auth.uid() and c.status = 'draft')
                                        or has_accounting_write())
    when 'tds_challan'            then has_accounting_write()
    when 'supplier_credit_note'   then has_accounting_write()
    when 'goods_receipt'          then has_grn_write()
    else false end)
  and (p_id is null or attachment_parent_visible(p_type, p_id))
$$;

create or replace function can_view_attachment(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select p_id is not null and (case p_type
    when 'voucher'                then has_accounting_view()
    when 'cash_settlement_report'  then has_bankcod_view()
    when 'bank_transaction'        then has_bankcod_view()
    when 'cod_collection'          then has_bankcod_view()
    when 'settlement'              then has_settlements_view()
    when 'claim'                   then has_claims_view()
    when 'return'                  then has_returns_view()
    when 'rto'                     then has_returns_view()
    when 'tax_transaction'         then has_tax_view()
    when 'supplier_bill'           then has_accounting_view()
    when 'supplier_payment'        then has_accounting_view()
    when 'expense_claim'           then true
    when 'tds_challan'            then has_accounting_view()
    when 'supplier_credit_note'   then has_accounting_view()
    when 'goods_receipt'          then has_po_view()
    else false end)
  and attachment_parent_visible(p_type, p_id)
$$;

-- ---------------------------------------------------------------- tighter goods receipt
create or replace function grn_create(p_po uuid, p_received_on date, p_challan text, p_lines jsonb, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; ln jsonb; v_g uuid; v_no text; l purchase_order_lines%rowtype; a numeric; r numeric; v_recv numeric; v_any boolean := false; v_open int;
  v_lot text; v_exp date; v_tracked boolean; v_self boolean; v_back int; v_bad boolean := false;
begin
  if not has_grn_write() then raise exception 'Only Operations or Warehouse roles can receive goods'; end if;
  select * into p from purchase_orders where po_id = p_po for update;
  if not found then raise exception 'Order not found'; end if;
  if p.status not in ('approved', 'part_received') then raise exception 'Goods can be received only against an approved order (this one is %)', p.status; end if;
  if not has_warehouse_scope(p.warehouse_id) then raise exception 'You are not assigned to this warehouse'; end if;
  select allow_self_approval, grn_backdate_days into v_self, v_back from purchase_settings where id = 1;
  if not coalesce(v_self, false) and auth.uid() in (p.created_by, p.decided_by) then
    raise exception 'You raised or approved this order, so someone else has to receive its goods';
  end if;
  if nullif(btrim(coalesce(p_challan, '')), '') is null then raise exception 'Enter the supplier''s challan / delivery note number'; end if;
  if p_received_on is null or p_received_on > current_date then raise exception 'The receipt date cannot be empty or in the future'; end if;
  if p_received_on < current_date - coalesce(v_back, 2) and not has_owner_approve() then
    raise exception 'Goods can be recorded at most % day(s) back. Ask the Owner to record an older receipt.', coalesce(v_back, 2);
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Enter what was received'; end if;
  select exists (select 1 from jsonb_array_elements(p_lines) e where coalesce(nullif(e ->> 'rejected', '')::numeric, 0) > 0) into v_bad;
  if v_bad and nullif(btrim(coalesce(p_notes, '')), '') is null then raise exception 'Some goods are damaged or rejected - write what was wrong with them'; end if;
  v_no := 'GRN-' || to_char(p_received_on, 'YYMM') || '-' || lpad(nextval('grn_seq')::text, 5, '0');
  insert into goods_receipts (grn_no, po_id, warehouse_id, received_on, challan_no, notes) values (v_no, p_po, p.warehouse_id, p_received_on, btrim(p_challan), nullif(btrim(coalesce(p_notes, '')), ''))
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

revoke execute on function rtv_create(uuid, date, text, text, jsonb) from public, anon;
grant execute on function rtv_create(uuid, date, text, text, jsonb) to authenticated;
