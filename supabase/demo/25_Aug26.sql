-- 25_Aug26.sql - August 2026: rent and bills, payroll, taxes and bank entries, day by day.
begin;
select set_config('request.jwt.claims', json_build_object('sub', (select user_id from user_profiles where email = 'amitsdeva@gmail.com'), 'role', 'authenticated')::text, false);
select set_config('demo.t0', clock_timestamp()::text, false);


create or replace function pg_temp.as_user(p_who text) returns void language plpgsql as $f$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', (select user_id from user_profiles where email = case p_who when 'sa' then 'amitsdeva@gmail.com' when 'acc' then 'vikram.rao@superseller360.demo' when 'fin' then 'rohan.mehta@superseller360.demo' when 'ops' then 'priya.sharma@superseller360.demo' when 'wh' then 'kavita.desai@superseller360.demo' when 'mkt' then 'arjun.nair@superseller360.demo' when 'tax' then 'meera.iyer@superseller360.demo' end), 'role', 'authenticated')::text, false);
end $f$;

-- a hand journal for a routine entry (a transfer between our own banks, a month-end set-off, a bank charge); an entry big enough to be held is approved by the Finance Manager
create or replace function pg_temp.mj(p_date date, p_narr text, p_lines jsonb) returns void language plpgsql as $f$
declare r jsonb;
begin
  perform pg_temp.as_user('acc');
  r := post_manual_journal(p_date, p_narr, p_lines, null, true, 'Routine entry, supporting statement or challan on file');
  if coalesce((r ->> 'held')::boolean, false) then
    perform pg_temp.as_user('fin'); perform journal_hold_decide((r ->> 'voucher_id')::uuid, true, 'Checked against the statement'); perform pg_temp.as_user('acc');
  end if;
end $f$;

create or replace function pg_temp.day(p_d date) returns void language plpgsql as $f$
begin perform set_config('app.today', p_d::text, false); end $f$;

create or replace function pg_temp.hdfc() returns uuid language sql as $f$ select bank_account_id from bank_accounts where account_number_last4 = '4821' $f$;
create or replace function pg_temp.icici() returns uuid language sql as $f$ select bank_account_id from bank_accounts where account_number_last4 = '7734' $f$;
create or replace function pg_temp.ts(p_t time) returns timestamptz language sql as $f$ select (app_today()::timestamp + p_t) at time zone 'Asia/Kolkata' $f$;

-- the engine stamps new rows with the real clock; rows made for a past day are given that day's date and a working-hours time
create or replace function pg_temp.retime() returns void language plpgsql as $f$
declare t0 timestamptz := coalesce(nullif(current_setting('demo.t0', true), '')::timestamptz, '2000-01-01');
        d timestamptz := (app_today()::timestamp + time '11:30') at time zone 'Asia/Kolkata';
        t text; c text;
begin
  foreach t in array array['purchase_bills','supplier_payments','suppliers','supplier_bank','employees','payroll_runs','fnf_settlements','bonus_runs','tds_challans','gst_filings','gstr2b_uploads',
                           'fixed_assets','asset_depreciation','expense_claims','marketplace_credit_entries','leave_entries','automation_issues'] loop
    foreach c in array array['created_at','decided_at','approved_at','submitted_at','manager_at','final_at','paid_at','entered_at','uploaded_at','updated_at'] loop
      if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = c) then
        begin
          execute format('update %I set %I = %L where %I >= %L', t, c, d, c, t0);
        exception when others then null;
        end;
      end if;
    end loop;
  end loop;
  perform set_config('demo.t0', clock_timestamp()::text, false);
end $f$;

-- a statement line on a bank account; the engine drafts an "unclassified" entry for it, which is withdrawn because the real entry is booked by the process itself
create or replace function pg_temp.bline(p_bank uuid, p_ref text, p_amount numeric, p_type text) returns uuid language plpgsql as $f$
declare v_txn uuid;
begin
  insert into bank_transactions (bank_account_id, txn_date, reference, amount, type, match_status, source, created_at)
  values (p_bank, app_today(), p_ref, round(p_amount, 2), p_type, 'unmatched', 'csv', pg_temp.ts('12:00')) returning bank_txn_id into v_txn;
  perform br_cancel_rule_draft(v_txn);
  return v_txn;
end $f$;

