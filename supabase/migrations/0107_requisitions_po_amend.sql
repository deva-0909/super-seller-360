-- 0107: Branch requisitions and purchase-order amendments (Round 23).
--   1. A branch store raises a requisition (what it needs, by when). A manager approves it, then purchase turns it into a PO for that branch
--      (the PO's lines remember which requisition line they serve, so "asked / ordered / received" can be tracked per branch).
--   2. A PO can be amended (quantity, price, products, date) while nothing has been received. Every amendment keeps the old version,
--      needs a reason, and sends the PO back for approval at the right tier.

create or replace function has_req_write() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Operations Manager', 'Warehouse Manager'), false)
$$;
create or replace function has_req_decide() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager'), false)
$$;

create sequence if not exists requisition_seq;
create table if not exists requisitions (
  req_id        uuid primary key default gen_random_uuid(),
  req_no        text not null unique,
  warehouse_id  uuid not null references warehouses(warehouse_id),
  needed_by     date,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled', 'closed')),
  notes         text,
  decision_note text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  decided_by    uuid,
  decided_at    timestamptz
);
create table if not exists requisition_lines (
  req_line_id uuid primary key default gen_random_uuid(),
  req_id      uuid not null references requisitions(req_id) on delete cascade,
  line_no     int not null,
  product_id  uuid not null references products(product_id),
  quantity    numeric(14,3) not null check (quantity > 0),
  note        text,
  unique (req_id, line_no)
);
alter table purchase_order_lines add column if not exists req_line_id uuid references requisition_lines(req_line_id);
alter table purchase_orders      add column if not exists req_id uuid references requisitions(req_id);
alter table purchase_orders      add column if not exists version int not null default 1;
create index if not exists pol_req_line on purchase_order_lines (req_line_id) where req_line_id is not null;

create table if not exists po_versions (
  po_id      uuid not null references purchase_orders(po_id) on delete cascade,
  version    int not null,
  snapshot   jsonb not null,
  reason     text not null,
  changed_by uuid default auth.uid(),
  changed_at timestamptz not null default now(),
  primary key (po_id, version)
);

alter table requisitions enable row level security;
alter table requisition_lines enable row level security;
alter table po_versions enable row level security;
drop policy if exists "req read" on requisitions;       create policy "req read"  on requisitions       for select to authenticated using ((select has_po_view()));
drop policy if exists "reql read" on requisition_lines; create policy "reql read" on requisition_lines  for select to authenticated using ((select has_po_view()));
drop policy if exists "pov read" on po_versions;        create policy "pov read"  on po_versions        for select to authenticated using ((select has_po_view()));
grant select on requisitions, requisition_lines, po_versions to authenticated;

-- asked / ordered / received per requisition line
create or replace view requisition_line_status with (security_invoker = true) as
select l.req_line_id, l.req_id, l.line_no, l.product_id, l.quantity,
       coalesce((select sum(pl.quantity) from purchase_order_lines pl join purchase_orders p on p.po_id = pl.po_id
                  where pl.req_line_id = l.req_line_id and p.status not in ('rejected', 'cancelled')), 0) as ordered_qty,
       coalesce((select sum(s.received_qty) from po_line_status s join purchase_order_lines pl on pl.po_line_id = s.po_line_id
                  where pl.req_line_id = l.req_line_id), 0) as received_qty
from requisition_lines l;
grant select on requisition_line_status to authenticated;

-- ---------------------------------------------------------------- PO lines: one validated writer for create and amend
create or replace function po_write_lines(p_po uuid, p_lines jsonb) returns numeric[]
language plpgsql security definer set search_path = public, pg_temp as $$
declare ln jsonb; n int := 0; q numeric; pr numeric; rt numeric; v_tx numeric := 0; v_tax numeric := 0; v_pid uuid;
  v_rates numeric[] := array[0, 0.25, 3, 5, 12, 18, 28, 40];
begin
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one line'; end if;
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
    insert into purchase_order_lines (po_id, line_no, product_id, quantity, unit_price, gst_rate, req_line_id)
      values (p_po, n, v_pid, q, pr, rt, nullif(ln ->> 'req_line_id', '')::uuid);
    v_tx := v_tx + round(q * pr, 2); v_tax := v_tax + round(round(q * pr, 2) * rt / 100, 2);
  end loop;
  return array[v_tx, v_tax];
end $$;
revoke execute on function po_write_lines(uuid, jsonb) from public, anon, authenticated;

create or replace function po_create(p_supplier uuid, p_warehouse uuid, p_lines jsonb, p_expected date default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype; v_id uuid; v_no text; v_t numeric[]; v_lim numeric; v_status text; v_self boolean;
begin
  if not has_po_write() then raise exception 'Only Operations, Finance or Accounts roles can raise a purchase order'; end if;
  select * into s from suppliers where supplier_id = p_supplier;
  if not found then raise exception 'Choose a supplier'; end if;
  if s.status <> 'active' then raise exception 'This supplier is % - it must be approved before orders can be raised', s.status; end if;
  if not exists (select 1 from warehouses where warehouse_id = p_warehouse) then raise exception 'Choose the warehouse the goods will come to'; end if;
  if p_expected is not null and p_expected < current_date then raise exception 'The expected date cannot be in the past'; end if;
  v_no := 'PO-' || to_char(current_date, 'YYMM') || '-' || lpad(nextval('purchase_order_seq')::text, 5, '0');
  insert into purchase_orders (po_no, supplier_id, warehouse_id, expected_date, notes, status) values (v_no, p_supplier, p_warehouse, p_expected, nullif(btrim(coalesce(p_notes, '')), ''), 'pending')
    returning po_id into v_id;
  v_t := po_write_lines(v_id, p_lines);
  select po_approval_limit, allow_self_approval into v_lim, v_self from purchase_settings where id = 1;
  v_status := case when coalesce(v_self, false) and v_t[1] + v_t[2] <= coalesce(v_lim, 0) and has_purchase_approve() then 'approved' else 'pending' end;
  update purchase_orders set taxable_value = v_t[1], tax_value = v_t[2], total = v_t[1] + v_t[2], status = v_status,
         approval_level = case when v_t[1] + v_t[2] > coalesce(v_lim, 0) then 'owner' else 'manager' end,
         decided_by = case when v_status = 'approved' then auth.uid() end, decided_at = case when v_status = 'approved' then now() end where po_id = v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------- amend a PO (nothing received yet)
create or replace function po_amend(p_id uuid, p_lines jsonb, p_expected date, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p purchase_orders%rowtype; v_t numeric[]; v_lim numeric; v_snap jsonb; v_map jsonb;
begin
  if not has_po_write() then raise exception 'Not authorized'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Say why the order is being changed'; end if;
  select * into p from purchase_orders where po_id = p_id for update;
  if not found then raise exception 'Order not found'; end if;
  if p.status not in ('pending', 'approved') then raise exception 'Only an order that is waiting or approved can be changed (this one is %)', p.status; end if;
  if exists (select 1 from goods_receipts where po_id = p_id) then raise exception 'Goods were already received against this order. Close it and raise a new one for the rest.'; end if;
  if p_expected is not null and p_expected < current_date then raise exception 'The expected date cannot be in the past'; end if;
  select jsonb_build_object('expected_date', p.expected_date, 'total', p.total, 'status', p.status,
           'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', product_id, 'quantity', quantity, 'unit_price', unit_price, 'gst_rate', gst_rate) order by line_no)
                               from purchase_order_lines where po_id = p_id), '[]'::jsonb)) into v_snap;
  insert into po_versions (po_id, version, snapshot, reason) values (p_id, p.version, v_snap, btrim(p_reason));
  select coalesce(jsonb_object_agg(product_id::text, req_line_id), '{}'::jsonb) into v_map from purchase_order_lines where po_id = p_id and req_line_id is not null;
  delete from purchase_order_lines where po_id = p_id;
  v_t := po_write_lines(p_id, p_lines);
  -- lines keep serving the requisition line they were raised for
  update purchase_order_lines l set req_line_id = (v_map ->> l.product_id::text)::uuid where l.po_id = p_id and l.req_line_id is null and v_map ? l.product_id::text;
  select po_approval_limit into v_lim from purchase_settings where id = 1;
  -- every change goes back for approval, at the tier the NEW total needs
  update purchase_orders set taxable_value = v_t[1], tax_value = v_t[2], total = v_t[1] + v_t[2], expected_date = p_expected, version = p.version + 1,
         status = 'pending', decided_by = null, decided_at = null, decision_note = null, created_by = auth.uid(),
         approval_level = case when v_t[1] + v_t[2] > coalesce(v_lim, 0) then 'owner' else 'manager' end
   where po_id = p_id;
