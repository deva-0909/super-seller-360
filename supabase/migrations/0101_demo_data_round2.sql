-- 0101: DEMO DATA for the features added in rounds 8-11, so every screen has something to check.
-- Everything goes through the app's own functions, so the books stay balanced. Safe to run twice (each part checks first).
-- Bank lines carry raw = {"demo": true}. This file never touches existing data.
-- tidy-ups found while preparing the demo data
-- (a) vendor-name recognition ignores a few more everyday words, so "OFFICE TEA" is not read as "Surat Office Mart"
create or replace function bank_review_suggest(p_ref text, p_type text)
returns table (s_ledger uuid, s_supplier uuid, s_source text, s_conf int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_norm text := br_norm(p_ref); r record; n int; m int; sid uuid;
begin
  if length(v_norm) < 4 then return; end if;
  select pr.ledger_id as lid, pr.supplier_id as sup, pr.source as src, pr.hits as h into r
    from bank_payee_rules pr
   where pr.status = 'active' and (pr.direction = 'any' or pr.direction = p_type) and v_norm like '%' || br_norm(pr.keyword) || '%'
   order by length(pr.keyword) desc, pr.hits desc limit 1;
  if found then
    return query select r.lid, r.sup, 'rule:' || r.src, case when r.src = 'manual' then 95 else least(70 + r.h * 3, 92) end;
    return;
  end if;
  if p_type = 'debit' then
    -- vendor named on the statement: the supplier whose name has the most words in the narration, if one clearly wins
    with sc as (
      select s.supplier_id, (select count(*) from regexp_split_to_table(s.name, '[^A-Za-z]+') w
                              where length(w) >= 5 and upper(w) <> all (array['PRIVATE','LIMITED','SHREE','COMPANY','INDUSTRIES','SERVICES','ENTERPRISE','ENTERPRISES','TRADERS','TRADING','ASSOCIATES','OFFICE','SOLUTIONS','SYSTEMS','GLOBAL','INDIA','STORE','STORES'])
                                and v_norm like '%' || upper(w) || '%') as hit
        from suppliers s)
    select (select max(hit) from sc), (select count(*) from sc where hit = (select max(hit) from sc)),
           (select supplier_id from sc where hit = (select max(hit) from sc) limit 1) into n, m, sid;
    if n > 0 and m = 1 then return query select null::uuid, sid, 'vendor_name'::text, 50; end if;
  end if;
end $$;


-- (b) the late-booked bills list showed the gap in days under a "months" heading; it now shows whole months
create or replace view bills_booked_late with (security_invoker = true) as
select b.bill_id, b.bill_no, s.name as supplier_name, b.supplier_invoice_no, b.supplier_invoice_date, b.bill_date, b.total,
       (extract(year from age(date_trunc('month', b.bill_date), date_trunc('month', b.supplier_invoice_date))) * 12
        + extract(month from age(date_trunc('month', b.bill_date), date_trunc('month', b.supplier_invoice_date))))::int as months_late
  from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
 where b.status = 'approved' and date_trunc('month', b.bill_date) > date_trunc('month', b.supplier_invoice_date);
grant select on bills_booked_late to authenticated;

do $demo$
declare
  v_acc uuid; v_fm uuid; v_bank uuid; v_hdfc uuid; v_n int;
  l_rent uuid; l_net uuid; l_soft uuid; l_chg uuid; l_int uuid; l_adv uuid; l_pack uuid; l_cgst uuid; l_sgst uuid; l_welf uuid; l_cash uuid; l_misc uuid;
  s_ganesh uuid; s_andheri uuid; s_airnet uuid; s_cloud uuid; s_dakshin uuid; s_swift uuid; s_adboost uuid; s_pack uuid; s_old uuid;
  v_bill uuid; v_note uuid; v_txn uuid;
begin
  select u.user_id into v_acc from user_profiles u join roles r using (role_id) where r.name = 'Accountant' limit 1;
  select u.user_id into v_fm  from user_profiles u join roles r using (role_id) where r.name = 'Finance Manager' limit 1;
  if v_acc is null or v_fm is null then raise exception 'Needs an Accountant and a Finance Manager user'; end if;
  select bank_account_id, ledger_id into v_hdfc, v_bank from bank_accounts where account_number_last4 = '4821' limit 1;
  if v_hdfc is null then raise exception 'HDFC account (4821) not found'; end if;

  select ledger_id into l_rent from ledgers where name = 'Rent';
  select ledger_id into l_net  from ledgers where name = 'Telephone & Internet';
  select ledger_id into l_soft from ledgers where name = 'Software & Subscriptions';
  select ledger_id into l_chg  from ledgers where name = 'Bank Charges';
  select ledger_id into l_int  from ledgers where name = 'Interest Income';
  select ledger_id into l_adv  from ledgers where name = 'Advertising & Promotion';
  select ledger_id into l_pack from ledgers where name = 'Packaging Materials Consumed';
  select ledger_id into l_cgst from ledgers where name = 'Input CGST';
  select ledger_id into l_sgst from ledgers where name = 'Input SGST';
  select ledger_id into l_welf from ledgers where name = 'Staff Welfare';
  select ledger_id into l_cash from ledgers where name = 'Cash in Hand';
  select ledger_id into l_misc from ledgers where name = 'Miscellaneous Expenses';
  select supplier_id into s_ganesh  from suppliers where name = 'Shree Ganesh Estates';
  select supplier_id into s_andheri from suppliers where name = 'Andheri Warehouse Holdings LLP';
  select supplier_id into s_airnet  from suppliers where name = 'Airnet Broadband Pvt Ltd';
  select supplier_id into s_cloud   from suppliers where name = 'CloudKart Software Services LLP';
  select supplier_id into s_dakshin from suppliers where name = 'Dakshin Gujarat Vij Company Ltd';
  select supplier_id into s_swift   from suppliers where name = 'SwiftRoute Couriers Pvt Ltd';
  select supplier_id into s_adboost from suppliers where name = 'AdBoost Digital Media Pvt Ltd';
  select supplier_id into s_pack    from suppliers where name = 'Gujarat Pack Industries';
  select supplier_id into s_old     from suppliers where name = 'Mehta Warehousing & Logistics Pvt Ltd';

  -- ============================================================ 1. remembered names for the For review inbox
  insert into bank_payee_rules (keyword, direction, supplier_id, ledger_id, source, hits) values
    ('AIRNET',     'debit',  s_airnet, l_net,  'manual', 0),
    ('CLOUDKART',  'debit',  s_cloud,  l_soft, 'manual', 0),
    ('CHARGES',    'debit',  null,     l_chg,  'manual', 0),
    ('INTPD',      'credit', null,     l_int,  'manual', 0),
    ('GOOGLE',     'debit',  null,     l_adv,  'learned', 4)
  on conflict (keyword, direction) do nothing;

  -- ============================================================ 2. bank lines waiting for review (HDFC 4821)
  -- ref | date | type | amount
  insert into bank_transactions (bank_account_id, txn_date, amount, type, reference, source, line_hash, raw)
  select v_hdfc, d, a, t, r, 'csv', md5('demo-r12-' || r), '{"demo": true}'::jsonb
    from (values
      ('UPI/DAKSHIN GUJARAT VIJ CO/OCT BILL',               date '2026-10-02', 'debit',   4210.00::numeric),
      ('NEFT/SHREE GANESH ESTATES/OFFICE RENT OCT',         date '2026-10-01', 'debit',  29500.00),
      ('NEFT/AIRNET BROADBAND/INV 8841',                    date '2026-10-03', 'debit',   1499.00),
      ('NEFT/CLOUDKART SOFTWARE/SUBSCRIPTION',              date '2026-10-03', 'debit',   6800.00),
      ('SMS ALERT CHARGES Q2',                              date '2026-10-01', 'debit',    354.00),
      ('UPI/RAMESH K/9981',                                 date '2026-10-04', 'debit',  12000.00),
      ('INT.PD:HDFC SAVINGS 01-07-2026 TO 30-09-2026',      date '2026-10-01', 'credit',  1842.50),
      ('NEFT/SWIFTROUTE COURIERS/FREIGHT SEP',              date '2026-10-04', 'debit',   3150.00),
      ('NEFT/ADBOOST DIGITAL MEDIA/CAMPAIGN',               date '2026-10-02', 'debit',   8750.00),
      ('UPI/CHAI POINT/OFFICE TEA',                         date '2026-10-04', 'debit',    640.00),
      ('GOOGLE ADS OCT PREPAID',                            date '2026-10-04', 'debit',   1180.00),
      ('UPI/PRIYA S/ADJ',                                   date '2026-10-04', 'credit',  3540.00)
    ) v(r, d, t, a)
   where not exists (select 1 from bank_transactions b where b.line_hash = md5('demo-r12-' || r));

  -- one payment already entered in the books but not yet matched: shows the "may already be in your books" warning
  if not exists (select 1 from vouchers where narration = 'Ad spend paid to AdBoost (entered before the statement arrived)') then
    perform set_config('request.jwt.claims', json_build_object('sub', v_acc, 'role', 'authenticated')::text, true);
    perform post_manual_journal(date '2026-10-01', 'Ad spend paid to AdBoost (entered before the statement arrived)',
      jsonb_build_array(jsonb_build_object('ledger_id', l_adv, 'debit', 8750, 'credit', 0, 'narration', 'AdBoost campaign'),
                        jsonb_build_object('ledger_id', v_bank, 'debit', 0, 'credit', 8750, 'narration', 'AdBoost campaign')),
      null, true, 'Demo data: paid by NEFT, booked ahead of the bank statement');
  end if;
  select bank_txn_id into v_txn from bank_transactions where line_hash = md5('demo-r12-NEFT/ADBOOST DIGITAL MEDIA/CAMPAIGN');
  if v_txn is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_acc, 'role', 'authenticated')::text, true);
    perform br_apply_rules_to_txn(v_txn);
  end if;

  -- ============================================================ 3. recurring bills
  perform set_config('request.jwt.claims', json_build_object('sub', v_acc, 'role', 'authenticated')::text, true);
  if not exists (select 1 from recurring_bills where name = 'Warehouse rent - Andheri') then
    perform recurring_bill_save(null, jsonb_build_object('name', 'Warehouse rent - Andheri', 'supplier_id', s_andheri, 'frequency', 'monthly', 'next_date', '2026-10-01',
      'invoice_prefix', 'ANDR', 'itc', true, 'lines', jsonb_build_array(jsonb_build_object('description', 'Warehouse rent', 'hsn_code', '997212', 'quantity', 1, 'unit_price', 40000, 'gst_rate', 18, 'ledger_id', l_rent))));
  end if;
  if not exists (select 1 from recurring_bills where name = 'Office broadband - Airnet') then
    perform recurring_bill_save(null, jsonb_build_object('name', 'Office broadband - Airnet', 'supplier_id', s_airnet, 'frequency', 'monthly', 'next_date', '2026-10-05',
      'invoice_prefix', 'AIRN', 'itc', true, 'lines', jsonb_build_array(jsonb_build_object('description', 'Broadband', 'hsn_code', '998422', 'quantity', 1, 'unit_price', 1270, 'gst_rate', 18, 'ledger_id', l_net))));
  end if;
  if not exists (select 1 from recurring_bills where name = 'CloudKart software - quarterly') then
    perform recurring_bill_save(null, jsonb_build_object('name', 'CloudKart software - quarterly', 'supplier_id', s_cloud, 'frequency', 'quarterly', 'next_date', '2026-11-01',
      'invoice_prefix', 'CLKT', 'itc', true, 'lines', jsonb_build_array(jsonb_build_object('description', 'Software subscription', 'hsn_code', '998314', 'quantity', 1, 'unit_price', 15000, 'gst_rate', 18, 'ledger_id', l_soft))));
  end if;
  if not exists (select 1 from recurring_bills where name = 'Old courier retainer (paused)') then
    perform recurring_bill_save(null, jsonb_build_object('name', 'Old courier retainer (paused)', 'supplier_id', s_old, 'frequency', 'monthly', 'next_date', '2026-10-10',
      'invoice_prefix', 'MEHT', 'itc', true, 'lines', jsonb_build_array(jsonb_build_object('description', 'Retainer', 'hsn_code', '996511', 'quantity', 1, 'unit_price', 5000, 'gst_rate', 18, 'ledger_id', l_misc))));
    update recurring_bills set status = 'paused' where name = 'Old courier retainer (paused)';
  end if;

  -- ============================================================ 4. a bill dated September but booked in October (month-end cut-off check)
  if not exists (select 1 from purchase_bills where supplier_id = s_pack and supplier_invoice_no = 'GPI/2609/118') then
    v_bill := create_purchase_bill(s_pack, 'GPI/2609/118', date '2026-09-27', date '2026-10-02',
      jsonb_build_array(jsonb_build_object('description', 'Poly mailers and cartons', 'hsn_code', '48191010', 'quantity', 500, 'unit_price', 14, 'gst_rate', 12, 'ledger_id', l_pack)), true, null, 'Demo data: invoice received late');
    perform set_config('request.jwt.claims', json_build_object('sub', v_fm, 'role', 'authenticated')::text, true);
    perform approve_purchase_bill(v_bill);
    perform set_config('request.jwt.claims', json_build_object('sub', v_acc, 'role', 'authenticated')::text, true);
  end if;

  -- ============================================================ 5. supplier credit notes (one approved, one waiting)
  if not exists (select 1 from supplier_credit_notes where supplier_note_no in ('CN/DEMO/01', 'CN/DEMO/02')) then
    select b.bill_id into v_bill from purchase_bills b join suppliers s using (supplier_id)
     where b.status = 'approved' and not b.is_opening and b.taxable_value >= 20000 and b.supplier_invoice_date <= date '2026-10-03' and s.gstin is not null
     order by b.supplier_invoice_date desc limit 1;
    if v_bill is not null then
      v_note := create_supplier_credit_note(v_bill, 'CN/DEMO/01', date '2026-10-03', 'rate_difference',
        jsonb_build_array(jsonb_build_object('description', 'Rate difference agreed with supplier', 'taxable', 1500, 'gst_rate', 5)), 'Demo data');
      perform set_config('request.jwt.claims', json_build_object('sub', v_fm, 'role', 'authenticated')::text, true);
      perform approve_supplier_credit_note(v_note);
      perform set_config('request.jwt.claims', json_build_object('sub', v_acc, 'role', 'authenticated')::text, true);
      perform create_supplier_credit_note(v_bill, 'CN/DEMO/02', date '2026-10-04', 'return',
        jsonb_build_array(jsonb_build_object('description', 'Returned: stitching defects', 'taxable', 2000, 'gst_rate', 5)), 'Demo data: waiting for approval');
    end if;
  end if;

  -- ============================================================ 6. GST credit entered from GSTR-2B (September)
  if not exists (select 1 from gst_itc_adjustments where period = '2026-09' and note = 'Demo data: marketplace fee credit per GSTR-2B') then
    perform add_gst_itc_adjustment('2026-09', 'other_itc', 0, 1620.00, 1620.00, 'Demo data: marketplace fee credit per GSTR-2B');
  end if;

  -- ============================================================ 7. planned cash items for the cash forecast
  if not exists (select 1 from cash_plan_items where label like 'Demo:%') then
    perform cash_plan_add(date '2026-10-15', 'out', 45000, 'Demo: Diwali bonus advance', 'none', null);
    perform cash_plan_add(date '2026-10-20', 'out', 12000, 'Demo: insurance premium', 'monthly', date '2027-03-20');
    perform cash_plan_add(date '2026-10-25', 'in',  80000, 'Demo: wholesale buyer advance', 'none', null);
  end if;

  -- ============================================================ 8. a repeating journal (small cash expense every month)
  if not exists (select 1 from recurring_journals where name = 'Monthly staff tea and snacks (cash)') then
    perform post_manual_journal(date '2026-10-01', 'Monthly staff tea and snacks (cash)',
      jsonb_build_array(jsonb_build_object('ledger_id', l_welf, 'debit', 3000, 'credit', 0, 'narration', 'Tea and snacks'),
                        jsonb_build_object('ledger_id', l_cash, 'debit', 0, 'credit', 3000, 'narration', 'Tea and snacks')),
      jsonb_build_object('frequency', 'monthly', 'name', 'Monthly staff tea and snacks (cash)'), true, 'Demo data');
  end if;
end
$demo$;
