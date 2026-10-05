-- 0087: let the posting engine use the date of the business event, not only today's date.
--
-- Everything the books post on its own (a return accepted, COD received, a settlement matched, stock dispatched, a claim recovered) was
-- dated "today". That is right when people work live, but wrong when old records are loaded or caught up (for example history imported
-- from another system, or a demo dataset): a return received in April would be booked in October.
--
-- app_today() returns the date set for the current session (select set_config('app.today', '2026-04-12', false)), and today's date when
-- nothing is set - so normal use does not change at all. The functions below now call it instead of current_date.
-- Sales invoices also take their number from the invoice date (INV-YYYYMM), not from the month the record was entered.

create or replace function app_today() returns date language sql stable as $$
  select coalesce(nullif(current_setting('app.today', true), '')::date, current_date)
$$;
revoke execute on function app_today() from public, anon;
grant execute on function app_today() to authenticated;

do $$
declare f record; d text;
begin
  -- functions that post or date a record of their own. Where the date matters (posting, numbering, "not in the future" checks) they now ask app_today().
  for f in select p.oid, p.proname from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
              and p.proname in ('trg_claims_journal', 'trg_cod_journal', 'trg_inventory_journal', 'trg_orders_journal', 'trg_returns_journal',
                                'trg_rtos_journal', 'trg_settlements_journal', 'post_journal_event', 'reconcile_settlement', 'record_cod_remittance',
                                'po_create', 'create_expense_claim', 'pay_expense_claim', 'approve_expense_claim', 'create_supplier_payment',
                                'create_supplier_credit_note', 'create_tds_challan', 'asset_create', 'asset_depreciate_month', 'payroll_run_create',
                                'payroll_run_pay', 'payroll_remit', 'bonus_create', 'bonus_pay', 'fnf_pay', 'fnf_approve', 'employee_exit',
                                'leave_record', 'leave_accrue', 'record_gst_filing', 'mtax_reconcile', 'mtax_credit_set', 'create_opening_bills',
                                'payment_run_create', 'payment_run_complete', 'create_purchase_bill', 'grn_create', 'submit_cash_settlement')
  loop
    d := pg_get_functiondef(f.oid);
    d := regexp_replace(d, 'current_date', 'app_today()', 'gi');
    d := replace(d, 'to_char(now()', 'to_char(app_today()');
    execute d;
  end loop;

  -- invoice number follows the invoice (order) date
  select pg_get_functiondef(p.oid) into d from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'post_sales_voucher';
  d := replace(d, 'to_char(now(), ''YYYYMM'')', 'to_char(v_order.order_date, ''YYYYMM'')');
  execute d;
end $$;
