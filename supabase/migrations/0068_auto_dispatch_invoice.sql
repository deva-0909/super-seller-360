-- 0068: Stock goes out when an order ships, and the sales invoice posts itself.
--
-- Until now the stock movement "sale_dispatch" existed only in the demo data and every invoice was posted by clicking a button.
--   * When an order becomes shipped or delivered (or arrives already shipped), each of its lines is taken out of a warehouse.
--     The warehouse is the one on the order, else the own / 3PL warehouse that can cover the most lines. Each line is dispatched once.
--   * The sales invoice is posted for the order, unless the channel is set to "manual" or the automatic invoice is switched off.
--   * Anything that cannot be done (not enough stock, no open period, no ship-to state) is not lost and does not block the order:
--     it becomes an open item in the work queue (automation_issues), and is retried and closed when it works.
--   * A cancelled order that had already been dispatched raises an item so someone confirms the goods really came back.
-- The accounting rule INV-DISPATCH-COGS (cost of goods sold) stays as the Rule Book has it (inactive). Switch it on only after opening
-- stock has been loaded with its value, so that the Inventory ledger does not go negative.

alter table orders add column if not exists warehouse_id uuid references warehouses(warehouse_id);
alter table channels add column if not exists auto_invoice_on text not null default 'shipped' check (auto_invoice_on in ('shipped', 'delivered', 'manual'));

-- ---------------------------------------------------------------- switches
create table if not exists automation_settings (
  key         text primary key,
  value       text not null,
  updated_by  uuid,
  updated_at  timestamptz not null default now()
);
insert into automation_settings (key, value) values ('auto_dispatch', 'on'), ('auto_invoice', 'on') on conflict do nothing;
alter table automation_settings enable row level security;
drop policy if exists "automation settings read" on automation_settings;
create policy "automation settings read" on automation_settings for select to authenticated using (auth.uid() is not null);
grant select on automation_settings to authenticated;

create or replace function automation_on(p_key text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select value = 'on' from automation_settings where key = p_key), false)
$$;

