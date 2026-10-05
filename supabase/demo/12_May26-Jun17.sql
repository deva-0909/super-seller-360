-- 26 May to 17 Jun 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Tue 26 May 2026
select pg_temp.day('2026-05-26');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1109','Amazon - Seller Central','2026-05-26 12:34+05:30','Neha Patel','prepaid',1178.0,117.8,53.02,1113.22,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1110','Amazon - Seller Central','2026-05-26 22:20+05:30','Tanvi Rana','prepaid',2198.0,219.8,98.92,2077.12,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1090','Flipkart - Seller Hub','2026-05-26 21:13+05:30','Sagar Rathod','prepaid',549.0,0.0,27.45,576.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1091','Flipkart - Seller Hub','2026-05-26 20:56+05:30','Aditi Joshi','prepaid',1198.0,59.9,56.91,1195.01,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1105','Shopify - Main Store','2026-05-26 21:51+05:30','Pratik Lad','prepaid',3795.0,0.0,189.75,3984.75,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1111','Amazon - Seller Central','2026-05-26 21:09+05:30','Nikhil Pandey','prepaid',599.0,59.9,26.96,566.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1106','Shopify - Main Store','2026-05-26 13:22+05:30','Rohit Iyer','prepaid',2397.0,0.0,119.85,2516.85,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1092','Flipkart - Seller Hub','2026-05-26 18:13+05:30','Aarav Mehta','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1109','MSHC-RED-L',1,899,89.9,40.46),
('AMAZ-1109','GLEG-BLK-67Y',1,279,27.9,12.56),
('AMAZ-1110','WJNS-IND-30',1,1349,134.9,60.71),
('AMAZ-1110','WKRT-PNK-S',1,849,84.9,38.21),
('FLIP-1090','GNGT-PNK-89Y',1,549,0.0,27.45),
('FLIP-1091','WTOP-PCH-S',2,599,59.9,56.91),
('SHOP-1105','WLEG-NVY-L',3,349,0.0,52.35),
('SHOP-1105','GNGT-PNK-89Y',1,549,0.0,27.45),
('SHOP-1105','WSAR-GRN-FREE',1,2199,0.0,109.95),
('AMAZ-1111','WTOP-PCH-L',1,599,59.9,26.96),
('SHOP-1106','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1106','WJNS-BLK-32',1,1349,0.0,67.45),
('SHOP-1106','WDUP-SLV-FREE',1,449,0.0,22.45),
('FLIP-1092','WTOP-PCH-S',1,599,29.95,28.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('AMAZ-1076');
select pg_temp.ret_set('FLIP-1066', 'pickup');
select pg_temp.ret_new('AMAZ-1086', 'Wrong item delivered', 'webhook');
select pg_temp.cod_collect(array['FLIP-1079']::text[]);
select pg_temp.cod_collect(array['SHOP-1092']::text[]);
select pg_temp.rto_new('SHOP-1095', 'AWB31000315', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['FLIP-1082']::text[]);
select pg_temp.settle_pay('FLK-STL-20260511', 0.0);
select pg_temp.retime();

-- Wed 27 May 2026
select pg_temp.day('2026-05-27');
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R050)', 'DC-TKF-0088', '[{"sku":"WLEG-BLK-L","q":5,"a":5,"r":0},{"sku":"WLEG-MAR-M","q":4,"a":4,"r":0},{"sku":"WTOP-PCH-L","q":8,"a":7,"r":1},{"sku":"BTEE-BLU-89Y","q":5,"a":5,"r":0},{"sku":"GLEG-BLK-67Y","q":5,"a":5,"r":0},{"sku":"GLEG-PNK-45Y","q":5,"a":5,"r":0},{"sku":"GLEG-PNK-67Y","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1107','Shopify - Main Store','2026-05-27 12:56+05:30','Riya Shah','cod',1199.0,0.0,59.95,1258.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1112','Amazon - Seller Central','2026-05-27 12:46+05:30','Aarav Mehta','prepaid',2697.0,0.0,134.85,2831.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1108','Shopify - Main Store','2026-05-27 09:27+05:30','Rahul Bhatt','prepaid',2048.0,102.4,97.28,2042.88,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('FLIP-1093','Flipkart - Seller Hub','2026-05-27 17:24+05:30','Aditi Joshi','prepaid',2396.0,0.0,119.8,2515.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1109','Shopify - Main Store','2026-05-27 11:17+05:30','Harsh Modi','cod',1798.0,0.0,89.9,1887.9,'delivered','pending','West Bengal','Surat Main Warehouse'),
('AMAZ-1113','Amazon - Seller Central','2026-05-27 16:53+05:30','Vivek Singh','prepaid',837.0,83.7,37.67,790.97,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1107','MCHN-OLV-32',1,1199,0.0,59.95),
('AMAZ-1112','MTRK-BLK-L',2,649,0.0,64.9),
('AMAZ-1112','MJNS-BLK-30',1,1399,0.0,69.95),
('SHOP-1108','WDRS-FLR-L',1,1499,74.95,71.2),
('SHOP-1108','GNGT-PNK-67Y',1,549,27.45,26.08),
('FLIP-1093','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1093','WPAL-YLW-XL',1,599,0.0,29.95),
('FLIP-1093','WTOP-PCH-S',2,599,0.0,59.9),
('SHOP-1109','MCHN-OLV-32',1,1199,0.0,59.95),
('SHOP-1109','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1113','GLEG-BLK-45Y',1,279,27.9,12.56),
('AMAZ-1113','GLEG-PNK-89Y',2,279,55.8,25.11)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1107','DTDC - Ring Road Surat'),
('SHOP-1109','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1086', 'approved');
select pg_temp.rto_recv('AMAZ-1088', 'good', 'restocked');
select pg_temp.settle_pay('SHP-STL-20260518', 0.0);
select pg_temp.claim_step('AMAZ-1015', 'lost_shipment', 'approved', null);
select pg_temp.retime();

-- Thu 28 May 2026
select pg_temp.day('2026-05-28');
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Rajdhani Shirting Mills (ref R047)', 'DC-RSM-0082', '[{"sku":"MSHC-GRN-L","q":2,"a":2,"r":0},{"sku":"MBLZ-NVY-40","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R049)', 'DC-TKF-0085', '[{"sku":"MPOL-NVY-M","q":6,"a":6,"r":0},{"sku":"MPOL-MRN-XL","q":6,"a":6,"r":0},{"sku":"WLEG-MAR-L","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-67Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R050)', 'TKF/26/0213', 1);
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Little Stitch Garments (ref R053)', 'DC-LSG-0076', '[{"sku":"WDRS-FLP-L","q":6,"a":6,"r":0},{"sku":"BKUR-CRM-89Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Shree Ambika Textiles (ref R056)', 'DC-SAT-0064', '[{"sku":"WPAL-WHT-XL","q":6,"a":6,"r":0},{"sku":"WSAR-BLU-FREE","q":6,"a":5,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1114','Amazon - Seller Central','2026-05-28 22:54+05:30','Divya Nair','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1115','Amazon - Seller Central','2026-05-28 16:42+05:30','Tanvi Rana','prepaid',699.0,69.9,31.46,660.56,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1116','Amazon - Seller Central','2026-05-28 12:12+05:30','Heena Khan','prepaid',3327.0,332.7,149.72,3144.02,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1114','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1115','MPOL-NVY-XL',1,699,69.9,31.46),
('AMAZ-1116','BTEE-RED-45Y',1,329,32.9,14.81),
('AMAZ-1116','WDRS-FLP-S',2,1499,299.8,134.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1076', 'wrong_item', 'claimed');
select pg_temp.ret_set('FLIP-1066', 'in_transit');
select pg_temp.ret_set('AMAZ-1086', 'pickup');
select pg_temp.rto_set('SHOP-1095', 'in_transit');
select pg_temp.rto_new('SHOP-1096', 'AWB31000331', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['FLIP-1083']::text[]);
select pg_temp.claim_new('AMAZ-1043', 'lost_shipment', 4626.73, '2026-06-27');
select pg_temp.claim_new('AMAZ-1076', 'other', 681.45, '2026-06-27');
select pg_temp.retime();

-- Fri 29 May 2026
select pg_temp.day('2026-05-29');
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Rajdhani Shirting Mills (ref R047)', 'RSM/26/0204', 1);
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R049)', 'TKF/26/0205', 1);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Little Stitch Garments (ref R053)', 'LSG/26/0187', 1);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Shree Ambika Textiles (ref R056)', 'SAT/26/0157', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1117','Amazon - Seller Central','2026-05-29 10:09+05:30','Kavya Menon','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1110','Shopify - Main Store','2026-05-29 16:41+05:30','Aditi Joshi','cod',1499.0,149.9,67.46,1416.56,'cancelled','failed','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1094','Flipkart - Seller Hub','2026-05-29 20:35+05:30','Anjali Verma','prepaid',1349.0,134.9,60.71,1274.81,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1118','Amazon - Seller Central','2026-05-29 19:07+05:30','Riya Shah','prepaid',1278.0,0.0,63.9,1341.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1117','BKUR-MUS-89Y',1,949,0.0,47.45),
('SHOP-1110','WDRS-FLR-L',1,1499,149.9,67.46),
('FLIP-1094','WJNS-IND-32',1,1349,134.9,60.71),
('AMAZ-1118','BKUR-MUS-45Y',1,949,0.0,47.45),
('AMAZ-1118','BTEE-RED-67Y',1,329,0.0,16.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.cod_collect(array['SHOP-1097']::text[]);
select pg_temp.cod_collect(array['SHOP-1099']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-29MAY', array['SHOP-1088','SHOP-1092','FLIP-1082']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-29MAY', array['AMAZ-1097']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-29MAY', array['SHOP-1084']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-29MAY', array['FLIP-1076','AMAZ-1096','FLIP-1079']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-06-01', 'ICIC000000882613', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-06-01', 'ICIC000000882688', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-06-01', 'ICIC000000882727', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-06-01', 'ICIC000000882824', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-06-01', 'ICIC000000882856', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-06-01', 'ICIC000000882899', 1);
select pg_temp.claim_step('AMAZ-1045', 'damaged_return', 'approved', null);
select pg_temp.retime();

-- Sat 30 May 2026
select pg_temp.day('2026-05-30');
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Krishna Denim Works (ref R052)', 'DC-KDW-0076', '[{"sku":"MJNS-BLK-32","q":12,"a":12,"r":0},{"sku":"MCHN-OLV-32","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Shree Ambika Textiles (ref R057)', 'DC-SAT-0067', '[{"sku":"WPAL-WHT-M","q":5,"a":5,"r":0},{"sku":"WPAL-YLW-XL","q":4,"a":4,"r":0},{"sku":"WSAR-BLU-FREE","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1111','Shopify - Main Store','2026-05-30 19:43+05:30','Vivek Singh','prepaid',1586.0,79.3,75.34,1582.04,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1112','Shopify - Main Store','2026-05-30 15:32+05:30','Ritu Saxena','prepaid',5897.0,589.7,709.86,6017.16,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1113','Shopify - Main Store','2026-05-30 17:55+05:30','Dev Trivedi','cod',1256.0,0.0,62.8,1318.8,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1095','Flipkart - Seller Hub','2026-05-30 15:53+05:30','Pooja Jain','prepaid',1499.0,0.0,74.95,1573.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1114','Shopify - Main Store','2026-05-30 09:52+05:30','Vipul Gandhi','prepaid',3297.0,0.0,164.85,3461.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1119','Amazon - Seller Central','2026-05-30 15:40+05:30','Foram Thakkar','prepaid',2246.0,112.3,106.69,2240.39,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1111','GFRK-LIL-89Y',1,749,37.45,35.58),
('SHOP-1111','GLEG-BLK-89Y',1,279,13.95,13.25),
('SHOP-1111','GLEG-PNK-89Y',2,279,27.9,26.51),
('SHOP-1112','MSHC-RED-XL',1,899,89.9,40.46),
('SHOP-1112','MCHN-OLV-30',1,1199,119.9,53.96),
('SHOP-1112','MBLZ-NVY-40',1,3799,379.9,615.44),
('SHOP-1113','GTOP-WHT-45Y',2,349,0.0,34.9),
('SHOP-1113','GLEG-BLK-89Y',2,279,0.0,27.9),
('FLIP-1095','WDRS-FLR-L',1,1499,0.0,74.95),
('SHOP-1114','WPAL-YLW-XL',1,599,0.0,29.95),
('SHOP-1114','WJNS-IND-32',2,1349,0.0,134.9),
('AMAZ-1119','MPOL-NVY-M',1,699,34.95,33.2),
('AMAZ-1119','WLEG-BLK-M',1,349,17.45,16.58),
('AMAZ-1119','WTOP-PCH-M',2,599,59.9,56.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1113','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1086', 'in_transit');
select pg_temp.rto_set('SHOP-1096', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1087']::text[]);
select pg_temp.cod_collect(array['FLIP-1088']::text[]);
select pg_temp.cod_collect(array['SHOP-1109']::text[]);
select pg_temp.retime();

-- Sun 31 May 2026
select pg_temp.day('2026-05-31');
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R050)', 'DC-TKF-0091', '[{"sku":"WLEG-BLK-L","q":3,"a":3,"r":0},{"sku":"WLEG-MAR-M","q":2,"a":2,"r":0},{"sku":"WTOP-PCH-L","q":4,"a":4,"r":0},{"sku":"BTEE-BLU-89Y","q":3,"a":3,"r":0},{"sku":"GLEG-BLK-67Y","q":3,"a":3,"r":0},{"sku":"GLEG-PNK-45Y","q":3,"a":3,"r":0},{"sku":"GLEG-PNK-67Y","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Krishna Denim Works (ref R051)', 'DC-KDW-0073', '[{"sku":"MCHN-KHK-30","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Krishna Denim Works (ref R052)', 'KDW/26/0188', 1);
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Rajdhani Shirting Mills (ref R054)', 'DC-RSM-0085', '[{"sku":"BSHF-WHT-89Y","q":5,"a":5,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Rajdhani Shirting Mills (ref R055)', 'DC-RSM-0091', '[{"sku":"MSHC-RED-M","q":6,"a":5,"r":1},{"sku":"MBLZ-NVY-40","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Shree Ambika Textiles (ref R057)', 'SAT/26/0167', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1120','Amazon - Seller Central','2026-05-31 10:32+05:30','Sagar Rathod','prepaid',878.0,0.0,43.9,921.9,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1115','Shopify - Main Store','2026-05-31 21:19+05:30','Neha Patel','cod',599.0,0.0,29.95,628.95,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1096','Flipkart - Seller Hub','2026-05-31 22:05+05:30','Sejal Kapadia','prepaid',4096.0,0.0,204.8,4300.8,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1121','Amazon - Seller Central','2026-05-31 14:29+05:30','Tanvi Rana','cod',3497.0,349.7,157.38,3304.68,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1116','Shopify - Main Store','2026-05-31 14:44+05:30','Divya Nair','prepaid',5545.0,0.0,277.25,5822.25,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1122','Amazon - Seller Central','2026-05-31 10:39+05:30','Tanvi Rana','prepaid',4196.0,0.0,209.8,4405.8,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1123','Amazon - Seller Central','2026-05-31 16:46+05:30','Sonal Parekh','prepaid',6395.0,639.5,287.78,6043.28,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1117','Shopify - Main Store','2026-05-31 14:41+05:30','Mitul Dave','prepaid',837.0,41.85,39.76,834.91,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1124','Amazon - Seller Central','2026-05-31 21:55+05:30','Sanjay Gajera','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1125','Amazon - Seller Central','2026-05-31 09:11+05:30','Nidhi Agarwal','prepaid',11946.0,0.0,2027.04,13973.04,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1120','BTEE-BLU-89Y',1,329,0.0,16.45),
('AMAZ-1120','GNGT-PNK-1011Y',1,549,0.0,27.45),
('SHOP-1115','WPAL-YLW-L',1,599,0.0,29.95),
('FLIP-1096','MSHC-GRN-L',3,899,0.0,134.85),
('FLIP-1096','MJNS-BLK-32',1,1399,0.0,69.95),
('AMAZ-1121','MCHN-OLV-34',1,1199,119.9,53.96),
('AMAZ-1121','MJNS-BLK-32',1,1399,139.9,62.96),
('AMAZ-1121','MSHC-GRN-M',1,899,89.9,40.46),
('SHOP-1116','WDRS-FLP-M',2,1499,0.0,149.9),
('SHOP-1116','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1116','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1116','WJNS-IND-28',1,1349,0.0,67.45),
('AMAZ-1122','MJNS-IND-34',2,1399,0.0,139.9),
('AMAZ-1122','MPOL-MRN-M',2,699,0.0,69.9),
('AMAZ-1123','MCHN-KHK-34',3,1199,359.7,161.87),
('AMAZ-1123','MJNS-BLK-30',2,1399,279.8,125.91),
('SHOP-1117','GLEG-PNK-67Y',3,279,41.85,39.76),
('AMAZ-1124','BSHF-WHT-45Y',1,599,29.95,28.45),
('AMAZ-1125','WLEG-BLK-M',1,349,0.0,17.45),
('AMAZ-1125','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1125','WLHG-RED-M',2,5499,0.0,1979.64)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1115','Xpressbees - Pandesara'),
('AMAZ-1121','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_new('FLIP-1080', 'Fabric quality not as expected', 'webhook');
select pg_temp.ret_new('FLIP-1092', 'Customer changed mind', 'webhook');
select pg_temp.settle_pay('AMZ-STL-20260518', 0.0);
select pg_temp.claim_step('AMAZ-1043', 'lost_shipment', 'claimed', null);
select pg_temp.claim_step('AMAZ-1076', 'other', 'claimed', null);
select pg_temp.retime();

-- Mon 01 Jun 2026
select pg_temp.day('2026-06-01');
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R050)', 'TKF/26/0222', 1);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Krishna Denim Works (ref R051)', 'KDW/26/0182', 1);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Rajdhani Shirting Mills (ref R054)', 'RSM/26/0209', 1);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Rajdhani Shirting Mills (ref R055)', 'RSM/26/0222', 1);
select pg_temp.po_new('Weekly replenishment 01 Jun 2026 - Krishna Denim Works (ref R060)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-30","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 01 Jun 2026 - Little Stitch Garments (ref R061)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"BKUR-MUS-67Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 01 Jun 2026 - Little Stitch Garments (ref R062)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLP-M","q":12},{"sku":"BKUR-MUS-89Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 01 Jun 2026 - Rajdhani Shirting Mills (ref R063)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHC-RED-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 01 Jun 2026 - Rajdhani Shirting Mills (ref R064)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-GRN-L","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 01 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R065)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"WLEG-BLK-M","q":8},{"sku":"WTOP-PCH-M","q":8},{"sku":"GTOP-WHT-45Y","q":6},{"sku":"GLEG-BLK-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 01 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R066)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"WLEG-BLK-M","q":10},{"sku":"WLEG-NVY-L","q":8},{"sku":"GLEG-PNK-67Y","q":10}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1118','Shopify - Main Store','2026-06-01 16:57+05:30','Jigar Chauhan','cod',3596.0,179.8,170.81,3587.01,'shipped','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1126','Amazon - Seller Central','2026-06-01 16:16+05:30','Anjali Verma','prepaid',999.0,99.9,44.96,944.06,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1097','Flipkart - Seller Hub','2026-06-01 20:53+05:30','Divya Nair','prepaid',349.0,17.45,16.58,348.13,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1098','Flipkart - Seller Hub','2026-06-01 19:04+05:30','Prachi Kulkarni','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1119','Shopify - Main Store','2026-06-01 10:16+05:30','Sanjay Gajera','cod',949.0,47.45,45.08,946.63,'delivered','pending','Delhi','Surat Main Warehouse'),
('FLIP-1099','Flipkart - Seller Hub','2026-06-01 16:26+05:30','Neha Patel','prepaid',1898.0,0.0,94.9,1992.9,'shipped','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1118','MSHC-GRN-L',3,899,134.85,128.11),
('SHOP-1118','MSHC-GRN-XL',1,899,44.95,42.7),
('AMAZ-1126','BTRK-BLK-89Y',1,999,99.9,44.96),
('FLIP-1097','GTOP-YLW-67Y',1,349,17.45,16.58),
('FLIP-1098','BKUR-MUS-45Y',1,949,0.0,47.45),
('SHOP-1119','BKUR-MUS-89Y',1,949,47.45,45.08),
('FLIP-1099','BKUR-MUS-45Y',2,949,0.0,94.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1119','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1066');
select pg_temp.ret_recv('AMAZ-1086');
select pg_temp.ret_set('FLIP-1080', 'approved');
select pg_temp.rto_recv('SHOP-1095', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1092', 'approved');
select pg_temp.cod_collect(array['SHOP-1107']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260525', '2026-05-25', '2026-05-31', array['AMAZ-1099','AMAZ-1101','AMAZ-1100','AMAZ-1104','AMAZ-1102','AMAZ-1103','AMAZ-1105','AMAZ-1107','AMAZ-1110','AMAZ-1106','AMAZ-1108','AMAZ-1113','AMAZ-1109','AMAZ-1114','AMAZ-1116']::text[], array['AMAZ-1076']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260525', '2026-05-25', '2026-05-31', array['FLIP-1080','FLIP-1085','FLIP-1081','FLIP-1084','FLIP-1086','FLIP-1089','FLIP-1092','FLIP-1090']::text[], array[]::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260525', '2026-05-25', '2026-05-31', array['SHOP-1087','SHOP-1093','SHOP-1094','SHOP-1102','SHOP-1098','SHOP-1100','SHOP-1101','SHOP-1105','SHOP-1106','SHOP-1103','SHOP-1104']::text[], array[]::text[]);
select pg_temp.claim_step('FLIP-1048', 'damaged_return', 'approved', null);
select pg_temp.retime();

-- Tue 02 Jun 2026
select pg_temp.day('2026-06-02');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1127','Amazon - Seller Central','2026-06-02 11:00+05:30','Pratik Lad','prepaid',4448.0,0.0,716.27,5164.27,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1128','Amazon - Seller Central','2026-06-02 21:33+05:30','Nidhi Agarwal','prepaid',1278.0,63.9,60.71,1274.81,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1120','Shopify - Main Store','2026-06-02 20:45+05:30','Amit Sethi','prepaid',2897.0,289.7,130.38,2737.68,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1129','Amazon - Seller Central','2026-06-02 12:50+05:30','Divya Nair','prepaid',658.0,0.0,32.9,690.9,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1100','Flipkart - Seller Hub','2026-06-02 12:53+05:30','Yash Vora','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1101','Flipkart - Seller Hub','2026-06-02 18:23+05:30','Kiran Naik','prepaid',1898.0,189.8,85.42,1793.62,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1102','Flipkart - Seller Hub','2026-06-02 12:12+05:30','Rahul Bhatt','cod',3395.0,0.0,169.75,3564.75,'delivered','pending','Delhi','Surat Main Warehouse'),
('FLIP-1103','Flipkart - Seller Hub','2026-06-02 17:16+05:30','Mitul Dave','prepaid',849.0,42.45,40.33,846.88,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1127','MBLZ-NVY-40',1,3799,0.0,683.82),
('AMAZ-1127','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1128','BTEE-RED-45Y',1,329,16.45,15.63),
('AMAZ-1128','BKUR-CRM-45Y',1,949,47.45,45.08),
('SHOP-1120','BKUR-CRM-45Y',1,949,94.9,42.71),
('SHOP-1120','BTRK-BLK-1011Y',1,999,99.9,44.96),
('SHOP-1120','BKUR-MUS-45Y',1,949,94.9,42.71),
('AMAZ-1129','BTEE-BLU-45Y',2,329,0.0,32.9),
('FLIP-1100','WTOP-PCH-L',1,599,29.95,28.45),
('FLIP-1101','BKUR-MUS-67Y',1,949,94.9,42.71),
('FLIP-1101','BKUR-CRM-89Y',1,949,94.9,42.71),
('FLIP-1102','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1102','WDRS-FLR-S',1,1499,0.0,74.95),
('FLIP-1102','WLEG-MAR-M',2,349,0.0,34.9),
('FLIP-1103','WKRT-PNK-XL',1,849,42.45,40.33)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1102','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1066', 'damaged', 'quarantined');
select pg_temp.ret_dispo('AMAZ-1086', 'wrong_item', 'claimed');
select pg_temp.ret_set('FLIP-1080', 'pickup');
select pg_temp.ret_new('AMAZ-1104', 'Item arrived damaged', 'webhook');
select pg_temp.ret_new('FLIP-1089', 'Wrong item delivered', 'webhook');
select pg_temp.ret_set('FLIP-1092', 'pickup');
select pg_temp.cod_collect(array['SHOP-1113']::text[]);
select pg_temp.settle_pay('FLK-STL-20260518', 0.0);
select pg_temp.claim_new('FLIP-1066', 'damaged_return', 1447.11, '2026-07-02');
select pg_temp.claim_new('AMAZ-1086', 'other', 9073.97, '2026-07-02');
select pg_temp.retime();

-- Wed 03 Jun 2026
select pg_temp.day('2026-06-03');
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Shree Ambika Textiles (ref R057)', 'DC-SAT-0070', '[{"sku":"WPAL-WHT-M","q":3,"a":3,"r":0},{"sku":"WPAL-YLW-XL","q":2,"a":2,"r":0},{"sku":"WSAR-BLU-FREE","q":2,"a":2,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1130','Amazon - Seller Central','2026-06-03 21:18+05:30','Vipul Gandhi','prepaid',4696.0,234.8,223.06,4684.26,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1131','Amazon - Seller Central','2026-06-03 09:29+05:30','Kiran Naik','prepaid',949.0,94.9,42.71,896.81,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1121','Shopify - Main Store','2026-06-03 21:52+05:30','Bhavna Solanki','prepaid',1107.0,0.0,55.35,1162.35,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1132','Amazon - Seller Central','2026-06-03 22:19+05:30','Divya Nair','prepaid',1897.0,189.7,85.38,1792.68,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1133','Amazon - Seller Central','2026-06-03 14:01+05:30','Sagar Rathod','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1122','Shopify - Main Store','2026-06-03 12:53+05:30','Amit Sethi','cod',1598.0,0.0,79.9,1677.9,'delivered','pending','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1130','MPOL-MRN-L',1,699,34.95,33.2),
('AMAZ-1130','MCHN-OLV-32',1,1199,59.95,56.95),
('AMAZ-1130','MJNS-IND-34',2,1399,139.9,132.91),
('AMAZ-1131','BKUR-MUS-67Y',1,949,94.9,42.71),
('SHOP-1121','GLEG-PNK-89Y',1,279,0.0,13.95),
('SHOP-1121','GLEG-PNK-67Y',1,279,0.0,13.95),
('SHOP-1121','GNGT-PNK-1011Y',1,549,0.0,27.45),
('AMAZ-1132','MTRK-BLK-M',1,649,64.9,29.21),
('AMAZ-1132','MSHC-RED-M',1,899,89.9,40.46),
('AMAZ-1132','WLEG-NVY-M',1,349,34.9,15.71),
('AMAZ-1133','MJNS-IND-34',1,1399,0.0,69.95),
('SHOP-1122','MSHC-RED-M',1,899,0.0,44.95),
('SHOP-1122','MPOL-NVY-XL',1,699,0.0,34.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1122','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_recv('SHOP-1096', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1104', 'approved');
select pg_temp.ret_set('FLIP-1089', 'approved');
select pg_temp.settle_pay('SHP-STL-20260525', 0.0);
select pg_temp.retime();

-- Thu 04 Jun 2026
select pg_temp.day('2026-06-04');
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Rajdhani Shirting Mills (ref R054)', 'DC-RSM-0088', '[{"sku":"BSHF-WHT-89Y","q":3,"a":3,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Shree Ambika Textiles (ref R057)', 'SAT/26/0175', 1);
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R058)', 'DC-TKF-0094', '[{"sku":"MPOL-NVY-M","q":6,"a":5,"r":1},{"sku":"MPOL-MRN-XL","q":6,"a":5,"r":1},{"sku":"WLEG-BLK-M","q":8,"a":8,"r":0},{"sku":"WTOP-PCH-M","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-67Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 25 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R059)', 'DC-TKF-0097', '[{"sku":"WLEG-BLK-M","q":6,"a":6,"r":0},{"sku":"WLEG-BLK-L","q":8,"a":8,"r":0},{"sku":"GLEG-BLK-67Y","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-45Y","q":8,"a":7,"r":1},{"sku":"GLEG-PNK-67Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 01 Jun 2026 - Little Stitch Garments (ref R061)', 'DC-LSG-0079', '[{"sku":"BKUR-MUS-67Y","q":6,"a":5,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1134','Amazon - Seller Central','2026-06-04 21:34+05:30','Mitul Dave','prepaid',1547.0,0.0,77.35,1624.35,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1135','Amazon - Seller Central','2026-06-04 19:24+05:30','Aditi Joshi','prepaid',628.0,0.0,31.4,659.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1123','Shopify - Main Store','2026-06-04 09:02+05:30','Divya Nair','cod',1199.0,0.0,59.95,1258.95,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1104','Flipkart - Seller Hub','2026-06-04 14:46+05:30','Dev Trivedi','prepaid',558.0,0.0,27.9,585.9,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1136','Amazon - Seller Central','2026-06-04 12:29+05:30','Mitul Dave','prepaid',449.0,44.9,20.21,424.31,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1134','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1134','WLEG-NVY-M',1,349,0.0,17.45),
('AMAZ-1134','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1135','GLEG-PNK-67Y',1,279,0.0,13.95),
('AMAZ-1135','GTOP-WHT-89Y',1,349,0.0,17.45),
('SHOP-1123','MCHN-OLV-34',1,1199,0.0,59.95),
('FLIP-1104','GLEG-BLK-89Y',2,279,0.0,27.9),
('AMAZ-1136','WDUP-GLD-FREE',1,449,44.9,20.21)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1123','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1080', 'in_transit');
select pg_temp.ret_set('AMAZ-1104', 'pickup');
select pg_temp.ret_set('FLIP-1089', 'pickup');
select pg_temp.ret_new('FLIP-1091', 'Customer changed mind', 'webhook');
select pg_temp.ret_set('FLIP-1092', 'in_transit');
select pg_temp.ret_new('AMAZ-1116', 'Item arrived damaged', 'webhook');
select pg_temp.cod_collect(array['SHOP-1115']::text[]);
select pg_temp.claim_step('AMAZ-1042', 'damaged_return', 'approved', null);
select pg_temp.retime();

-- Fri 05 Jun 2026
select pg_temp.day('2026-06-05');
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Rajdhani Shirting Mills (ref R054)', 'RSM/26/0218', 1);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R058)', 'TKF/26/0227', 1);
select pg_temp.bill_po('Weekly replenishment 25 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R059)', 'TKF/26/0237', 1);
select pg_temp.bill_po('Weekly replenishment 01 Jun 2026 - Little Stitch Garments (ref R061)', 'LSG/26/0196', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1137','Amazon - Seller Central','2026-06-05 19:49+05:30','Sanjay Gajera','prepaid',1848.0,0.0,92.4,1940.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1138','Amazon - Seller Central','2026-06-05 09:12+05:30','Prachi Kulkarni','prepaid',2446.0,122.3,116.19,2439.89,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1139','Amazon - Seller Central','2026-06-05 15:31+05:30','Chirag Zaveri','cod',1347.0,0.0,67.35,1414.35,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1140','Amazon - Seller Central','2026-06-05 18:28+05:30','Sonal Parekh','prepaid',1948.0,0.0,97.4,2045.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1124','Shopify - Main Store','2026-06-05 11:04+05:30','Anjali Verma','prepaid',1278.0,0.0,63.9,1341.9,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1141','Amazon - Seller Central','2026-06-05 13:25+05:30','Aarav Mehta','prepaid',2497.0,0.0,124.85,2621.85,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1142','Amazon - Seller Central','2026-06-05 16:25+05:30','Sonal Parekh','prepaid',3546.0,0.0,177.3,3723.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1125','Shopify - Main Store','2026-06-05 10:15+05:30','Meghna Rao','prepaid',279.0,27.9,12.56,263.66,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1137','MTRK-BLK-M',1,649,0.0,32.45),
('AMAZ-1137','MCHN-OLV-34',1,1199,0.0,59.95),
('AMAZ-1138','MTRK-BLK-L',1,649,32.45,30.83),
('AMAZ-1138','WTOP-PCH-M',3,599,89.85,85.36),
('AMAZ-1139','WDUP-SLV-FREE',3,449,0.0,67.35),
('AMAZ-1140','WJNS-BLK-30',1,1349,0.0,67.45),
('AMAZ-1140','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1124','BTEE-RED-89Y',1,329,0.0,16.45),
('SHOP-1124','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1141','BKUR-CRM-89Y',1,949,0.0,47.45),
('AMAZ-1141','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1141','BSHF-WHT-45Y',1,599,0.0,29.95),
('AMAZ-1142','WDRS-FLR-S',1,1499,0.0,74.95),
('AMAZ-1142','WPAL-YLW-XL',1,599,0.0,29.95),
('AMAZ-1142','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1142','WKRT-PNK-M',1,849,0.0,42.45),
('SHOP-1125','GLEG-BLK-45Y',1,279,27.9,12.56)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1139','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1091', 'approved');
select pg_temp.ret_set('AMAZ-1116', 'approved');
select pg_temp.cod_collect(array['AMAZ-1121']::text[]);
select pg_temp.cod_collect(array['SHOP-1119']::text[]);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-05JUN', array['FLIP-1083','SHOP-1107']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-05JUN', array['SHOP-1099','SHOP-1109']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-05JUN', array['SHOP-1097','FLIP-1087','FLIP-1088','SHOP-1113']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-06-08', 'ICIC000000882963', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-06-08', 'ICIC000000883050', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-06-08', 'ICIC000000883081', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-06-08', 'ICIC000000883118', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-06-08', 'ICIC000000883174', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-06-08', 'ICIC000000883264', 1);
select pg_temp.claim_new('AMAZ-1064', 'lost_shipment', 5823.3, '2026-07-05');
select pg_temp.claim_step('FLIP-1066', 'damaged_return', 'claimed', null);
select pg_temp.claim_step('AMAZ-1086', 'other', 'claimed', null);
select pg_temp.retime();

-- Sat 06 Jun 2026
select pg_temp.day('2026-06-06');
select pg_temp.grn_new('Weekly replenishment 01 Jun 2026 - Little Stitch Garments (ref R062)', 'DC-LSG-0082', '[{"sku":"WDRS-FLP-M","q":8,"a":7,"r":1},{"sku":"BKUR-MUS-89Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1105','Flipkart - Seller Hub','2026-06-06 19:44+05:30','Manav Joshi','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1126','Shopify - Main Store','2026-06-06 11:26+05:30','Amit Sethi','prepaid',2598.0,0.0,129.9,2727.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1106','Flipkart - Seller Hub','2026-06-06 12:02+05:30','Prachi Kulkarni','prepaid',3296.0,164.8,156.56,3287.76,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1107','Flipkart - Seller Hub','2026-06-06 12:16+05:30','Dev Trivedi','cod',3547.0,0.0,177.35,3724.35,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1127','Shopify - Main Store','2026-06-06 09:53+05:30','Divya Nair','cod',1548.0,77.4,73.53,1544.13,'shipped','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1143','Amazon - Seller Central','2026-06-06 19:13+05:30','Sanjay Gajera','prepaid',2277.0,227.7,102.47,2151.77,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1108','Flipkart - Seller Hub','2026-06-06 13:53+05:30','Mitul Dave','prepaid',3196.0,0.0,159.8,3355.8,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1144','Amazon - Seller Central','2026-06-06 13:00+05:30','Ritu Saxena','cod',4596.0,229.8,218.31,4584.51,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1145','Amazon - Seller Central','2026-06-06 13:40+05:30','Kunal Desai','prepaid',2277.0,227.7,102.48,2151.78,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1146','Amazon - Seller Central','2026-06-06 11:27+05:30','Aditi Joshi','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1128','Shopify - Main Store','2026-06-06 19:35+05:30','Mehul Shukla','prepaid',7794.0,389.7,370.22,7774.52,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1105','MJNS-BLK-32',1,1399,0.0,69.95),
('SHOP-1126','MJNS-IND-32',1,1399,0.0,69.95),
('SHOP-1126','MCHN-OLV-34',1,1199,0.0,59.95),
('FLIP-1106','WTOP-PCH-L',1,599,29.95,28.45),
('FLIP-1106','WTOP-PCH-S',2,599,59.9,56.91),
('FLIP-1106','WDRS-FLP-L',1,1499,74.95,71.2),
('FLIP-1107','WDRS-FLR-S',2,1499,0.0,149.9),
('FLIP-1107','GNGT-PNK-89Y',1,549,0.0,27.45),
('SHOP-1127','WTOP-WHT-M',1,599,29.95,28.45),
('SHOP-1127','BKUR-MUS-67Y',1,949,47.45,45.08),
('AMAZ-1143','GJNS-IND-45Y',1,779,77.9,35.06),
('AMAZ-1143','GFRK-LIL-45Y',2,749,149.8,67.41),
('FLIP-1108','BKUR-MUS-45Y',3,949,0.0,142.35),
('FLIP-1108','BSHT-GRY-89Y',1,349,0.0,17.45),
('AMAZ-1144','MCHN-OLV-32',1,1199,59.95,56.95),
('AMAZ-1144','MSHF-SKY-M',1,999,49.95,47.45),
('AMAZ-1144','MCHN-KHK-34',2,1199,119.9,113.91),
('AMAZ-1145','BKUR-MUS-67Y',1,949,94.9,42.71),
('AMAZ-1145','BTRK-BLK-67Y',1,999,99.9,44.96),
('AMAZ-1145','BTEE-BLU-89Y',1,329,32.9,14.81),
('AMAZ-1146','BSHF-WHT-67Y',1,599,0.0,29.95),
('SHOP-1128','MCHN-OLV-34',3,1199,179.85,170.86),
('SHOP-1128','MJNS-IND-30',2,1399,139.9,132.91),
('SHOP-1128','MJNS-BLK-32',1,1399,69.95,66.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1107','Bluedart - Surat City'),
('AMAZ-1144','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1104', 'in_transit');
select pg_temp.ret_set('FLIP-1089', 'in_transit');
select pg_temp.ret_set('FLIP-1091', 'pickup');
select pg_temp.ret_set('AMAZ-1116', 'pickup');
select pg_temp.rto_new('SHOP-1118', 'AWB31000350', 'Customer refused delivery');
select pg_temp.rto_new('FLIP-1099', 'AWB31000381', 'Address incomplete');
select pg_temp.cod_collect(array['SHOP-1122']::text[]);
select pg_temp.retime();

-- Sun 07 Jun 2026
select pg_temp.day('2026-06-07');
select pg_temp.grn_new('Weekly replenishment 01 Jun 2026 - Krishna Denim Works (ref R060)', 'DC-KDW-0079', '[{"sku":"MJNS-BLK-30","q":6,"a":5,"r":1}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 01 Jun 2026 - Little Stitch Garments (ref R062)', 'LSG/26/0202', 1);
select pg_temp.grn_new('Weekly replenishment 01 Jun 2026 - Rajdhani Shirting Mills (ref R063)', 'DC-RSM-0094', '[{"sku":"MSHC-RED-XL","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 01 Jun 2026 - Rajdhani Shirting Mills (ref R064)', 'DC-RSM-0097', '[{"sku":"MSHC-GRN-L","q":12,"a":12,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1147','Amazon - Seller Central','2026-06-07 12:39+05:30','Mehul Shukla','cod',899.0,44.95,42.7,896.75,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1109','Flipkart - Seller Hub','2026-06-07 09:50+05:30','Sanjay Gajera','prepaid',1978.0,98.9,93.95,1973.05,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1110','Flipkart - Seller Hub','2026-06-07 09:36+05:30','Harsh Modi','prepaid',558.0,55.8,25.11,527.31,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1129','Shopify - Main Store','2026-06-07 09:02+05:30','Sanjay Gajera','cod',5096.0,0.0,254.8,5350.8,'shipped','pending','Rajasthan','Surat Main Warehouse'),
('SHOP-1130','Shopify - Main Store','2026-06-07 10:15+05:30','Mitul Dave','cod',2497.0,0.0,124.85,2621.85,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1111','Flipkart - Seller Hub','2026-06-07 19:01+05:30','Harsh Modi','prepaid',3397.0,339.7,152.88,3210.18,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1148','Amazon - Seller Central','2026-06-07 20:16+05:30','Sanjay Gajera','cod',699.0,69.9,31.46,660.56,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1147','MSHC-RED-M',1,899,44.95,42.7),
('FLIP-1109','MCHN-OLV-34',1,1199,59.95,56.95),
('FLIP-1109','GJNS-IND-45Y',1,779,38.95,37.0),
('FLIP-1110','GLEG-BLK-67Y',2,279,55.8,25.11),
('SHOP-1129','MSHC-GRN-M',1,899,0.0,44.95),
('SHOP-1129','MJNS-IND-32',3,1399,0.0,209.85),
('SHOP-1130','MPOL-NVY-M',1,699,0.0,34.95),
('SHOP-1130','WTOP-PCH-S',1,599,0.0,29.95),
('SHOP-1130','MCHN-KHK-34',1,1199,0.0,59.95),
('FLIP-1111','MCHN-OLV-32',1,1199,119.9,53.96),
('FLIP-1111','MCHN-OLV-34',1,1199,119.9,53.96),
('FLIP-1111','MSHF-WHT-L',1,999,99.9,44.96),
('AMAZ-1148','MPOL-MRN-XL',1,699,69.9,31.46)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1147','Delhivery - Sachin GIDC Surat'),
('SHOP-1130','Bluedart - Surat City'),
('AMAZ-1148','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1080');
select pg_temp.ret_recv('FLIP-1092');
select pg_temp.settle_pay('AMZ-STL-20260525', 320.0);
select pg_temp.claim_recover('AMAZ-1015', 'lost_shipment', 'CLAIM-CR-AMAZ-1015');
select pg_temp.retime();

-- Mon 08 Jun 2026
select pg_temp.day('2026-06-08');
select pg_temp.bill_po('Weekly replenishment 01 Jun 2026 - Krishna Denim Works (ref R060)', 'KDW/26/0192', 1);
select pg_temp.bill_po('Weekly replenishment 01 Jun 2026 - Rajdhani Shirting Mills (ref R063)', 'RSM/26/0231', 1);
select pg_temp.bill_po('Weekly replenishment 01 Jun 2026 - Rajdhani Shirting Mills (ref R064)', 'RSM/26/0237', 1);
select pg_temp.po_new('Weekly replenishment 08 Jun 2026 - Krishna Denim Works (ref R067)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"GJNS-IND-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 08 Jun 2026 - Krishna Denim Works (ref R068)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-IND-32","q":10},{"sku":"MCHN-KHK-34","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 08 Jun 2026 - Little Stitch Garments (ref R069)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLR-S","q":10},{"sku":"BKUR-MUS-45Y","q":18},{"sku":"BKUR-MUS-67Y","q":14},{"sku":"GFRK-LIL-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 08 Jun 2026 - Rajdhani Shirting Mills (ref R070)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MBLZ-NVY-40","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 08 Jun 2026 - Shree Ambika Textiles (ref R071)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-XL","q":6},{"sku":"WDUP-SLV-FREE","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 08 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R072)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"WLEG-NVY-M","q":6},{"sku":"GTOP-WHT-45Y","q":6},{"sku":"GLEG-BLK-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 08 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R073)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MPOL-NVY-M","q":6},{"sku":"WLEG-NVY-L","q":8},{"sku":"GLEG-BLK-89Y","q":6}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1112','Flipkart - Seller Hub','2026-06-08 22:47+05:30','Manav Joshi','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1131','Shopify - Main Store','2026-06-08 22:09+05:30','Ritu Saxena','cod',649.0,0.0,32.45,681.45,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1132','Shopify - Main Store','2026-06-08 16:02+05:30','Sejal Kapadia','prepaid',898.0,0.0,44.9,942.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1133','Shopify - Main Store','2026-06-08 12:25+05:30','Pooja Jain','cod',4193.0,419.3,188.7,3962.4,'shipped','pending','West Bengal','Surat Main Warehouse'),
('AMAZ-1149','Amazon - Seller Central','2026-06-08 14:57+05:30','Bhavna Solanki','prepaid',8495.0,849.5,826.77,8472.27,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1150','Amazon - Seller Central','2026-06-08 13:22+05:30','Yash Vora','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1151','Amazon - Seller Central','2026-06-08 17:17+05:30','Kiran Naik','prepaid',1198.0,119.8,53.91,1132.11,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1112','WTOP-WHT-L',2,599,0.0,59.9),
('SHOP-1131','MTRK-BLK-L',1,649,0.0,32.45),
('SHOP-1132','GNGT-PNK-67Y',1,549,0.0,27.45),
('SHOP-1132','GTOP-WHT-45Y',1,349,0.0,17.45),
('SHOP-1133','WTOP-WHT-M',2,599,119.8,53.91),
('SHOP-1133','WTOP-PCH-L',1,599,59.9,26.96),
('SHOP-1133','WTOP-WHT-L',1,599,59.9,26.96),
('SHOP-1133','WTOP-PCH-M',3,599,179.7,80.87),
('AMAZ-1149','MSHC-RED-M',1,899,89.9,40.46),
('AMAZ-1149','MCHN-KHK-34',2,1199,239.8,107.91),
('AMAZ-1149','MBLZ-NVY-40',1,3799,379.9,615.44),
('AMAZ-1149','MJNS-IND-34',1,1399,139.9,62.96),
('AMAZ-1150','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1151','WTOP-PCH-L',2,599,119.8,53.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1131','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1091', 'in_transit');
select pg_temp.ret_set('AMAZ-1116', 'in_transit');
select pg_temp.ret_new('AMAZ-1118', 'Size did not fit', 'webhook');
select pg_temp.rto_set('SHOP-1118', 'in_transit');
select pg_temp.rto_set('FLIP-1099', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1102']::text[]);
select pg_temp.cod_collect(array['SHOP-1123']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260601', '2026-06-01', '2026-06-07', array['AMAZ-1111','AMAZ-1112','AMAZ-1115','AMAZ-1117','AMAZ-1118','AMAZ-1119','AMAZ-1122','AMAZ-1124','AMAZ-1125','AMAZ-1120','AMAZ-1126','AMAZ-1123','AMAZ-1128','AMAZ-1130','AMAZ-1127','AMAZ-1129','AMAZ-1134']::text[], array['AMAZ-1086']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260601', '2026-06-01', '2026-06-07', array['FLIP-1091','FLIP-1093','FLIP-1094','FLIP-1095','FLIP-1096','FLIP-1100','FLIP-1097','FLIP-1098','FLIP-1101','FLIP-1103']::text[], array['FLIP-1066','FLIP-1080','FLIP-1092']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260601', '2026-06-01', '2026-06-07', array['SHOP-1111','SHOP-1116','SHOP-1117','SHOP-1112','SHOP-1114','SHOP-1120']::text[], array[]::text[]);
select pg_temp.claim_step('AMAZ-1064', 'lost_shipment', 'claimed', null);
select pg_temp.retime();

-- Tue 09 Jun 2026
select pg_temp.day('2026-06-09');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1134','Shopify - Main Store','2026-06-09 16:50+05:30','Pooja Jain','cod',1848.0,92.4,87.78,1843.38,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1113','Flipkart - Seller Hub','2026-06-09 14:53+05:30','Jigar Chauhan','prepaid',1498.0,149.8,67.42,1415.62,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1134','WLEG-NVY-L',1,349,17.45,16.58),
('SHOP-1134','WDRS-FLR-S',1,1499,74.95,71.2),
('FLIP-1113','MSHC-RED-XL',1,899,89.9,40.46),
('FLIP-1113','WTOP-PCH-S',1,599,59.9,26.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1134','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1080', 'good', 'restocked');
select pg_temp.ret_recv('FLIP-1089');
select pg_temp.ret_dispo('FLIP-1092', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1118', 'approved');
select pg_temp.ret_new('SHOP-1117', 'Fabric quality not as expected', 'manual');
select pg_temp.cod_collect(array['AMAZ-1139']::text[]);
select pg_temp.settle_pay('FLK-STL-20260525', 0.0);
select pg_temp.claim_new('AMAZ-1099', 'incorrect_deduction', 320.0, '2026-07-09');
select pg_temp.retime();

-- Wed 10 Jun 2026
select pg_temp.day('2026-06-10');
select pg_temp.grn_new('Weekly replenishment 01 Jun 2026 - Little Stitch Garments (ref R062)', 'DC-LSG-0085', '[{"sku":"WDRS-FLP-M","q":4,"a":4,"r":0},{"sku":"BKUR-MUS-89Y","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 01 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R065)', 'DC-TKF-0100', '[{"sku":"WLEG-BLK-M","q":8,"a":8,"r":0},{"sku":"WTOP-PCH-M","q":8,"a":8,"r":0},{"sku":"GTOP-WHT-45Y","q":6,"a":5,"r":1},{"sku":"GLEG-BLK-89Y","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1152','Amazon - Seller Central','2026-06-10 22:47+05:30','Sanjay Gajera','prepaid',2699.0,0.0,485.82,3184.82,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1114','Flipkart - Seller Hub','2026-06-10 21:19+05:30','Pratik Lad','prepaid',19044.0,0.0,3096.81,22140.81,'shipped','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1153','Amazon - Seller Central','2026-06-10 12:42+05:30','Aditi Joshi','prepaid',1356.0,0.0,67.8,1423.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1154','Amazon - Seller Central','2026-06-10 15:47+05:30','Tanvi Rana','prepaid',449.0,0.0,22.45,471.45,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1115','Flipkart - Seller Hub','2026-06-10 14:54+05:30','Heena Khan','prepaid',5395.0,539.5,242.79,5098.29,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1116','Flipkart - Seller Hub','2026-06-10 11:03+05:30','Harsh Modi','prepaid',3884.0,194.2,184.49,3874.29,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1152','WJKT-BLK-M',1,2699,0.0,485.82),
('FLIP-1114','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1114','WTOP-WHT-M',1,599,0.0,29.95),
('FLIP-1114','WLHG-RED-L',3,5499,0.0,2969.46),
('FLIP-1114','WJNS-BLK-32',1,1349,0.0,67.45),
('AMAZ-1153','BTEE-BLU-89Y',2,329,0.0,32.9),
('AMAZ-1153','BSHT-GRY-67Y',2,349,0.0,34.9),
('AMAZ-1154','MTEE-WHT-XL',1,449,0.0,22.45),
('FLIP-1115','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1115','WJNS-BLK-32',2,1349,269.8,121.41),
('FLIP-1115','WPAL-YLW-L',1,599,59.9,26.96),
('FLIP-1115','WDRS-FLR-L',1,1499,149.9,67.46),
('FLIP-1116','BTRK-BLK-89Y',1,999,49.95,47.45),
('FLIP-1116','BKUR-MUS-45Y',2,949,94.9,90.16),
('FLIP-1116','BTEE-BLU-67Y',3,329,49.35,46.88)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('AMAZ-1104');
select pg_temp.ret_dispo('FLIP-1089', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1118', 'pickup');
select pg_temp.ret_set('SHOP-1117', 'approved');
select pg_temp.ret_new('AMAZ-1128', 'Item arrived damaged', 'webhook');
select pg_temp.rto_new('SHOP-1127', 'AWB31000396', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['AMAZ-1144']::text[]);
select pg_temp.cod_collect(array['AMAZ-1148']::text[]);
select pg_temp.settle_pay('SHP-STL-20260601', 0.0);
select pg_temp.retime();

-- Thu 11 Jun 2026
select pg_temp.day('2026-06-11');
select pg_temp.bill_po('Weekly replenishment 01 Jun 2026 - Little Stitch Garments (ref R062)', 'LSG/26/0211', 1);
select pg_temp.bill_po('Weekly replenishment 01 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R065)', 'TKF/26/0243', 1);
select pg_temp.grn_new('Weekly replenishment 01 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R066)', 'DC-TKF-0103', '[{"sku":"WLEG-BLK-M","q":10,"a":10,"r":0},{"sku":"WLEG-NVY-L","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-67Y","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 08 Jun 2026 - Shree Ambika Textiles (ref R071)', 'DC-SAT-0073', '[{"sku":"WKRT-PNK-XL","q":6,"a":6,"r":0},{"sku":"WDUP-SLV-FREE","q":12,"a":12,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1155','Amazon - Seller Central','2026-06-11 20:49+05:30','Pooja Jain','prepaid',1777.0,0.0,88.85,1865.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1117','Flipkart - Seller Hub','2026-06-11 18:34+05:30','Karan Malhotra','prepaid',3597.0,0.0,179.85,3776.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1118','Flipkart - Seller Hub','2026-06-11 18:48+05:30','Vivek Singh','cod',3796.0,0.0,189.8,3985.8,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1156','Amazon - Seller Central','2026-06-11 13:01+05:30','Pooja Jain','prepaid',2847.0,0.0,142.35,2989.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1119','Flipkart - Seller Hub','2026-06-11 21:15+05:30','Dev Trivedi','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1155','GLEG-BLK-67Y',1,279,0.0,13.95),
('AMAZ-1155','GFRK-LIL-89Y',2,749,0.0,74.9),
('FLIP-1117','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1117','WDRS-FLP-S',2,1499,0.0,149.9),
('FLIP-1118','MSHC-RED-XL',1,899,0.0,44.95),
('FLIP-1118','MPOL-MRN-XL',1,699,0.0,34.95),
('FLIP-1118','MKUR-MUS-XL',2,1099,0.0,109.9),
('AMAZ-1156','MTEE-WHT-L',1,449,0.0,22.45),
('AMAZ-1156','MCHN-OLV-34',1,1199,0.0,59.95),
('AMAZ-1156','MCHN-KHK-34',1,1199,0.0,59.95),
('FLIP-1119','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1119','MSHC-GRN-XL',1,899,0.0,44.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1118','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1117', 'pickup');
select pg_temp.ret_set('AMAZ-1128', 'approved');
select pg_temp.cod_collect(array['FLIP-1107']::text[]);
select pg_temp.cod_collect(array['AMAZ-1147']::text[]);
select pg_temp.cod_collect(array['SHOP-1131']::text[]);
select pg_temp.claim_step('AMAZ-1043', 'lost_shipment', 'rejected', null);
select pg_temp.claim_step('AMAZ-1076', 'other', 'approved', null);
select pg_temp.retime();

-- Fri 12 Jun 2026
select pg_temp.day('2026-06-12');
select pg_temp.bill_po('Weekly replenishment 01 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R066)', 'TKF/26/0253', 1);
select pg_temp.grn_new('Weekly replenishment 08 Jun 2026 - Krishna Denim Works (ref R068)', 'DC-KDW-0085', '[{"sku":"MJNS-IND-32","q":10,"a":10,"r":0},{"sku":"MCHN-KHK-34","q":10,"a":9,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 08 Jun 2026 - Little Stitch Garments (ref R069)', 'DC-LSG-0088', '[{"sku":"WDRS-FLR-S","q":10,"a":10,"r":0},{"sku":"BKUR-MUS-45Y","q":18,"a":18,"r":0},{"sku":"BKUR-MUS-67Y","q":14,"a":14,"r":0},{"sku":"GFRK-LIL-45Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 08 Jun 2026 - Shree Ambika Textiles (ref R071)', 'SAT/26/0177', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1135','Shopify - Main Store','2026-06-12 11:50+05:30','Isha Gupta','prepaid',999.0,0.0,49.95,1048.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1157','Amazon - Seller Central','2026-06-12 20:57+05:30','Aditi Joshi','prepaid',2896.0,0.0,144.8,3040.8,'delivered','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1136','Shopify - Main Store','2026-06-12 17:05+05:30','Aditi Joshi','prepaid',329.0,16.45,15.63,328.18,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1158','Amazon - Seller Central','2026-06-12 15:39+05:30','Pratik Lad','prepaid',1047.0,0.0,52.35,1099.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1159','Amazon - Seller Central','2026-06-12 17:20+05:30','Anjali Verma','prepaid',4695.0,0.0,234.75,4929.75,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1160','Amazon - Seller Central','2026-06-12 09:21+05:30','Yash Vora','prepaid',2699.0,0.0,485.82,3184.82,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1161','Amazon - Seller Central','2026-06-12 14:06+05:30','Harsh Modi','prepaid',2297.0,114.85,109.11,2291.26,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1120','Flipkart - Seller Hub','2026-06-12 16:14+05:30','Sanjay Gajera','cod',3425.0,342.5,154.14,3236.64,'delivered','pending','West Bengal','Surat Main Warehouse'),
('FLIP-1121','Flipkart - Seller Hub','2026-06-12 13:33+05:30','Ritu Saxena','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1162','Amazon - Seller Central','2026-06-12 11:33+05:30','Harsh Modi','prepaid',949.0,47.45,45.08,946.63,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1163','Amazon - Seller Central','2026-06-12 22:44+05:30','Prachi Kulkarni','prepaid',1347.0,0.0,67.35,1414.35,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1135','BTRK-BLK-89Y',1,999,0.0,49.95),
('AMAZ-1157','MTEE-WHT-L',2,449,0.0,44.9),
('AMAZ-1157','MSHF-WHT-XL',2,999,0.0,99.9),
('SHOP-1136','BTEE-BLU-89Y',1,329,16.45,15.63),
('AMAZ-1158','BSHT-NVY-45Y',3,349,0.0,52.35),
('AMAZ-1159','BKUR-CRM-67Y',2,949,0.0,94.9),
('AMAZ-1159','MSHC-GRN-M',1,899,0.0,44.95),
('AMAZ-1159','BKUR-MUS-89Y',1,949,0.0,47.45),
('AMAZ-1159','BKUR-CRM-89Y',1,949,0.0,47.45),
('AMAZ-1160','WJKT-BLK-XL',1,2699,0.0,485.82),
('AMAZ-1161','WKRT-TEL-XL',2,849,84.9,80.66),
('AMAZ-1161','WTOP-PCH-L',1,599,29.95,28.45),
('FLIP-1120','WJNS-BLK-28',1,1349,134.9,60.71),
('FLIP-1120','GLEG-BLK-45Y',1,279,27.9,12.56),
('FLIP-1120','WTOP-WHT-M',2,599,119.8,53.91),
('FLIP-1120','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1121','BKUR-CRM-89Y',1,949,0.0,47.45),
('FLIP-1121','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1162','BKUR-CRM-89Y',1,949,47.45,45.08),
('AMAZ-1163','WDUP-SLV-FREE',3,449,0.0,67.35)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1120','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1104', 'damaged', 'quarantined');
select pg_temp.ret_recv('FLIP-1091');
select pg_temp.ret_recv('AMAZ-1116');
select pg_temp.ret_set('AMAZ-1118', 'in_transit');
select pg_temp.rto_recv('SHOP-1118', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1128', 'pickup');
select pg_temp.rto_set('SHOP-1127', 'in_transit');
select pg_temp.rto_new('SHOP-1133', 'AWB31000422', 'Address incomplete');
select pg_temp.cod_collect(array['SHOP-1134']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-12JUN', array['SHOP-1119','FLIP-1102','AMAZ-1144']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-12JUN', array['AMAZ-1121','SHOP-1122']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-12JUN', array['SHOP-1123','AMAZ-1139','AMAZ-1148']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-12JUN', array['SHOP-1115']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-06-15', 'ICIC000000883358', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-06-15', 'ICIC000000883369', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-06-15', 'ICIC000000883403', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-06-15', 'ICIC000000883437', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-06-15', 'ICIC000000883518', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-06-15', 'ICIC000000883564', 1);
select pg_temp.claim_recover('FLIP-1048', 'damaged_return', 'CLAIM-CR-FLIP-1048');
select pg_temp.claim_new('AMAZ-1104', 'damaged_return', 1402.38, '2026-07-12');
select pg_temp.claim_step('AMAZ-1099', 'incorrect_deduction', 'claimed', null);
select pg_temp.retime();

-- Sat 13 Jun 2026
select pg_temp.day('2026-06-13');
select pg_temp.bill_po('Weekly replenishment 08 Jun 2026 - Krishna Denim Works (ref R068)', 'KDW/26/0208', 1);
select pg_temp.bill_po('Weekly replenishment 08 Jun 2026 - Little Stitch Garments (ref R069)', 'LSG/26/0217', 1);
select pg_temp.grn_new('Weekly replenishment 08 Jun 2026 - Rajdhani Shirting Mills (ref R070)', 'DC-RSM-0100', '[{"sku":"MBLZ-NVY-40","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1122','Flipkart - Seller Hub','2026-06-13 17:24+05:30','Riya Shah','cod',658.0,65.8,29.61,621.81,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1123','Flipkart - Seller Hub','2026-06-13 10:20+05:30','Meghna Rao','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1164','Amazon - Seller Central','2026-06-13 09:31+05:30','Pratik Lad','prepaid',1948.0,0.0,97.4,2045.4,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1124','Flipkart - Seller Hub','2026-06-13 15:13+05:30','Rahul Bhatt','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1165','Amazon - Seller Central','2026-06-13 21:34+05:30','Jigar Chauhan','cod',3297.0,164.85,156.61,3288.76,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1166','Amazon - Seller Central','2026-06-13 17:09+05:30','Chirag Zaveri','prepaid',1048.0,0.0,52.4,1100.4,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1122','BTEE-BLU-67Y',2,329,65.8,29.61),
('FLIP-1123','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1164','BTRK-BLK-89Y',1,999,0.0,49.95),
('AMAZ-1164','BKUR-MUS-45Y',1,949,0.0,47.45),
('FLIP-1124','MTRK-BLK-M',1,649,0.0,32.45),
('AMAZ-1165','WTOP-PCH-M',1,599,29.95,28.45),
('AMAZ-1165','WJNS-IND-28',2,1349,134.9,128.16),
('AMAZ-1166','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1166','WDUP-GLD-FREE',1,449,0.0,22.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1122','DTDC - Ring Road Surat'),
('AMAZ-1165','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1117', 'in_transit');
select pg_temp.ret_new('FLIP-1098', 'Colour different from photo', 'webhook');
select pg_temp.ret_new('SHOP-1121', 'Item arrived damaged', 'webhook');
select pg_temp.ret_new('AMAZ-1140', 'Customer changed mind', 'webhook');
select pg_temp.rto_new('SHOP-1129', 'AWB31000408', 'Customer refused delivery');
select pg_temp.cod_collect(array['SHOP-1130']::text[]);
select pg_temp.retime();

-- Sun 14 Jun 2026
select pg_temp.day('2026-06-14');
select pg_temp.grn_new('Weekly replenishment 08 Jun 2026 - Krishna Denim Works (ref R067)', 'DC-KDW-0082', '[{"sku":"GJNS-IND-45Y","q":6,"a":5,"r":1}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 08 Jun 2026 - Rajdhani Shirting Mills (ref R070)', 'RSM/26/0245', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1137','Shopify - Main Store','2026-06-14 22:49+05:30','Shreya Banerjee','prepaid',2897.0,0.0,144.85,3041.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1167','Amazon - Seller Central','2026-06-14 19:39+05:30','Vivek Singh','prepaid',1499.0,149.9,67.46,1416.56,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1125','Flipkart - Seller Hub','2026-06-14 11:53+05:30','Anjali Verma','prepaid',1099.0,54.95,52.2,1096.25,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1138','Shopify - Main Store','2026-06-14 16:19+05:30','Heena Khan','cod',1157.0,115.7,52.07,1093.37,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1126','Flipkart - Seller Hub','2026-06-14 21:06+05:30','Harsh Modi','cod',5852.0,0.0,786.47,6638.47,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1139','Shopify - Main Store','2026-06-14 12:33+05:30','Yash Vora','cod',1798.0,89.9,85.41,1793.51,'shipped','pending','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1140','Shopify - Main Store','2026-06-14 15:51+05:30','Anjali Verma','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1141','Shopify - Main Store','2026-06-14 21:14+05:30','Heena Khan','prepaid',698.0,69.8,31.41,659.61,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1168','Amazon - Seller Central','2026-06-14 21:03+05:30','Amit Sethi','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1137','MSHC-RED-XL',2,899,0.0,89.9),
('SHOP-1137','MKUR-MUS-L',1,1099,0.0,54.95),
('AMAZ-1167','WDRS-FLP-M',1,1499,149.9,67.46),
('FLIP-1125','MKUR-WHT-XL',1,1099,54.95,52.2),
('SHOP-1138','GLEG-BLK-67Y',2,279,55.8,25.11),
('SHOP-1138','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1126','BTEE-BLU-67Y',2,329,0.0,32.9),
('FLIP-1126','GLEG-PNK-89Y',3,279,0.0,41.85),
('FLIP-1126','MBLZ-NVY-40',1,3799,0.0,683.82),
('FLIP-1126','GLEG-PNK-67Y',2,279,0.0,27.9),
('SHOP-1139','MSHC-RED-M',2,899,89.9,85.41),
('SHOP-1140','BKUR-CRM-67Y',1,949,0.0,47.45),
('SHOP-1141','GTOP-YLW-67Y',2,349,69.8,31.41),
('AMAZ-1168','BKUR-CRM-45Y',1,949,0.0,47.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1138','DTDC - Ring Road Surat'),
('FLIP-1126','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1091', 'good', 'restocked');
select pg_temp.ret_dispo('AMAZ-1116', 'damaged', 'quarantined');
select pg_temp.ret_set('FLIP-1098', 'approved');
select pg_temp.rto_recv('FLIP-1099', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1128', 'in_transit');
select pg_temp.ret_set('SHOP-1121', 'approved');
select pg_temp.ret_set('AMAZ-1140', 'approved');
select pg_temp.rto_set('SHOP-1133', 'in_transit');
select pg_temp.settle_pay('AMZ-STL-20260601', 0.0);
select pg_temp.claim_new('AMAZ-1116', 'damaged_return', 1886.41, '2026-07-14');
select pg_temp.retime();

-- Mon 15 Jun 2026
select pg_temp.day('2026-06-15');
select pg_temp.bill_po('Weekly replenishment 08 Jun 2026 - Krishna Denim Works (ref R067)', 'KDW/26/0200', 1);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Krishna Denim Works (ref R074)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"WJNS-BLK-32","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Krishna Denim Works (ref R075)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MCHN-OLV-32","q":12},{"sku":"WJNS-BLK-28","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Little Stitch Garments (ref R076)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"BSHT-NVY-45Y","q":6},{"sku":"BKUR-CRM-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Ludhiana Winter Wear Co (ref R077)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"BTRK-BLK-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Rajdhani Shirting Mills (ref R078)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHF-WHT-XL","q":6},{"sku":"MSHC-RED-M","q":14},{"sku":"MSHC-GRN-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R079)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WPAL-YLW-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R080)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-TEL-XL","q":8},{"sku":"WLHG-RED-L","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R081)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"WLEG-NVY-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 15 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R082)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-WHT-L","q":6},{"sku":"MPOL-NVY-M","q":6},{"sku":"GTOP-YLW-67Y","q":6},{"sku":"GLEG-BLK-89Y","q":6}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1169','Amazon - Seller Central','2026-06-15 13:51+05:30','Nikhil Pandey','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1127','Flipkart - Seller Hub','2026-06-15 10:35+05:30','Sagar Rathod','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1170','Amazon - Seller Central','2026-06-15 10:25+05:30','Sanjay Gajera','prepaid',828.0,41.4,39.33,825.93,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1171','Amazon - Seller Central','2026-06-15 20:17+05:30','Jigar Chauhan','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1128','Flipkart - Seller Hub','2026-06-15 16:13+05:30','Aditi Joshi','cod',4047.0,202.35,192.23,4036.88,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1129','Flipkart - Seller Hub','2026-06-15 18:54+05:30','Amit Sethi','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1142','Shopify - Main Store','2026-06-15 15:43+05:30','Neha Patel','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1172','Amazon - Seller Central','2026-06-15 20:34+05:30','Aarav Mehta','prepaid',4556.0,0.0,227.8,4783.8,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1173','Amazon - Seller Central','2026-06-15 19:07+05:30','Aditi Joshi','prepaid',1399.0,69.95,66.45,1395.5,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1143','Shopify - Main Store','2026-06-15 12:21+05:30','Divya Nair','prepaid',2646.0,0.0,132.3,2778.3,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1169','BKUR-CRM-89Y',1,949,0.0,47.45),
('FLIP-1127','WTOP-WHT-L',2,599,0.0,59.9),
('FLIP-1127','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1170','GNGT-PNK-89Y',1,549,27.45,26.08),
('AMAZ-1170','GLEG-BLK-67Y',1,279,13.95,13.25),
('AMAZ-1171','MTRK-BLK-L',1,649,0.0,32.45),
('FLIP-1128','WJNS-IND-28',3,1349,202.35,192.23),
('FLIP-1129','BSHF-WHT-89Y',1,599,29.95,28.45),
('SHOP-1142','GLEG-BLK-89Y',1,279,0.0,13.95),
('AMAZ-1172','GLEG-BLK-89Y',1,279,0.0,13.95),
('AMAZ-1172','GLHG-RED-45Y',2,1999,0.0,199.9),
('AMAZ-1172','GLEG-BLK-45Y',1,279,0.0,13.95),
('AMAZ-1173','MJNS-BLK-32',1,1399,69.95,66.45),
('SHOP-1143','WTOP-PCH-M',2,599,0.0,59.9),
('SHOP-1143','WKRT-TEL-M',1,849,0.0,42.45),
('SHOP-1143','WTOP-PCH-S',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1128','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1118');
select pg_temp.ret_recv('SHOP-1117');
select pg_temp.ret_set('FLIP-1098', 'pickup');
select pg_temp.ret_set('SHOP-1121', 'pickup');
select pg_temp.ret_set('AMAZ-1140', 'pickup');
select pg_temp.rto_set('SHOP-1129', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1118']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260608', '2026-06-08', '2026-06-14', array['AMAZ-1138','AMAZ-1142','AMAZ-1131','AMAZ-1132','AMAZ-1133','AMAZ-1136','AMAZ-1140','AMAZ-1135','AMAZ-1137','AMAZ-1141','AMAZ-1143','AMAZ-1145','AMAZ-1146','AMAZ-1149','AMAZ-1151','AMAZ-1152','AMAZ-1150','AMAZ-1153','AMAZ-1155']::text[], array['AMAZ-1104','AMAZ-1116']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260608', '2026-06-08', '2026-06-14', array['FLIP-1104','FLIP-1105','FLIP-1106','FLIP-1108','FLIP-1109','FLIP-1111','FLIP-1110','FLIP-1113','FLIP-1112','FLIP-1116','FLIP-1117']::text[], array['FLIP-1089','FLIP-1091']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260608', '2026-06-08', '2026-06-14', array['SHOP-1124','SHOP-1125','SHOP-1121','SHOP-1126','SHOP-1128','SHOP-1132']::text[], array[]::text[]);
select pg_temp.claim_step('AMAZ-1104', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Tue 16 Jun 2026
select pg_temp.day('2026-06-16');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1130','Flipkart - Seller Hub','2026-06-16 15:02+05:30','Dev Trivedi','cod',2598.0,259.8,116.92,2455.12,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1131','Flipkart - Seller Hub','2026-06-16 09:01+05:30','Sonal Parekh','cod',3097.0,0.0,154.85,3251.85,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1132','Flipkart - Seller Hub','2026-06-16 15:37+05:30','Dev Trivedi','cod',3024.0,0.0,151.2,3175.2,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('AMAZ-1174','Amazon - Seller Central','2026-06-16 09:01+05:30','Divya Nair','prepaid',5644.0,0.0,282.2,5926.2,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1133','Flipkart - Seller Hub','2026-06-16 12:40+05:30','Ritu Saxena','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1175','Amazon - Seller Central','2026-06-16 12:09+05:30','Karan Malhotra','prepaid',1298.0,64.9,61.66,1294.76,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1134','Flipkart - Seller Hub','2026-06-16 22:56+05:30','Jigar Chauhan','prepaid',279.0,13.95,13.25,278.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1176','Amazon - Seller Central','2026-06-16 09:53+05:30','Sagar Rathod','prepaid',1448.0,0.0,72.4,1520.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1135','Flipkart - Seller Hub','2026-06-16 10:39+05:30','Vipul Gandhi','prepaid',1457.0,145.7,65.57,1376.87,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1136','Flipkart - Seller Hub','2026-06-16 12:03+05:30','Harsh Modi','prepaid',1298.0,0.0,64.9,1362.9,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1130','MJNS-BLK-32',1,1399,139.9,62.96),
('FLIP-1130','MCHN-KHK-30',1,1199,119.9,53.96),
('FLIP-1131','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1131','BKUR-MUS-67Y',2,949,0.0,94.9),
('FLIP-1132','GTOP-WHT-89Y',1,349,0.0,17.45),
('FLIP-1132','GLEG-PNK-45Y',1,279,0.0,13.95),
('FLIP-1132','WTOP-WHT-M',2,599,0.0,59.9),
('FLIP-1132','WTOP-PCH-S',2,599,0.0,59.9),
('AMAZ-1174','WKRT-PNK-XL',2,849,0.0,84.9),
('AMAZ-1174','MCHN-OLV-34',3,1199,0.0,179.85),
('AMAZ-1174','WLEG-BLK-M',1,349,0.0,17.45),
('FLIP-1133','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1175','MTRK-BLK-M',2,649,64.9,61.66),
('FLIP-1134','GLEG-PNK-67Y',1,279,13.95,13.25),
('AMAZ-1176','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1176','WKRT-PNK-XL',1,849,0.0,42.45),
('FLIP-1135','BJNS-IND-89Y',1,799,79.9,35.96),
('FLIP-1135','BTEE-BLU-45Y',2,329,65.8,29.61),
('FLIP-1136','MTRK-BLK-M',2,649,0.0,64.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1130','Xpressbees - Pandesara'),
('FLIP-1131','Ecom Express - Udhna Hub'),
('FLIP-1132','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_recv('SHOP-1127', 'good', 'restocked');
select pg_temp.ret_new('SHOP-1132', 'Fabric quality not as expected', 'webhook');
select pg_temp.rto_new('FLIP-1114', 'AWB31000441', 'Customer refused delivery');
select pg_temp.cod_collect(array['FLIP-1122']::text[]);
select pg_temp.cod_collect(array['AMAZ-1165']::text[]);
select pg_temp.settle_pay('FLK-STL-20260601', 0.0);
select pg_temp.claim_step('FLIP-1066', 'damaged_return', 'approved', null);
select pg_temp.claim_step('AMAZ-1086', 'other', 'rejected', null);
select pg_temp.retime();

-- Wed 17 Jun 2026
select pg_temp.day('2026-06-17');
select pg_temp.grn_new('Weekly replenishment 08 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R073)', 'DC-TKF-0109', '[{"sku":"MPOL-NVY-M","q":6,"a":5,"r":1},{"sku":"WLEG-NVY-L","q":8,"a":8,"r":0},{"sku":"GLEG-BLK-89Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1137','Flipkart - Seller Hub','2026-06-17 19:26+05:30','Isha Gupta','prepaid',1848.0,0.0,92.4,1940.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1177','Amazon - Seller Central','2026-06-17 12:53+05:30','Anjali Verma','prepaid',1386.0,69.3,65.84,1382.54,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1138','Flipkart - Seller Hub','2026-06-17 17:59+05:30','Rohit Iyer','prepaid',4042.0,404.2,181.9,3819.7,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1139','Flipkart - Seller Hub','2026-06-17 10:41+05:30','Kiran Naik','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1140','Flipkart - Seller Hub','2026-06-17 09:46+05:30','Pooja Jain','cod',599.0,0.0,29.95,628.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1178','Amazon - Seller Central','2026-06-17 16:00+05:30','Bhavna Solanki','prepaid',6794.0,0.0,339.7,7133.7,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1141','Flipkart - Seller Hub','2026-06-17 11:21+05:30','Sejal Kapadia','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1142','Flipkart - Seller Hub','2026-06-17 16:59+05:30','Jigar Chauhan','cod',599.0,59.9,26.96,566.06,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1137','MTRK-BLK-XL',1,649,0.0,32.45),
('FLIP-1137','MCHN-KHK-30',1,1199,0.0,59.95),
('AMAZ-1177','GLEG-PNK-89Y',1,279,13.95,13.25),
('AMAZ-1177','GLEG-BLK-67Y',2,279,27.9,26.51),
('AMAZ-1177','GNGT-PNK-45Y',1,549,27.45,26.08),
('FLIP-1138','WLEG-MAR-L',2,349,69.8,31.41),
('FLIP-1138','WTOP-WHT-M',3,599,179.7,80.87),
('FLIP-1138','WLEG-BLK-M',1,349,34.9,15.71),
('FLIP-1138','WTOP-PCH-S',2,599,119.8,53.91),
('FLIP-1139','MSHC-RED-XL',1,899,0.0,44.95),
('FLIP-1139','MTEE-BLK-M',2,449,0.0,44.9),
('FLIP-1140','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1178','MCHN-OLV-32',1,1199,0.0,59.95),
('AMAZ-1178','MPOL-MRN-XL',2,699,0.0,69.9),
('AMAZ-1178','MJNS-IND-32',1,1399,0.0,69.95),
('AMAZ-1178','MJNS-IND-34',2,1399,0.0,139.9),
('FLIP-1141','WTOP-WHT-M',1,599,0.0,29.95),
('FLIP-1142','WTOP-PCH-L',1,599,59.9,26.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1140','Delhivery - Sachin GIDC Surat'),
('FLIP-1142','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1118', 'good', 'restocked');
select pg_temp.ret_dispo('SHOP-1117', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1098', 'in_transit');
select pg_temp.ret_recv('AMAZ-1128');
select pg_temp.ret_set('SHOP-1121', 'in_transit');
select pg_temp.ret_set('AMAZ-1140', 'in_transit');
select pg_temp.ret_new('SHOP-1128', 'Customer changed mind', 'webhook');
select pg_temp.ret_set('SHOP-1132', 'approved');
select pg_temp.cod_collect(array['SHOP-1138']::text[]);
select pg_temp.settle_pay('SHP-STL-20260608', 0.0);
select pg_temp.claim_step('AMAZ-1116', 'damaged_return', 'claimed', null);
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