-- keep the HDFC current account funded: move money from the ICICI collections account in lumps of Rs 50,000
create or replace function pg_temp.fund_hdfc(p_need numeric) returns void language plpgsql as $f$
declare v_h uuid; v_i uuid; v_bal numeric; v_top numeric;
begin
  select ledger_id into v_h from ledgers where name = 'Bank - HDFC Bank (4821)';
  select ledger_id into v_i from ledgers where name = 'Bank - ICICI Bank (7734)';
  select coalesce(sum(debit - credit), 0) + (select opening_balance from ledgers where ledger_id = v_h) into v_bal from journal_entries where account_id = v_h and date <= app_today();
  if v_bal >= p_need then return; end if;
  v_top := ceil((p_need - v_bal) / 50000.0) * 50000;
  perform pg_temp.as_user('acc');
  perform pg_temp.mj(app_today(), 'Funds moved from ICICI collections account to HDFC current account',
    jsonb_build_array(jsonb_build_object('ledger_id', v_h, 'debit', v_top, 'credit', 0, 'narration', 'Transfer in from ICICI 7734'),
                      jsonb_build_object('ledger_id', v_i, 'debit', 0, 'credit', v_top, 'narration', 'Transfer out to HDFC 4821')));
  perform pg_temp.bline(pg_temp.icici(), 'NEFT/IB TRF/HDFC 4821', v_top, 'debit');
  perform pg_temp.bline(pg_temp.hdfc(), 'NEFT/IB TRF/ICICI 7734', v_top, 'credit');
end $f$;

-- ---------------------------------------------------------------- suppliers
create or replace function pg_temp.sup_new(p_json jsonb, p_approve boolean default true) returns uuid language plpgsql as $f$
declare v uuid;
begin
  perform pg_temp.as_user('acc');
  v := supplier_save(null, p_json);
  if p_approve then perform pg_temp.as_user('fin'); perform supplier_decide(v, 'approve'); perform pg_temp.as_user('acc'); end if;
  return v;
end $f$;

-- ---------------------------------------------------------------- bills and payments
-- p_lines: [{"d": description, "h": hsn, "q": qty, "p": unit price, "r": gst rate, "l": ledger name}]
create or replace function pg_temp.bill_new(p_sup text, p_inv text, p_inv_date date, p_lines jsonb, p_approve boolean default true) returns uuid language plpgsql as $f$
declare v_s uuid; v_l jsonb; v_id uuid;
begin
  select supplier_id into v_s from suppliers where name = p_sup;
  if v_s is null then raise exception 'demo: supplier % not found', p_sup; end if;
  select jsonb_agg(jsonb_build_object('description', t.x ->> 'd', 'hsn_code', t.x ->> 'h', 'quantity', (t.x ->> 'q')::numeric, 'unit_price', (t.x ->> 'p')::numeric,
                                      'gst_rate', (t.x ->> 'r')::numeric, 'ledger_id', (select ledger_id from ledgers where name = t.x ->> 'l')) order by t.ord)
    into v_l from jsonb_array_elements(p_lines) with ordinality t(x, ord);
  perform pg_temp.as_user('acc');
  v_id := create_purchase_bill(v_s, p_inv, p_inv_date, app_today(), v_l, true, null, null);
  if p_approve then
    perform pg_temp.as_user('fin');
    perform approve_purchase_bill(v_id);
    perform pg_temp.as_user('acc');
  end if;
  return v_id;
end $f$;

-- pay what is owed to a supplier (every approved bill with something outstanding) from the HDFC account
create or replace function pg_temp.pay_sup(p_sup text, p_utr text, p_frac numeric default 1, p_approve boolean default true) returns numeric language plpgsql as $f$
declare v_s uuid; v_alloc jsonb; v_tot numeric; v_pay uuid;
begin
  select supplier_id into v_s from suppliers where name = p_sup;
  select jsonb_agg(jsonb_build_object('bill_id', x.bill_id, 'amount', x.amt)), sum(x.amt) into v_alloc, v_tot
    from (select b.bill_id, round(bill_outstanding(b.bill_id, null, true) * p_frac, 2) amt from purchase_bills b
           where b.supplier_id = v_s and b.status = 'approved' and bill_outstanding(b.bill_id, null, true) > 0) x where x.amt > 0;
  if v_tot is null or v_tot <= 0 then return 0; end if;
  perform pg_temp.fund_hdfc(v_tot + 25000);
  perform pg_temp.as_user('acc');
  v_pay := create_supplier_payment(v_s, app_today(), 'bank', pg_temp.hdfc(), v_tot, p_utr, null, v_alloc);
  if p_approve then
    perform pg_temp.as_user('fin');
    perform approve_supplier_payment(v_pay);
    perform pg_temp.as_user('acc');
    perform pg_temp.bline(pg_temp.hdfc(), 'NEFT/' || p_utr || '/' || p_sup, v_tot, 'debit');
  end if;
  return v_tot;
end $f$;

-- the courier and 3PL bills are worked out from the month's real orders
create or replace function pg_temp.month_orders(p_month date, p_channel text, p_where text default 'true') returns bigint language plpgsql as $f$
declare n bigint;
begin
  execute format($q$select count(*) from orders o join channels c on c.channel_id = o.channel_id
     where c.name like %L and o.order_date >= %L and o.order_date < (%L::date + interval '1 month') and o.fulfilment_status in ('shipped','delivered','rto') and %s$q$,
     p_channel, p_month, p_month, p_where) into n;
  return n;
