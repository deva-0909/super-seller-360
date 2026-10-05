-- 01 Apr to 29 Apr 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
-- Each day is posted as of that day (the books are dated by the event, not by when this file runs).
begin;
select set_config('request.jwt.claims', json_build_object('sub', '2911a288-1727-4d24-869d-06ba96fc8ffa', 'role', 'authenticated')::text, false);
select set_config('demo.self_ok', (select allow_self_approval::text from purchase_settings where id = 1), false);
update purchase_settings set allow_self_approval = true where id = 1;
select set_config('demo.t0', clock_timestamp()::text, false);


create or replace function pg_temp.day(p_d date) returns void language plpgsql as $f$
begin perform set_config('app.today', p_d::text, false); end $f$;

-- the engine stamps new rows with the real clock; history loaded for a past day is given that day's date instead
create or replace function pg_temp.retime() returns void language plpgsql as $f$
declare t0 timestamptz := coalesce(nullif(current_setting('demo.t0', true), '')::timestamptz, '2000-01-01');
        d timestamptz := (app_today()::timestamp + time '11:00') at time zone 'Asia/Kolkata';
begin
  update inventory_transactions set created_at = d where created_at >= t0;
  update purchase_orders set created_at = d, decided_at = case when decided_at >= t0 then d else decided_at end where created_at >= t0;
  update goods_receipts set created_at = d where created_at >= t0;
  update purchase_bills set created_at = d, decided_at = case when decided_at >= t0 then d else decided_at end where created_at >= t0;
  update supplier_payments set created_at = d, decided_at = case when decided_at >= t0 then d else decided_at end where created_at >= t0;
  update order_dispatch set dispatched_at = d where dispatched_at >= t0;
  update credit_notes set created_at = d where created_at >= t0;
  update invoices set created_at = d where created_at >= t0;
  update automation_issues set created_at = d, updated_at = d where created_at >= t0;
  perform set_config('demo.t0', clock_timestamp()::text, false);
end $f$;

create or replace function pg_temp.icici() returns uuid language sql as $f$ select bank_account_id from bank_accounts where account_number_last4 = '7734' $f$;

create or replace function pg_temp.ts(p_t time) returns timestamptz language sql as $f$ select (app_today()::timestamp + p_t) at time zone 'Asia/Kolkata' $f$;
create or replace function pg_temp.cancel_order(p_ext text) returns void language plpgsql as $f$
begin
  update orders set fulfilment_status = 'cancelled', payment_status = 'refunded' where external_order_id = p_ext;
end $f$;

-- a statement line on the ICICI account; the engine drafts an "unclassified" entry for it, which is withdrawn here because the real entry is booked by the process itself
create or replace function pg_temp.bank_line(p_ref text, p_amount numeric, p_type text) returns uuid language plpgsql as $f$
declare v_txn uuid;
begin
  insert into bank_transactions (bank_account_id, txn_date, reference, amount, type, match_status, source, created_at)
  values (pg_temp.icici(), app_today(), p_ref, p_amount, p_type, 'unmatched', 'csv', pg_temp.ts('12:00')) returning bank_txn_id into v_txn;
  perform br_cancel_rule_draft(v_txn);
  return v_txn;
end $f$;

-- ---------------------------------------------------------------- purchasing
create or replace function pg_temp.po_new(p_note text, p_sup text, p_wh text, p_lines jsonb) returns void language plpgsql as $f$
declare v_po uuid; v_l jsonb;
begin
  select jsonb_agg(jsonb_build_object('product_id', p.product_id, 'quantity', (l ->> 'q')::numeric, 'unit_price', p.cost_price, 'gst_rate', p.gst_rate))
    into v_l from jsonb_array_elements(p_lines) l join products p on p.sku = l ->> 'sku';
  v_po := po_create((select supplier_id from suppliers where name = p_sup), (select warehouse_id from warehouses where name = p_wh), v_l, null, p_note);
  if (select status from purchase_orders where po_id = v_po) = 'pending' then perform po_decide(v_po, true, null); end if;
end $f$;

create or replace function pg_temp.grn_new(p_note text, p_challan text, p_lines jsonb) returns void language plpgsql as $f$
declare v_po uuid; v_l jsonb;
begin
  select po_id into v_po from purchase_orders where notes = p_note;
  select jsonb_agg(jsonb_build_object('po_line_id', pl.po_line_id, 'accepted', (l ->> 'a')::numeric, 'rejected', (l ->> 'r')::numeric))
    into v_l from jsonb_array_elements(p_lines) l join products p on p.sku = l ->> 'sku' join purchase_order_lines pl on pl.po_id = v_po and pl.product_id = p.product_id;
  perform grn_create(v_po, app_today(), p_challan, v_l, null);
end $f$;

create or replace function pg_temp.bill_po(p_note text, p_inv text, p_days_before int) returns void language plpgsql as $f$
declare v_po uuid; v_r jsonb;
begin
  select po_id into v_po from purchase_orders where notes = p_note;
  v_r := po_create_bill(v_po, p_inv, app_today() - p_days_before, app_today());
  perform approve_purchase_bill((v_r ->> 'bill_id')::uuid);
end $f$;

create or replace function pg_temp.pay_due(p_sup text, p_upto date, p_utr text, p_frac numeric) returns void language plpgsql as $f$
declare v_s uuid; v_alloc jsonb; v_tot numeric; v_pay uuid;
begin
  select supplier_id into v_s from suppliers where name = p_sup;
  select jsonb_agg(jsonb_build_object('bill_id', x.bill_id, 'amount', x.amt)), sum(x.amt) into v_alloc, v_tot
    from (select b.bill_id, round(bill_outstanding(b.bill_id, null, true) * p_frac, 2) amt from purchase_bills b
           where b.supplier_id = v_s and b.status = 'approved' and b.due_date <= p_upto and bill_outstanding(b.bill_id, null, true) > 0) x where x.amt > 0;
  if v_tot is null or v_tot <= 0 then return; end if;
  v_pay := create_supplier_payment(v_s, app_today(), 'bank', pg_temp.icici(), v_tot, p_utr, 'Weekly payment run', v_alloc);
  perform approve_supplier_payment(v_pay);
  perform pg_temp.bank_line('NEFT/' || p_utr || '/' || p_sup, v_tot, 'debit');
end $f$;

create or replace function pg_temp.adjust(p_sku text, p_wh text, p_delta numeric) returns void language plpgsql as $f$
begin
  perform record_inventory_movement((select product_id from products where sku = p_sku), (select warehouse_id from warehouses where name = p_wh), 'adjustment', p_delta, 'stock_take', null);
end $f$;

-- ---------------------------------------------------------------- COD
create or replace function pg_temp.cod_collect(p_exts text[]) returns void language plpgsql as $f$
begin
  update cod_collections c set status = 'collected', collected_amount = c.cod_amount, collected_date = app_today()
    from orders o where o.order_id = c.order_id and o.external_order_id = any (p_exts) and c.status = 'pending';
  update orders set payment_status = 'paid' where external_order_id = any (p_exts);
end $f$;

create or replace function pg_temp.cod_remit(p_courier text, p_ref text, p_exts text[], p_short numeric) returns void language plpgsql as $f$
declare v_txn uuid; v_tot numeric; r record; v_first boolean := true; v_amt numeric; v_ids uuid[] := '{}'; v_lines uuid[]; v_short numeric;
begin
  select sum(c.cod_amount) into v_tot from cod_collections c join orders o on o.order_id = c.order_id where o.external_order_id = any (p_exts) and c.status = 'collected';
  if v_tot is null then return; end if;
  -- a short remittance is taken off the first order of the batch (never more than half of it)
  select least(p_short, round(c.cod_amount * .5, 2)) into v_short from cod_collections c join orders o on o.order_id = c.order_id
   where o.external_order_id = any (p_exts) and c.status = 'collected' order by o.external_order_id limit 1;
  v_txn := pg_temp.bank_line('NEFT-' || p_ref, v_tot - v_short, 'credit');
  for r in select c.cod_id, c.cod_amount from cod_collections c join orders o on o.order_id = c.order_id where o.external_order_id = any (p_exts) and c.status = 'collected' order by o.external_order_id loop
    v_amt := r.cod_amount - case when v_first then v_short else 0 end; v_first := false;
    perform record_cod_remittance(r.cod_id, v_amt, v_txn);
    v_ids := v_ids || r.cod_id;
  end loop;
  -- one bank credit covers many COD orders: tie it to all of their receipt entries
  select array_agg(vl.voucher_line_id) into v_lines from voucher_lines vl join vouchers v on v.voucher_id = vl.voucher_id
   where v.source_type = 'cod' and v.source_id = any (v_ids) and vl.debit > 0 and vl.ledger_id = (select ledger_id from bank_accounts where bank_account_id = pg_temp.icici()) and v.voucher_date = app_today()
     and not exists (select 1 from bank_recon_matches m where m.voucher_line_id = vl.voucher_line_id and m.status = 'active');
  if v_lines is not null and (select recon_status from bank_transactions where bank_txn_id = v_txn) <> 'reconciled' then perform br_link(v_txn, v_lines, 'manual', null, 'Courier remittance ' || p_ref); end if;
end $f$;

-- ---------------------------------------------------------------- returns and RTO
create or replace function pg_temp.ret_new(p_ext text, p_reason text, p_src text) returns void language plpgsql as $f$
begin
  insert into returns (order_id, return_reason, status, restock_status, refund_status, warehouse_id, source, created_at)
  select o.order_id, p_reason, 'requested', 'pending', 'pending', o.warehouse_id, p_src, (app_today()::timestamp + time '10:30') at time zone 'Asia/Kolkata' from orders o where o.external_order_id = p_ext;
end $f$;
create or replace function pg_temp.ret_set(p_ext text, p_st text) returns void language plpgsql as $f$
begin
  update returns r set status = p_st, pickup_date = case when p_st = 'pickup' then app_today() else r.pickup_date end
    from orders o where o.order_id = r.order_id and o.external_order_id = p_ext;
end $f$;
create or replace function pg_temp.ret_reject(p_ext text) returns void language plpgsql as $f$
begin
  update returns r set status = 'rejected', refund_status = 'rejected' from orders o where o.order_id = r.order_id and o.external_order_id = p_ext;
end $f$;
create or replace function pg_temp.ret_recv(p_ext text) returns void language plpgsql as $f$
begin
  update returns r set status = 'received', received_date = app_today() from orders o where o.order_id = r.order_id and o.external_order_id = p_ext;
end $f$;
create or replace function pg_temp.ret_dispo(p_ext text, p_insp text, p_disp text) returns void language plpgsql as $f$
begin
  perform disposition_return(r.return_id, p_insp, p_disp) from returns r join orders o on o.order_id = r.order_id where o.external_order_id = p_ext;
end $f$;
create or replace function pg_temp.ret_refund_d2c(p_ext text, p_ref text) returns void language plpgsql as $f$
declare v_net numeric;
begin
  select net_amount into v_net from orders where external_order_id = p_ext;
  perform pg_temp.bank_line(p_ref, v_net, 'debit');
  update returns r set refund_status = 'refunded' from orders o where o.order_id = r.order_id and o.external_order_id = p_ext;
end $f$;

