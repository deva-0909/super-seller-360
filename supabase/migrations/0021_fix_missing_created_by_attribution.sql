-- ============================================================================
-- Super Seller 360 — Fix: post_sales_voucher/close_accounting_period never
-- set vouchers.created_by
--
-- Found while building the Audit Trail screen — checked whether the data it
-- would display was real before building on top of it, and it wasn't.
-- Confirmed live: 11 real posted vouchers, 0 attributed to anyone, despite
-- the created_by column existing and both functions being SECURITY DEFINER
-- with auth.uid() readily available.
-- ============================================================================

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
  v_gst_ledger        uuid;
begin
  if not (has_orders_write() or has_accounting_write()) then
    raise exception 'Not authorized to post sales vouchers';
  end if;

  select * into v_order from orders where order_id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
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
  select ledger_id into v_gst_ledger from ledgers where name = 'GST Payable (Output)';

  if v_voucher_type_id is null or v_receivable_ledger is null or v_sales_ledger is null then
    raise exception 'Accounting masters not seeded — run the Phase 2 seed data first.';
  end if;

  v_invoice_number := 'INV-' || to_char(now(), 'YYYYMM') || '-' ||
    lpad((select count(*) + 1 from invoices where invoice_number like 'INV-' || to_char(now(), 'YYYYMM') || '-%')::text, 5, '0');

  insert into vouchers (
    voucher_type_id, voucher_no, voucher_date, accounting_period_id,
    status, source_type, source_id, narration, total_debit, total_credit, created_by
  ) values (
    v_voucher_type_id, v_invoice_number, v_order.order_date::date, v_period_id,
    'draft', 'order', p_order_id, 'Sales invoice for order ' || v_order.external_order_id,
    v_order.net_amount, v_order.net_amount, auth.uid()
  ) returning voucher_id into v_voucher_id;

  insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
  values (v_voucher_id, v_receivable_ledger, v_order.net_amount, 0, 'order', p_order_id);

  if v_order.tax_amount > 0 and v_gst_ledger is not null then
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_sales_ledger, 0, v_order.net_amount - v_order.tax_amount, 'order', p_order_id);
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_gst_ledger, 0, v_order.tax_amount, 'order', p_order_id);
  else
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_sales_ledger, 0, v_order.net_amount, 'order', p_order_id);
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

create or replace function close_accounting_period(p_period_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period accounting_periods%rowtype;
  v_voucher_type_id uuid;
  v_voucher_id uuid;
  v_retained_earnings_ledger uuid;
  v_line record;
  v_total_debit numeric := 0;
  v_total_credit numeric := 0;
  v_net_profit numeric := 0;
begin
  if not has_period_close() then
    raise exception 'Not authorized to close accounting periods';
  end if;

  select * into v_period from accounting_periods where accounting_period_id = p_period_id;
  if not found then
    raise exception 'Accounting period % not found', p_period_id;
  end if;
  if v_period.status <> 'open' then
    raise exception 'Period % is already %', v_period.period_name, v_period.status;
  end if;

  select ledger_id into v_retained_earnings_ledger from ledgers where name = 'Retained Earnings';
  select voucher_type_id into v_voucher_type_id from voucher_types where code = 'JOURNAL';

  insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, source_type, source_id, narration, total_debit, total_credit, created_by)
  values (v_voucher_type_id, 'CLOSE-' || v_period.period_name, v_period.end_date, p_period_id, 'draft', 'period_close', p_period_id, 'Period close: ' || v_period.period_name, 0, 0, auth.uid())
  returning voucher_id into v_voucher_id;

  for v_line in
    select l.ledger_id, sum(je.credit) - sum(je.debit) as balance
    from ledgers l
    join journal_entries je on je.account_id = l.ledger_id
    where l.nature = 'income' and je.date between v_period.start_date and v_period.end_date
    group by l.ledger_id
    having sum(je.credit) - sum(je.debit) <> 0
  loop
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_line.ledger_id, v_line.balance, 0, 'period_close', p_period_id);
    v_total_debit := v_total_debit + v_line.balance;
    v_net_profit := v_net_profit + v_line.balance;
  end loop;

  for v_line in
    select l.ledger_id, sum(je.debit) - sum(je.credit) as balance
    from ledgers l
    join journal_entries je on je.account_id = l.ledger_id
    where l.nature = 'expense' and je.date between v_period.start_date and v_period.end_date
    group by l.ledger_id
    having sum(je.debit) - sum(je.credit) <> 0
  loop
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_line.ledger_id, 0, v_line.balance, 'period_close', p_period_id);
    v_total_credit := v_total_credit + v_line.balance;
    v_net_profit := v_net_profit - v_line.balance;
  end loop;

  if v_total_debit <> 0 or v_total_credit <> 0 then
    if v_net_profit >= 0 then
      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_retained_earnings_ledger, 0, v_net_profit, 'period_close', p_period_id);
      v_total_credit := v_total_credit + v_net_profit;
    else
      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_retained_earnings_ledger, -v_net_profit, 0, 'period_close', p_period_id);
      v_total_debit := v_total_debit - v_net_profit;
    end if;

    update vouchers set total_debit = v_total_debit, total_credit = v_total_credit, status = 'posted'
      where voucher_id = v_voucher_id;
  else
    delete from vouchers where voucher_id = v_voucher_id;
    v_voucher_id := null;
  end if;

  update accounting_periods
    set status = 'closed', locked_at = now(), closed_by = auth.uid()
    where accounting_period_id = p_period_id;

  return v_voucher_id;
end;
$$;
