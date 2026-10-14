-- 0105: Procurement controls (Round 21).
--   1. Two-tier PO approval: up to the limit a Finance Manager / Super Admin approves; above it the Owner (Super Admin / CEO-Owner) must.
--      A PO is no longer auto-approved for its own raiser unless "allow self approval" is on.
--   2. Supplier invoice capture + three-way match (PO price, goods received, supplier invoice). Zero tolerance: ANY mismatch puts the bill
--      "on hold" and only the Owner can release it. A held bill cannot be approved, so it can never be paid.
--   3. Stock bills with no purchase order are held as well (closes the double-billing / bypass hole).

alter table purchase_settings add column if not exists match_round_off numeric(6,2) not null default 1.00 check (match_round_off >= 0);
alter table purchase_orders   add column if not exists approval_level text not null default 'manager' check (approval_level in ('manager', 'owner'));
alter table purchase_bills    add column if not exists match_status text not null default 'not_applicable'
  check (match_status in ('not_applicable', 'matched', 'held', 'released'));
alter table purchase_bills    add column if not exists match_variance jsonb not null default '[]'::jsonb;
alter table purchase_bills    add column if not exists supplier_invoice_total numeric(14,2);
alter table purchase_bills    add column if not exists match_released_by uuid;
alter table purchase_bills    add column if not exists match_released_at timestamptz;
alter table purchase_bills    add column if not exists match_note text;

create or replace function has_owner_approve() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'CEO/Owner'), false)
$$;