end $f$;
create or replace function pg_temp.month_orders_wh(p_month date, p_wh text) returns bigint language sql as $f$
  select count(*) from orders o join warehouses w on w.warehouse_id = o.warehouse_id
   where w.name like p_wh and o.order_date >= p_month and o.order_date < (p_month + interval '1 month') and o.fulfilment_status in ('shipped','delivered','rto')
$f$;

-- ---------------------------------------------------------------- TDS deposit (challan) for a month's deductions
create or replace function pg_temp.tds_deposit(p_period text, p_late_months int default 0, p_approve boolean default true) returns numeric language plpgsql as $f$
declare s record; v_pos jsonb; v_left numeric; v_id uuid; v_n int; v_first boolean := true; v_tot numeric := 0; v_int numeric;
begin
  for s in select section from tds_sections where active order by section loop
    v_pos := tds_position(p_period, s.section);
    v_left := coalesce((v_pos ->> 'deducted')::numeric, 0) - coalesce((v_pos ->> 'paid')::numeric, 0) - coalesce((v_pos ->> 'pending')::numeric, 0);
    if v_left > 0 then
      v_n := coalesce(nullif(current_setting('demo.chal_seq', true), ''), '0')::int + 1;
      perform set_config('demo.chal_seq', v_n::text, false);
      v_int := round(v_left * 0.015 * p_late_months, 0);
      perform pg_temp.fund_hdfc(v_left + v_int + 25000);
      perform pg_temp.as_user('acc');
      v_id := create_tds_challan(p_period, s.section, v_left, v_int, 0, app_today(), pg_temp.hdfc(), '6360222', lpad((v_n + 10400)::text, 5, '0'), null);
      if p_approve then
        perform pg_temp.as_user('fin');
        perform approve_tds_challan(v_id);
        perform pg_temp.as_user('acc');
        perform pg_temp.bline(pg_temp.hdfc(), 'CBDT/OLTAS/TDS ' || s.section || ' ' || p_period || '/BSR 6360222', v_left + v_int, 'debit');
      end if;
      v_tot := v_tot + v_left + v_int; v_first := false;
    end if;
  end loop;
  return v_tot;
end $f$;

-- ---------------------------------------------------------------- GST: set the month's credits against its tax, pay the rest, file the returns
create or replace function pg_temp.gst_setoff(p_period text) returns numeric language plpgsql as $f$
declare
  m_end date := (to_date(p_period || '-01', 'YYYY-MM-DD') + interval '1 month - 1 day')::date;
  l_oc uuid; l_os uuid; l_oi uuid; l_ic uuid; l_is uuid; l_ii uuid; l_ig uuid; l_tcs uuid; l_h uuid;
  oc numeric; os numeric; oi numeric; ic numeric; is_ numeric; ii numeric; ig numeric; tcs numeric;
  tot_out numeric; t numeric; u_ic numeric := 0; u_is numeric := 0; u_ii numeric := 0; u_ig numeric := 0; ci numeric; v_tcs numeric := 0; v_cash numeric; r_tot numeric;
  v_lines jsonb := '[]'::jsonb;
  function_name text;