create or replace function pg_temp.rto_new(p_ext text, p_awb text, p_reason text) returns void language plpgsql as $f$
begin
  update orders set fulfilment_status = 'rto' where external_order_id = p_ext;
  insert into rtos (order_id, awb, reason, status, warehouse_id, source, created_at)
  select o.order_id, p_awb, p_reason, 'initiated', o.warehouse_id, 'webhook', (app_today()::timestamp + time '10:30') at time zone 'Asia/Kolkata' from orders o where o.external_order_id = p_ext;
end $f$;
create or replace function pg_temp.rto_set(p_ext text, p_st text) returns void language plpgsql as $f$
begin
  update rtos r set status = p_st from orders o where o.order_id = r.order_id and o.external_order_id = p_ext;
end $f$;
create or replace function pg_temp.rto_recv(p_ext text, p_insp text, p_disp text) returns void language plpgsql as $f$
begin
  update rtos r set status = 'received', received_date = app_today() from orders o where o.order_id = r.order_id and o.external_order_id = p_ext;
  perform disposition_rto(r.rto_id, p_insp, p_disp) from rtos r join orders o on o.order_id = r.order_id where o.external_order_id = p_ext;
end $f$;

-- ---------------------------------------------------------------- marketplace and gateway payouts
create or replace function pg_temp.settle_new(p_ch text, p_ref text, p_ws date, p_we date, p_orders text[], p_refunds text[]) returns void language plpgsql as $f$
declare ch channels%rowtype; s uuid; o record; pct numeric; ship numeric; mkt boolean; comm numeric; shp numeric; g numeric := 0; ded numeric := 0; base numeric; tcs numeric; tds numeric; ftype text;
begin
  select * into ch from channels where name = p_ch;
  mkt := ch.type = 'marketplace';
  pct := case when ch.name like 'Amazon%' then .13 when ch.name like 'Flipkart%' then .115 else .02 end;
  ship := case when ch.name like 'Amazon%' then 55 when ch.name like 'Flipkart%' then 48 else 0 end;
  ftype := case when mkt then 'commission' else 'gateway_fee' end;
  insert into settlements (channel_id, external_settlement_id, period_start, period_end, gross, deductions, expected_amount, status, created_at)
  values (ch.channel_id, p_ref, p_ws, p_we, 0, 0, 0, 'pending', pg_temp.ts('09:30')) returning settlement_id into s;
  for o in select * from orders where external_order_id = any (p_orders) order by external_order_id loop
    comm := round(o.net_amount * pct / 1.18, 2); shp := round(ship / 1.18, 2); base := o.net_amount - o.tax_amount;
    insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (s, o.order_id, 'order_value', o.net_amount, 0);
    insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (s, o.order_id, ftype, comm, round(comm * .18, 2));
    g := g + o.net_amount; ded := ded + comm + round(comm * .18, 2);
    if shp > 0 then
      insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (s, o.order_id, 'shipping', shp, round(shp * .18, 2));
      ded := ded + shp + round(shp * .18, 2);
    end if;
    if mkt then
      tcs := round(base * .005, 2); tds := round(base * .001, 2);
      insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (s, o.order_id, 'tcs', tcs, 0), (s, o.order_id, 'tds_194o', tds, 0);
      ded := ded + tcs + tds;
    end if;
  end loop;
  for o in select * from orders where external_order_id = any (p_refunds) order by external_order_id loop
    base := o.net_amount - o.tax_amount;
    insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (s, o.order_id, 'refund', o.net_amount, 0);
    g := g - o.net_amount;
    if mkt then
      tcs := -round(base * .005, 2); tds := -round(base * .001, 2);
      insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (s, o.order_id, 'tcs', tcs, 0), (s, o.order_id, 'tds_194o', tds, 0);
      ded := ded + tcs + tds;
    end if;
    update returns set refund_status = 'refunded' where order_id = o.order_id;
  end loop;
  update settlements set gross = g, deductions = round(ded, 2), expected_amount = round(g - ded, 2) where settlement_id = s;
end $f$;

create or replace function pg_temp.settle_pay(p_ref text, p_short numeric) returns void language plpgsql as $f$
declare st settlements%rowtype; v_txn uuid; v_amt numeric;
begin
  select * into st from settlements where external_settlement_id = p_ref;
  if st.settlement_id is null then return; end if;
  v_amt := st.expected_amount - p_short;
  v_txn := pg_temp.bank_line('NEFT-' || p_ref, v_amt, 'credit');
  perform reconcile_settlement(st.settlement_id, v_amt, v_txn);
end $f$;

-- ---------------------------------------------------------------- claims
create or replace function pg_temp.claim_new(p_ext text, p_type text, p_amt numeric, p_deadline date) returns void language plpgsql as $f$
begin
  insert into claims (order_id, claim_type, potential_amount, deadline, owner, status, created_at)
  select o.order_id, p_type, p_amt, p_deadline, coalesce((select user_id from user_profiles where user_id = 'f08a6962-1e79-4a95-85a8-e59910ebdaff'), auth.uid()), 'potential', pg_temp.ts('11:00') from orders o where o.external_order_id = p_ext;
end $f$;
create or replace function pg_temp.claim_step(p_ext text, p_type text, p_st text, p_amt numeric) returns void language plpgsql as $f$
begin
  perform advance_claim(c.claim_id, p_st, p_amt) from claims c join orders o on o.order_id = c.order_id where o.external_order_id = p_ext and c.claim_type = p_type;
end $f$;
create or replace function pg_temp.claim_recover(p_ext text, p_type text, p_ref text) returns void language plpgsql as $f$
declare c claims%rowtype;
begin
  select cl.* into c from claims cl join orders o on o.order_id = cl.order_id where o.external_order_id = p_ext and cl.claim_type = p_type and cl.status = 'approved';
  if c.claim_id is null then return; end if;
  perform advance_claim(c.claim_id, 'recovered', c.approved_amount);
  perform pg_temp.bank_line(p_ref, c.approved_amount, 'credit');
end $f$;


