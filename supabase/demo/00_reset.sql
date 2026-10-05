-- 00_reset.sql - clears the demo TRANSACTIONS so the story can be loaded cleanly.
-- Keeps: users and roles, company, channels, warehouses, bank accounts, products, ledgers and account groups, the Rule Book, tax and statutory settings, connection settings.
-- Removes: orders, invoices, vouchers and journals, stock movements, returns, RTOs, COD, settlements, bank lines, purchases, payroll, assets, filings, accounting periods.
begin;
truncate table accounting_periods, opening_balances, vouchers, voucher_lines, journal_entries, journal_review, journal_rule_log, invoices, credit_notes, einvoice_records, orders, order_lines, order_dispatch, order_status_history, shipments, cod_collections, returns, rtos, claims, settlements, settlement_lines, settlement_fee_dismissals, bank_transactions, bank_recon_matches, bank_recon_suggestions, bank_recon_book_exclusions, inventory_transactions, inventory_balances, automation_issues, marketplace_credit_entries, supplier_credit_notes, supplier_payments, payment_allocations, payment_runs, payment_run_items, purchase_orders, purchase_order_lines, goods_receipts, goods_receipt_lines, purchase_bills, purchase_bill_lines, tds_challans, gst_filings, gstr2b_uploads, gstr2b_lines, gst_itc_adjustments, tax_transactions, employees, employee_bank, employee_declarations, employee_salary, payroll_runs, payroll_lines, payroll_remittances, bonus_runs, bonus_lines, fnf_settlements, leave_entries, expense_claims, expense_claim_lines, fixed_assets, asset_depreciation, recurring_journal_runs, cash_movements, cash_plan_items, cash_settlement_reports, cash_settlement_report_lines, notifications, message_outbox, import_runs, import_run_rows, attachments, compliance_filings, job_runs, connector_log, channel_sku_map, rate_change_log, role_preview restart identity cascade;
-- suppliers are removed one by one (not truncated) so the product catalogue that points to a preferred supplier is kept
update products set preferred_supplier_id = null where preferred_supplier_id is not null;
delete from supplier_bank;
delete from suppliers;
update ledgers set opening_balance = 0, opening_balance_type = null;
-- document numbers start again from 1
do $$ declare s record; begin
  for s in select c.relname from pg_class c where c.relkind = 'S' and c.relnamespace = 'public'::regnamespace
            and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype in ('a', 'i')) loop
    execute format('alter sequence public.%I restart', s.relname);
  end loop;
end $$;
commit;