begin
  select ledger_id into l_oc from ledgers where name = 'CGST Payable (Output)';
  select ledger_id into l_os from ledgers where name = 'SGST Payable (Output)';
  select ledger_id into l_oi from ledgers where name = 'IGST Payable (Output)';
  select ledger_id into l_ic from ledgers where name = 'Input CGST';
  select ledger_id into l_is from ledgers where name = 'Input SGST';
  select ledger_id into l_ii from ledgers where name = 'Input IGST';
  select ledger_id into l_ig from ledgers where name = 'GST Input Tax Credit (ITC)';
  select ledger_id into l_tcs from ledgers where name = 'GST TCS Credit Receivable';
  select ledger_id into l_h from ledgers where name = 'Bank - HDFC Bank (4821)';
  select greatest(coalesce(sum(credit - debit), 0), 0) into oc from journal_entries where account_id = l_oc and date <= m_end;
  select greatest(coalesce(sum(credit - debit), 0), 0) into os from journal_entries where account_id = l_os and date <= m_end;
  select greatest(coalesce(sum(credit - debit), 0), 0) into oi from journal_entries where account_id = l_oi and date <= m_end;
  select greatest(coalesce(sum(debit - credit), 0), 0) into ic from journal_entries where account_id = l_ic and date <= m_end;
  select greatest(coalesce(sum(debit - credit), 0), 0) into is_ from journal_entries where account_id = l_is and date <= m_end;
  select greatest(coalesce(sum(debit - credit), 0), 0) into ii from journal_entries where account_id = l_ii and date <= m_end;
  select greatest(coalesce(sum(debit - credit), 0), 0) into ig from journal_entries where account_id = l_ig and date <= m_end;
  select greatest(coalesce(sum(debit - credit), 0), 0) into tcs from journal_entries where account_id = l_tcs and date <= m_end;
  tot_out := oc + os + oi;
  if tot_out <= 0 then perform set_config('demo.cash3b', '0', false); return 0; end if;
  -- credit is used in the order the law sets: IGST credit against IGST, then CGST, then SGST; CGST credit against CGST, then IGST; SGST credit against SGST, then IGST
  declare ci_i numeric := ii + ig; rc numeric := oc; rs numeric := os; ri numeric := oi; used numeric;
  begin
    t := least(ci_i, ri); ri := ri - t; ci_i := ci_i - t; u_ii := t;
    t := least(ci_i, rc); rc := rc - t; ci_i := ci_i - t; u_ii := u_ii + t;
    t := least(ci_i, rs); rs := rs - t; ci_i := ci_i - t; u_ii := u_ii + t;
    t := least(ic, rc); rc := rc - t; u_ic := t;
    t := least(ic - u_ic, ri); ri := ri - t; u_ic := u_ic + t;
    t := least(is_, rs); rs := rs - t; u_is := t;
    t := least(is_ - u_is, ri); ri := ri - t; u_is := u_is + t;
    r_tot := rc + rs + ri;
    v_tcs := least(tcs, r_tot);
    v_cash := r_tot - v_tcs;
    -- the combined IGST-type credit comes first from the Input IGST ledger, then from the general ITC ledger
    u_ig := greatest(u_ii - ii, 0); u_ii := least(u_ii, ii);
  end;
  if v_cash > 0 then perform pg_temp.fund_hdfc(v_cash + 25000); end if;
  if oc > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_oc, 'debit', oc, 'credit', 0, 'narration', 'CGST payable ' || p_period); end if;
  if os > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_os, 'debit', os, 'credit', 0, 'narration', 'SGST payable ' || p_period); end if;
  if oi > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_oi, 'debit', oi, 'credit', 0, 'narration', 'IGST payable ' || p_period); end if;
  if u_ic > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_ic, 'debit', 0, 'credit', u_ic, 'narration', 'CGST credit used'); end if;
  if u_is > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_is, 'debit', 0, 'credit', u_is, 'narration', 'SGST credit used'); end if;
  if u_ii > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_ii, 'debit', 0, 'credit', u_ii, 'narration', 'IGST credit used'); end if;
  if u_ig > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_ig, 'debit', 0, 'credit', u_ig, 'narration', 'IGST credit on marketplace fees used'); end if;
  if v_tcs > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tcs, 'debit', 0, 'credit', v_tcs, 'narration', 'GST TCS credit used'); end if;
  if v_cash > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_h, 'debit', 0, 'credit', v_cash, 'narration', 'GST paid in cash'); end if;
  perform pg_temp.as_user('acc');
  perform pg_temp.mj(app_today(), 'GST for ' || p_period || ': credits set off against tax, balance paid (GSTR-3B)', v_lines);
  if v_cash > 0 then perform pg_temp.bline(pg_temp.hdfc(), 'GST/PMT-06/CPIN' || to_char(app_today(), 'YYMMDD') || '/' || p_period, v_cash, 'debit'); end if;
  perform set_config('demo.cash3b', (v_cash + v_tcs)::text, false);
  return v_cash;
end $f$;

create or replace function pg_temp.gst_file(p_period text, p_type text, p_note text default null) returns void language plpgsql as $f$
declare v_n int; v_arn text;
begin
  v_n := coalesce(nullif(current_setting('demo.arn_seq', true), ''), '0')::int + 1;
  perform set_config('demo.arn_seq', v_n::text, false);
  v_arn := 'AA24' || to_char(app_today(), 'MMYY') || lpad((v_n * 37 + 1000)::text, 7, '0');
  perform pg_temp.as_user('acc');
  perform record_gst_filing(p_period, p_type, v_arn, app_today(), case when p_type = 'GSTR3B' then coalesce(nullif(current_setting('demo.cash3b', true), ''), '0')::numeric end, p_note);
end $f$;