create or replace function set_automation_setting(p_key text, p_value text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_role_name() not in ('Super Admin', 'Operations Manager', 'Finance Manager') then raise exception 'Only a Super Admin, Operations Manager or Finance Manager can change automation settings'; end if;
  if p_key not in ('auto_dispatch', 'auto_invoice') then raise exception 'Unknown setting'; end if;
  if p_value not in ('on', 'off') then raise exception 'Choose on or off'; end if;
  update automation_settings set value = p_value, updated_by = auth.uid(), updated_at = now() where key = p_key;
end $$;

-- ---------------------------------------------------------------- items that need a person (the work queue reads these)
create table if not exists automation_issues (
  issue_id     uuid primary key default gen_random_uuid(),
  kind         text not null,                -- dispatch_failed | invoice_failed | cancelled_after_dispatch | ...
  entity_type  text not null,
  entity_id    uuid not null,
  message      text not null,
  status       text not null default 'open' check (status in ('open', 'resolved')),
  attempts     int not null default 1,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  resolved_at  timestamptz
);
create unique index if not exists automation_issues_open on automation_issues (kind, entity_type, entity_id) where status = 'open';
alter table automation_issues enable row level security;
drop policy if exists "automation issues read" on automation_issues;
create policy "automation issues read" on automation_issues for select to authenticated using (has_orders_write() or has_accounting_view() or has_returns_view());
grant select on automation_issues to authenticated;

create or replace function auto_issue_open(p_kind text, p_type text, p_id uuid, p_msg text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into automation_issues (kind, entity_type, entity_id, message) values (p_kind, p_type, p_id, left(p_msg, 500))
  on conflict (kind, entity_type, entity_id) where status = 'open'
  do update set message = excluded.message, attempts = automation_issues.attempts + 1, updated_at = now()
$$;
create or replace function auto_issue_close(p_kind text, p_type text, p_id uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update automation_issues set status = 'resolved', resolved_at = now(), updated_at = now()
   where kind = p_kind and entity_type = p_type and entity_id = p_id and status = 'open'
$$;

-- ---------------------------------------------------------------- what each dispatched line did (also stops a line going out twice)
create table if not exists order_dispatch (
  order_line_id  uuid primary key references order_lines(order_line_id) on delete cascade,
  order_id       uuid not null references orders(order_id) on delete cascade,
  product_id     uuid not null references products(product_id),
  warehouse_id   uuid not null references warehouses(warehouse_id),
  quantity       numeric(10,2) not null,
  txn_id         uuid,
  dispatched_at  timestamptz not null default now()
);
create index if not exists order_dispatch_order on order_dispatch (order_id);
alter table order_dispatch enable row level security;
drop policy if exists "order dispatch read" on order_dispatch;
create policy "order dispatch read" on order_dispatch for select to authenticated using (auth.uid() is not null);
grant select on order_dispatch to authenticated;

-- orders that shipped before this migration already had their stock handled (or never will): mark their lines as dispatched so nothing goes out twice
insert into order_dispatch (order_line_id, order_id, product_id, warehouse_id, quantity, txn_id)
select ol.order_line_id, ol.order_id, ol.product_id,
       coalesce((select t.warehouse_id from inventory_transactions t where t.reference_type = 'order' and t.reference_id = ol.order_id and t.product_id = ol.product_id limit 1),
                (select w.warehouse_id from warehouses w order by w.created_at limit 1)),
       ol.quantity, null
from order_lines ol join orders o on o.order_id = ol.order_id
where o.fulfilment_status in ('shipped', 'delivered', 'cancelled', 'rto') and ol.product_id is not null
  and exists (select 1 from warehouses)
on conflict do nothing;

-- stock promised to orders that have not shipped yet, so the buyer can see what is really free
create or replace view inventory_reserved with (security_invoker = true) as
select ol.product_id, sum(ol.quantity) as reserved
from order_lines ol join orders o on o.order_id = ol.order_id
where o.fulfilment_status in ('pending', 'processing') and ol.product_id is not null
  and not exists (select 1 from order_dispatch d where d.order_line_id = ol.order_line_id)
group by ol.product_id;
grant select on inventory_reserved to authenticated;

-- ---------------------------------------------------------------- posting an invoice: the same function, now also callable by the automatic job
create or replace function post_sales_voucher(p_order_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order            orders%rowtype;
  v_period_id        uuid;
  v_voucher_type_id  uuid;
  v_voucher_id       uuid;
  v_invoice_id       uuid;
  v_invoice_number   text;
  v_receivable_ledger uuid;
  v_sales_ledger      uuid;
  v_cgst_ledger        uuid;
  v_sgst_ledger        uuid;
  v_igst_ledger         uuid;
  v_company_state       text;
  v_is_interstate        boolean;
  v_half_tax               numeric;
  v_remainder_tax          numeric;
begin
  -- a person with order or accounting rights, or the automatic job (it sets app.auto_post for its own transaction only)
  if not (has_orders_write() or has_accounting_write() or coalesce(current_setting('app.auto_post', true), '') = 'on') then
    raise exception 'Not authorized to post sales vouchers';
  end if;

  select * into v_order from orders where order_id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if v_order.fulfilment_status in ('cancelled', 'rto') then
    raise exception 'Cannot invoice an order with fulfilment status %', v_order.fulfilment_status;
  end if;

  if exists (select 1 from invoices where order_id = p_order_id) then
    raise exception 'Order % is already invoiced', p_order_id;
  end if;

  select accounting_period_id into v_period_id from accounting_periods
    where v_order.order_date::date between start_date and end_date and status = 'open'
    limit 1;
  if v_period_id is null then
    raise exception 'No open accounting period covers order date %', v_order.order_date;
  end if;

  select voucher_type_id into v_voucher_type_id from voucher_types where code = 'SALES';
  select ledger_id into v_receivable_ledger from ledgers where name = 'Trade Receivables';
  select ledger_id into v_sales_ledger from ledgers where name = 'Sales Revenue';
  select ledger_id into v_cgst_ledger from ledgers where name = 'CGST Payable (Output)';
  select ledger_id into v_sgst_ledger from ledgers where name = 'SGST Payable (Output)';
  select ledger_id into v_igst_ledger from ledgers where name = 'IGST Payable (Output)';

  if v_voucher_type_id is null or v_receivable_ledger is null or v_sales_ledger is null then
    raise exception 'Accounting masters not seeded — run the Phase 2 seed data first.';
  end if;
  if v_order.tax_amount > 0 and (v_cgst_ledger is null or v_sgst_ledger is null or v_igst_ledger is null) then
    raise exception 'GST ledgers not seeded — CGST/SGST/IGST Payable ledgers are required.';
  end if;

  select state into v_company_state from companies limit 1;
  if v_order.tax_amount > 0 and v_order.ship_to_state is null then
    raise exception 'Order has tax but no ship_to_state set — cannot determine CGST/SGST vs IGST without a place of supply.';
  end if;
  v_is_interstate := (v_order.ship_to_state is distinct from v_company_state);

  -- one invoice number at a time, so two invoices raised together can never share a number
  perform pg_advisory_xact_lock(hashtext('invoice-number'));
  v_invoice_number := 'INV-' || to_char(now(), 'YYYYMM') || '-' ||
    lpad((select count(*) + 1 from invoices where invoice_number like 'INV-' || to_char(now(), 'YYYYMM') || '-%')::text, 5, '0');

  insert into vouchers (
    voucher_type_id, voucher_no, voucher_date, accounting_period_id,
    status, source_type, source_id, narration, total_debit, total_credit, created_by
  ) values (
    v_voucher_type_id, v_invoice_number, v_order.order_date::date, v_period_id,
    'draft', 'order', p_order_id,
    'Sales invoice for order ' || v_order.external_order_id || ' — ship to ' || coalesce(v_order.ship_to_state, 'N/A') ||
      case when v_is_interstate then ' (interstate, IGST)' else ' (intrastate, CGST+SGST)' end,
    v_order.net_amount, v_order.net_amount, auth.uid()
  ) returning voucher_id into v_voucher_id;

  insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
  values (v_voucher_id, v_receivable_ledger, v_order.net_amount, 0, 'order', p_order_id);

  insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
  values (v_voucher_id, v_sales_ledger, 0, v_order.net_amount - v_order.tax_amount, 'order', p_order_id);

  if v_order.tax_amount > 0 then
    if v_is_interstate then
      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_igst_ledger, 0, v_order.tax_amount, 'order', p_order_id);
    else
      v_half_tax := round(v_order.tax_amount / 2, 2);
      v_remainder_tax := v_order.tax_amount - v_half_tax;
      if v_half_tax > 0 then
        insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
        values (v_voucher_id, v_cgst_ledger, 0, v_half_tax, 'order', p_order_id);
      end if;
      if v_remainder_tax > 0 then
        insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
        values (v_voucher_id, v_sgst_ledger, 0, v_remainder_tax, 'order', p_order_id);
      end if;
    end if;
  end if;

  update vouchers set status = 'posted' where voucher_id = v_voucher_id;

  insert into invoices (order_id, invoice_number, invoice_date, taxable_value, gst_amount, total, voucher_id)
  values (
    p_order_id, v_invoice_number, v_order.order_date::date,
    v_order.net_amount - v_order.tax_amount, v_order.tax_amount, v_order.net_amount, v_voucher_id
  ) returning invoice_id into v_invoice_id;

  return v_invoice_id;
end;
$$;

-- ---------------------------------------------------------------- the warehouse an order leaves from
create or replace function pick_dispatch_warehouse(p_order uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select warehouse_id from orders where order_id = p_order),
    (select w.warehouse_id from warehouses w
      where w.status = 'active' and w.type in ('own', '3pl')
      order by (select count(*) from order_lines ol
                  left join inventory_balances b on b.product_id = ol.product_id and b.warehouse_id = w.warehouse_id
                 where ol.order_id = p_order and ol.product_id is not null and coalesce(b.quantity, 0) < ol.quantity), w.created_at
      limit 1))
$$;

-- ---------------------------------------------------------------- take the order's lines out of stock (each line once)
create or replace function auto_dispatch_order(p_order uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o orders%rowtype; l record; v_wh uuid; v_txn uuid; v_done int := 0; v_fail text := null;
begin
  if not automation_on('auto_dispatch') then return jsonb_build_object('skipped', 'auto dispatch is off'); end if;
  select * into o from orders where order_id = p_order;
  if not found or o.fulfilment_status not in ('shipped', 'delivered') then return jsonb_build_object('skipped', 'order is not shipped'); end if;
  v_wh := pick_dispatch_warehouse(p_order);
  if v_wh is null then
    perform auto_issue_open('dispatch_failed', 'order', p_order, 'No active own or 3PL warehouse to take the stock from');
    return jsonb_build_object('failed', 'no warehouse');
  end if;
  for l in select ol.* from order_lines ol
            where ol.order_id = p_order and ol.product_id is not null
              and not exists (select 1 from order_dispatch d where d.order_line_id = ol.order_line_id) loop
    begin
      v_txn := record_inventory_movement(l.product_id, v_wh, 'sale_dispatch', -l.quantity, 'order', p_order);
      insert into order_dispatch (order_line_id, order_id, product_id, warehouse_id, quantity, txn_id) values (l.order_line_id, p_order, l.product_id, v_wh, l.quantity, v_txn);
      v_done := v_done + 1;
    exception when others then
      v_fail := coalesce(v_fail || '; ', '') || (select sku from products where product_id = l.product_id) || ': ' || sqlerrm;
    end;
  end loop;
  if v_fail is not null then
    perform auto_issue_open('dispatch_failed', 'order', p_order, 'Order ' || o.external_order_id || ' shipped but stock could not be taken out. ' || v_fail || '. Count the stock and adjust it, then retry.');
  elsif not exists (select 1 from order_lines ol where ol.order_id = p_order and ol.product_id is not null
                    and not exists (select 1 from order_dispatch d where d.order_line_id = ol.order_line_id)) then
    perform auto_issue_close('dispatch_failed', 'order', p_order);
  end if;
  return jsonb_build_object('dispatched', v_done, 'failed', v_fail);
end $$;

-- ---------------------------------------------------------------- post the sales invoice for a shipped order
create or replace function auto_invoice_order(p_order uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare o orders%rowtype; v_mode text;
begin
  if not automation_on('auto_invoice') then return jsonb_build_object('skipped', 'auto invoice is off'); end if;
  select * into o from orders where order_id = p_order;
  if not found then return jsonb_build_object('skipped', 'no order'); end if;
  select auto_invoice_on into v_mode from channels where channel_id = o.channel_id;
  if v_mode = 'manual' then return jsonb_build_object('skipped', 'channel invoices by hand'); end if;
  if o.fulfilment_status not in ('shipped', 'delivered') or (v_mode = 'delivered' and o.fulfilment_status <> 'delivered') then
    return jsonb_build_object('skipped', 'not at the invoicing stage'); end if;
  if exists (select 1 from invoices where order_id = p_order) then
    perform auto_issue_close('invoice_failed', 'order', p_order);
    return jsonb_build_object('skipped', 'already invoiced');
  end if;
  begin
    perform set_config('app.auto_post', 'on', true);
    perform post_sales_voucher(p_order);
    perform set_config('app.auto_post', 'off', true);
    perform auto_issue_close('invoice_failed', 'order', p_order);
    return jsonb_build_object('invoiced', true);
  exception when others then
    perform set_config('app.auto_post', 'off', true);
    perform auto_issue_open('invoice_failed', 'order', p_order, 'Order ' || o.external_order_id || ' could not be invoiced: ' || sqlerrm);
    return jsonb_build_object('failed', sqlerrm);
  end;
end $$;

-- ---------------------------------------------------------------- triggers
create or replace function trg_orders_fulfil() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if new.fulfilment_status in ('shipped', 'delivered') and (tg_op = 'INSERT' or old.fulfilment_status is distinct from new.fulfilment_status) then
      perform auto_dispatch_order(new.order_id);
      perform auto_invoice_order(new.order_id);
    elsif new.fulfilment_status = 'cancelled' and tg_op = 'UPDATE' and old.fulfilment_status is distinct from 'cancelled'
          and exists (select 1 from order_dispatch where order_id = new.order_id) then
      perform auto_issue_open('cancelled_after_dispatch', 'order', new.order_id,
        'Order ' || new.external_order_id || ' was cancelled after its stock was taken out. Confirm the goods came back and restock them through a return or an adjustment.');
    end if;
  exception when others then
    perform auto_issue_open('dispatch_failed', 'order', new.order_id, 'Automatic dispatch stopped: ' || sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_orders_fulfil on orders;
create trigger trg_orders_fulfil after insert or update of fulfilment_status on orders for each row execute function trg_orders_fulfil();

-- an order that arrives already shipped gets its lines a moment later: dispatch each line when it lands
create or replace function trg_order_lines_fulfil() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if exists (select 1 from orders where order_id = new.order_id and fulfilment_status in ('shipped', 'delivered')) then
      perform auto_dispatch_order(new.order_id);
    end if;
  exception when others then
    perform auto_issue_open('dispatch_failed', 'order', new.order_id, 'Automatic dispatch stopped: ' || sqlerrm);
  end;
  return null;
end $$;
drop trigger if exists trg_order_lines_fulfil on order_lines;
create constraint trigger trg_order_lines_fulfil after insert on order_lines deferrable initially deferred for each row execute function trg_order_lines_fulfil();

-- ---------------------------------------------------------------- retry what failed, by hand from the work queue or by the nightly job
create or replace function retry_automation_issue(p_issue uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare i automation_issues%rowtype; r jsonb := '{}'::jsonb;
begin
  if not (has_orders_write() or has_accounting_write()) then raise exception 'Not authorized'; end if;
  select * into i from automation_issues where issue_id = p_issue and status = 'open';
  if not found then raise exception 'That item is already closed'; end if;
  if i.kind = 'dispatch_failed' then r := auto_dispatch_order(i.entity_id);
  elsif i.kind = 'invoice_failed' then r := auto_invoice_order(i.entity_id);
  else raise exception 'This item has to be sorted out by a person'; end if;
  return r;
end $$;

create or replace function run_automation_retries() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare i record; n int := 0;
begin
  for i in select * from automation_issues where status = 'open' and kind in ('dispatch_failed', 'invoice_failed') and entity_type = 'order' loop
    if i.kind = 'dispatch_failed' then perform auto_dispatch_order(i.entity_id); else perform auto_invoice_order(i.entity_id); end if;
    n := n + 1;
  end loop;
  -- orders shipped before the switch was on, or whose trigger never ran
  for i in select o.order_id from orders o
            where o.fulfilment_status in ('shipped', 'delivered') and o.created_at > now() - interval '30 days'
              and exists (select 1 from order_lines ol where ol.order_id = o.order_id and ol.product_id is not null
                          and not exists (select 1 from order_dispatch d where d.order_line_id = ol.order_line_id)) loop
    perform auto_dispatch_order(i.order_id); n := n + 1;
  end loop;
  return jsonb_build_object('retried', n);
end $$;

revoke execute on function automation_on(text), set_automation_setting(text, text), auto_issue_open(text, text, uuid, text), auto_issue_close(text, text, uuid),
  pick_dispatch_warehouse(uuid), auto_dispatch_order(uuid), auto_invoice_order(uuid), retry_automation_issue(uuid), run_automation_retries(),
  trg_orders_fulfil(), trg_order_lines_fulfil(), post_sales_voucher(uuid) from public, anon, authenticated;
grant execute on function set_automation_setting(text, text), retry_automation_issue(uuid), post_sales_voucher(uuid) to authenticated;
grant execute on function automation_on(text) to authenticated;
