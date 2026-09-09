-- ============================================================================
-- Super Seller 360 — Fix: post_sales_voucher never checked fulfilment_status
--
-- Found during senior-QA testing: post_sales_voucher() checked that an
-- order existed and wasn't already invoiced, but never checked its
-- fulfilment_status. Confirmed live: a CANCELLED order was successfully
-- invoiced, generating phantom revenue for something never actually sold.
-- Fixed by rejecting 'cancelled' and 'rto' orders explicitly.
--
-- None of the previously-seeded invoices are affected — all 10 were
-- posted for genuinely delivered orders.
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