-- the supplier-return file for the month: what the portal would show for the bills booked in it, with a few real-world differences
create or replace function pg_temp.gstr2b_load(p_period text, p_skip text[] default '{}'::text[], p_extra jsonb default '[]'::jsonb, p_note text default 'Checked with the supplier') returns void language plpgsql as $f$
declare v_from date := (p_period || '-01')::date; v_rows jsonb; r record; v_res jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('gstin', s.gstin, 'name', s.name, 'type', 'invoice', 'doc_no', b.supplier_invoice_no, 'doc_date', b.supplier_invoice_date,
                  'taxable', b.taxable_value, 'igst', b.igst, 'cgst', b.cgst, 'sgst', b.sgst, 'itc_available', true) order by b.bill_date, b.bill_no), '[]'::jsonb) into v_rows
    from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
   where b.status = 'approved' and b.itc_eligible and b.bill_date >= v_from and b.bill_date < v_from + interval '1 month' and s.gstin is not null
     and (b.igst + b.cgst + b.sgst) > 0 and not (b.supplier_invoice_no = any (p_skip));
  v_rows := v_rows || p_extra;
  if jsonb_array_length(v_rows) = 0 then return; end if;
  perform pg_temp.as_user('acc');
  perform import_gstr2b(p_period, 'GSTR2B_' || replace(p_period, '-', '') || '.json', v_rows);
  for r in select x.line_id, x.status from jsonb_to_recordset(gstr2b_recon(p_period) -> 'lines') x(line_id uuid, status text) where x.status in ('not_in_books', 'mismatch') loop
    perform resolve_gstr2b_line(r.line_id, case r.status when 'not_in_books' then 'ignored' else 'accepted' end, p_note);
  end loop;
end $f$;

-- what the marketplaces' portals show for the month's tax they collected or deducted
create or replace function pg_temp.mtax_credits(p_month date, p_short numeric default 0, p_skip_tds boolean default false) returns void language plpgsql as $f$
declare r record;
begin
  perform pg_temp.as_user('sa');
  for r in select * from mtax_reconcile(p_month, p_month) where month = date_trunc('month', p_month)::date and deducted > 0 loop
    if r.kind = 'tds_194o' and p_skip_tds and r.channel_name like 'Amazon%' then continue; end if;
    perform mtax_credit_set(r.kind, r.channel_id, p_month, r.deducted - case when r.kind = 'gst_tcs' and r.channel_name like 'Flipkart%' then p_short else 0 end, null,
      case r.kind when 'gst_tcs' then 'gstr2b' else 'form26as' end, r.kind = 'gst_tcs', null);
  end loop;
  perform pg_temp.as_user('acc');
end $f$;

-- ---------------------------------------------------------------- people and payroll
create or replace function pg_temp.emp_new(p jsonb) returns uuid language plpgsql as $f$
declare v uuid;
begin
  perform pg_temp.as_user('acc');
  v := employee_save(null, p);
  perform employee_set_salary(v, (p ->> 'date_of_joining')::date, (p ->> 'basic')::numeric, (p ->> 'da')::numeric, (p ->> 'hra')::numeric, (p ->> 'other')::numeric);
  perform employee_set_bank(v, p ->> 'bank', p ->> 'ifsc', p ->> 'account', p ->> 'name');
  perform employee_set_declaration(v, 2026, coalesce(p ->> 'regime', 'new'), coalesce((p ->> 'd80c')::numeric, 0), 0, 0, 0, 0, 0, 0);
  if coalesce((p ->> 'leave_open')::numeric, 0) > 0 then
    perform leave_record(v, 'adjust', (p ->> 'leave_open')::numeric, app_today(), 'Opening leave balance as on 1 April 2026');
  end if;
  return v;
end $f$;

create or replace function pg_temp.leave_take(p_name text, p_days numeric, p_date date, p_note text) returns void language plpgsql as $f$
begin
  perform pg_temp.as_user('acc');
  perform leave_record((select emp_id from employees where name = p_name), 'taken', p_days, p_date, p_note);
end $f$;

-- month-end payroll: prepare, adjust for days not worked, approve (a different person), add the month's earned leave
create or replace function pg_temp.payroll_close(p_lop jsonb default '{}'::jsonb) returns void language plpgsql as $f$
declare m date := date_trunc('month', app_today())::date; v_run uuid; k text;
begin
  perform pg_temp.as_user('acc');
  v_run := payroll_run_create(m);
  for k in select jsonb_object_keys(p_lop) loop
    perform payroll_line_adjust((select l.line_id from payroll_lines l join employees e on e.emp_id = l.emp_id where l.run_id = v_run and e.name = k), (p_lop ->> k)::numeric, 0, false, null, 0, null);
  end loop;
  perform pg_temp.as_user('fin');
  perform payroll_run_approve(v_run);
  perform pg_temp.as_user('acc');
  perform leave_accrue(m);
end $f$;

create or replace function pg_temp.payroll_pay(p_month date) returns void language plpgsql as $f$
declare v_run uuid; v_net numeric;
begin
  select run_id into v_run from payroll_runs where month = p_month and status = 'approved';
  select coalesce(sum(net_pay), 0) into v_net from payroll_lines where run_id = v_run;
  perform pg_temp.fund_hdfc(v_net + 25000);
  perform pg_temp.as_user('acc');
  perform payroll_run_pay(v_run, pg_temp.hdfc(), app_today(), 'SALARY ' || to_char(p_month, 'MON YYYY'));
  perform pg_temp.bline(pg_temp.hdfc(), 'NEFT/SALARY/' || to_char(p_month, 'MON YYYY') || ' BATCH', v_net, 'debit');
end $f$;