-- ---------------------------------------------------------------- 1. tiered PO approval
create or replace function po_create(p_supplier uuid, p_warehouse uuid, p_lines jsonb, p_expected date default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype; ln jsonb; n int := 0; v_id uuid; v_no text; q numeric; pr numeric; rt numeric; v_tx numeric := 0; v_tax numeric := 0; v_lim numeric; v_status text;
  v_self boolean; v_rates numeric[] := array[0, 0.25, 3, 5, 12, 18, 28, 40]; v_pid uuid;
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
  select po_approval_limit, allow_self_approval into v_lim, v_self from purchase_settings where id = 1;
  -- a PO goes straight through only when self-approval is switched on (one-person shop) and it is within the manager tier
  v_status := case when coalesce(v_self, false) and v_tx + v_tax <= coalesce(v_lim, 0) and has_purchase_approve() then 'approved' else 'pending' end;
  update purchase_orders set taxable_value = v_tx, tax_value = v_tax, total = v_tx + v_tax, status = v_status,
         approval_level = case when v_tx + v_tax > coalesce(v_lim, 0) then 'owner' else 'manager' end,
         decided_by = case when v_status = 'approved' then auth.uid() end, decided_at = case when v_status = 'approved' then now() end where po_id = v_id;
  return v_id;
end $$;

create or replace function po_decide(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; v_self boolean; v_lim numeric;
begin
  if not (has_purchase_approve() or has_owner_approve()) then raise exception 'Only a Finance Manager or the Owner can approve a purchase order'; end if;
  select * into p from purchase_orders where po_id = p_id for update;
  if not found then raise exception 'Order not found'; end if;
  if p.status <> 'pending' then raise exception 'This order is already %', p.status; end if;
  select allow_self_approval, po_approval_limit into v_self, v_lim from purchase_settings where id = 1;
  if p.total > coalesce(v_lim, 0) and not has_owner_approve() then
    raise exception 'This order is above the manager limit of % - only the Owner can approve it', coalesce(v_lim, 0);
  end if;
  if p.created_by = auth.uid() and not coalesce(v_self, false) then raise exception 'You raised this order, so someone else has to approve it'; end if;
  if not p_approve and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say why the order is rejected'; end if;
  update purchase_orders set status = case when p_approve then 'approved' else 'rejected' end, decision_note = nullif(btrim(coalesce(p_note, '')), ''), decided_by = auth.uid(), decided_at = now() where po_id = p_id;
end $$;

-- ---------------------------------------------------------------- 2. invoice capture + three-way match
drop function if exists po_create_bill(uuid, text, date, date, jsonb);

-- p_lines: the supplier's invoice AS PRINTED: [{po_line_id, quantity, unit_price}], p_invoice_total: the grand total on the invoice
create or replace function po_create_bill(p_po uuid, p_invoice_no text, p_invoice_date date, p_bill_date date, p_lines jsonb, p_invoice_total numeric) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; st record; ln jsonb; v_lines jsonb := '[]'::jsonb; v_map jsonb := '[]'::jsonb; v_var jsonb := '[]'::jsonb; v_bill uuid; v_ledger uuid;
  q numeric; pr numeric; n int := 0; v_seen uuid[] := '{}'; v_pl uuid; v_total numeric; v_ro numeric; v_state text;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can enter a purchase bill'; end if;
  select * into p from purchase_orders where po_id = p_po;
  if not found then raise exception 'Order not found'; end if;
  if p.status not in ('approved', 'part_received', 'received', 'closed') then raise exception 'This order is %', p.status; end if;
  if p_invoice_total is null or p_invoice_total <= 0 then raise exception 'Enter the total amount printed on the supplier''s invoice'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Enter the lines exactly as printed on the supplier''s invoice'; end if;
  select ledger_id into v_ledger from ledgers where name = 'Inventory - Stock-in-Trade';
  select coalesce(match_round_off, 1) into v_ro from purchase_settings where id = 1;
  for ln in select * from jsonb_array_elements(p_lines) loop
    v_pl := nullif(ln ->> 'po_line_id', '')::uuid;
    q  := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    pr := coalesce(nullif(ln ->> 'unit_price', '')::numeric, -1);
    if q = 0 then continue; end if;   -- not on this invoice
    if q < 0 or q <> trunc(q) then raise exception 'Invoice quantities must be whole numbers'; end if;
    if pr < 0 then raise exception 'Enter the invoice price on every line'; end if;
    if v_pl = any (v_seen) then raise exception 'A line appears twice'; end if;
    v_seen := v_seen || v_pl;
    select s.*, pr2.name, pr2.hsn into st from po_line_status s join products pr2 on pr2.product_id = s.product_id where s.po_line_id = v_pl and s.po_id = p_po;
    if not found then raise exception 'A line does not belong to this order'; end if;
    n := n + 1;
    if q > greatest(st.received_qty - st.billed_qty, 0) then
      v_var := v_var || jsonb_build_object('kind', 'qty', 'line', st.line_no, 'product', st.name, 'expected', greatest(st.received_qty - st.billed_qty, 0), 'invoiced', q,
                                           'note', 'Invoice bills more than was received and not yet billed');
    end if;
    if pr <> st.unit_price then
      v_var := v_var || jsonb_build_object('kind', 'price', 'line', st.line_no, 'product', st.name, 'expected', st.unit_price, 'invoiced', pr, 'note', 'Invoice price differs from the order');
    end if;
    v_lines := v_lines || jsonb_build_object('description', st.name, 'hsn_code', st.hsn, 'quantity', q, 'unit_price', pr, 'gst_rate', st.gst_rate, 'ledger_id', v_ledger);
    v_map := v_map || jsonb_build_object('line_no', n, 'po_line_id', st.po_line_id);
  end loop;
  if n = 0 then raise exception 'Enter at least one line with a quantity'; end if;
  v_bill := create_purchase_bill(p.supplier_id, p_invoice_no, p_invoice_date, p_bill_date, v_lines, true, null, 'Raised from ' || p.po_no);
  select total into v_total from purchase_bills where bill_id = v_bill;
  if abs(v_total - round(p_invoice_total, 2)) > v_ro then
    v_var := v_var || jsonb_build_object('kind', 'total', 'expected', v_total, 'invoiced', round(p_invoice_total, 2),
                                         'note', 'The invoice total differs from the lines (check GST and round-off)');
  end if;
  v_state := case when jsonb_array_length(v_var) = 0 then 'matched' else 'held' end;
  update purchase_bills set po_id = p_po, supplier_invoice_total = round(p_invoice_total, 2), match_status = v_state, match_variance = v_var where bill_id = v_bill;
  update purchase_bill_lines bl set po_line_id = (m ->> 'po_line_id')::uuid
    from jsonb_array_elements(v_map) m where bl.bill_id = v_bill and bl.line_no = (m ->> 'line_no')::int;
  return jsonb_build_object('bill_id', v_bill, 'lines', n, 'match_status', v_state, 'variances', v_var);
end $$;

-- ---------------------------------------------------------------- 3. stock bills without a purchase order are held
create or replace function pbl_flag_unmatched_stock() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.ledger_id = (select ledger_id from ledgers where name = 'Inventory - Stock-in-Trade') then
    update purchase_bills set match_status = 'held',
           match_variance = jsonb_build_array(jsonb_build_object('kind', 'no_po', 'note', 'Stock bought with no purchase order and no goods receipt'))
     where bill_id = new.bill_id and po_id is null and match_status = 'not_applicable';
  end if;
  return new;
end $$;
drop trigger if exists trg_pbl_flag_unmatched_stock on purchase_bill_lines;
create trigger trg_pbl_flag_unmatched_stock after insert on purchase_bill_lines for each row execute function pbl_flag_unmatched_stock();

-- ---------------------------------------------------------------- hold = cannot be approved (and so can never be paid)
create or replace function pb_block_held() returns trigger language plpgsql as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and new.match_status = 'held' then
    raise exception 'This bill does not match the order / goods received. The Owner must release it before it can be approved.';
  end if;
  return new;
end $$;
drop trigger if exists trg_pb_block_held on purchase_bills;
create trigger trg_pb_block_held before update of status on purchase_bills for each row execute function pb_block_held();

create or replace function bill_release_hold(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b purchase_bills%rowtype;
begin
  if not has_owner_approve() then raise exception 'Only the Owner can release a bill that does not match'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say why the difference is acceptable'; end if;
  select * into b from purchase_bills where bill_id = p_id for update;
  if not found then raise exception 'Bill not found'; end if;
  if b.status <> 'pending' or b.match_status <> 'held' then raise exception 'Only a pending bill that is on hold can be released'; end if;
  if not pur_self_ok(b.created_by) then raise exception 'A different person must release this bill (you entered it)'; end if;
  update purchase_bills set match_status = 'released', match_released_by = auth.uid(), match_released_at = now(), match_note = btrim(p_note) where bill_id = p_id;
end $$;