end $$;

-- ---------------------------------------------------------------- requisitions
-- p_lines: [{product_id, quantity, note}]
create or replace function req_create(p_warehouse uuid, p_needed_by date, p_lines jsonb, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare ln jsonb; v_id uuid; n int := 0; q numeric; v_pid uuid;
begin
  if not has_req_write() then raise exception 'Only Operations or Warehouse roles can raise a requisition'; end if;
  if not exists (select 1 from warehouses where warehouse_id = p_warehouse and status = 'active') then raise exception 'Choose the branch store that needs the goods'; end if;
  if not has_warehouse_scope(p_warehouse) then raise exception 'You are not assigned to this branch store'; end if;
  if p_needed_by is not null and p_needed_by < current_date then raise exception 'The needed-by date cannot be in the past'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one item'; end if;
  insert into requisitions (req_no, warehouse_id, needed_by, notes)
    values ('RQ-' || to_char(current_date, 'YYMM') || '-' || lpad(nextval('requisition_seq')::text, 5, '0'), p_warehouse, p_needed_by, nullif(btrim(coalesce(p_notes, '')), ''))
    returning req_id into v_id;
  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_pid := nullif(ln ->> 'product_id', '')::uuid;
    q := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    if v_pid is null or not exists (select 1 from products where product_id = v_pid) then raise exception 'Line %: choose a product', n; end if;
    if q <= 0 or q <> trunc(q) then raise exception 'Line %: quantity must be a whole number above zero', n; end if;
    insert into requisition_lines (req_id, line_no, product_id, quantity, note) values (v_id, n, v_pid, q, nullif(btrim(coalesce(ln ->> 'note', '')), ''));
  end loop;
  return v_id;
end $$;

create or replace function req_decide(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r requisitions%rowtype; v_self boolean;
begin
  if not has_req_decide() then raise exception 'Only a manager can approve a requisition'; end if;
  select * into r from requisitions where req_id = p_id for update;
  if not found then raise exception 'Requisition not found'; end if;
  if r.status <> 'pending' then raise exception 'This requisition is already %', r.status; end if;
  select allow_self_approval into v_self from purchase_settings where id = 1;
  if r.created_by = auth.uid() and not coalesce(v_self, false) then raise exception 'You raised this requisition, so someone else has to approve it'; end if;
  if not p_approve and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say why the requisition is rejected'; end if;
  update requisitions set status = case when p_approve then 'approved' else 'rejected' end, decision_note = nullif(btrim(coalesce(p_note, '')), ''),
         decided_by = auth.uid(), decided_at = now() where req_id = p_id;
end $$;

create or replace function req_cancel(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r requisitions%rowtype;
begin
  select * into r from requisitions where req_id = p_id for update;
  if not found then raise exception 'Requisition not found'; end if;
  if r.status not in ('pending', 'approved') then raise exception 'This requisition is already %', r.status; end if;
  if not (r.created_by = auth.uid() or has_req_decide()) then raise exception 'Only the person who raised it, or a manager, can cancel it'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  if exists (select 1 from purchase_orders where req_id = p_id and status not in ('rejected', 'cancelled')) then raise exception 'An order was already raised from this requisition. Cancel the order first, or close the requisition.'; end if;
  update requisitions set status = 'cancelled', decision_note = btrim(p_reason) where req_id = p_id;
end $$;

create or replace function req_close(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_po_write() then raise exception 'Not authorized'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say why the rest will not be ordered'; end if;
  update requisitions set status = 'closed', decision_note = btrim(p_note) where req_id = p_id and status = 'approved';
  if not found then raise exception 'Only an approved requisition can be closed'; end if;
end $$;

-- a PO for what is still not ordered on an approved requisition, delivered to the branch that asked
create or replace function po_from_requisition(p_req uuid, p_supplier uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare r requisitions%rowtype; v_lines jsonb := '[]'::jsonb; s record; v_po uuid;
begin
  if not has_po_write() then raise exception 'Not authorized'; end if;
  select * into r from requisitions where req_id = p_req for update;
  if not found then raise exception 'Requisition not found'; end if;
  if r.status <> 'approved' then raise exception 'Only an approved requisition can be ordered (this one is %)', r.status; end if;
  for s in select st.req_line_id, st.product_id, st.quantity - st.ordered_qty as left_qty, coalesce(pr.cost_price, 0) as price, coalesce(pr.gst_rate, 0) as gst
             from requisition_line_status st join products pr on pr.product_id = st.product_id where st.req_id = p_req order by st.line_no loop
    if s.left_qty <= 0 then continue; end if;
    v_lines := v_lines || jsonb_build_object('product_id', s.product_id, 'quantity', s.left_qty, 'unit_price', s.price, 'gst_rate', s.gst, 'req_line_id', s.req_line_id);
  end loop;
  if jsonb_array_length(v_lines) = 0 then raise exception 'Everything on this requisition is already ordered'; end if;
  v_po := po_create(p_supplier, r.warehouse_id, v_lines, r.needed_by, 'From requisition ' || r.req_no);
  update purchase_orders set req_id = p_req where po_id = v_po;
  return v_po;
end $$;

revoke execute on function req_create(uuid, date, jsonb, text), req_decide(uuid, boolean, text), req_cancel(uuid, text), req_close(uuid, text),
  po_from_requisition(uuid, uuid), po_amend(uuid, jsonb, date, text) from public, anon;
grant execute on function req_create(uuid, date, jsonb, text), req_decide(uuid, boolean, text), req_cancel(uuid, text), req_close(uuid, text),
  po_from_requisition(uuid, uuid), po_amend(uuid, jsonb, date, text) to authenticated;