create or replace function pg_temp.payroll_remit_all(p_month date) returns void language plpgsql as $f$
declare d record;
begin
  for d in select head, balance from payroll_dues where month = p_month and balance > 0 order by head loop
    perform pg_temp.fund_hdfc(d.balance + 25000);
    perform pg_temp.as_user('acc');
    perform payroll_remit(d.head, p_month, d.balance, pg_temp.hdfc(), app_today(), upper(d.head) || ' ' || to_char(p_month, 'MON YYYY'));
    perform pg_temp.bline(pg_temp.hdfc(), case d.head when 'pf' then 'EPFO/ECR/' when 'esi' then 'ESIC/CHALLAN/' when 'pt' then 'GSTN-PT/ePAY/' when 'tds' then 'CBDT/OLTAS/24G/' else 'LWF/CHALLAN/' end || to_char(p_month, 'MON YYYY'), d.balance, 'debit');
  end loop;
end $f$;

-- ---------------------------------------------------------------- staff expense claims
-- p_lines: [{"date": ..., "cat": code, "desc": ..., "amt": n}]; p_review / p_final: 'approve' | 'reject' | 'wait'
create or replace function pg_temp.claim_new(p_who text, p_title text, p_lines jsonb, p_review text default 'approve', p_final text default 'approve', p_pay boolean default true, p_submit boolean default true, p_rev text default 'ops', p_fin text default 'fin') returns uuid language plpgsql as $f$
declare v_id uuid; v_no text; v_uid uuid; n int := 0; v_tot numeric; ln jsonb;
begin
  perform pg_temp.as_user(p_who);
  v_uid := auth.uid();
  v_id := create_expense_claim(p_title, (select jsonb_agg(jsonb_build_object('expense_date', x ->> 'date', 'category_code', x ->> 'cat', 'description', x ->> 'desc', 'amount', (x ->> 'amt')::numeric)) from jsonb_array_elements(p_lines) x));
  if not p_submit then return v_id; end if;
  select claim_no, total into v_no, v_tot from expense_claims where claim_id = v_id;
  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    insert into attachments (entity_type, entity_id, path, file_name, mime_type, size_bytes, kind, note, uploaded_by)
    values ('expense_claim', v_id, 'demo-receipts/' || v_no || '-' || n || '.jpg', v_no || '-receipt-' || n || '.jpg', 'image/jpeg', 0, 'receipt', 'Demo placeholder: no file is stored', v_uid);
  end loop;
  perform submit_expense_claim(v_id);
  if p_review <> 'wait' then
    perform pg_temp.as_user(p_rev);
    if p_review = 'approve' then perform review_expense_claim(v_id, true, 'Looks fine'); else perform review_expense_claim(v_id, false, 'Not a business expense'); return v_id; end if;
  else return v_id; end if;
  if p_final = 'wait' then return v_id; end if;
  perform pg_temp.as_user(p_fin);
  perform approve_expense_claim(v_id, p_final = 'approve', case when p_final = 'approve' then null else 'Not allowed under the expense policy' end);
  if p_final <> 'approve' or not p_pay then return v_id; end if;
  perform pg_temp.fund_hdfc(v_tot + 25000);
  perform pg_temp.as_user('acc');
  perform pay_expense_claim(v_id, app_today(), 'bank', pg_temp.hdfc(), 'UPI' || to_char(app_today(), 'YYMMDD') || lpad((abs(hashtext(v_no)) % 100000)::text, 5, '0'));
  perform pg_temp.bline(pg_temp.hdfc(), 'UPI/' || v_no || '/REIMBURSEMENT', v_tot, 'debit');
  return v_id;
end $f$;

-- ---------------------------------------------------------------- fixed assets and bank charges
create or replace function pg_temp.asset_new(p_name text, p_cat text, p_bill uuid, p_cost numeric, p_loc text default 'Surat Main Warehouse') returns uuid language plpgsql as $f$
begin
  perform pg_temp.as_user('acc');
  return asset_create(p_name, (select category_id from asset_categories where name = p_cat), app_today(), app_today(), p_cost, p_loc, p_bill);
end $f$;

-- a bank's monthly charge: the charge plus 18% GST (credit claimed), booked as a journal and shown on the statement
create or replace function pg_temp.bank_charge(p_bank text, p_base numeric, p_what text) returns void language plpgsql as $f$
declare v_b uuid := case p_bank when 'hdfc' then pg_temp.hdfc() else pg_temp.icici() end; v_l uuid; v_gst numeric := round(p_base * 0.09, 2);
begin
  select ledger_id into v_l from bank_accounts where bank_account_id = v_b;
  perform pg_temp.as_user('acc');
  perform pg_temp.mj(app_today(), p_what || ' with GST, ' || (case p_bank when 'hdfc' then 'HDFC 4821' else 'ICICI 7734' end),
    jsonb_build_array(jsonb_build_object('ledger_id', (select ledger_id from ledgers where name = 'Bank Charges'), 'debit', p_base, 'credit', 0),
                      jsonb_build_object('ledger_id', (select ledger_id from ledgers where name = 'Input CGST'), 'debit', v_gst, 'credit', 0),
                      jsonb_build_object('ledger_id', (select ledger_id from ledgers where name = 'Input SGST'), 'debit', v_gst, 'credit', 0),
                      jsonb_build_object('ledger_id', v_l, 'debit', 0, 'credit', p_base + 2 * v_gst)));
  perform pg_temp.bline(v_b, upper(p_what) || ' INCL GST', p_base + 2 * v_gst, 'debit');
