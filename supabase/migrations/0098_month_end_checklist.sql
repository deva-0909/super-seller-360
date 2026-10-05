-- 0098: month-end books-health checklist. Read-only: it counts what still needs attention for a month; it changes nothing.
create or replace function month_end_checklist(p_month text) returns table (c_key text, c_label text, c_status text, c_n bigint, c_detail text, c_href text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_from date; v_to date; v_next date; tb numeric; v_today date := current_date;
begin
  if not (has_books_view() or has_accounting_view()) then raise exception 'Not authorized'; end if;
  if p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'Month must look like 2026-09'; end if;
  v_from := (p_month || '-01')::date; v_to := (v_from + interval '1 month - 1 day')::date; v_next := (v_from + interval '1 month')::date;

  -- 1 books balance
  select coalesce(sum(closing), 0) into tb from trial_balance(date '2000-01-01', v_to);
  return query select 'tb', 'Trial Balance agrees (debits = credits)', case when abs(tb) < 0.01 then 'ok' else 'fail' end, case when abs(tb) < 0.01 then 0 else 1 end::bigint,
    case when abs(tb) < 0.01 then 'Balanced as on ' || v_to else 'Out of balance by ' || round(abs(tb), 2) end, '/accounting/trial-balance';

  -- 2 bank lines not in the books
  return query select 'bank', 'Bank lines still to review', case when c = 0 then 'ok' else 'warn' end, c,
    case when c = 0 then 'Every bank line this month is in the books or set aside' else c || ' line(s) are not in the books yet' end, '/bank/review'
    from (select count(*) c from bank_transactions where txn_date between v_from and v_to and recon_status in ('unreconciled','suggested')) x;

  -- 3 marketplace settlements not closed
  return query select 'settle', 'Marketplace settlements still open', case when c = 0 then 'ok' else 'warn' end, c,
    case when c = 0 then 'All settlements for the month are reconciled' else c || ' settlement(s) pending, short-paid or in excess' end, '/settlements'
    from (select count(*) c from settlements where period_end between v_from and v_to and status in ('pending','short_pay','excess')) x;

  -- 4 purchase bills waiting for approval
  return query select 'bills_pending', 'Purchase bills waiting for approval', case when c = 0 then 'ok' else 'warn' end, c,
    case when c = 0 then 'No bill dated this month is waiting' else c || ' bill(s) not yet approved, so not in the books or GST credit' end, '/purchases/bills'
    from (select count(*) c from purchase_bills where bill_date between v_from and v_to and status = 'pending') x;

  -- 5 supplier invoices dated this month but booked later (cut-off)
  return query select 'cutoff', 'Supplier invoices dated this month but booked later', case when c = 0 then 'ok' else 'warn' end, c,
    case when c = 0 then 'No late-booked invoices for the month' else c || ' invoice(s) belong to this month but are booked after it; consider an accrual' end, '/purchases/bills'
    from (select count(*) c from purchase_bills where status = 'approved' and supplier_invoice_date between v_from and v_to and bill_date > v_to) x;

  -- 6 staff expense claims in the pipeline
  return query select 'claims', 'Staff expense claims not yet decided', case when c = 0 then 'ok' else 'warn' end, c,
    case when c = 0 then 'Nothing waiting' else c || ' claim(s) submitted or manager-approved but not final' end, '/expenses'
    from (select count(*) c from expense_claims where status in ('submitted','manager_approved') and created_at::date <= v_to) x;

  -- 7 payroll
  return query select 'payroll', 'Payroll for the month', case when r.status = 'paid' then 'ok' when r.run_id is null then (case when v_today > v_to then 'fail' else 'warn' end) else 'warn' end,
    case when r.run_id is null then 0 else 1 end::bigint,
    case when r.run_id is null then 'No pay run for this month' else 'Run ' || r.run_no || ' is ' || r.status end, '/payroll'
    from (select 1) d left join lateral (select run_id, run_no, status from payroll_runs where month = v_from or to_char(month, 'YYYY-MM') = p_month order by created_at desc limit 1) r on true;

  -- 8 GST returns
  return query select 'gstr1', 'GSTR-1 filed', case when exists (select 1 from gst_filings f where f.period = p_month and f.return_type = 'GSTR1' and not f.withdrawn) then 'ok'
                                                       when v_today > (v_next + 10) then 'fail' else 'warn' end,
    0::bigint, 'Due on ' || to_char(v_next + 10, 'DD Mon YYYY'), '/gst/gstr1';
  return query select 'gstr3b', 'GSTR-3B filed', case when exists (select 1 from gst_filings f where f.period = p_month and f.return_type = 'GSTR3B' and not f.withdrawn) then 'ok'
                                                        when v_today > (v_next + 19) then 'fail' else 'warn' end,
    0::bigint, 'Due on ' || to_char(v_next + 19, 'DD Mon YYYY'), '/gst';

  -- 9 COD cash still with couriers for a long time
  return query select 'cod', 'COD orders delivered over 30 days ago and not settled', case when c = 0 then 'ok' else 'warn' end, c,
    case when c = 0 then 'None overdue' else c || ' marketplace COD order(s) have no settlement yet' end, '/cod'
    from (select count(*) c from cod_awaiting_settlement where days_old > 30) x;

  -- 10 data health
  return query select 'health', 'Data health checks', case when c = 0 then 'ok' else 'warn' end, c,
    case when c = 0 then 'All checks pass' else c || ' check(s) need attention' end, '/admin/data-health'
    from (select count(*) c from data_health() where status <> 'ok') x;

  -- 11 period state
  return query select 'period', 'Accounting period status', 'info', 0::bigint,
    coalesce((select 'Period ' || period_name || ' is ' || ap.status from accounting_periods ap where v_from between ap.start_date and ap.end_date limit 1), 'No accounting period covers this month'),
    '/accounting/periods';
end $$;
revoke execute on function month_end_checklist(text) from public, anon;
grant execute on function month_end_checklist(text) to authenticated;