-- Wed 01 Apr 2026
select pg_temp.day('2026-04-01');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1001','Flipkart - Seller Hub','2026-04-01 18:15+05:30','Ritu Saxena','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1001','Amazon - Seller Central','2026-04-01 14:27+05:30','Tanvi Rana','prepaid',2896.0,144.8,137.57,2888.77,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1002','Flipkart - Seller Hub','2026-04-01 15:17+05:30','Sonal Parekh','prepaid',2947.0,147.35,139.98,2939.63,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1003','Flipkart - Seller Hub','2026-04-01 19:25+05:30','Pratik Lad','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1001','WTOP-WHT-L',1,599,0.0,29.95),
('AMAZ-1001','WTOP-WHT-M',2,599,59.9,56.91),
('AMAZ-1001','WKRT-TEL-L',1,849,42.45,40.33),
('AMAZ-1001','WKRT-TEL-XL',1,849,42.45,40.33),
('FLIP-1002','MCHN-OLV-34',1,1199,59.95,56.95),
('FLIP-1002','MTRK-BLK-M',1,649,32.45,30.83),
('FLIP-1002','MKUR-MUS-M',1,1099,54.95,52.2),
('FLIP-1003','GTOP-WHT-89Y',1,349,0.0,17.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.retime();

-- Thu 02 Apr 2026
select pg_temp.day('2026-04-02');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1001','Shopify - Main Store','2026-04-02 11:21+05:30','Sejal Kapadia','prepaid',1186.0,59.3,56.34,1183.04,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1004','Flipkart - Seller Hub','2026-04-02 19:23+05:30','Vipul Gandhi','prepaid',3797.0,0.0,189.85,3986.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1002','Shopify - Main Store','2026-04-02 15:02+05:30','Mitul Dave','prepaid',1898.0,189.8,85.42,1793.62,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1005','Flipkart - Seller Hub','2026-04-02 13:53+05:30','Sanjay Gajera','prepaid',2348.0,117.4,111.53,2342.13,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1006','Flipkart - Seller Hub','2026-04-02 16:39+05:30','Rohit Iyer','prepaid',749.0,74.9,33.71,707.81,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1001','GLEG-PNK-89Y',2,279,27.9,26.51),
('SHOP-1001','GTOP-YLW-89Y',1,349,17.45,16.58),
('SHOP-1001','GLEG-BLK-45Y',1,279,13.95,13.25),
('FLIP-1004','MCHN-OLV-34',2,1199,0.0,119.9),
('FLIP-1004','MJNS-BLK-32',1,1399,0.0,69.95),
('SHOP-1002','MPOL-MRN-M',1,699,69.9,31.46),
('SHOP-1002','MCHN-KHK-30',1,1199,119.9,53.96),
('FLIP-1005','WDRS-FLP-S',1,1499,74.95,71.2),
('FLIP-1005','WKRT-PNK-L',1,849,42.45,40.33),
('FLIP-1006','GFRK-LIL-67Y',1,749,74.9,33.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.retime();

-- Fri 03 Apr 2026
select pg_temp.day('2026-04-03');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1003','Shopify - Main Store','2026-04-03 21:55+05:30','Mitul Dave','prepaid',4495.0,224.75,213.52,4483.77,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1002','Amazon - Seller Central','2026-04-03 13:50+05:30','Neha Patel','prepaid',1748.0,174.8,78.67,1651.87,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1003','Amazon - Seller Central','2026-04-03 09:19+05:30','Aditi Joshi','prepaid',999.0,99.9,44.96,944.06,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1007','Flipkart - Seller Hub','2026-04-03 14:48+05:30','Sejal Kapadia','cod',2798.0,279.8,125.91,2644.11,'cancelled','failed','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1003','BSHT-GRY-89Y',1,349,17.45,16.58),
('SHOP-1003','BKUR-CRM-89Y',1,949,47.45,45.08),
('SHOP-1003','BSHF-WHT-1011Y',1,599,29.95,28.45),
('SHOP-1003','MHOD-BLK-XL',2,1299,129.9,123.41),
('AMAZ-1002','MSHF-WHT-L',1,999,99.9,44.96),
('AMAZ-1002','GFRK-LIL-45Y',1,749,74.9,33.71),
('AMAZ-1003','MSHF-WHT-XL',1,999,99.9,44.96),
('FLIP-1007','MJNS-BLK-32',2,1399,279.8,125.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.pay_due('Shree Ambika Textiles', '2026-04-06', 'ICIC000000880035', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-04-06', 'ICIC000000880057', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-04-06', 'ICIC000000880122', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-04-06', 'ICIC000000880217', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-04-06', 'ICIC000000880283', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-04-06', 'ICIC000000880319', 1);
select pg_temp.retime();

-- Sat 04 Apr 2026
select pg_temp.day('2026-04-04');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1008','Flipkart - Seller Hub','2026-04-04 22:23+05:30','Pratik Lad','cod',1098.0,54.9,52.16,1095.26,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1009','Flipkart - Seller Hub','2026-04-04 20:10+05:30','Vipul Gandhi','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1010','Flipkart - Seller Hub','2026-04-04 22:22+05:30','Mitul Dave','prepaid',2278.0,0.0,113.9,2391.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1004','Amazon - Seller Central','2026-04-04 22:33+05:30','Nikhil Pandey','prepaid',948.0,0.0,47.4,995.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1008','GNGT-PNK-1011Y',2,549,54.9,52.16),
('FLIP-1009','GLEG-PNK-89Y',1,279,0.0,13.95),
('FLIP-1010','GLHG-RED-67Y',1,1999,0.0,99.95),
('FLIP-1010','GLEG-BLK-67Y',1,279,0.0,13.95),
('AMAZ-1004','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1004','WLEG-BLK-L',1,349,0.0,17.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1008','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.retime();

-- Sun 05 Apr 2026
select pg_temp.day('2026-04-05');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1005','Amazon - Seller Central','2026-04-05 20:09+05:30','Chirag Zaveri','prepaid',4425.0,0.0,221.25,4646.25,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1011','Flipkart - Seller Hub','2026-04-05 15:46+05:30','Jigar Chauhan','prepaid',1797.0,179.7,80.88,1698.18,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1006','Amazon - Seller Central','2026-04-05 21:06+05:30','Dev Trivedi','prepaid',948.0,0.0,47.4,995.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1004','Shopify - Main Store','2026-04-05 10:57+05:30','Mehul Shukla','cod',899.0,0.0,44.95,943.95,'delivered','pending','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1005','MJNS-IND-32',2,1399,0.0,139.9),
('AMAZ-1005','BTEE-BLU-67Y',1,329,0.0,16.45),
('AMAZ-1005','MTRK-BLK-L',2,649,0.0,64.9),
('FLIP-1011','WTOP-PCH-S',1,599,59.9,26.96),
('FLIP-1011','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1011','WTOP-PCH-L',1,599,59.9,26.96),
('AMAZ-1006','WLEG-BLK-L',1,349,0.0,17.45),
('AMAZ-1006','WPAL-WHT-XL',1,599,0.0,29.95),
('SHOP-1004','MSHC-GRN-L',1,899,0.0,44.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1004','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.retime();

-- Mon 06 Apr 2026
select pg_temp.day('2026-04-06');
select pg_temp.po_new('Weekly replenishment 06 Apr 2026 - Krishna Denim Works (ref R001)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MJNS-IND-32","q":16},{"sku":"MJNS-BLK-32","q":8},{"sku":"MCHN-OLV-34","q":24}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Apr 2026 - Little Stitch Garments (ref R002)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"BSHT-GRY-89Y","q":8},{"sku":"BKUR-CRM-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Apr 2026 - Little Stitch Garments (ref R003)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"GNGT-PNK-1011Y","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Apr 2026 - Ludhiana Winter Wear Co (ref R004)', 'Ludhiana Winter Wear Co', 'Mumbai Fulfilment Center', '[{"sku":"MHOD-BLK-XL","q":16}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Apr 2026 - Rajdhani Shirting Mills (ref R005)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHF-WHT-XL","q":8},{"sku":"MKUR-MUS-M","q":8},{"sku":"BSHF-WHT-1011Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R006)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTRK-BLK-M","q":8},{"sku":"MTRK-BLK-L","q":16},{"sku":"WLEG-BLK-L","q":8},{"sku":"WTOP-WHT-L","q":8},{"sku":"WTOP-PCH-S","q":8},{"sku":"WTOP-PCH-L","q":16},{"sku":"BTEE-BLU-67Y","q":8},{"sku":"GTOP-WHT-89Y","q":8},{"sku":"GLEG-PNK-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R007)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"WTOP-WHT-M","q":12},{"sku":"GLEG-PNK-89Y","q":12}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1007','Amazon - Seller Central','2026-04-06 11:31+05:30','Bhavna Solanki','prepaid',3297.0,164.85,156.61,3288.76,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1005','Shopify - Main Store','2026-04-06 12:07+05:30','Sejal Kapadia','prepaid',849.0,84.9,38.21,802.31,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1008','Amazon - Seller Central','2026-04-06 10:15+05:30','Sagar Rathod','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1006','Shopify - Main Store','2026-04-06 16:37+05:30','Riya Shah','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1007','Shopify - Main Store','2026-04-06 18:35+05:30','Isha Gupta','prepaid',2256.0,0.0,112.8,2368.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1012','Flipkart - Seller Hub','2026-04-06 15:13+05:30','Aditi Joshi','prepaid',599.0,59.9,26.96,566.06,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1007','MCHN-KHK-30',2,1199,119.9,113.91),
('AMAZ-1007','MSHC-RED-L',1,899,44.95,42.7),
('SHOP-1005','WKRT-TEL-XL',1,849,84.9,38.21),
('AMAZ-1008','GLEG-PNK-89Y',1,279,0.0,13.95),
('SHOP-1006','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1007','BTEE-RED-89Y',2,329,0.0,32.9),
('SHOP-1007','BJNS-IND-89Y',2,799,0.0,79.9),
('FLIP-1012','WTOP-WHT-L',1,599,59.9,26.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260401', '2026-04-01', '2026-04-05', array['FLIP-1004']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 07 Apr 2026
select pg_temp.day('2026-04-07');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1008','Shopify - Main Store','2026-04-07 19:31+05:30','Foram Thakkar','prepaid',599.0,59.9,26.96,566.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1013','Flipkart - Seller Hub','2026-04-07 17:22+05:30','Vipul Gandhi','prepaid',949.0,94.9,42.71,896.81,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1009','Shopify - Main Store','2026-04-07 10:15+05:30','Kunal Desai','prepaid',349.0,34.9,15.71,329.81,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1008','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1013','BKUR-MUS-67Y',1,949,94.9,42.71),
('SHOP-1009','GTOP-WHT-67Y',1,349,34.9,15.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.retime();

-- Wed 08 Apr 2026
select pg_temp.day('2026-04-08');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1014','Flipkart - Seller Hub','2026-04-08 19:33+05:30','Meghna Rao','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1010','Shopify - Main Store','2026-04-08 14:38+05:30','Karan Malhotra','cod',2547.0,0.0,127.35,2674.35,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1011','Shopify - Main Store','2026-04-08 09:26+05:30','Isha Gupta','prepaid',1897.0,0.0,94.85,1991.85,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1009','Amazon - Seller Central','2026-04-08 18:49+05:30','Harsh Modi','prepaid',6095.0,0.0,304.75,6399.75,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1015','Flipkart - Seller Hub','2026-04-08 13:26+05:30','Pratik Lad','prepaid',849.0,84.9,38.21,802.31,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1016','Flipkart - Seller Hub','2026-04-08 18:38+05:30','Kiran Naik','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1010','Amazon - Seller Central','2026-04-08 18:20+05:30','Kavya Menon','prepaid',2698.0,134.9,128.16,2691.26,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1011','Amazon - Seller Central','2026-04-08 21:03+05:30','Aditi Joshi','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1014','MTRK-BLK-M',1,649,0.0,32.45),
('SHOP-1010','BJNS-IND-45Y',2,799,0.0,79.9),
('SHOP-1010','BKUR-MUS-89Y',1,949,0.0,47.45),
('SHOP-1011','GNGT-PNK-1011Y',1,549,0.0,27.45),
('SHOP-1011','GFRK-LIL-67Y',1,749,0.0,37.45),
('SHOP-1011','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1009','MCHN-OLV-34',2,1199,0.0,119.9),
('AMAZ-1009','MHOD-BLK-M',1,1299,0.0,64.95),
('AMAZ-1009','MCHN-KHK-34',2,1199,0.0,119.9),
('FLIP-1015','WKRT-PNK-M',1,849,84.9,38.21),
('FLIP-1016','BTEE-BLU-67Y',1,329,32.9,14.81),
('AMAZ-1010','WJNS-IND-28',2,1349,134.9,128.16),
('AMAZ-1011','WTOP-PCH-L',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1010','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.retime();

-- Thu 09 Apr 2026
select pg_temp.day('2026-04-09');
select pg_temp.grn_new('Weekly replenishment 06 Apr 2026 - Little Stitch Garments (ref R002)', 'DC-LSG-0043', '[{"sku":"BSHT-GRY-89Y","q":8,"a":8,"r":0},{"sku":"BKUR-CRM-89Y","q":8,"a":7,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 06 Apr 2026 - Little Stitch Garments (ref R003)', 'DC-LSG-0046', '[{"sku":"GNGT-PNK-1011Y","q":12,"a":12,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1012','Amazon - Seller Central','2026-04-09 19:39+05:30','Isha Gupta','cod',649.0,64.9,29.21,613.31,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1012','Shopify - Main Store','2026-04-09 17:43+05:30','Sanjay Gajera','cod',6633.0,663.3,298.49,6268.19,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1017','Flipkart - Seller Hub','2026-04-09 20:29+05:30','Mitul Dave','prepaid',6894.0,0.0,344.7,7238.7,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1018','Flipkart - Seller Hub','2026-04-09 12:12+05:30','Mehul Shukla','prepaid',1148.0,0.0,57.4,1205.4,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1012','MTRK-BLK-M',1,649,64.9,29.21),
('SHOP-1012','MCHN-OLV-34',2,1199,239.8,107.91),
('SHOP-1012','BTEE-BLU-67Y',2,329,65.8,29.61),
('SHOP-1012','MJNS-IND-34',2,1399,279.8,125.91),
('SHOP-1012','GJNS-IND-89Y',1,779,77.9,35.06),
('FLIP-1017','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1017','WJNS-IND-32',2,1349,0.0,134.9),
('FLIP-1017','WDRS-FLR-L',2,1499,0.0,149.9),
('FLIP-1017','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1018','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1018','GNGT-PNK-1011Y',1,549,0.0,27.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1012','Xpressbees - Pandesara'),
('SHOP-1012','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_new('FLIP-1011', 'AWB31000021', 'Address incomplete');
select pg_temp.retime();

-- Fri 10 Apr 2026
select pg_temp.day('2026-04-10');
select pg_temp.bill_po('Weekly replenishment 06 Apr 2026 - Little Stitch Garments (ref R002)', 'LSG/26/0107', 1);
select pg_temp.bill_po('Weekly replenishment 06 Apr 2026 - Little Stitch Garments (ref R003)', 'LSG/26/0114', 1);
select pg_temp.grn_new('Weekly replenishment 06 Apr 2026 - Rajdhani Shirting Mills (ref R005)', 'DC-RSM-0043', '[{"sku":"MSHF-WHT-XL","q":8,"a":8,"r":0},{"sku":"MKUR-MUS-M","q":8,"a":8,"r":0},{"sku":"BSHF-WHT-1011Y","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1013','Shopify - Main Store','2026-04-10 19:07+05:30','Sejal Kapadia','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1014','Shopify - Main Store','2026-04-10 20:17+05:30','Nidhi Agarwal','cod',2946.0,0.0,147.3,3093.3,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1015','Shopify - Main Store','2026-04-10 20:58+05:30','Sonal Parekh','prepaid',1528.0,0.0,76.4,1604.4,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1016','Shopify - Main Store','2026-04-10 17:53+05:30','Karan Malhotra','cod',849.0,0.0,42.45,891.45,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1017','Shopify - Main Store','2026-04-10 14:51+05:30','Nikhil Pandey','prepaid',2348.0,0.0,117.4,2465.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1019','Flipkart - Seller Hub','2026-04-10 16:43+05:30','Jigar Chauhan','cod',2447.0,0.0,122.35,2569.35,'cancelled','failed','Rajasthan','Surat Main Warehouse'),
('FLIP-1020','Flipkart - Seller Hub','2026-04-10 15:54+05:30','Vivek Singh','prepaid',4196.0,209.8,199.31,4185.51,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1018','Shopify - Main Store','2026-04-10 09:17+05:30','Pratik Lad','prepaid',2206.0,0.0,110.3,2316.3,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1013','WLEG-MAR-L',1,349,0.0,17.45),
('SHOP-1014','GNGT-PNK-89Y',3,549,0.0,82.35),
('SHOP-1014','MHOD-GRY-M',1,1299,0.0,64.95),
('SHOP-1015','GFRK-LIL-67Y',1,749,0.0,37.45),
('SHOP-1015','GJNS-IND-45Y',1,779,0.0,38.95),
('SHOP-1016','WKRT-PNK-L',1,849,0.0,42.45),
('SHOP-1017','WKRT-TEL-M',1,849,0.0,42.45),
('SHOP-1017','WDRS-FLR-L',1,1499,0.0,74.95),
('FLIP-1019','WLEG-MAR-M',1,349,0.0,17.45),
('FLIP-1019','WDRS-FLR-L',1,1499,0.0,74.95),
('FLIP-1019','WTOP-WHT-M',1,599,0.0,29.95),
('FLIP-1020','WDRS-FLR-S',2,1499,149.9,142.41),
('FLIP-1020','WTOP-WHT-M',1,599,29.95,28.45),
('FLIP-1020','WTOP-PCH-S',1,599,29.95,28.45),
('SHOP-1018','BTEE-BLU-67Y',2,329,0.0,32.9),
('SHOP-1018','BSHT-NVY-67Y',1,349,0.0,17.45),
('SHOP-1018','MCHN-KHK-34',1,1199,0.0,59.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1014','Delhivery - Sachin GIDC Surat'),
('SHOP-1016','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.cod_collect(array['FLIP-1008']::text[]);
select pg_temp.cod_collect(array['SHOP-1004']::text[]);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-04-13', 'ICIC000000880365', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-04-13', 'ICIC000000880435', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-04-13', 'ICIC000000880489', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-04-13', 'ICIC000000880508', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-04-13', 'ICIC000000880568', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-04-13', 'ICIC000000880646', 1);
select pg_temp.retime();

-- Sat 11 Apr 2026
select pg_temp.day('2026-04-11');
select pg_temp.bill_po('Weekly replenishment 06 Apr 2026 - Rajdhani Shirting Mills (ref R005)', 'RSM/26/0111', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1013','Amazon - Seller Central','2026-04-11 12:16+05:30','Bhavna Solanki','prepaid',1798.0,0.0,89.9,1887.9,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1021','Flipkart - Seller Hub','2026-04-11 11:25+05:30','Riya Shah','prepaid',2698.0,0.0,134.9,2832.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1014','Amazon - Seller Central','2026-04-11 21:51+05:30','Kiran Naik','cod',3446.0,0.0,172.3,3618.3,'delivered','pending','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1013','MSHC-RED-XL',2,899,0.0,89.9),
('FLIP-1021','WJNS-IND-28',1,1349,0.0,67.45),
('FLIP-1021','WJNS-BLK-28',1,1349,0.0,67.45),
('AMAZ-1014','MTEE-WHT-XL',1,449,0.0,22.45),
('AMAZ-1014','MSHF-WHT-L',1,999,0.0,49.95),
('AMAZ-1014','MSHF-SKY-XL',2,999,0.0,99.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1014','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_set('FLIP-1011', 'in_transit');
select pg_temp.retime();

-- Sun 12 Apr 2026
select pg_temp.day('2026-04-12');
select pg_temp.grn_new('Weekly replenishment 06 Apr 2026 - Krishna Denim Works (ref R001)', 'DC-KDW-0043', '[{"sku":"MJNS-IND-32","q":16,"a":16,"r":0},{"sku":"MJNS-BLK-32","q":8,"a":8,"r":0},{"sku":"MCHN-OLV-34","q":24,"a":23,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1022','Flipkart - Seller Hub','2026-04-12 15:45+05:30','Isha Gupta','cod',1199.0,119.9,53.96,1133.06,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1019','Shopify - Main Store','2026-04-12 19:13+05:30','Riya Shah','cod',1298.0,0.0,64.9,1362.9,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('SHOP-1020','Shopify - Main Store','2026-04-12 21:38+05:30','Manav Joshi','prepaid',1807.0,0.0,90.35,1897.35,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1023','Flipkart - Seller Hub','2026-04-12 11:52+05:30','Dev Trivedi','cod',1648.0,82.4,78.28,1643.88,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1024','Flipkart - Seller Hub','2026-04-12 10:25+05:30','Chirag Zaveri','prepaid',2646.0,132.3,125.69,2639.39,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1022','MCHN-KHK-30',1,1199,119.9,53.96),
('SHOP-1019','MTRK-BLK-L',2,649,0.0,64.9),
('SHOP-1020','GLEG-BLK-45Y',1,279,0.0,13.95),
('SHOP-1020','GJNS-IND-45Y',1,779,0.0,38.95),
('SHOP-1020','GFRK-PNK-67Y',1,749,0.0,37.45),
('FLIP-1023','MTRK-BLK-XL',1,649,32.45,30.83),
('FLIP-1023','MSHF-WHT-L',1,999,49.95,47.45),
('FLIP-1024','WTOP-WHT-M',3,599,89.85,85.36),
('FLIP-1024','WKRT-PNK-XL',1,849,42.45,40.33)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1022','Delhivery - Sachin GIDC Surat'),
('FLIP-1023','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.cod_collect(array['AMAZ-1012']::text[]);
select pg_temp.retime();

-- Mon 13 Apr 2026
select pg_temp.day('2026-04-13');
select pg_temp.bill_po('Weekly replenishment 06 Apr 2026 - Krishna Denim Works (ref R001)', 'KDW/26/0113', 1);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Krishna Denim Works (ref R008)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MCHN-KHK-30","q":6},{"sku":"WJNS-IND-28","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Krishna Denim Works (ref R009)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-IND-34","q":6},{"sku":"MCHN-KHK-30","q":12},{"sku":"MCHN-KHK-34","q":12},{"sku":"MCHN-OLV-34","q":16},{"sku":"WJNS-IND-32","q":6},{"sku":"BJNS-IND-45Y","q":6},{"sku":"BJNS-IND-89Y","q":6},{"sku":"GJNS-IND-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Little Stitch Garments (ref R010)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"WDRS-FLR-L","q":6},{"sku":"BKUR-MUS-67Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Little Stitch Garments (ref R011)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLR-S","q":6},{"sku":"WDRS-FLR-L","q":6},{"sku":"GFRK-LIL-67Y","q":12},{"sku":"GNGT-PNK-89Y","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Ludhiana Winter Wear Co (ref R012)', 'Ludhiana Winter Wear Co', 'Mumbai Fulfilment Center', '[{"sku":"MHOD-BLK-XL","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Rajdhani Shirting Mills (ref R013)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHF-WHT-L","q":6},{"sku":"MSHF-SKY-XL","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Rajdhani Shirting Mills (ref R014)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHF-WHT-L","q":6},{"sku":"MSHC-RED-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Shree Ambika Textiles (ref R015)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WKRT-PNK-M","q":6},{"sku":"WKRT-TEL-M","q":6},{"sku":"WKRT-TEL-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Shree Ambika Textiles (ref R016)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R017)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-WHT-XL","q":6},{"sku":"MTRK-BLK-M","q":6},{"sku":"MTRK-BLK-L","q":10},{"sku":"WLEG-BLK-L","q":6},{"sku":"WTOP-WHT-L","q":6},{"sku":"WTOP-PCH-S","q":6},{"sku":"WTOP-PCH-L","q":10},{"sku":"BTEE-BLU-67Y","q":6},{"sku":"GTOP-WHT-89Y","q":6},{"sku":"GLEG-PNK-89Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R018)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTRK-BLK-M","q":6},{"sku":"WTOP-WHT-M","q":30},{"sku":"WTOP-WHT-L","q":22},{"sku":"WTOP-PCH-L","q":6},{"sku":"BTEE-BLU-67Y","q":22},{"sku":"BTEE-RED-89Y","q":6},{"sku":"GLEG-BLK-45Y","q":6},{"sku":"GLEG-PNK-89Y","q":12}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1015','Amazon - Seller Central','2026-04-13 22:20+05:30','Bhavna Solanki','prepaid',6245.0,0.0,312.25,6557.25,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1016','Amazon - Seller Central','2026-04-13 12:15+05:30','Mitul Dave','prepaid',2557.0,0.0,127.85,2684.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1017','Amazon - Seller Central','2026-04-13 11:11+05:30','Kunal Desai','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1021','Shopify - Main Store','2026-04-13 11:51+05:30','Nikhil Pandey','cod',2098.0,0.0,104.9,2202.9,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1025','Flipkart - Seller Hub','2026-04-13 16:50+05:30','Jigar Chauhan','cod',658.0,65.8,29.62,621.82,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1018','Amazon - Seller Central','2026-04-13 18:51+05:30','Tanvi Rana','cod',2146.0,107.3,101.94,2140.64,'delivered','pending','Delhi','Surat Main Warehouse'),
('SHOP-1022','Shopify - Main Store','2026-04-13 09:36+05:30','Pratik Lad','prepaid',3497.0,0.0,174.85,3671.85,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1015','MJNS-BLK-30',1,1399,0.0,69.95),
('AMAZ-1015','MJNS-IND-34',1,1399,0.0,69.95),
('AMAZ-1015','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1015','MJNS-IND-32',2,1399,0.0,139.9),
('AMAZ-1016','GLEG-PNK-89Y',2,279,0.0,27.9),
('AMAZ-1016','GLHG-TEL-45Y',1,1999,0.0,99.95),
('AMAZ-1017','WPAL-WHT-M',1,599,0.0,29.95),
('AMAZ-1017','WPAL-YLW-XL',1,599,0.0,29.95),
('SHOP-1021','BJNS-IND-45Y',1,799,0.0,39.95),
('SHOP-1021','MHOD-GRY-XL',1,1299,0.0,64.95),
('FLIP-1025','BTEE-BLU-67Y',1,329,32.9,14.81),
('FLIP-1025','BTEE-RED-89Y',1,329,32.9,14.81),
('AMAZ-1018','WTOP-PCH-M',1,599,29.95,28.45),
('AMAZ-1018','WPAL-WHT-M',2,599,59.9,56.91),
('AMAZ-1018','WLEG-BLK-M',1,349,17.45,16.58),
('SHOP-1022','MJNS-BLK-32',1,1399,0.0,69.95),
('SHOP-1022','MSHC-RED-XL',1,899,0.0,44.95),
('SHOP-1022','MCHN-OLV-30',1,1199,0.0,59.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1021','Xpressbees - Pandesara'),
('FLIP-1025','Xpressbees - Pandesara'),
('AMAZ-1018','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.cod_collect(array['SHOP-1010']::text[]);
select pg_temp.cod_collect(array['SHOP-1012']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260406', '2026-04-06', '2026-04-12', array['AMAZ-1001','AMAZ-1003','AMAZ-1002','AMAZ-1004','AMAZ-1005','AMAZ-1007','AMAZ-1006','AMAZ-1010','AMAZ-1008']::text[], array[]::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260406', '2026-04-06', '2026-04-12', array['FLIP-1002','FLIP-1003','FLIP-1001','FLIP-1005','FLIP-1006','FLIP-1010','FLIP-1009','FLIP-1016','FLIP-1012','FLIP-1015']::text[], array[]::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260406', '2026-04-06', '2026-04-12', array['SHOP-1002','SHOP-1001','SHOP-1003','SHOP-1005','SHOP-1006','SHOP-1007','SHOP-1008']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 14 Apr 2026
select pg_temp.day('2026-04-14');
select pg_temp.grn_new('Weekly replenishment 06 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R007)', 'DC-TKF-0046', '[{"sku":"WTOP-WHT-M","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-89Y","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1023','Shopify - Main Store','2026-04-14 13:18+05:30','Anjali Verma','cod',2227.0,222.7,100.22,2104.52,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1026','Flipkart - Seller Hub','2026-04-14 19:58+05:30','Foram Thakkar','cod',1298.0,0.0,64.9,1362.9,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('AMAZ-1019','Amazon - Seller Central','2026-04-14 09:37+05:30','Yash Vora','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1024','Shopify - Main Store','2026-04-14 19:01+05:30','Heena Khan','prepaid',10998.0,1099.8,1781.68,11679.88,'cancelled','refunded','Rajasthan','Surat Main Warehouse'),
('FLIP-1027','Flipkart - Seller Hub','2026-04-14 12:04+05:30','Mitul Dave','cod',4094.0,0.0,204.7,4298.7,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1020','Amazon - Seller Central','2026-04-14 10:18+05:30','Tanvi Rana','prepaid',1399.0,69.95,66.45,1395.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1028','Flipkart - Seller Hub','2026-04-14 11:56+05:30','Sagar Rathod','prepaid',2585.0,0.0,129.25,2714.25,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1023','BKUR-CRM-67Y',2,949,189.8,85.41),
('SHOP-1023','BTEE-RED-45Y',1,329,32.9,14.81),
('FLIP-1026','MTRK-BLK-M',2,649,0.0,64.9),
('AMAZ-1019','MJNS-BLK-32',1,1399,0.0,69.95),
('AMAZ-1019','MPOL-NVY-M',1,699,0.0,34.95),
('SHOP-1024','WLHG-RED-L',2,5499,1099.8,1781.68),
('FLIP-1027','WJNS-BLK-32',1,1349,0.0,67.45),
('FLIP-1027','WLEG-MAR-L',1,349,0.0,17.45),
('FLIP-1027','WTOP-WHT-M',3,599,0.0,89.85),
('FLIP-1027','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1020','MJNS-BLK-32',1,1399,69.95,66.45),
('FLIP-1028','BTEE-BLU-89Y',1,329,0.0,16.45),
('FLIP-1028','BTEE-RED-89Y',2,329,0.0,32.9),
('FLIP-1028','BKUR-MUS-45Y',1,949,0.0,47.45),
('FLIP-1028','MTRK-BLK-M',1,649,0.0,32.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1023','Xpressbees - Pandesara'),
('FLIP-1027','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_new('FLIP-1001', 'Size did not fit', 'webhook');
select pg_temp.cod_collect(array['SHOP-1016']::text[]);
select pg_temp.settle_pay('FLK-STL-20260401', 0.0);
select pg_temp.retime();

-- Wed 15 Apr 2026
select pg_temp.day('2026-04-15');
select pg_temp.bill_po('Weekly replenishment 06 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R007)', 'TKF/26/0120', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1029','Flipkart - Seller Hub','2026-04-15 13:10+05:30','Karan Malhotra','prepaid',4998.0,0.0,743.77,5741.77,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1025','Shopify - Main Store','2026-04-15 14:00+05:30','Sejal Kapadia','cod',1199.0,59.95,56.95,1196.0,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('SHOP-1026','Shopify - Main Store','2026-04-15 10:57+05:30','Bhavna Solanki','prepaid',7447.0,0.0,1087.22,8534.22,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1030','Flipkart - Seller Hub','2026-04-15 20:57+05:30','Shreya Banerjee','cod',1198.0,0.0,59.9,1257.9,'shipped','pending','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1027','Shopify - Main Store','2026-04-15 21:04+05:30','Sonal Parekh','prepaid',10496.0,0.0,1239.67,11735.67,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1031','Flipkart - Seller Hub','2026-04-15 13:37+05:30','Aarav Mehta','cod',329.0,32.9,14.81,310.91,'delivered','pending','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1029','MCHN-OLV-34',1,1199,0.0,59.95),
('FLIP-1029','MBLZ-NVY-40',1,3799,0.0,683.82),
('SHOP-1025','MCHN-OLV-34',1,1199,59.95,56.95),
('SHOP-1026','WLHG-MAG-L',1,5499,0.0,989.82),
('SHOP-1026','WTOP-PCH-M',1,599,0.0,29.95),
('SHOP-1026','WJNS-BLK-32',1,1349,0.0,67.45),
('FLIP-1030','WTOP-PCH-S',2,599,0.0,59.9),
('SHOP-1027','WSAR-BLU-FREE',2,2199,0.0,219.9),
('SHOP-1027','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1027','WLHG-MAG-M',1,5499,0.0,989.82),
('FLIP-1031','BTEE-BLU-45Y',1,329,32.9,14.81)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1025','Delhivery - Sachin GIDC Surat'),
('FLIP-1031','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1001', 'approved');
select pg_temp.ret_new('AMAZ-1004', 'Size did not fit', 'webhook');
select pg_temp.cod_collect(array['SHOP-1014']::text[]);
select pg_temp.cod_collect(array['AMAZ-1014']::text[]);
select pg_temp.cod_collect(array['FLIP-1022']::text[]);
select pg_temp.cod_collect(array['FLIP-1023']::text[]);
select pg_temp.settle_pay('SHP-STL-20260406', 0.0);
select pg_temp.retime();

-- Thu 16 Apr 2026
select pg_temp.day('2026-04-16');
select pg_temp.grn_new('Weekly replenishment 06 Apr 2026 - Ludhiana Winter Wear Co (ref R004)', 'DC-LWW-0043', '[{"sku":"MHOD-BLK-XL","q":16,"a":15,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 06 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R006)', 'DC-TKF-0043', '[{"sku":"MTRK-BLK-M","q":8,"a":8,"r":0},{"sku":"MTRK-BLK-L","q":16,"a":16,"r":0},{"sku":"WLEG-BLK-L","q":8,"a":8,"r":0},{"sku":"WTOP-WHT-L","q":8,"a":8,"r":0},{"sku":"WTOP-PCH-S","q":8,"a":7,"r":1},{"sku":"WTOP-PCH-L","q":16,"a":15,"r":1},{"sku":"BTEE-BLU-67Y","q":8,"a":8,"r":0},{"sku":"GTOP-WHT-89Y","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-89Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Shree Ambika Textiles (ref R016)', 'DC-SAT-0046', '[{"sku":"WKRT-PNK-L","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1032','Flipkart - Seller Hub','2026-04-16 11:17+05:30','Anjali Verma','cod',1748.0,0.0,87.4,1835.4,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1028','Shopify - Main Store','2026-04-16 21:20+05:30','Sonal Parekh','cod',2198.0,109.9,104.41,2192.51,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1033','Flipkart - Seller Hub','2026-04-16 14:31+05:30','Jigar Chauhan','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1029','Shopify - Main Store','2026-04-16 16:17+05:30','Kunal Desai','prepaid',3297.0,0.0,164.85,3461.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1034','Flipkart - Seller Hub','2026-04-16 22:04+05:30','Amit Sethi','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1032','MKUR-MUS-M',1,1099,0.0,54.95),
('FLIP-1032','MTRK-BLK-M',1,649,0.0,32.45),
('SHOP-1028','MKUR-WHT-L',2,1099,109.9,104.41),
('FLIP-1033','BTEE-BLU-45Y',1,329,0.0,16.45),
('SHOP-1029','WJNS-IND-28',2,1349,0.0,134.9),
('SHOP-1029','WTOP-PCH-S',1,599,0.0,29.95),
('FLIP-1034','GTOP-WHT-45Y',1,349,0.0,17.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1032','DTDC - Ring Road Surat'),
('SHOP-1028','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1001', 'pickup');
select pg_temp.ret_set('AMAZ-1004', 'approved');
select pg_temp.rto_recv('FLIP-1011', 'good', 'restocked');
select pg_temp.retime();

-- Fri 17 Apr 2026
select pg_temp.day('2026-04-17');
select pg_temp.bill_po('Weekly replenishment 06 Apr 2026 - Ludhiana Winter Wear Co (ref R004)', 'LWW/26/0109', 1);
select pg_temp.bill_po('Weekly replenishment 06 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R006)', 'TKF/26/0111', 1);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Krishna Denim Works (ref R009)', 'DC-KDW-0049', '[{"sku":"MJNS-IND-34","q":6,"a":6,"r":0},{"sku":"MCHN-KHK-30","q":12,"a":12,"r":0},{"sku":"MCHN-KHK-34","q":12,"a":12,"r":0},{"sku":"MCHN-OLV-34","q":16,"a":16,"r":0},{"sku":"WJNS-IND-32","q":6,"a":6,"r":0},{"sku":"BJNS-IND-45Y","q":6,"a":6,"r":0},{"sku":"BJNS-IND-89Y","q":6,"a":6,"r":0},{"sku":"GJNS-IND-45Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Little Stitch Garments (ref R010)', 'DC-LSG-0049', '[{"sku":"WDRS-FLR-L","q":6,"a":6,"r":0},{"sku":"BKUR-MUS-67Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Rajdhani Shirting Mills (ref R013)', 'DC-RSM-0046', '[{"sku":"MSHF-WHT-L","q":6,"a":6,"r":0},{"sku":"MSHF-SKY-XL","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Shree Ambika Textiles (ref R016)', 'SAT/26/0119', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1021','Amazon - Seller Central','2026-04-17 15:28+05:30','Meghna Rao','prepaid',2798.0,139.9,132.91,2791.01,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1030','Shopify - Main Store','2026-04-17 17:21+05:30','Mitul Dave','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1022','Amazon - Seller Central','2026-04-17 21:42+05:30','Vivek Singh','prepaid',1948.0,194.8,87.67,1840.87,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1035','Flipkart - Seller Hub','2026-04-17 22:46+05:30','Kiran Naik','prepaid',1499.0,0.0,74.95,1573.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1036','Flipkart - Seller Hub','2026-04-17 09:52+05:30','Mitul Dave','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1023','Amazon - Seller Central','2026-04-17 16:32+05:30','Karan Malhotra','prepaid',899.0,0.0,44.95,943.95,'delivered','paid','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1021','MJNS-BLK-32',2,1399,139.9,132.91),
('SHOP-1030','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1022','WJNS-IND-28',1,1349,134.9,60.71),
('AMAZ-1022','WTOP-PCH-M',1,599,59.9,26.96),
('FLIP-1035','WDRS-FLP-L',1,1499,0.0,74.95),
('FLIP-1036','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1023','MSHC-GRN-L',1,899,0.0,44.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_set('AMAZ-1004', 'pickup');
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-17APR', array['SHOP-1004','SHOP-1010','SHOP-1014','FLIP-1022']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-17APR', array['FLIP-1008','SHOP-1016']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-17APR', array['SHOP-1012','AMAZ-1014']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-17APR', array['AMAZ-1012','FLIP-1023']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-04-20', 'ICIC000000880732', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-04-20', 'ICIC000000880754', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-04-20', 'ICIC000000880768', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-04-20', 'ICIC000000880793', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-04-20', 'ICIC000000880853', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-04-20', 'ICIC000000880938', 1);
select pg_temp.retime();

-- Sat 18 Apr 2026
select pg_temp.day('2026-04-18');
select pg_temp.grn_new('Weekly replenishment 06 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R007)', 'DC-TKF-0049', '[{"sku":"WTOP-WHT-M","q":4,"a":4,"r":0},{"sku":"GLEG-PNK-89Y","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Krishna Denim Works (ref R008)', 'DC-KDW-0046', '[{"sku":"MCHN-KHK-30","q":6,"a":6,"r":0},{"sku":"WJNS-IND-28","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Krishna Denim Works (ref R009)', 'KDW/26/0124', 1);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Little Stitch Garments (ref R010)', 'LSG/26/0121', 1);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Little Stitch Garments (ref R011)', 'DC-LSG-0052', '[{"sku":"WDRS-FLR-S","q":6,"a":6,"r":0},{"sku":"WDRS-FLR-L","q":6,"a":6,"r":0},{"sku":"GFRK-LIL-67Y","q":12,"a":12,"r":0},{"sku":"GNGT-PNK-89Y","q":12,"a":12,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Rajdhani Shirting Mills (ref R013)', 'RSM/26/0115', 1);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Rajdhani Shirting Mills (ref R014)', 'DC-RSM-0049', '[{"sku":"MSHF-WHT-L","q":6,"a":5,"r":1},{"sku":"MSHC-RED-XL","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Shree Ambika Textiles (ref R015)', 'DC-SAT-0043', '[{"sku":"WKRT-PNK-M","q":6,"a":6,"r":0},{"sku":"WKRT-TEL-M","q":6,"a":6,"r":0},{"sku":"WKRT-TEL-XL","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1037','Flipkart - Seller Hub','2026-04-18 16:12+05:30','Shreya Banerjee','cod',3825.0,0.0,191.25,4016.25,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('AMAZ-1024','Amazon - Seller Central','2026-04-18 16:30+05:30','Mehul Shukla','prepaid',2697.0,0.0,134.85,2831.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1038','Flipkart - Seller Hub','2026-04-18 12:21+05:30','Jigar Chauhan','prepaid',2455.0,0.0,122.75,2577.75,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1031','Shopify - Main Store','2026-04-18 10:08+05:30','Divya Nair','cod',2248.0,224.8,101.17,2124.37,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1039','Flipkart - Seller Hub','2026-04-18 09:11+05:30','Vipul Gandhi','prepaid',4645.0,464.5,209.04,4389.54,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1025','Amazon - Seller Central','2026-04-18 16:04+05:30','Neha Patel','prepaid',878.0,87.8,39.52,829.72,'delivered','paid','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1037','BJNS-IND-89Y',2,799,0.0,79.9),
('FLIP-1037','BKUR-MUS-67Y',1,949,0.0,47.45),
('FLIP-1037','BKUR-MUS-45Y',1,949,0.0,47.45),
('FLIP-1037','BTEE-RED-89Y',1,329,0.0,16.45),
('AMAZ-1024','MSHC-GRN-L',3,899,0.0,134.85),
('FLIP-1038','BTEE-BLU-89Y',2,329,0.0,32.9),
('FLIP-1038','BSHF-WHT-89Y',3,599,0.0,89.85),
('SHOP-1031','WDRS-FLP-S',1,1499,149.9,67.46),
('SHOP-1031','GFRK-LIL-67Y',1,749,74.9,33.71),
('FLIP-1039','BSHF-WHT-1011Y',3,599,179.7,80.87),
('FLIP-1039','WJNS-IND-32',1,1349,134.9,60.71),
('FLIP-1039','WDRS-FLP-L',1,1499,149.9,67.46),
('AMAZ-1025','WPAL-WHT-M',1,599,59.9,26.96),
('AMAZ-1025','GLEG-BLK-45Y',1,279,27.9,12.56)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1037','Bluedart - Surat City'),
('SHOP-1031','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1001', 'in_transit');
select pg_temp.cod_collect(array['AMAZ-1018']::text[]);
select pg_temp.cod_collect(array['SHOP-1025']::text[]);
select pg_temp.cod_collect(array['FLIP-1031']::text[]);
select pg_temp.retime();

-- Sun 19 Apr 2026
select pg_temp.day('2026-04-19');
select pg_temp.bill_po('Weekly replenishment 06 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R007)', 'TKF/26/0126', 1);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Krishna Denim Works (ref R008)', 'KDW/26/0114', 1);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Little Stitch Garments (ref R011)', 'LSG/26/0129', 1);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Rajdhani Shirting Mills (ref R014)', 'RSM/26/0127', 1);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Shree Ambika Textiles (ref R015)', 'SAT/26/0112', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1032','Shopify - Main Store','2026-04-19 18:33+05:30','Nikhil Pandey','cod',2697.0,0.0,134.85,2831.85,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1033','Shopify - Main Store','2026-04-19 13:35+05:30','Chirag Zaveri','prepaid',928.0,46.4,44.08,925.68,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1034','Shopify - Main Store','2026-04-19 20:38+05:30','Kiran Naik','cod',279.0,0.0,13.95,292.95,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1026','Amazon - Seller Central','2026-04-19 09:20+05:30','Shreya Banerjee','prepaid',2997.0,0.0,149.85,3146.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1040','Flipkart - Seller Hub','2026-04-19 21:21+05:30','Yash Vora','prepaid',2396.0,239.6,107.82,2264.22,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1027','Amazon - Seller Central','2026-04-19 15:40+05:30','Nidhi Agarwal','prepaid',1399.0,69.95,66.45,1395.5,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1035','Shopify - Main Store','2026-04-19 14:09+05:30','Isha Gupta','prepaid',2997.0,0.0,149.85,3146.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1028','Amazon - Seller Central','2026-04-19 16:02+05:30','Kavya Menon','prepaid',3834.0,0.0,191.7,4025.7,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1032','WDRS-FLP-L',1,1499,0.0,74.95),
('SHOP-1032','WTOP-WHT-L',2,599,0.0,59.9),
('SHOP-1033','WTOP-PCH-S',1,599,29.95,28.45),
('SHOP-1033','BTEE-RED-45Y',1,329,16.45,15.63),
('SHOP-1034','GLEG-PNK-89Y',1,279,0.0,13.95),
('AMAZ-1026','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1026','MCHN-OLV-34',2,1199,0.0,119.9),
('FLIP-1040','WTOP-PCH-S',2,599,119.8,53.91),
('FLIP-1040','WTOP-WHT-L',2,599,119.8,53.91),
('AMAZ-1027','MJNS-IND-32',1,1399,69.95,66.45),
('SHOP-1035','MSHF-SKY-M',3,999,0.0,149.85),
('AMAZ-1028','BTEE-BLU-45Y',1,329,0.0,16.45),
('AMAZ-1028','BTEE-RED-45Y',2,329,0.0,32.9),
('AMAZ-1028','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1028','BKUR-CRM-67Y',2,949,0.0,94.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1032','Ecom Express - Udhna Hub'),
('SHOP-1034','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1004', 'in_transit');
select pg_temp.rto_new('AMAZ-1015', 'AWB31000047', 'Customer refused delivery');
select pg_temp.cod_collect(array['SHOP-1021']::text[]);
select pg_temp.cod_collect(array['FLIP-1025']::text[]);
select pg_temp.cod_collect(array['SHOP-1023']::text[]);
select pg_temp.cod_collect(array['FLIP-1027']::text[]);
select pg_temp.cod_collect(array['FLIP-1032']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260406', 0.0);
select pg_temp.retime();

-- Mon 20 Apr 2026
select pg_temp.day('2026-04-20');
select pg_temp.po_new('Weekly replenishment 20 Apr 2026 - Krishna Denim Works (ref R019)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-32","q":14},{"sku":"WJNS-IND-28","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Apr 2026 - Little Stitch Garments (ref R020)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"WDRS-FLP-S","q":6},{"sku":"WDRS-FLP-L","q":6},{"sku":"BKUR-MUS-45Y","q":6},{"sku":"GFRK-LIL-67Y","q":6},{"sku":"GLHG-TEL-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Apr 2026 - Little Stitch Garments (ref R021)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"BKUR-CRM-67Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Apr 2026 - Rajdhani Shirting Mills (ref R022)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHC-GRN-L","q":10},{"sku":"MKUR-WHT-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Apr 2026 - Rajdhani Shirting Mills (ref R023)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHF-SKY-M","q":8},{"sku":"BSHF-WHT-89Y","q":8},{"sku":"BSHF-WHT-1011Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Apr 2026 - Shree Ambika Textiles (ref R024)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WPAL-WHT-M","q":6},{"sku":"WPAL-YLW-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R025)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-WHT-XL","q":6},{"sku":"WTOP-WHT-L","q":8},{"sku":"WTOP-PCH-S","q":10},{"sku":"WTOP-PCH-M","q":6},{"sku":"BTEE-BLU-89Y","q":6},{"sku":"BTEE-RED-89Y","q":6},{"sku":"GLEG-BLK-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R026)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"WTOP-WHT-M","q":22},{"sku":"WTOP-WHT-L","q":18},{"sku":"WTOP-PCH-S","q":14},{"sku":"WTOP-PCH-M","q":8},{"sku":"BTEE-BLU-45Y","q":8},{"sku":"BTEE-BLU-67Y","q":18},{"sku":"BTEE-RED-45Y","q":10},{"sku":"BTEE-RED-89Y","q":10}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1036','Shopify - Main Store','2026-04-20 12:11+05:30','Sanjay Gajera','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1037','Shopify - Main Store','2026-04-20 22:02+05:30','Heena Khan','prepaid',2847.0,0.0,142.35,2989.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1029','Amazon - Seller Central','2026-04-20 18:44+05:30','Divya Nair','prepaid',5094.0,0.0,254.7,5348.7,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1041','Flipkart - Seller Hub','2026-04-20 09:31+05:30','Mehul Shukla','cod',349.0,34.9,15.71,329.81,'delivered','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1036','MTRK-BLK-M',1,649,0.0,32.45),
('SHOP-1037','BKUR-MUS-45Y',1,949,0.0,47.45),
('SHOP-1037','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1037','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1029','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1029','WPAL-WHT-XL',1,599,0.0,29.95),
('AMAZ-1029','WJNS-IND-28',2,1349,0.0,134.9),
('AMAZ-1029','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1041','WLEG-MAR-M',1,349,34.9,15.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1041','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260413', '2026-04-13', '2026-04-19', array['AMAZ-1009','AMAZ-1011','AMAZ-1013','AMAZ-1017','AMAZ-1020','AMAZ-1016']::text[], array[]::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260413', '2026-04-13', '2026-04-19', array['FLIP-1013','FLIP-1017','FLIP-1014','FLIP-1018','FLIP-1020','FLIP-1021','FLIP-1024','FLIP-1028']::text[], array[]::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260413', '2026-04-13', '2026-04-19', array['SHOP-1009','SHOP-1011','SHOP-1017','SHOP-1018','SHOP-1015','SHOP-1013','SHOP-1020','SHOP-1026','SHOP-1022']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 21 Apr 2026
select pg_temp.day('2026-04-21');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1042','Flipkart - Seller Hub','2026-04-21 14:13+05:30','Amit Sethi','prepaid',7347.0,367.35,1028.11,8007.76,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1038','Shopify - Main Store','2026-04-21 19:36+05:30','Ritu Saxena','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1043','Flipkart - Seller Hub','2026-04-21 18:43+05:30','Sejal Kapadia','cod',2397.0,239.7,107.87,2265.17,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1030','Amazon - Seller Central','2026-04-21 17:12+05:30','Vivek Singh','prepaid',3095.0,0.0,154.75,3249.75,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1044','Flipkart - Seller Hub','2026-04-21 22:11+05:30','Bhavna Solanki','prepaid',1499.0,0.0,74.95,1573.95,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1042','WDRS-FLP-S',1,1499,74.95,71.2),
('FLIP-1042','WLHG-RED-M',1,5499,274.95,940.33),
('FLIP-1042','WLEG-BLK-M',1,349,17.45,16.58),
('SHOP-1038','WTOP-WHT-M',3,599,0.0,89.85),
('FLIP-1043','WTOP-PCH-L',2,599,119.8,53.91),
('FLIP-1043','MCHN-KHK-30',1,1199,119.9,53.96),
('AMAZ-1030','WDUP-SLV-FREE',1,449,0.0,22.45),
('AMAZ-1030','WKRT-TEL-XL',1,849,0.0,42.45),
('AMAZ-1030','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1030','WPAL-WHT-L',2,599,0.0,59.9),
('FLIP-1044','WDRS-FLP-S',1,1499,0.0,74.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1043','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_set('AMAZ-1015', 'in_transit');
select pg_temp.rto_new('FLIP-1030', 'AWB31000076', 'Customer refused delivery');
select pg_temp.cod_collect(array['SHOP-1028']::text[]);
select pg_temp.cod_collect(array['SHOP-1031']::text[]);
select pg_temp.settle_pay('FLK-STL-20260406', 0.0);
select pg_temp.retime();

-- Wed 22 Apr 2026
select pg_temp.day('2026-04-22');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1039','Shopify - Main Store','2026-04-22 10:02+05:30','Aditi Joshi','cod',1948.0,97.4,92.53,1943.13,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1040','Shopify - Main Store','2026-04-22 21:27+05:30','Karan Malhotra','prepaid',11597.0,579.85,1909.11,12926.26,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1039','BKUR-MUS-89Y',1,949,47.45,45.08),
('SHOP-1039','BTRK-BLK-1011Y',1,999,49.95,47.45),
('SHOP-1040','WPAL-YLW-M',1,599,29.95,28.45),
('SHOP-1040','WLHG-MAG-M',2,5499,549.9,1880.66)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1039','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1001');
select pg_temp.ret_new('SHOP-1020', 'Customer changed mind', 'webhook');
select pg_temp.cod_collect(array['SHOP-1034']::text[]);
select pg_temp.settle_pay('SHP-STL-20260413', 0.0);
select pg_temp.retime();

-- Thu 23 Apr 2026
select pg_temp.day('2026-04-23');
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R017)', 'DC-TKF-0052', '[{"sku":"MTEE-WHT-XL","q":6,"a":6,"r":0},{"sku":"MTRK-BLK-M","q":6,"a":6,"r":0},{"sku":"MTRK-BLK-L","q":10,"a":10,"r":0},{"sku":"WLEG-BLK-L","q":6,"a":6,"r":0},{"sku":"WTOP-WHT-L","q":6,"a":6,"r":0},{"sku":"WTOP-PCH-S","q":6,"a":6,"r":0},{"sku":"WTOP-PCH-L","q":10,"a":10,"r":0},{"sku":"BTEE-BLU-67Y","q":6,"a":6,"r":0},{"sku":"GTOP-WHT-89Y","q":6,"a":6,"r":0},{"sku":"GLEG-PNK-89Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R018)', 'DC-TKF-0055', '[{"sku":"MTRK-BLK-M","q":6,"a":6,"r":0},{"sku":"WTOP-WHT-M","q":30,"a":30,"r":0},{"sku":"WTOP-WHT-L","q":22,"a":22,"r":0},{"sku":"WTOP-PCH-L","q":6,"a":6,"r":0},{"sku":"BTEE-BLU-67Y","q":22,"a":22,"r":0},{"sku":"BTEE-RED-89Y","q":6,"a":6,"r":0},{"sku":"GLEG-BLK-45Y","q":6,"a":6,"r":0},{"sku":"GLEG-PNK-89Y","q":12,"a":11,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1031','Amazon - Seller Central','2026-04-23 11:05+05:30','Harsh Modi','prepaid',3896.0,194.8,185.06,3886.26,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1032','Amazon - Seller Central','2026-04-23 11:21+05:30','Mehul Shukla','prepaid',1349.0,0.0,67.45,1416.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1045','Flipkart - Seller Hub','2026-04-23 12:42+05:30','Harsh Modi','cod',599.0,0.0,29.95,628.95,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1041','Shopify - Main Store','2026-04-23 16:06+05:30','Sonal Parekh','prepaid',4397.0,439.7,197.87,4155.17,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1042','Shopify - Main Store','2026-04-23 14:30+05:30','Nidhi Agarwal','cod',2797.0,0.0,139.85,2936.85,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1043','Shopify - Main Store','2026-04-23 12:03+05:30','Bhavna Solanki','prepaid',2398.0,119.9,113.9,2392.0,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1031','MJNS-BLK-32',1,1399,69.95,66.45),
('AMAZ-1031','GFRK-LIL-89Y',2,749,74.9,71.16),
('AMAZ-1031','MSHF-SKY-XL',1,999,49.95,47.45),
('AMAZ-1032','WJNS-IND-32',1,1349,0.0,67.45),
('FLIP-1045','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1041','MCHN-KHK-34',2,1199,239.8,107.91),
('SHOP-1041','GLHG-RED-89Y',1,1999,199.9,89.96),
('SHOP-1042','MSHC-RED-L',2,899,0.0,89.9),
('SHOP-1042','MSHF-SKY-XL',1,999,0.0,49.95),
('SHOP-1043','MCHN-OLV-32',1,1199,59.95,56.95),
('SHOP-1043','MCHN-KHK-30',1,1199,59.95,56.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1045','Delhivery - Sachin GIDC Surat'),
('SHOP-1042','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1001', 'good', 'restocked');
select pg_temp.ret_recv('AMAZ-1004');
select pg_temp.ret_set('SHOP-1020', 'approved');
select pg_temp.rto_set('FLIP-1030', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1037']::text[]);
select pg_temp.retime();

-- Fri 24 Apr 2026
select pg_temp.day('2026-04-24');
select pg_temp.grn_new('Weekly replenishment 13 Apr 2026 - Ludhiana Winter Wear Co (ref R012)', 'DC-LWW-0046', '[{"sku":"MHOD-BLK-XL","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R017)', 'TKF/26/0130', 1);
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R018)', 'TKF/26/0139', 1);
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Little Stitch Garments (ref R020)', 'DC-LSG-0055', '[{"sku":"WDRS-FLP-S","q":6,"a":6,"r":0},{"sku":"WDRS-FLP-L","q":6,"a":6,"r":0},{"sku":"BKUR-MUS-45Y","q":6,"a":6,"r":0},{"sku":"GFRK-LIL-67Y","q":6,"a":6,"r":0},{"sku":"GLHG-TEL-45Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Rajdhani Shirting Mills (ref R023)', 'DC-RSM-0055', '[{"sku":"MSHF-SKY-M","q":5,"a":5,"r":0},{"sku":"BSHF-WHT-89Y","q":5,"a":5,"r":0},{"sku":"BSHF-WHT-1011Y","q":5,"a":5,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Shree Ambika Textiles (ref R024)', 'DC-SAT-0049', '[{"sku":"WPAL-WHT-M","q":6,"a":6,"r":0},{"sku":"WPAL-YLW-XL","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1044','Shopify - Main Store','2026-04-24 20:20+05:30','Isha Gupta','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1033','Amazon - Seller Central','2026-04-24 14:22+05:30','Anjali Verma','prepaid',699.0,34.95,33.2,697.25,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1034','Amazon - Seller Central','2026-04-24 10:54+05:30','Vipul Gandhi','prepaid',1598.0,0.0,79.9,1677.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1045','Shopify - Main Store','2026-04-24 09:22+05:30','Nikhil Pandey','cod',1407.0,0.0,70.35,1477.35,'delivered','pending','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1044','BTEE-RED-45Y',1,329,0.0,16.45),
('AMAZ-1033','MPOL-MRN-L',1,699,34.95,33.2),
('AMAZ-1034','BTRK-BLK-67Y',1,999,0.0,49.95),
('AMAZ-1034','BSHF-WHT-67Y',1,599,0.0,29.95),
('SHOP-1045','GLEG-PNK-89Y',2,279,0.0,27.9),
('SHOP-1045','WKRT-PNK-L',1,849,0.0,42.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1045','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1004', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1020', 'pickup');
select pg_temp.cod_collect(array['SHOP-1032']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-24APR', array['SHOP-1025']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-24APR', array['FLIP-1031','SHOP-1031']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-24APR', array['FLIP-1032','SHOP-1028']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-24APR', array['AMAZ-1018','FLIP-1027']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-24APR', array['SHOP-1021','FLIP-1025','SHOP-1023','SHOP-1034']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-04-27', 'ICIC000000880953', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-04-27', 'ICIC000000880972', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-04-27', 'ICIC000000881055', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-04-27', 'ICIC000000881079', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-04-27', 'ICIC000000881164', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-04-27', 'ICIC000000881224', 1);
select pg_temp.retime();

-- Sat 25 Apr 2026
select pg_temp.day('2026-04-25');
select pg_temp.bill_po('Weekly replenishment 13 Apr 2026 - Ludhiana Winter Wear Co (ref R012)', 'LWW/26/0115', 1);
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Krishna Denim Works (ref R019)', 'DC-KDW-0052', '[{"sku":"MJNS-BLK-32","q":9,"a":9,"r":0},{"sku":"WJNS-IND-28","q":5,"a":5,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Little Stitch Garments (ref R020)', 'LSG/26/0139', 1);
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Little Stitch Garments (ref R021)', 'DC-LSG-0058', '[{"sku":"BKUR-CRM-67Y","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Rajdhani Shirting Mills (ref R023)', 'RSM/26/0140', 1);
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Shree Ambika Textiles (ref R024)', 'SAT/26/0123', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1046','Shopify - Main Store','2026-04-25 11:43+05:30','Foram Thakkar','cod',2227.0,111.35,105.78,2221.43,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1047','Shopify - Main Store','2026-04-25 10:48+05:30','Divya Nair','cod',4204.0,420.4,189.19,3972.79,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1046','Flipkart - Seller Hub','2026-04-25 15:17+05:30','Manav Joshi','prepaid',2647.0,0.0,132.35,2779.35,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1035','Amazon - Seller Central','2026-04-25 18:37+05:30','Karan Malhotra','prepaid',2835.0,0.0,141.75,2976.75,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1036','Amazon - Seller Central','2026-04-25 18:03+05:30','Neha Patel','prepaid',928.0,46.4,44.08,925.68,'shipped','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1046','MCHN-OLV-34',1,1199,59.95,56.95),
('SHOP-1046','MPOL-MRN-XL',1,699,34.95,33.2),
('SHOP-1046','BTEE-BLU-67Y',1,329,16.45,15.63),
('SHOP-1047','GLEG-PNK-89Y',2,279,55.8,25.11),
('SHOP-1047','WJNS-IND-28',2,1349,269.8,121.41),
('SHOP-1047','WTOP-PCH-M',1,599,59.9,26.96),
('SHOP-1047','WLEG-MAR-L',1,349,34.9,15.71),
('FLIP-1046','WTOP-PCH-S',1,599,0.0,29.95),
('FLIP-1046','MJNS-BLK-32',1,1399,0.0,69.95),
('FLIP-1046','MTRK-BLK-M',1,649,0.0,32.45),
('AMAZ-1035','GFRK-LIL-89Y',2,749,0.0,74.9),
('AMAZ-1035','GLEG-BLK-45Y',2,279,0.0,27.9),
('AMAZ-1035','GJNS-IND-45Y',1,779,0.0,38.95),
('AMAZ-1036','BSHF-WHT-89Y',1,599,29.95,28.45),
('AMAZ-1036','BTEE-RED-89Y',1,329,16.45,15.63)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1046','Delhivery - Sachin GIDC Surat'),
('SHOP-1047','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.cod_collect(array['SHOP-1039']::text[]);
select pg_temp.retime();

-- Sun 26 Apr 2026
select pg_temp.day('2026-04-26');
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Krishna Denim Works (ref R019)', 'KDW/26/0128', 1);
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Little Stitch Garments (ref R021)', 'LSG/26/0145', 1);
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Rajdhani Shirting Mills (ref R022)', 'DC-RSM-0052', '[{"sku":"MSHC-GRN-L","q":10,"a":10,"r":0},{"sku":"MKUR-WHT-L","q":6,"a":5,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1048','Shopify - Main Store','2026-04-26 14:07+05:30','Kunal Desai','prepaid',349.0,34.9,15.71,329.81,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1037','Amazon - Seller Central','2026-04-26 22:27+05:30','Chirag Zaveri','prepaid',1448.0,144.8,65.17,1368.37,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1038','Amazon - Seller Central','2026-04-26 15:29+05:30','Dev Trivedi','prepaid',3997.0,0.0,199.85,4196.85,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1049','Shopify - Main Store','2026-04-26 12:33+05:30','Meghna Rao','cod',599.0,59.9,26.96,566.06,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1050','Shopify - Main Store','2026-04-26 21:54+05:30','Jigar Chauhan','prepaid',1607.0,0.0,80.35,1687.35,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1051','Shopify - Main Store','2026-04-26 11:16+05:30','Sejal Kapadia','prepaid',2248.0,112.4,106.78,2242.38,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1048','GTOP-YLW-89Y',1,349,34.9,15.71),
('AMAZ-1037','MTEE-WHT-XL',1,449,44.9,20.21),
('AMAZ-1037','MSHF-SKY-M',1,999,99.9,44.96),
('AMAZ-1038','MJNS-BLK-32',1,1399,0.0,69.95),
('AMAZ-1038','MCHN-OLV-34',1,1199,0.0,59.95),
('AMAZ-1038','MJNS-IND-34',1,1399,0.0,69.95),
('SHOP-1049','WTOP-WHT-L',1,599,59.9,26.96),
('SHOP-1050','BKUR-MUS-67Y',1,949,0.0,47.45),
('SHOP-1050','BTEE-RED-67Y',2,329,0.0,32.9),
('SHOP-1051','GFRK-LIL-45Y',1,749,37.45,35.58),
('SHOP-1051','WDRS-FLR-L',1,1499,74.95,71.2)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1049','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1020', 'in_transit');
select pg_temp.rto_recv('FLIP-1030', 'good', 'restocked');
select pg_temp.ret_new('FLIP-1034', 'Wrong item delivered', 'webhook');
select pg_temp.cod_collect(array['FLIP-1041']::text[]);
select pg_temp.cod_collect(array['FLIP-1043']::text[]);
select pg_temp.cod_collect(array['FLIP-1045']::text[]);
select pg_temp.cod_collect(array['SHOP-1042']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260413', 0.0);
select pg_temp.retime();

-- Mon 27 Apr 2026
select pg_temp.day('2026-04-27');
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Rajdhani Shirting Mills (ref R022)', 'RSM/26/0130', 1);
select pg_temp.po_new('Weekly replenishment 27 Apr 2026 - Krishna Denim Works (ref R027)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"WJNS-IND-28","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Apr 2026 - Little Stitch Garments (ref R028)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"GFRK-LIL-89Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Apr 2026 - Little Stitch Garments (ref R029)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLP-S","q":6},{"sku":"BKUR-MUS-67Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Apr 2026 - Rajdhani Shirting Mills (ref R030)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-RED-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Apr 2026 - Shree Ambika Textiles (ref R031)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WLHG-MAG-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R032)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"WTOP-PCH-M","q":8},{"sku":"BTEE-RED-67Y","q":6},{"sku":"BTEE-RED-89Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R033)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"WTOP-PCH-S","q":12},{"sku":"WTOP-PCH-M","q":6},{"sku":"BTEE-BLU-45Y","q":6},{"sku":"BTEE-RED-45Y","q":12}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1039','Amazon - Seller Central','2026-04-27 18:20+05:30','Mehul Shukla','prepaid',1647.0,0.0,82.35,1729.35,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1052','Shopify - Main Store','2026-04-27 13:46+05:30','Foram Thakkar','cod',599.0,59.9,26.96,566.06,'delivered','pending','Delhi','Surat Main Warehouse'),
('FLIP-1047','Flipkart - Seller Hub','2026-04-27 15:14+05:30','Aditi Joshi','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1053','Shopify - Main Store','2026-04-27 19:17+05:30','Amit Sethi','cod',949.0,0.0,47.45,996.45,'shipped','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1054','Shopify - Main Store','2026-04-27 13:05+05:30','Yash Vora','cod',949.0,0.0,47.45,996.45,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('SHOP-1055','Shopify - Main Store','2026-04-27 13:20+05:30','Isha Gupta','cod',7444.0,744.4,334.99,7034.59,'delivered','pending','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1039','WDUP-SLV-FREE',1,449,0.0,22.45),
('AMAZ-1039','WTOP-WHT-M',2,599,0.0,59.9),
('SHOP-1052','WTOP-WHT-M',1,599,59.9,26.96),
('FLIP-1047','MCHN-KHK-30',1,1199,0.0,59.95),
('SHOP-1053','BKUR-MUS-67Y',1,949,0.0,47.45),
('SHOP-1054','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1055','MJNS-IND-34',2,1399,279.8,125.91),
('SHOP-1055','MTRK-BLK-M',1,649,64.9,29.21),
('SHOP-1055','MJNS-IND-32',2,1399,279.8,125.91),
('SHOP-1055','MCHN-OLV-34',1,1199,119.9,53.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1052','DTDC - Ring Road Surat'),
('SHOP-1055','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1034', 'approved');
select pg_temp.ret_new('SHOP-1037', 'Customer changed mind', 'webhook');
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260420', '2026-04-20', '2026-04-26', array['AMAZ-1019','AMAZ-1021','AMAZ-1023','AMAZ-1026','AMAZ-1028','AMAZ-1022','AMAZ-1025','AMAZ-1024','AMAZ-1027','AMAZ-1029']::text[], array['AMAZ-1004']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260420', '2026-04-20', '2026-04-26', array['FLIP-1036','FLIP-1029','FLIP-1034','FLIP-1039','FLIP-1033','FLIP-1038','FLIP-1035','FLIP-1042','FLIP-1040']::text[], array['FLIP-1001']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260420', '2026-04-20', '2026-04-26', array['SHOP-1027','SHOP-1030','SHOP-1029','SHOP-1033','SHOP-1035','SHOP-1037','SHOP-1038','SHOP-1036']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 28 Apr 2026
select pg_temp.day('2026-04-28');
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Rajdhani Shirting Mills (ref R023)', 'DC-RSM-0058', '[{"sku":"MSHF-SKY-M","q":3,"a":3,"r":0},{"sku":"BSHF-WHT-89Y","q":3,"a":3,"r":0},{"sku":"BSHF-WHT-1011Y","q":3,"a":3,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1040','Amazon - Seller Central','2026-04-28 17:37+05:30','Chirag Zaveri','prepaid',899.0,0.0,44.95,943.95,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1056','Shopify - Main Store','2026-04-28 16:54+05:30','Chirag Zaveri','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1040','MSHC-GRN-M',1,899,0.0,44.95),
('SHOP-1056','WLEG-MAR-L',1,349,0.0,17.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('SHOP-1020');
select pg_temp.ret_set('FLIP-1034', 'pickup');
select pg_temp.ret_set('SHOP-1037', 'approved');
select pg_temp.cod_collect(array['SHOP-1046']::text[]);
select pg_temp.settle_pay('FLK-STL-20260413', 0.0);
select pg_temp.retime();

-- Wed 29 Apr 2026
select pg_temp.day('2026-04-29');
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Krishna Denim Works (ref R019)', 'DC-KDW-0055', '[{"sku":"MJNS-BLK-32","q":5,"a":5,"r":0},{"sku":"WJNS-IND-28","q":3,"a":3,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Rajdhani Shirting Mills (ref R023)', 'RSM/26/0143', 1);
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R025)', 'DC-TKF-0058', '[{"sku":"MTEE-WHT-XL","q":6,"a":6,"r":0},{"sku":"WTOP-WHT-L","q":8,"a":8,"r":0},{"sku":"WTOP-PCH-S","q":10,"a":10,"r":0},{"sku":"WTOP-PCH-M","q":6,"a":6,"r":0},{"sku":"BTEE-BLU-89Y","q":6,"a":6,"r":0},{"sku":"BTEE-RED-89Y","q":6,"a":6,"r":0},{"sku":"GLEG-BLK-45Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1048','Flipkart - Seller Hub','2026-04-29 18:27+05:30','Sanjay Gajera','prepaid',1198.0,59.9,56.91,1195.01,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1041','Amazon - Seller Central','2026-04-29 13:59+05:30','Aditi Joshi','prepaid',1198.0,59.9,56.91,1195.01,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1042','Amazon - Seller Central','2026-04-29 19:39+05:30','Vivek Singh','prepaid',3197.0,159.85,151.86,3189.01,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1049','Flipkart - Seller Hub','2026-04-29 09:26+05:30','Karan Malhotra','prepaid',1548.0,154.8,69.67,1462.87,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1043','Amazon - Seller Central','2026-04-29 15:30+05:30','Nikhil Pandey','prepaid',4896.0,489.6,220.33,4626.73,'shipped','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1048','BSHF-WHT-1011Y',2,599,59.9,56.91),
('AMAZ-1041','WTOP-PCH-M',2,599,59.9,56.91),
('AMAZ-1042','MSHC-RED-XL',2,899,89.9,85.41),
('AMAZ-1042','MJNS-BLK-32',1,1399,69.95,66.45),
('FLIP-1049','BSHF-WHT-1011Y',1,599,59.9,26.96),
('FLIP-1049','BKUR-MUS-67Y',1,949,94.9,42.71),
('AMAZ-1043','MJNS-BLK-32',2,1399,279.8,125.91),
('AMAZ-1043','MSHC-RED-XL',1,899,89.9,40.46),
('AMAZ-1043','MCHN-OLV-32',1,1199,119.9,53.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('SHOP-1020', 'good', 'restocked');
select pg_temp.ret_new('FLIP-1035', 'Fabric quality not as expected', 'webhook');
select pg_temp.ret_set('SHOP-1037', 'pickup');
select pg_temp.cod_collect(array['SHOP-1045']::text[]);
select pg_temp.rto_new('AMAZ-1036', 'AWB31000081', 'Address incomplete');
select pg_temp.settle_pay('SHP-STL-20260420', 0.0);
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