end $f$;


create or replace function pg_temp.courier_bill(p_month date, p_inv text) returns uuid language plpgsql as $f$
declare n_s bigint := pg_temp.month_orders(p_month, 'Shopify%'); n_r bigint := pg_temp.month_orders(p_month, 'Shopify%', 'o.fulfilment_status = ''rto'''); v_lines jsonb := '[]'::jsonb;
begin
  if n_s > 0 then v_lines := v_lines || jsonb_build_object('d', 'Shopify parcels dispatched in ' || to_char(p_month, 'FMMonth YYYY') || ' (' || n_s || ' at Rs 78)', 'h', '996812', 'q', n_s, 'p', 78, 'r', 18, 'l', 'Freight & Courier Charges - Outward'); end if;
  if n_r > 0 then v_lines := v_lines || jsonb_build_object('d', 'Return-to-origin freight, ' || to_char(p_month, 'FMMonth YYYY') || ' (' || n_r || ' at Rs 62)', 'h', '996812', 'q', n_r, 'p', 62, 'r', 18, 'l', 'Reverse Logistics & RTO Charges'); end if;
  if jsonb_array_length(v_lines) = 0 then return null; end if;
  return pg_temp.bill_new('SwiftRoute Couriers Pvt Ltd', p_inv, app_today(), v_lines);
end $f$;

create or replace function pg_temp.fulfil_bill(p_month date, p_inv text) returns uuid language plpgsql as $f$
declare n bigint := pg_temp.month_orders_wh(p_month, 'Mumbai%'); v_lines jsonb;
begin
  v_lines := jsonb_build_array(jsonb_build_object('d', 'Storage and space, Mumbai, ' || to_char(p_month, 'FMMonth YYYY'), 'h', '996729', 'q', 1, 'p', 15000, 'r', 18, 'l', 'Freight & Courier Charges - Outward'));
  if n > 0 then v_lines := v_lines || jsonb_build_object('d', 'Pick, pack and dispatch, ' || to_char(p_month, 'FMMonth YYYY') || ' (' || n || ' orders at Rs 26)', 'h', '996729', 'q', n, 'p', 26, 'r', 18, 'l', 'Freight & Courier Charges - Outward'); end if;
  return pg_temp.bill_new('Mehta Warehousing & Logistics Pvt Ltd', p_inv, app_today(), v_lines);
end $f$;

create or replace function pg_temp.pay_run(p_utr_seed text, p_names text[]) returns void language plpgsql as $f$
declare n text; i int := 0;
begin
  foreach n in array p_names loop i := i + 1; perform pg_temp.pay_sup(n, p_utr_seed || lpad(i::text, 2, '0')); end loop;
end $f$;

