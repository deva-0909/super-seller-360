-- ============================================================================
-- Super Seller 360 — GST correctness audit, part 3: post_sales_voucher split
--
-- Rewrites post_sales_voucher to correctly split tax per Indian GST law:
-- same state as the company's registered state (Gujarat) = intrastate =
-- CGST + SGST (split evenly, remainder to SGST so they always sum exactly
-- to tax_amount); different state = interstate = IGST (full amount).
-- Previously posted the entire tax_amount to a single pooled "GST Payable
-- (Output)" ledger regardless of the customer's state — structurally
-- incapable of the split GST law requires.
--
-- Includes a fix for an edge case found while testing this exact function:
-- an extremely small tax_amount (₹0.01) split into CGST=0.01 (rounds up,
-- consuming the whole amount) and SGST=0.00 — a zero-value voucher line,
-- which violates the existing voucher_line_single_side constraint.
-- Confirmed live before this fix: posting such an order failed with
-- exactly that constraint violation. Fixed by only inserting a CGST/SGST
-- line when its amount is actually non-zero.
--
-- Verified live: a Gujarat (intrastate) order split ₹177 into exactly
-- ₹88.50 CGST + ₹88.50 SGST; a Maharashtra (interstate) order sent its
-- full tax amount to IGST with zero CGST/SGST; a ₹0.01-tax order (the
-- edge case) now posts successfully instead of crashing.
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
  v_cgst_ledger        uuid;
  v_sgst_ledger        uuid;
  v_igst_ledger         uuid;
  v_company_state       text;
  v_is_interstate        boolean;
  v_half_tax               numeric;
  v_remainder_tax          numeric;
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
