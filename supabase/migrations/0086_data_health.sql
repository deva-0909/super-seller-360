-- 0086: Data health - cross-checks that the data agrees with itself across modules.
--
-- data_health() runs about 30 reconciliations (orders against invoices against journals, stock against movements, bills against payments,
-- payroll against its journal, assets against depreciation, and so on). Each check returns:
--   ok     nothing wrong        warn  worth a look, not a break        fail  the books disagree
--   empty  there is no data in that area yet (nothing to check)         error the check itself could not run
-- SECURITY INVOKER: it sees only what the caller's role can see, so run it as Super Admin / CEO / Auditor for the full picture.
-- Tolerance is 1 rupee on money comparisons (rounding).

create or replace function data_health()
returns table (module text, check_name text, status text, bad bigint, total bigint, hint text)
language plpgsql stable set search_path = public, pg_temp as $fn$
declare
  c record;
  v_bad bigint;
  v_tot bigint;
begin
  for c in
    select * from (values
      -- module, check, severity if bad, bad-count sql, total-count sql, hint
      ('Accounting', 'Debits equal credits across all posted entries', 'fail',
        $q$select case when abs(coalesce(sum(debit) - sum(credit), 0)) > 0.01 then 1 else 0 end from journal_entries where status = 'posted'$q$,
        $q$select count(*) from journal_entries where status = 'posted'$q$,
        'The books are out of balance. Find the voucher whose lines do not net to zero.'),
      ('Accounting', 'Voucher header totals match their lines', 'fail',
        $q$select count(*) from vouchers v where abs(v.total_debit - coalesce((select sum(debit) from voucher_lines l where l.voucher_id = v.voucher_id), 0)) > 0.01 or abs(v.total_credit - coalesce((select sum(credit) from voucher_lines l where l.voucher_id = v.voucher_id), 0)) > 0.01$q$,
        $q$select count(*) from vouchers$q$,
        'A voucher total differs from the sum of its lines.'),
      ('Accounting', 'Every voucher is balanced (debit = credit)', 'fail',
        $q$select count(*) from vouchers where abs(total_debit - total_credit) > 0.01$q$,
        $q$select count(*) from vouchers$q$, 'An unbalanced voucher exists.'),
      ('Accounting', 'Posted vouchers have matching ledger entries', 'fail',
        $q$select count(*) from vouchers v where v.status = 'posted' and abs(coalesce((select sum(debit) from journal_entries j where j.voucher_id = v.voucher_id), 0) - v.total_debit) > 0.01$q$,
        $q$select count(*) from vouchers where status = 'posted'$q$, 'A posted voucher has no or different ledger entries.'),
      ('Accounting', 'No voucher dated outside every accounting period', 'warn',
        $q$select count(*) from vouchers v where v.status = 'posted' and not exists (select 1 from accounting_periods p where v.voucher_date between p.start_date and p.end_date)$q$,
        $q$select count(*) from vouchers where status = 'posted'$q$, 'Create the accounting period that covers these dates.'),
      ('Accounting', 'Nothing posted into a period after it was closed', 'warn',
        $q$select count(*) from vouchers v join accounting_periods p on v.voucher_date between p.start_date and p.end_date where p.status <> 'open' and p.locked_at is not null and v.status = 'posted' and coalesce(v.source_type, '') <> 'period_close' and v.created_at > p.locked_at$q$,
        $q$select count(*) from vouchers where status = 'posted'$q$, 'Something was posted into a period after it was closed.'),

      ('Orders', 'Order total = gross - discount + tax', 'fail',
        $q$select count(*) from orders where abs(net_amount - (gross_amount - coalesce(discount, 0) + coalesce(tax_amount, 0))) > 1$q$,
        $q$select count(*) from orders$q$, 'An order header does not add up.'),
      ('Orders', 'Order lines add up to the order total', 'warn',
        $q$select count(*) from orders o where abs(o.net_amount - coalesce((select sum(l.quantity * l.unit_price - coalesce(l.discount, 0) + coalesce(l.tax, 0)) from order_lines l where l.order_id = o.order_id), 0)) > 1$q$,
        $q$select count(*) from orders$q$, 'The discount is on the order header but not on its lines (or the lines are missing).'),
      ('Orders', 'Every order has at least one line', 'fail',
        $q$select count(*) from orders o where not exists (select 1 from order_lines l where l.order_id = o.order_id)$q$,
        $q$select count(*) from orders$q$, 'An order with no items.'),
      ('Orders', 'Shipped or delivered orders are invoiced', 'warn',
        $q$select count(*) from orders o where o.fulfilment_status in ('shipped', 'delivered') and not exists (select 1 from invoices i where i.order_id = o.order_id)$q$,
        $q$select count(*) from orders where fulfilment_status in ('shipped', 'delivered')$q$, 'Invoice these orders (Orders screen).'),
      ('Orders', 'Invoice total = order total', 'fail',
        $q$select count(*) from invoices i join orders o on o.order_id = i.order_id where abs(i.total - o.net_amount) > 1$q$,
        $q$select count(*) from invoices$q$, 'An invoice differs from its order.'),
      ('Orders', 'Every invoice has a posted voucher', 'fail',
        $q$select count(*) from invoices i where i.voucher_id is null or not exists (select 1 from vouchers v where v.voucher_id = i.voucher_id and v.status = 'posted')$q$,
        $q$select count(*) from invoices$q$, 'An invoice is not reflected in the books.'),
      ('Orders', 'Invoice tax = tax on the order', 'warn',
        $q$select count(*) from invoices i join orders o on o.order_id = i.order_id where abs(i.gst_amount - o.tax_amount) > 1$q$,
        $q$select count(*) from invoices$q$, 'GST on the invoice differs from GST on the order.'),
      ('Orders', 'Dispatched quantity = ordered quantity (shipped/delivered)', 'warn',
        $q$select count(*) from order_lines l join orders o on o.order_id = l.order_id where o.fulfilment_status in ('shipped', 'delivered') and l.quantity <> coalesce((select sum(d.quantity) from order_dispatch d where d.order_line_id = l.order_line_id), 0)$q$,
        $q$select count(*) from order_lines l join orders o on o.order_id = l.order_id where o.fulfilment_status in ('shipped', 'delivered')$q$, 'Stock was not taken out for the full quantity.'),

      ('Inventory', 'Stock balance = sum of stock movements', 'fail',
        $q$select count(*) from inventory_balances b where abs(b.quantity - coalesce((select sum(t.quantity) from inventory_transactions t where t.product_id = b.product_id and t.warehouse_id = b.warehouse_id), 0)) > 0.001$q$,
        $q$select count(*) from inventory_balances$q$, 'A stock balance cannot be explained by its movements.'),
      ('Inventory', 'No negative stock', 'fail',
        $q$select count(*) from inventory_balances where quantity < 0$q$,
        $q$select count(*) from inventory_balances$q$, 'Stock below zero.'),
      ('Inventory', 'Active products have a channel listing', 'warn',
        $q$select count(*) from products p where p.status = 'active' and not exists (select 1 from channel_sku_map m where m.product_id = p.product_id)$q$,
        $q$select count(*) from products where status = 'active'$q$, 'Map these products to a marketplace listing.'),
      ('Inventory', 'Products have a cost price', 'warn',
        $q$select count(*) from products where status = 'active' and coalesce(cost_price, 0) <= 0$q$,
        $q$select count(*) from products where status = 'active'$q$, 'Margins cannot be worked out without a cost price.'),

      ('Settlements', 'Settlement lines belong to real orders', 'fail',
        $q$select count(*) from settlement_lines l where l.order_id is not null and not exists (select 1 from orders o where o.order_id = l.order_id)$q$,
        $q$select count(*) from settlement_lines$q$, 'A settlement line points to a missing order.'),
      ('Settlements', 'Reconciled settlements received what was expected', 'fail',
        $q$select count(*) from settlements where status = 'reconciled' and abs(coalesce(expected_amount, 0) - coalesce(actual_amount, 0)) > 1$q$,
        $q$select count(*) from settlements where status = 'reconciled'$q$, 'Marked reconciled but the amounts differ.'),
      ('Settlements', 'Short-paid settlements are really short', 'warn',
        $q$select count(*) from settlements where status = 'short_pay' and coalesce(actual_amount, 0) >= coalesce(expected_amount, 0)$q$,
        $q$select count(*) from settlements where status = 'short_pay'$q$, 'Marked short-pay but nothing is short.'),
      ('Settlements', 'Bank entries are reconciled (older than 30 days)', 'warn',
        $q$select count(*) from bank_transactions where recon_status = 'unreconciled' and txn_date < current_date - 30$q$,
        $q$select count(*) from bank_transactions$q$, 'Old bank lines still unmatched.'),
      ('Settlements', 'COD: collected <= COD amount and remitted <= collected', 'fail',
        $q$select count(*) from cod_collections where coalesce(collected_amount, 0) > cod_amount + 1 or coalesce(remitted_amount, 0) > coalesce(collected_amount, 0) + 1$q$,
        $q$select count(*) from cod_collections$q$, 'COD money does not add up.'),
      ('Settlements', 'COD records belong to COD orders', 'warn',
        $q$select count(*) from cod_collections c join orders o on o.order_id = c.order_id where o.payment_type <> 'cod'$q$,
        $q$select count(*) from cod_collections$q$, 'A COD record on a prepaid order.'),
      ('Returns', 'Refunded returns have a credit note', 'warn',
        $q$select count(*) from returns r where r.refund_status = 'refunded' and not exists (select 1 from credit_notes c where c.return_id = r.return_id)$q$,
        $q$select count(*) from returns where refund_status = 'refunded'$q$, 'Refund given without a credit note.'),
      ('Returns', 'Returns and RTOs belong to real orders', 'fail',
        $q$select (select count(*) from returns r where not exists (select 1 from orders o where o.order_id = r.order_id)) + (select count(*) from rtos r where not exists (select 1 from orders o where o.order_id = r.order_id))$q$,
        $q$select (select count(*) from returns) + (select count(*) from rtos)$q$, 'An orphan return.'),

      ('Purchasing', 'Bill total = taxable + GST', 'fail',
        $q$select count(*) from purchase_bills where abs(total - (taxable_value + cgst + sgst + igst)) > 1$q$,
        $q$select count(*) from purchase_bills$q$, 'A bill does not add up.'),
      ('Purchasing', 'Bill lines add up to the bill', 'fail',
        $q$select count(*) from purchase_bills b where not b.is_opening and abs(b.taxable_value - coalesce((select sum(l.taxable) from purchase_bill_lines l where l.bill_id = b.bill_id), 0)) > 1$q$,
        $q$select count(*) from purchase_bills where not is_opening$q$, 'Bill header and lines disagree.'),
      ('Purchasing', 'Amount payable = total - TDS', 'fail',
        $q$select count(*) from purchase_bills where abs(net_payable - (total - coalesce(tds_amount, 0))) > 1$q$,
        $q$select count(*) from purchase_bills$q$, 'Payable amount is wrong.'),
      ('Purchasing', 'GST split matches the supply type (intra: CGST+SGST, inter: IGST)', 'fail',
        $q$select count(*) from purchase_bills where (is_intra_state and igst <> 0) or (not is_intra_state and (cgst <> 0 or sgst <> 0))$q$,
        $q$select count(*) from purchase_bills$q$, 'Wrong GST type for the supplier state.'),
      ('Purchasing', 'Approved bills and payments are in the books', 'fail',
        $q$select (select count(*) from purchase_bills where status = 'approved' and voucher_id is null) + (select count(*) from supplier_payments where status = 'approved' and voucher_id is null)$q$,
        $q$select (select count(*) from purchase_bills where status = 'approved') + (select count(*) from supplier_payments where status = 'approved')$q$, 'Approved but not posted.'),
      ('Purchasing', 'Payments are fully allocated and never exceed the bill', 'fail',
        $q$select (select count(*) from supplier_payments p where p.status = 'approved' and abs(p.amount - coalesce((select sum(a.amount) from payment_allocations a where a.payment_id = p.payment_id), 0)) > 1) + (select count(*) from purchase_bills b where b.status = 'approved' and coalesce((select sum(a.amount) from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id where a.bill_id = b.bill_id and p.status = 'approved'), 0) > b.net_payable + 1)$q$,
        $q$select count(*) from supplier_payments where status = 'approved'$q$, 'A payment is not fully matched to bills, or a bill is overpaid.'),
      ('Purchasing', 'Goods received never exceed what was ordered', 'warn',
        $q$select count(*) from purchase_order_lines l where coalesce((select sum(g.qty_accepted + g.qty_rejected) from goods_receipt_lines g where g.po_line_id = l.po_line_id), 0) > l.quantity$q$,
        $q$select count(*) from purchase_order_lines$q$, 'Over-receipt against a purchase order.'),
      ('Purchasing', 'Suppliers have GSTIN and PAN', 'warn',
        $q$select count(*) from suppliers where status = 'active' and (coalesce(gstin, '') = '' or coalesce(pan, '') = '')$q$,
        $q$select count(*) from suppliers where status = 'active'$q$, 'Missing identifiers block GST and TDS reporting.'),
      ('Purchasing', 'TDS deposited never exceeds TDS deducted', 'warn',
        $q$select case when coalesce((select sum(tax) from tds_challans where status = 'approved'), 0) > coalesce((select sum(tds_amount) from purchase_bills where status = 'approved'), 0) + 1 then 1 else 0 end$q$,
        $q$select count(*) from tds_challans where status = 'approved'$q$, 'More TDS paid to the government than was deducted.'),

      ('Payroll', 'Payslip net = gross - deductions', 'fail',
        $q$select count(*) from payroll_lines where abs(net_pay - (gross - pf_ee - esi_ee - pt - lwf_ee - tds - coalesce(other_ded, 0))) > 1$q$,
        $q$select count(*) from payroll_lines$q$, 'A payslip does not add up.'),
      ('Payroll', 'Payslip gross = salary components', 'fail',
        $q$select count(*) from payroll_lines where abs(gross - (basic + da + hra + other_allowance + coalesce(extra_earning, 0))) > 1$q$,
        $q$select count(*) from payroll_lines$q$, 'Gross differs from the sum of the earnings.'),
      ('Payroll', 'Approved payroll runs are in the books', 'fail',
        $q$select count(*) from payroll_runs where status in ('approved', 'paid') and voucher_id is null$q$,
        $q$select count(*) from payroll_runs where status in ('approved', 'paid')$q$, 'Payroll approved but not posted.'),
      ('Payroll', 'Paid runs have a payment voucher', 'fail',
        $q$select count(*) from payroll_runs where status = 'paid' and paid_voucher_id is null$q$,
        $q$select count(*) from payroll_runs where status = 'paid'$q$, 'Marked paid with no bank entry.'),
      ('Payroll', 'Employees have PAN and bank details', 'warn',
        $q$select count(*) from employees e where e.status = 'active' and (coalesce(e.pan, '') = '' or not exists (select 1 from employee_bank b where b.emp_id = e.emp_id))$q$,
        $q$select count(*) from employees where status = 'active'$q$, 'Missing PAN or bank account.'),
      ('Payroll', 'Every active employee has a salary structure', 'fail',
        $q$select count(*) from employees e where e.status = 'active' and not exists (select 1 from employee_salary s where s.emp_id = e.emp_id)$q$,
        $q$select count(*) from employees where status = 'active'$q$, 'Cannot run payroll without a salary.'),

      ('Assets', 'Accumulated depreciation = sum of monthly depreciation', 'fail',
        $q$select count(*) from fixed_assets a where abs(a.accumulated_dep - coalesce((select sum(d.amount) from asset_depreciation d where d.asset_id = a.asset_id), 0)) > 1$q$,
        $q$select count(*) from fixed_assets$q$, 'Asset register differs from depreciation postings.'),
      ('Assets', 'Depreciation never exceeds cost less salvage', 'fail',
        $q$select count(*) from fixed_assets where accumulated_dep > cost - salvage_value + 1$q$,
        $q$select count(*) from fixed_assets$q$, 'Over-depreciated asset.'),

      ('Expenses', 'Claim total = sum of its lines', 'fail',
        $q$select count(*) from expense_claims c where abs(c.total - coalesce((select sum(l.amount) from expense_claim_lines l where l.claim_id = c.claim_id), 0)) > 1$q$,
        $q$select count(*) from expense_claims$q$, 'A claim total differs from its lines.'),
      ('Expenses', 'Approved and paid claims are in the books', 'fail',
        $q$select count(*) from expense_claims where (status in ('approved', 'paid') and voucher_id is null) or (status = 'paid' and paid_voucher_id is null)$q$,
        $q$select count(*) from expense_claims where status in ('approved', 'paid')$q$, 'Approved or paid but not posted.'),

      ('GST', 'Every GSTR-2B line is resolved or matched', 'warn',
        $q$select count(*) from gstr2b_lines where coalesce(resolution, '') = ''$q$,
        $q$select count(*) from gstr2b_lines$q$, 'Open items in the supplier-return reconciliation.'),
      ('GST', 'Filed GST returns cover the months that have sales', 'warn',
        $q$select count(*) from (select distinct to_char(invoice_date, 'YYYY-MM') p from invoices where invoice_date < date_trunc('month', current_date) - interval '1 month') m where not exists (select 1 from gst_filings f where f.return_type = 'GSTR-1' and f.period = m.p and not f.withdrawn)$q$,
        $q$select count(distinct to_char(invoice_date, 'YYYY-MM')) from invoices$q$, 'A past month with sales and no GSTR-1 filed.')
    ) as t(module, check_name, sev, bad_sql, tot_sql, hint)
  loop
    begin
      execute c.bad_sql into v_bad;
      execute c.tot_sql into v_tot;
      return query select c.module, c.check_name,
        case when coalesce(v_tot, 0) = 0 then 'empty' when coalesce(v_bad, 0) = 0 then 'ok' else c.sev end,
        coalesce(v_bad, 0), coalesce(v_tot, 0), c.hint;
    exception when others then
      return query select c.module, c.check_name, 'error', 0::bigint, 0::bigint, left(sqlerrm, 160);
    end;
  end loop;
end
$fn$;

revoke execute on function data_health() from public, anon;
grant execute on function data_health() to authenticated;