select pg_temp.day('2026-08-01');
select pg_temp.bill_new('Shree Ganesh Estates', 'SGE/2608/005', '2026-08-01', '[{"d": "Warehouse rent, Surat, August 2026", "h": "997212", "q": 1, "p": 30000, "r": 18, "l": "Rent"}]'::jsonb);
select pg_temp.bill_new('Andheri Warehouse Holdings LLP', 'AWH/2608/005', '2026-08-01', '[{"d": "Fulfilment centre rent, Mumbai, August 2026", "h": "997212", "q": 1, "p": 12000, "r": 18, "l": "Rent"}]'::jsonb);
select pg_temp.retime();
select pg_temp.day('2026-08-02');
select pg_temp.payroll_pay('2026-07-01');
select pg_temp.retime();
select pg_temp.day('2026-08-03');
select pg_temp.fulfil_bill('2026-07-01', 'MWL/2608/004');
select pg_temp.courier_bill('2026-07-01', 'SRC/2608/004');
select pg_temp.retime();
select pg_temp.day('2026-08-05');
select pg_temp.pay_run('HDFCN260805', array['Shree Ganesh Estates','Andheri Warehouse Holdings LLP']);
select pg_temp.retime();
select pg_temp.day('2026-08-07');
select pg_temp.tds_deposit('2026-07');
select pg_temp.retime();
select pg_temp.day('2026-08-08');
select pg_temp.bill_new('Gujarat Pack Industries', 'GPI/2608/005', '2026-08-08', '[{"d": "Cartons, poly mailers and tape, August 2026", "h": "4819", "q": 1, "p": 11800, "r": 18, "l": "Packaging Materials Consumed"}]'::jsonb);
select pg_temp.retime();
select pg_temp.day('2026-08-10');
select pg_temp.bill_new('Dakshin Gujarat Vij Company Ltd', 'DGV/2608/004', '2026-08-10', '[{"d": "Electricity, Surat warehouse, July 2026", "h": "997142", "q": 1, "p": 11600, "r": 0, "l": "Electricity & Utilities"}]'::jsonb);
select pg_temp.retime();
select pg_temp.day('2026-08-11');
select pg_temp.gst_file('2026-07', 'GSTR1');
select pg_temp.retime();
select pg_temp.day('2026-08-12');
select pg_temp.bill_new('CloudKart Software Services LLP', 'CKS/2608/005', '2026-08-12', '[{"d": "Store apps and cloud tools, August 2026", "h": "998314", "q": 1, "p": 7500, "r": 18, "l": "Software & Subscriptions"}]'::jsonb);
select pg_temp.mtax_credits('2026-07-01');
select pg_temp.retime();
select pg_temp.day('2026-08-14');
select pg_temp.bill_new('Airnet Broadband Pvt Ltd', 'ANB/2608/005', '2026-08-14', '[{"d": "Leased-line internet, August 2026", "h": "998411", "q": 1, "p": 4200, "r": 18, "l": "Telephone & Internet"}]'::jsonb);
select pg_temp.gstr2b_load('2026-07', array['CKS/2607/001'], '[]'::jsonb);
select pg_temp.retime();
select pg_temp.day('2026-08-15');
select pg_temp.payroll_remit_all('2026-07-01');
select pg_temp.retime();
select pg_temp.day('2026-08-18');
select pg_temp.pay_run('HDFCN260818', array['Dakshin Gujarat Vij Company Ltd','Mehta Warehousing & Logistics Pvt Ltd','SwiftRoute Couriers Pvt Ltd']);
do $x$ declare b uuid; begin b := pg_temp.bill_new('Gujarat Pack Industries', 'GPI/2608/017', '2026-08-18', '[{"d": "Heat sealing and strapping machine", "h": "8422", "q": 1, "p": 48000, "r": 18, "l": "Plant & Machinery"}]'::jsonb); perform pg_temp.asset_new('Heat sealing and strapping machine', 'Plant & Machinery', b, 48000, 'Mumbai Fulfilment Center'); end $x$;
select pg_temp.retime();
select pg_temp.day('2026-08-20');
select pg_temp.gst_setoff('2026-07');
select pg_temp.gst_file('2026-07', 'GSTR3B');
select pg_temp.retime();
select pg_temp.day('2026-08-21');
select pg_temp.leave_take('Vikram Rao', 3, '2026-08-21', 'Out of town');
select pg_temp.retime();
select pg_temp.day('2026-08-22');
select pg_temp.pay_run('HDFCN260822', array['CloudKart Software Services LLP','Airnet Broadband Pvt Ltd','AdBoost Digital Media Pvt Ltd','Kothari & Associates']);
select pg_temp.retime();
select pg_temp.day('2026-08-24');
select pg_temp.claim_new('mkt', 'Client lunch', '[{"date": "2026-08-24", "cat": "FOOD", "desc": "Lunch with a prospective supplier", "amt": 2600}]'::jsonb, p_review => 'reject');
select pg_temp.retime();
select pg_temp.day('2026-08-25');
select pg_temp.pay_run('HDFCN260825', array['Gujarat Pack Industries']);
select pg_temp.retime();
select pg_temp.day('2026-08-28');
select pg_temp.pay_run('HDFCN260828', array['Gujarat Pack Industries']);
select pg_temp.retime();
select pg_temp.day('2026-08-31');
select pg_temp.bill_new('AdBoost Digital Media Pvt Ltd', 'ABD/2608/005', '2026-08-31', '[{"d": "Marketplace and social advertising management, August 2026", "h": "998361", "q": 1, "p": 26000, "r": 18, "l": "Advertising & Promotion"}]'::jsonb);
select pg_temp.bill_new('Kothari & Associates', 'KAC/2608/005', '2026-08-31', '[{"d": "Monthly accounts and compliance retainer, August 2026", "h": "998221", "q": 1, "p": 8000, "r": 18, "l": "Professional & Audit Fees"}]'::jsonb);
select pg_temp.payroll_close('{}'::jsonb);
select asset_depreciate_month('2026-08-01');
select pg_temp.bank_charge('hdfc', 590, 'Account maintenance and cheque charges');
select pg_temp.bank_charge('icici', 1180, 'Collection, RTGS and SMS charges');
select employee_exit((select emp_id from employees where name = 'Imran Qureshi'), '2026-08-31');
select pg_temp.retime();
select set_config('app.today', '', false);
commit;
