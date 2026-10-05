-- 01 Aug to 20 Aug 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Sat 01 Aug 2026
select pg_temp.day('2026-08-01');
select pg_temp.grn_new('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R116)', 'DC-TKF-0154', '[{"sku":"MTEE-WHT-M","q":2,"a":2,"r":0},{"sku":"BTEE-RED-45Y","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 27 Jul 2026 - Krishna Denim Works (ref R118)', 'DC-KDW-0118', '[{"sku":"MJNS-BLK-30","q":10,"a":10,"r":0},{"sku":"WJNS-IND-28","q":12,"a":12,"r":0},{"sku":"WJNS-IND-32","q":8,"a":7,"r":1},{"sku":"WJNS-BLK-30","q":6,"a":6,"r":0},{"sku":"WJNS-BLK-32","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 27 Jul 2026 - Shree Ambika Textiles (ref R120)', 'DC-SAT-0115', '[{"sku":"WPAL-WHT-M","q":8,"a":8,"r":0},{"sku":"WLHG-RED-M","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1315','Amazon - Seller Central','2026-08-01 20:29+05:30','Nikhil Pandey','prepaid',3297.0,164.85,156.61,3288.76,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1316','Amazon - Seller Central','2026-08-01 09:33+05:30','Vipul Gandhi','prepaid',2773.0,415.95,117.86,2474.91,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1248','Shopify - Main Store','2026-08-01 16:03+05:30','Mitul Dave','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1249','Shopify - Main Store','2026-08-01 10:05+05:30','Sejal Kapadia','cod',4596.0,0.0,229.8,4825.8,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1250','Shopify - Main Store','2026-08-01 16:50+05:30','Chirag Zaveri','prepaid',949.0,94.9,42.71,896.81,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1244','Flipkart - Seller Hub','2026-08-01 12:03+05:30','Sanjay Gajera','prepaid',849.0,127.35,36.08,757.73,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1251','Shopify - Main Store','2026-08-01 22:53+05:30','Rahul Bhatt','prepaid',2947.0,0.0,147.35,3094.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1245','Flipkart - Seller Hub','2026-08-01 16:05+05:30','Isha Gupta','prepaid',3395.0,0.0,169.75,3564.75,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1246','Flipkart - Seller Hub','2026-08-01 09:50+05:30','Tanvi Rana','cod',5395.0,0.0,269.75,5664.75,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1252','Shopify - Main Store','2026-08-01 18:53+05:30','Tanvi Rana','cod',1399.0,69.95,66.45,1395.5,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1247','Flipkart - Seller Hub','2026-08-01 11:35+05:30','Tanvi Rana','cod',1897.0,94.85,90.11,1892.26,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1317','Amazon - Seller Central','2026-08-01 18:15+05:30','Vipul Gandhi','prepaid',1028.0,0.0,51.4,1079.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1248','Flipkart - Seller Hub','2026-08-01 22:18+05:30','Pratik Lad','prepaid',1048.0,0.0,52.4,1100.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1253','Shopify - Main Store','2026-08-01 12:10+05:30','Tanvi Rana','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1315','WJNS-IND-32',2,1349,134.9,128.16),
('AMAZ-1315','WTOP-WHT-M',1,599,29.95,28.45),
('AMAZ-1316','BKUR-MUS-45Y',1,949,142.35,40.33),
('AMAZ-1316','BTEE-BLU-67Y',3,329,148.05,41.95),
('AMAZ-1316','GLEG-BLK-45Y',2,279,83.7,23.72),
('AMAZ-1316','GLEG-BLK-89Y',1,279,41.85,11.86),
('SHOP-1248','MJNS-IND-30',1,1399,0.0,69.95),
('SHOP-1249','MSHC-GRN-L',2,899,0.0,89.9),
('SHOP-1249','MJNS-BLK-32',1,1399,0.0,69.95),
('SHOP-1249','MJNS-IND-32',1,1399,0.0,69.95),
('SHOP-1250','BKUR-MUS-89Y',1,949,94.9,42.71),
('FLIP-1244','WKRT-PNK-XL',1,849,127.35,36.08),
('SHOP-1251','MSHC-RED-XL',1,899,0.0,44.95),
('SHOP-1251','MJNS-BLK-30',1,1399,0.0,69.95),
('SHOP-1251','MTRK-BLK-L',1,649,0.0,32.45),
('FLIP-1245','WLEG-MAR-L',3,349,0.0,52.35),
('FLIP-1245','WKRT-PNK-XL',1,849,0.0,42.45),
('FLIP-1245','WDRS-FLP-L',1,1499,0.0,74.95),
('FLIP-1246','MCHN-OLV-34',1,1199,0.0,59.95),
('FLIP-1246','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1246','MSHF-WHT-L',3,999,0.0,149.85),
('SHOP-1252','MJNS-BLK-32',1,1399,69.95,66.45),
('FLIP-1247','MTRK-BLK-M',2,649,64.9,61.66),
('FLIP-1247','WTOP-PCH-L',1,599,29.95,28.45),
('AMAZ-1317','GFRK-LIL-89Y',1,749,0.0,37.45),
('AMAZ-1317','GLEG-PNK-67Y',1,279,0.0,13.95),
('FLIP-1248','MTEE-WHT-M',1,449,0.0,22.45),
('FLIP-1248','WTOP-PCH-S',1,599,0.0,29.95),
('SHOP-1253','WKRT-TEL-XL',1,849,0.0,42.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1249','Delhivery - Sachin GIDC Surat'),
('FLIP-1246','Ecom Express - Udhna Hub'),
('SHOP-1252','DTDC - Ring Road Surat'),
('FLIP-1247','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('SHOP-1200');
select pg_temp.ret_recv('AMAZ-1264');
select pg_temp.ret_recv('FLIP-1195');
select pg_temp.ret_dispo('AMAZ-1268', 'good', 'restocked');
select pg_temp.ret_dispo('AMAZ-1269', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1278', 'approved');
select pg_temp.ret_reject('AMAZ-1278');
select pg_temp.ret_dispo('AMAZ-1280', 'wrong_item', 'claimed');
select pg_temp.rto_recv('FLIP-1214', 'good', 'restocked');
select pg_temp.ret_new('FLIP-1217', 'Item arrived damaged', 'webhook');
select pg_temp.ret_new('AMAZ-1289', 'Customer changed mind', 'webhook');
select pg_temp.rto_set('SHOP-1234', 'in_transit');
select pg_temp.ret_new('FLIP-1222', 'Size did not fit', 'webhook');
select pg_temp.claim_new('FLIP-1168', 'lost_shipment', 1738.8, '2026-08-31');
select pg_temp.claim_new('AMAZ-1280', 'other', 1025.43, '2026-08-31');
select pg_temp.retime();

-- Sun 02 Aug 2026
select pg_temp.day('2026-08-02');
select pg_temp.bill_po('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R116)', 'TKF/26/0368', 1);
select pg_temp.grn_new('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R117)', 'DC-TKF-0160', '[{"sku":"MTEE-BLK-XL","q":3,"a":3,"r":0},{"sku":"MTEE-WHT-M","q":2,"a":2,"r":0},{"sku":"MTRK-BLK-M","q":3,"a":3,"r":0},{"sku":"MTRK-BLK-L","q":2,"a":2,"r":0},{"sku":"WLEG-MAR-M","q":2,"a":2,"r":0},{"sku":"WLEG-NVY-M","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 27 Jul 2026 - Krishna Denim Works (ref R118)', 'KDW/26/0288', 1);
select pg_temp.bill_po('Weekly replenishment 27 Jul 2026 - Shree Ambika Textiles (ref R120)', 'SAT/26/0279', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1249','Flipkart - Seller Hub','2026-08-02 19:21+05:30','Mehul Shukla','cod',599.0,89.85,25.46,534.61,'delivered','pending','Delhi','Surat Main Warehouse'),
('SHOP-1254','Shopify - Main Store','2026-08-02 19:40+05:30','Karan Malhotra','prepaid',2205.0,0.0,110.25,2315.25,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1318','Amazon - Seller Central','2026-08-02 22:25+05:30','Vipul Gandhi','prepaid',1499.0,149.9,67.46,1416.56,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1319','Amazon - Seller Central','2026-08-02 21:07+05:30','Pratik Lad','prepaid',928.0,92.8,41.77,876.97,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1250','Flipkart - Seller Hub','2026-08-02 15:55+05:30','Heena Khan','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1255','Shopify - Main Store','2026-08-02 15:25+05:30','Prachi Kulkarni','cod',1898.0,189.8,85.42,1793.62,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1256','Shopify - Main Store','2026-08-02 21:46+05:30','Prachi Kulkarni','cod',558.0,0.0,27.9,585.9,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1320','Amazon - Seller Central','2026-08-02 09:53+05:30','Shreya Banerjee','prepaid',779.0,0.0,38.95,817.95,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1249','WTOP-WHT-L',1,599,89.85,25.46),
('SHOP-1254','GNGT-PNK-45Y',1,549,0.0,27.45),
('SHOP-1254','GLEG-PNK-67Y',2,279,0.0,27.9),
('SHOP-1254','GNGT-PNK-1011Y',2,549,0.0,54.9),
('AMAZ-1318','WDRS-FLP-M',1,1499,149.9,67.46),
('AMAZ-1319','BTEE-BLU-67Y',1,329,32.9,14.81),
('AMAZ-1319','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1250','WTOP-PCH-S',1,599,0.0,29.95),
('SHOP-1255','BKUR-CRM-45Y',1,949,94.9,42.71),
('SHOP-1255','BKUR-MUS-89Y',1,949,94.9,42.71),
('SHOP-1256','GLEG-BLK-67Y',1,279,0.0,13.95),
('SHOP-1256','GLEG-PNK-67Y',1,279,0.0,13.95),
('AMAZ-1320','GJNS-IND-89Y',1,779,0.0,38.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1249','DTDC - Ring Road Surat'),
('SHOP-1255','Ecom Express - Udhna Hub'),
('SHOP-1256','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1217', 'approved');
select pg_temp.ret_set('AMAZ-1289', 'approved');
select pg_temp.ret_set('FLIP-1222', 'approved');
select pg_temp.cod_collect(array['FLIP-1230']::text[]);
select pg_temp.rto_new('AMAZ-1301', 'AWB31000823', 'Address incomplete');
select pg_temp.cod_collect(array['SHOP-1243']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260720', 0.0);
select pg_temp.retime();

-- Mon 03 Aug 2026
select pg_temp.day('2026-08-03');
select pg_temp.bill_po('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R117)', 'TKF/26/0384', 1);
select pg_temp.po_new('Weekly replenishment 03 Aug 2026 - Krishna Denim Works (ref R123)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MJNS-BLK-32","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 03 Aug 2026 - Krishna Denim Works (ref R124)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-32","q":10},{"sku":"MCHN-OLV-34","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 03 Aug 2026 - Little Stitch Garments (ref R125)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"BKUR-MUS-67Y","q":8},{"sku":"GNGT-PNK-89Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 03 Aug 2026 - Ludhiana Winter Wear Co (ref R126)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"BTRK-BLK-1011Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 03 Aug 2026 - Rajdhani Shirting Mills (ref R127)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHF-WHT-L","q":6},{"sku":"MSHC-RED-XL","q":20}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 03 Aug 2026 - Shree Ambika Textiles (ref R128)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-M","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 03 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R129)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"BTEE-BLU-67Y","q":10},{"sku":"GLEG-BLK-45Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 03 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R130)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-BLK-M","q":6},{"sku":"WTOP-PCH-S","q":12},{"sku":"GLEG-BLK-89Y","q":12}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1321','Amazon - Seller Central','2026-08-03 13:58+05:30','Anjali Verma','prepaid',3595.0,359.5,161.79,3397.29,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1322','Amazon - Seller Central','2026-08-03 09:53+05:30','Tanvi Rana','prepaid',4095.0,409.5,184.29,3869.79,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1257','Shopify - Main Store','2026-08-03 22:34+05:30','Aditi Joshi','cod',1477.0,0.0,73.85,1550.85,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1251','Flipkart - Seller Hub','2026-08-03 11:33+05:30','Mitul Dave','prepaid',3298.0,494.7,140.17,2943.47,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1323','Amazon - Seller Central','2026-08-03 19:04+05:30','Heena Khan','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1252','Flipkart - Seller Hub','2026-08-03 18:54+05:30','Pooja Jain','prepaid',5393.0,0.0,269.65,5662.65,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1253','Flipkart - Seller Hub','2026-08-03 22:30+05:30','Manav Joshi','cod',3897.0,584.55,165.63,3478.08,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1324','Amazon - Seller Central','2026-08-03 18:56+05:30','Mehul Shukla','prepaid',6594.0,659.4,296.74,6231.34,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1325','Amazon - Seller Central','2026-08-03 18:00+05:30','Mehul Shukla','prepaid',4446.0,0.0,222.3,4668.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1326','Amazon - Seller Central','2026-08-03 15:33+05:30','Dev Trivedi','prepaid',1999.0,0.0,99.95,2098.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1321','WTOP-PCH-L',2,599,119.8,53.91),
('AMAZ-1321','WKRT-PNK-L',1,849,84.9,38.21),
('AMAZ-1321','MCHN-OLV-34',1,1199,119.9,53.96),
('AMAZ-1321','WLEG-BLK-M',1,349,34.9,15.71),
('AMAZ-1322','MSHC-RED-M',3,899,269.7,121.37),
('AMAZ-1322','MPOL-NVY-XL',1,699,69.9,31.46),
('AMAZ-1322','MPOL-MRN-L',1,699,69.9,31.46),
('SHOP-1257','GLEG-BLK-67Y',1,279,0.0,13.95),
('SHOP-1257','BSHF-WHT-67Y',2,599,0.0,59.9),
('FLIP-1251','WSAR-RED-FREE',1,2199,329.85,93.46),
('FLIP-1251','MKUR-MUS-L',1,1099,164.85,46.71),
('AMAZ-1323','BKUR-CRM-89Y',2,949,0.0,94.9),
('FLIP-1252','MPOL-MRN-M',3,699,0.0,104.85),
('FLIP-1252','MKUR-MUS-XL',2,1099,0.0,109.9),
('FLIP-1252','MTRK-BLK-XL',1,649,0.0,32.45),
('FLIP-1252','MTEE-WHT-M',1,449,0.0,22.45),
('FLIP-1253','MHOD-GRY-M',1,1299,194.85,55.21),
('FLIP-1253','MHOD-BLK-XL',2,1299,389.7,110.42),
('AMAZ-1324','MCHN-OLV-34',1,1199,119.9,53.96),
('AMAZ-1324','MCHN-KHK-30',3,1199,359.7,161.87),
('AMAZ-1324','MSHC-RED-XL',2,899,179.8,80.91),
('AMAZ-1325','WDRS-FLP-M',2,1499,0.0,149.9),
('AMAZ-1325','WPAL-YLW-M',1,599,0.0,29.95),
('AMAZ-1325','WKRT-PNK-S',1,849,0.0,42.45),
('AMAZ-1326','GLHG-TEL-45Y',1,1999,0.0,99.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1257','Ecom Express - Udhna Hub'),
('FLIP-1253','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('SHOP-1200', 'damaged', 'quarantined');
select pg_temp.ret_dispo('AMAZ-1264', 'damaged', 'quarantined');
select pg_temp.ret_dispo('FLIP-1195', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1217', 'pickup');
select pg_temp.ret_set('AMAZ-1289', 'pickup');
select pg_temp.ret_set('FLIP-1222', 'pickup');
select pg_temp.cod_collect(array['AMAZ-1310']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260727', '2026-07-27', '2026-08-02', array['AMAZ-1283','AMAZ-1286','AMAZ-1288','AMAZ-1289','AMAZ-1290','AMAZ-1293','AMAZ-1298','AMAZ-1300','AMAZ-1294','AMAZ-1297','AMAZ-1303','AMAZ-1304','AMAZ-1296','AMAZ-1299','AMAZ-1302','AMAZ-1305','AMAZ-1306','AMAZ-1307','AMAZ-1309','AMAZ-1311']::text[], array['AMAZ-1268','AMAZ-1269','AMAZ-1280','AMAZ-1264']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260727', '2026-07-27', '2026-08-02', array['FLIP-1220','FLIP-1215','FLIP-1217','FLIP-1222','FLIP-1226','FLIP-1228','FLIP-1224','FLIP-1229','FLIP-1231','FLIP-1234']::text[], array['FLIP-1191','FLIP-1190','FLIP-1195']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260727', '2026-07-27', '2026-08-02', array['SHOP-1226','SHOP-1228','SHOP-1233','SHOP-1235','SHOP-1237','SHOP-1238','SHOP-1239','SHOP-1242','SHOP-1240','SHOP-1245']::text[], array[]::text[]);
select pg_temp.claim_new('AMAZ-1264', 'damaged_return', 755.37, '2026-09-02');
select pg_temp.claim_step('FLIP-1190', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Tue 04 Aug 2026
select pg_temp.day('2026-08-04');
select pg_temp.grn_new('Weekly replenishment 27 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R122)', 'DC-TKF-0166', '[{"sku":"MTEE-BLK-M","q":6,"a":6,"r":0},{"sku":"MTEE-WHT-M","q":6,"a":6,"r":0},{"sku":"MTRK-BLK-L","q":10,"a":10,"r":0},{"sku":"WLEG-MAR-M","q":8,"a":8,"r":0},{"sku":"WLEG-NVY-M","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1258','Shopify - Main Store','2026-08-04 17:47+05:30','Aditi Joshi','prepaid',1477.0,147.7,66.47,1395.77,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1259','Shopify - Main Store','2026-08-04 21:12+05:30','Vivek Singh','cod',11696.0,0.0,2014.54,13710.54,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1327','Amazon - Seller Central','2026-08-04 13:01+05:30','Jigar Chauhan','prepaid',2596.0,259.6,116.83,2453.23,'cancelled','refunded','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1328','Amazon - Seller Central','2026-08-04 11:33+05:30','Meghna Rao','cod',329.0,32.9,14.81,310.91,'shipped','pending','Rajasthan','Surat Main Warehouse'),
('AMAZ-1329','Amazon - Seller Central','2026-08-04 09:42+05:30','Rahul Bhatt','prepaid',3695.0,0.0,184.75,3879.75,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1254','Flipkart - Seller Hub','2026-08-04 18:37+05:30','Anjali Verma','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1260','Shopify - Main Store','2026-08-04 21:42+05:30','Harsh Modi','prepaid',1898.0,189.8,85.41,1793.61,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1255','Flipkart - Seller Hub','2026-08-04 15:24+05:30','Aarav Mehta','cod',3295.0,0.0,164.75,3459.75,'delivered','pending','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1258','WTOP-PCH-S',2,599,119.8,53.91),
('SHOP-1258','GLEG-PNK-67Y',1,279,27.9,12.56),
('SHOP-1259','WLHG-RED-M',2,5499,0.0,1979.64),
('SHOP-1259','WLEG-NVY-L',2,349,0.0,34.9),
('AMAZ-1327','MTRK-BLK-L',3,649,194.7,87.62),
('AMAZ-1327','MTRK-BLK-M',1,649,64.9,29.21),
('AMAZ-1328','BTEE-RED-67Y',1,329,32.9,14.81),
('AMAZ-1329','WKRT-PNK-S',1,849,0.0,42.45),
('AMAZ-1329','WDUP-GLD-FREE',2,449,0.0,44.9),
('AMAZ-1329','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1329','WJNS-IND-32',1,1349,0.0,67.45),
('FLIP-1254','MJNS-BLK-34',1,1399,0.0,69.95),
('SHOP-1260','BKUR-MUS-45Y',2,949,189.8,85.41),
('FLIP-1255','MPOL-MRN-M',1,699,0.0,34.95),
('FLIP-1255','MTRK-BLK-L',1,649,0.0,32.45),
('FLIP-1255','MTRK-BLK-XL',3,649,0.0,97.35)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1259','Delhivery - Sachin GIDC Surat'),
('FLIP-1255','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_set('AMAZ-1301', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1252']::text[]);
select pg_temp.settle_pay('FLK-STL-20260720', 0.0);
select pg_temp.claim_recover('FLIP-1114', 'lost_shipment', 'CLAIM-CR-FLIP-1114');
select pg_temp.claim_step('FLIP-1168', 'lost_shipment', 'claimed', null);
select pg_temp.claim_step('AMAZ-1280', 'other', 'claimed', null);
select pg_temp.retime();

-- Wed 05 Aug 2026
select pg_temp.day('2026-08-05');
select pg_temp.bill_po('Weekly replenishment 27 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R122)', 'TKF/26/0396', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1261','Shopify - Main Store','2026-08-05 15:34+05:30','Jigar Chauhan','prepaid',2646.0,396.9,112.46,2361.56,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1262','Shopify - Main Store','2026-08-05 13:38+05:30','Yash Vora','prepaid',1228.0,122.8,55.27,1160.47,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1330','Amazon - Seller Central','2026-08-05 17:35+05:30','Amit Sethi','prepaid',279.0,27.9,12.56,263.66,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1256','Flipkart - Seller Hub','2026-08-05 14:45+05:30','Mehul Shukla','prepaid',8497.0,1274.55,1200.7,8423.15,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1257','Flipkart - Seller Hub','2026-08-05 13:54+05:30','Dev Trivedi','prepaid',3896.0,0.0,194.8,4090.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1263','Shopify - Main Store','2026-08-05 17:32+05:30','Sejal Kapadia','cod',5174.0,0.0,258.7,5432.7,'shipped','pending','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1331','Amazon - Seller Central','2026-08-05 12:29+05:30','Karan Malhotra','prepaid',1216.0,0.0,60.8,1276.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1258','Flipkart - Seller Hub','2026-08-05 20:36+05:30','Bhavna Solanki','prepaid',2745.0,0.0,137.25,2882.25,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1261','WTOP-PCH-S',1,599,89.85,25.46),
('SHOP-1261','WKRT-PNK-XL',1,849,127.35,36.08),
('SHOP-1261','WTOP-WHT-M',2,599,179.7,50.92),
('SHOP-1262','GLEG-PNK-45Y',1,279,27.9,12.56),
('SHOP-1262','BKUR-MUS-45Y',1,949,94.9,42.71),
('AMAZ-1330','GLEG-PNK-67Y',1,279,27.9,12.56),
('FLIP-1256','MSHC-GRN-L',1,899,134.85,38.21),
('FLIP-1256','MBLZ-NVY-40',2,3799,1139.7,1162.49),
('FLIP-1257','GLHG-TEL-89Y',1,1999,0.0,99.95),
('FLIP-1257','MTRK-BLK-L',2,649,0.0,64.9),
('FLIP-1257','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1263','BTRK-BLK-1011Y',2,999,0.0,99.9),
('SHOP-1263','BKUR-CRM-67Y',1,949,0.0,47.45),
('SHOP-1263','BKUR-CRM-45Y',2,949,0.0,94.9),
('SHOP-1263','BTEE-BLU-67Y',1,329,0.0,16.45),
('AMAZ-1331','GLEG-PNK-89Y',2,279,0.0,27.9),
('AMAZ-1331','BTEE-RED-45Y',2,329,0.0,32.9),
('FLIP-1258','MPOL-MRN-M',2,699,0.0,69.9),
('FLIP-1258','MTEE-BLK-M',3,449,0.0,67.35)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_refund_d2c('SHOP-1200', 'UPI-REFUND-SHOP-1200');
select pg_temp.ret_set('FLIP-1217', 'in_transit');
select pg_temp.ret_set('AMAZ-1289', 'in_transit');
select pg_temp.ret_set('FLIP-1222', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1241']::text[]);
select pg_temp.cod_collect(array['SHOP-1249']::text[]);
select pg_temp.cod_collect(array['FLIP-1249']::text[]);
select pg_temp.settle_pay('SHP-STL-20260727', 0.0);
select pg_temp.retime();

-- Thu 06 Aug 2026
select pg_temp.day('2026-08-06');
select pg_temp.grn_new('Weekly replenishment 27 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R121)', 'DC-TKF-0163', '[{"sku":"MTEE-WHT-M","q":6,"a":6,"r":0},{"sku":"BTEE-BLU-67Y","q":8,"a":8,"r":0},{"sku":"BTEE-RED-45Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1332','Amazon - Seller Central','2026-08-06 09:00+05:30','Kiran Naik','prepaid',3896.0,0.0,194.8,4090.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1259','Flipkart - Seller Hub','2026-08-06 14:59+05:30','Dev Trivedi','prepaid',558.0,0.0,27.9,585.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1264','Shopify - Main Store','2026-08-06 17:35+05:30','Kavya Menon','prepaid',5499.0,549.9,890.84,5839.94,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1333','Amazon - Seller Central','2026-08-06 21:48+05:30','Manav Joshi','prepaid',2497.0,124.85,118.61,2490.76,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1334','Amazon - Seller Central','2026-08-06 18:23+05:30','Vivek Singh','prepaid',3298.0,494.7,438.41,3241.71,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1260','Flipkart - Seller Hub','2026-08-06 19:51+05:30','Vivek Singh','prepaid',1577.0,236.55,67.02,1407.47,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1335','Amazon - Seller Central','2026-08-06 21:30+05:30','Isha Gupta','prepaid',3345.0,334.5,150.54,3161.04,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1261','Flipkart - Seller Hub','2026-08-06 10:23+05:30','Chirag Zaveri','cod',1678.0,251.7,71.32,1497.62,'delivered','pending','West Bengal','Surat Main Warehouse'),
('FLIP-1262','Flipkart - Seller Hub','2026-08-06 15:40+05:30','Isha Gupta','cod',649.0,0.0,32.45,681.45,'delivered','pending','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1332','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1332','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1332','WJNS-IND-30',2,1349,0.0,134.9),
('FLIP-1259','GLEG-BLK-89Y',1,279,0.0,13.95),
('FLIP-1259','GLEG-BLK-45Y',1,279,0.0,13.95),
('SHOP-1264','WLHG-RED-L',1,5499,549.9,890.84),
('AMAZ-1333','BSHF-WHT-67Y',1,599,29.95,28.45),
('AMAZ-1333','BKUR-CRM-67Y',2,949,94.9,90.16),
('AMAZ-1334','WJKT-BLK-M',1,2699,404.85,412.95),
('AMAZ-1334','WTOP-PCH-L',1,599,89.85,25.46),
('FLIP-1260','BKUR-CRM-89Y',1,949,142.35,40.33),
('FLIP-1260','GLEG-PNK-45Y',1,279,41.85,11.86),
('FLIP-1260','BSHT-GRY-89Y',1,349,52.35,14.83),
('AMAZ-1335','MPOL-MRN-L',1,699,69.9,31.46),
('AMAZ-1335','MHOD-GRY-M',1,1299,129.9,58.46),
('AMAZ-1335','MTEE-WHT-M',3,449,134.7,60.62),
('FLIP-1261','MJNS-IND-34',1,1399,209.85,59.46),
('FLIP-1261','GLEG-BLK-67Y',1,279,41.85,11.86),
('FLIP-1262','MTRK-BLK-L',1,649,0.0,32.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1261','Bluedart - Surat City'),
('FLIP-1262','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.cod_collect(array['SHOP-1246']::text[]);
select pg_temp.cod_collect(array['FLIP-1246']::text[]);
select pg_temp.cod_collect(array['FLIP-1253']::text[]);
select pg_temp.claim_step('AMAZ-1264', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Fri 07 Aug 2026
select pg_temp.day('2026-08-07');
select pg_temp.bill_po('Weekly replenishment 27 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R121)', 'TKF/26/0392', 1);
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Krishna Denim Works (ref R124)', 'DC-KDW-0124', '[{"sku":"MJNS-BLK-32","q":6,"a":6,"r":0},{"sku":"MCHN-OLV-34","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Shree Ambika Textiles (ref R128)', 'DC-SAT-0118', '[{"sku":"WKRT-PNK-M","q":10,"a":9,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1263','Flipkart - Seller Hub','2026-08-07 15:39+05:30','Karan Malhotra','prepaid',3998.0,0.0,199.9,4197.9,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1336','Amazon - Seller Central','2026-08-07 22:34+05:30','Aditi Joshi','prepaid',2097.0,0.0,104.85,2201.85,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1337','Amazon - Seller Central','2026-08-07 15:30+05:30','Anjali Verma','prepaid',599.0,89.85,25.46,534.61,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1264','Flipkart - Seller Hub','2026-08-07 20:21+05:30','Mehul Shukla','prepaid',1199.0,179.85,50.96,1070.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1338','Amazon - Seller Central','2026-08-07 09:12+05:30','Shreya Banerjee','prepaid',2698.0,269.8,121.42,2549.62,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1265','Shopify - Main Store','2026-08-07 13:56+05:30','Divya Nair','cod',4346.0,434.6,195.58,4106.98,'shipped','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1339','Amazon - Seller Central','2026-08-07 21:02+05:30','Kunal Desai','prepaid',6098.0,0.0,1019.77,7117.77,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1266','Shopify - Main Store','2026-08-07 09:48+05:30','Shreya Banerjee','prepaid',1947.0,0.0,97.35,2044.35,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1263','GLHG-TEL-45Y',2,1999,0.0,199.9),
('AMAZ-1336','MPOL-NVY-M',3,699,0.0,104.85),
('AMAZ-1337','WPAL-WHT-M',1,599,89.85,25.46),
('FLIP-1264','MCHN-OLV-32',1,1199,179.85,50.96),
('AMAZ-1338','WDRS-FLR-S',1,1499,149.9,67.46),
('AMAZ-1338','MCHN-OLV-32',1,1199,119.9,53.96),
('SHOP-1265','MTRK-BLK-XL',1,649,64.9,29.21),
('SHOP-1265','WDRS-FLR-L',1,1499,149.9,67.46),
('SHOP-1265','MKUR-MUS-L',2,1099,219.8,98.91),
('AMAZ-1339','WLHG-RED-M',1,5499,0.0,989.82),
('AMAZ-1339','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1266','WTOP-PCH-L',2,599,0.0,59.9),
('SHOP-1266','GFRK-PNK-45Y',1,749,0.0,37.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('FLIP-1217');
select pg_temp.rto_recv('SHOP-1234', 'damaged', 'quarantined');
select pg_temp.ret_recv('FLIP-1222');
select pg_temp.rto_recv('AMAZ-1301', 'damaged', 'quarantined');
select pg_temp.ret_new('AMAZ-1304', 'Size did not fit', 'webhook');
select pg_temp.cod_collect(array['FLIP-1247']::text[]);
select pg_temp.cod_collect(array['SHOP-1256']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-07AUG', array['FLIP-1221','AMAZ-1310','SHOP-1249']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-07AUG', array['SHOP-1241','SHOP-1244']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-07AUG', array['SHOP-1243','SHOP-1252','FLIP-1249']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-07AUG', array['AMAZ-1292','FLIP-1225','FLIP-1230','FLIP-1241']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-07AUG', array['FLIP-1223','FLIP-1227']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-08-10', 'ICIC000000885788', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-08-10', 'ICIC000000885862', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-08-10', 'ICIC000000885924', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-08-10', 'ICIC000000885960', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-08-10', 'ICIC000000886055', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-08-10', 'ICIC000000886128', 1);
select pg_temp.retime();

-- Sat 08 Aug 2026
select pg_temp.day('2026-08-08');
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Krishna Denim Works (ref R124)', 'KDW/26/0296', 1);
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Little Stitch Garments (ref R125)', 'DC-LSG-0112', '[{"sku":"BKUR-MUS-67Y","q":8,"a":8,"r":0},{"sku":"GNGT-PNK-89Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Shree Ambika Textiles (ref R128)', 'SAT/26/0286', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1267','Shopify - Main Store','2026-08-08 11:28+05:30','Foram Thakkar','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1340','Amazon - Seller Central','2026-08-08 18:11+05:30','Bhavna Solanki','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1268','Shopify - Main Store','2026-08-08 10:33+05:30','Meghna Rao','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1269','Shopify - Main Store','2026-08-08 09:09+05:30','Kiran Naik','prepaid',698.0,34.9,33.16,696.26,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1265','Flipkart - Seller Hub','2026-08-08 11:16+05:30','Chirag Zaveri','cod',6495.0,649.5,292.28,6137.78,'delivered','pending','West Bengal','Surat Main Warehouse'),
('SHOP-1270','Shopify - Main Store','2026-08-08 18:19+05:30','Meghna Rao','cod',2596.0,259.6,116.83,2453.23,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1341','Amazon - Seller Central','2026-08-08 17:33+05:30','Mitul Dave','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1266','Flipkart - Seller Hub','2026-08-08 17:27+05:30','Nikhil Pandey','cod',977.0,0.0,48.85,1025.85,'delivered','pending','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1267','MSHC-RED-M',1,899,0.0,44.95),
('SHOP-1267','MCHN-KHK-30',1,1199,0.0,59.95),
('AMAZ-1340','BSHT-GRY-67Y',1,349,0.0,17.45),
('SHOP-1268','MCHN-OLV-34',1,1199,119.9,53.96),
('SHOP-1269','WLEG-MAR-L',2,349,34.9,33.16),
('FLIP-1265','MHOD-GRY-M',1,1299,129.9,58.46),
('FLIP-1265','MCHN-OLV-34',2,1199,239.8,107.91),
('FLIP-1265','MJNS-BLK-32',2,1399,279.8,125.91),
('SHOP-1270','BSHT-GRY-89Y',2,349,69.8,31.41),
('SHOP-1270','BKUR-CRM-45Y',1,949,94.9,42.71),
('SHOP-1270','BKUR-CRM-89Y',1,949,94.9,42.71),
('AMAZ-1341','MTRK-BLK-M',1,649,0.0,32.45),
('FLIP-1266','GTOP-YLW-67Y',2,349,0.0,34.9),
('FLIP-1266','GLEG-PNK-89Y',1,279,0.0,13.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1265','Xpressbees - Pandesara'),
('SHOP-1270','Xpressbees - Pandesara'),
('FLIP-1266','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1217', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1304', 'approved');
select pg_temp.cod_collect(array['SHOP-1255']::text[]);
select pg_temp.cod_collect(array['SHOP-1257']::text[]);
select pg_temp.cod_collect(array['SHOP-1259']::text[]);
select pg_temp.rto_new('AMAZ-1328', 'AWB31000846', 'Delivery attempts exhausted');
select pg_temp.claim_new('FLIP-1217', 'damaged_return', 597.24, '2026-09-07');
select pg_temp.retime();

-- Sun 09 Aug 2026
select pg_temp.day('2026-08-09');
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Krishna Denim Works (ref R123)', 'DC-KDW-0121', '[{"sku":"MJNS-BLK-32","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Little Stitch Garments (ref R125)', 'LSG/26/0270', 1);
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Rajdhani Shirting Mills (ref R127)', 'DC-RSM-0124', '[{"sku":"MSHF-WHT-L","q":6,"a":6,"r":0},{"sku":"MSHC-RED-XL","q":20,"a":19,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1342','Amazon - Seller Central','2026-08-09 14:26+05:30','Divya Nair','prepaid',3455.0,0.0,172.75,3627.75,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1271','Shopify - Main Store','2026-08-09 09:29+05:30','Sagar Rathod','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1272','Shopify - Main Store','2026-08-09 20:27+05:30','Divya Nair','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1267','Flipkart - Seller Hub','2026-08-09 20:21+05:30','Anjali Verma','prepaid',1028.0,102.8,46.27,971.47,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1273','Shopify - Main Store','2026-08-09 10:21+05:30','Rohit Iyer','cod',1499.0,74.95,71.2,1495.25,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1343','Amazon - Seller Central','2026-08-09 19:02+05:30','Sonal Parekh','prepaid',4795.0,479.5,215.79,4531.29,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1268','Flipkart - Seller Hub','2026-08-09 21:13+05:30','Pratik Lad','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1274','Shopify - Main Store','2026-08-09 22:26+05:30','Shreya Banerjee','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1344','Amazon - Seller Central','2026-08-09 13:51+05:30','Sanjay Gajera','prepaid',1837.0,91.85,87.26,1832.41,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1269','Flipkart - Seller Hub','2026-08-09 18:38+05:30','Nikhil Pandey','prepaid',6643.0,996.45,282.33,5928.88,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1342','WJNS-IND-28',1,1349,0.0,67.45),
('AMAZ-1342','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1342','BTEE-RED-89Y',2,329,0.0,32.9),
('AMAZ-1342','WKRT-PNK-L',1,849,0.0,42.45),
('SHOP-1271','BKUR-MUS-67Y',1,949,0.0,47.45),
('SHOP-1272','MTRK-BLK-L',1,649,0.0,32.45),
('FLIP-1267','GFRK-LIL-67Y',1,749,74.9,33.71),
('FLIP-1267','GLEG-BLK-45Y',1,279,27.9,12.56),
('SHOP-1273','WDRS-FLP-L',1,1499,74.95,71.2),
('AMAZ-1343','MJNS-BLK-32',1,1399,139.9,62.96),
('AMAZ-1343','MCHN-KHK-34',1,1199,119.9,53.96),
('AMAZ-1343','MSHC-RED-L',1,899,89.9,40.46),
('AMAZ-1343','MTRK-BLK-M',2,649,129.8,58.41),
('FLIP-1268','GLEG-PNK-67Y',1,279,0.0,13.95),
('SHOP-1274','BKUR-CRM-89Y',2,949,0.0,94.9),
('AMAZ-1344','GJNS-IND-45Y',2,779,77.9,74.01),
('AMAZ-1344','GLEG-PNK-67Y',1,279,13.95,13.25),
('FLIP-1269','MCHN-OLV-34',2,1199,359.7,101.92),
('FLIP-1269','MTRK-BLK-XL',1,649,97.35,27.58),
('FLIP-1269','MSHC-GRN-XL',3,899,404.55,114.62),
('FLIP-1269','MSHC-RED-M',1,899,134.85,38.21)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1273','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1289');
select pg_temp.ret_dispo('FLIP-1222', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1304', 'pickup');
select pg_temp.ret_new('AMAZ-1313', 'Colour different from photo', 'webhook');
select pg_temp.ret_new('AMAZ-1318', 'Wrong item delivered', 'webhook');
select pg_temp.settle_pay('AMZ-STL-20260727', 0.0);
select pg_temp.retime();

-- Mon 10 Aug 2026
select pg_temp.day('2026-08-10');
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Krishna Denim Works (ref R123)', 'KDW/26/0292', 1);
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Rajdhani Shirting Mills (ref R127)', 'RSM/26/0300', 1);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Krishna Denim Works (ref R131)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-32","q":12},{"sku":"MCHN-KHK-30","q":16},{"sku":"MCHN-OLV-34","q":12},{"sku":"WJNS-IND-30","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Little Stitch Garments (ref R132)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"BSHT-GRY-67Y","q":6},{"sku":"BKUR-MUS-45Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Little Stitch Garments (ref R133)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLR-L","q":6},{"sku":"BKUR-CRM-45Y","q":8},{"sku":"GLHG-TEL-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Ludhiana Winter Wear Co (ref R134)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"MHOD-GRY-M","q":8},{"sku":"BTRK-BLK-1011Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Rajdhani Shirting Mills (ref R135)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MBLZ-NVY-40","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Rajdhani Shirting Mills (ref R136)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-RED-M","q":12},{"sku":"MKUR-MUS-L","q":6},{"sku":"MKUR-MUS-XL","q":8},{"sku":"BSHF-WHT-67Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Shree Ambika Textiles (ref R137)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WKRT-PNK-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Shree Ambika Textiles (ref R138)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R139)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTRK-BLK-M","q":6},{"sku":"GTOP-YLW-67Y","q":8},{"sku":"GLEG-BLK-45Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 10 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R140)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-BLK-M","q":6},{"sku":"MPOL-MRN-M","q":10},{"sku":"MPOL-MRN-L","q":8},{"sku":"MTRK-BLK-XL","q":12},{"sku":"WTOP-PCH-S","q":20},{"sku":"GLEG-BLK-89Y","q":8}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1270','Flipkart - Seller Hub','2026-08-10 18:34+05:30','Ritu Saxena','prepaid',2278.0,341.7,96.82,2033.12,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1345','Amazon - Seller Central','2026-08-10 16:23+05:30','Foram Thakkar','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1275','Shopify - Main Store','2026-08-10 10:16+05:30','Aarav Mehta','prepaid',7344.0,0.0,367.2,7711.2,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1276','Shopify - Main Store','2026-08-10 14:06+05:30','Aarav Mehta','prepaid',2998.0,449.7,127.42,2675.72,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1277','Shopify - Main Store','2026-08-10 20:48+05:30','Harsh Modi','cod',6098.0,609.8,917.8,6406.0,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1278','Shopify - Main Store','2026-08-10 15:19+05:30','Vipul Gandhi','cod',2798.0,139.9,132.9,2791.0,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1271','Flipkart - Seller Hub','2026-08-10 10:36+05:30','Ritu Saxena','prepaid',1099.0,0.0,54.95,1153.95,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('SHOP-1279','Shopify - Main Store','2026-08-10 19:18+05:30','Kavya Menon','cod',4244.0,212.2,201.6,4233.4,'shipped','pending','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1280','Shopify - Main Store','2026-08-10 09:12+05:30','Karan Malhotra','prepaid',749.0,0.0,37.45,786.45,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1270','GLHG-RED-45Y',1,1999,299.85,84.96),
('FLIP-1270','GLEG-BLK-89Y',1,279,41.85,11.86),
('AMAZ-1345','BKUR-CRM-67Y',1,949,0.0,47.45),
('AMAZ-1345','BKUR-MUS-45Y',1,949,0.0,47.45),
('SHOP-1275','BKUR-MUS-89Y',1,949,0.0,47.45),
('SHOP-1275','MCHN-OLV-34',2,1199,0.0,119.9),
('SHOP-1275','MCHN-KHK-34',1,1199,0.0,59.95),
('SHOP-1275','MJNS-BLK-32',2,1399,0.0,139.9),
('SHOP-1276','WDRS-FLP-L',1,1499,224.85,63.71),
('SHOP-1276','WDRS-FLP-M',1,1499,224.85,63.71),
('SHOP-1277','WLHG-RED-L',1,5499,549.9,890.84),
('SHOP-1277','WTOP-PCH-M',1,599,59.9,26.96),
('SHOP-1278','MJNS-IND-34',1,1399,69.95,66.45),
('SHOP-1278','MJNS-IND-32',1,1399,69.95,66.45),
('FLIP-1271','MKUR-MUS-L',1,1099,0.0,54.95),
('SHOP-1279','MTEE-WHT-L',2,449,44.9,42.66),
('SHOP-1279','GFRK-LIL-89Y',2,749,74.9,71.16),
('SHOP-1279','MTRK-BLK-M',1,649,32.45,30.83),
('SHOP-1279','MCHN-KHK-34',1,1199,59.95,56.95),
('SHOP-1280','GFRK-LIL-67Y',1,749,0.0,37.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1277','DTDC - Ring Road Surat'),
('SHOP-1278','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1289', 'missing', 'claimed');
select pg_temp.ret_new('FLIP-1237', 'Wrong item delivered', 'webhook');
select pg_temp.ret_set('AMAZ-1313', 'approved');
select pg_temp.ret_set('AMAZ-1318', 'approved');
select pg_temp.rto_set('AMAZ-1328', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1255']::text[]);
select pg_temp.cod_collect(array['FLIP-1261']::text[]);
select pg_temp.cod_collect(array['FLIP-1262']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260803', '2026-08-03', '2026-08-09', array['AMAZ-1313','AMAZ-1314','AMAZ-1312','AMAZ-1317','AMAZ-1318','AMAZ-1319','AMAZ-1322','AMAZ-1324','AMAZ-1315','AMAZ-1316','AMAZ-1320','AMAZ-1321','AMAZ-1323','AMAZ-1326','AMAZ-1325','AMAZ-1329','AMAZ-1330','AMAZ-1334','AMAZ-1335']::text[], array['AMAZ-1289']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260803', '2026-08-03', '2026-08-09', array['FLIP-1232','FLIP-1233','FLIP-1235','FLIP-1237','FLIP-1238','FLIP-1239','FLIP-1242','FLIP-1236','FLIP-1243','FLIP-1248','FLIP-1240','FLIP-1245','FLIP-1250','FLIP-1244','FLIP-1251','FLIP-1252','FLIP-1256','FLIP-1258','FLIP-1257','FLIP-1260']::text[], array['FLIP-1217','FLIP-1222']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260803', '2026-08-03', '2026-08-09', array['SHOP-1247','SHOP-1251','SHOP-1253','SHOP-1248','SHOP-1250','SHOP-1258','SHOP-1260','SHOP-1254','SHOP-1261','SHOP-1262','SHOP-1264']::text[], array[]::text[]);
select pg_temp.claim_new('AMAZ-1289', 'lost_shipment', 1940.4, '2026-09-09');
select pg_temp.retime();

-- Tue 11 Aug 2026
select pg_temp.day('2026-08-11');
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Krishna Denim Works (ref R124)', 'DC-KDW-0127', '[{"sku":"MJNS-BLK-32","q":4,"a":4,"r":0},{"sku":"MCHN-OLV-34","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1346','Amazon - Seller Central','2026-08-11 15:21+05:30','Sanjay Gajera','prepaid',279.0,41.85,11.86,249.01,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1347','Amazon - Seller Central','2026-08-11 10:16+05:30','Foram Thakkar','prepaid',987.0,0.0,49.35,1036.35,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1281','Shopify - Main Store','2026-08-11 09:58+05:30','Rahul Bhatt','cod',549.0,27.45,26.08,547.63,'shipped','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1282','Shopify - Main Store','2026-08-11 20:44+05:30','Divya Nair','cod',698.0,69.8,31.41,659.61,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1348','Amazon - Seller Central','2026-08-11 09:33+05:30','Sagar Rathod','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1349','Amazon - Seller Central','2026-08-11 15:04+05:30','Sagar Rathod','prepaid',4196.0,0.0,209.8,4405.8,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1350','Amazon - Seller Central','2026-08-11 21:31+05:30','Ritu Saxena','prepaid',5997.0,0.0,299.85,6296.85,'delivered','paid','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1346','GLEG-BLK-89Y',1,279,41.85,11.86),
('AMAZ-1347','BTEE-RED-67Y',3,329,0.0,49.35),
('SHOP-1281','GNGT-PNK-45Y',1,549,27.45,26.08),
('SHOP-1282','WLEG-BLK-M',2,349,69.8,31.41),
('AMAZ-1348','WKRT-PNK-M',1,849,0.0,42.45),
('AMAZ-1349','WPAL-WHT-L',1,599,0.0,29.95),
('AMAZ-1349','WDRS-FLP-S',2,1499,0.0,149.9),
('AMAZ-1349','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1350','GLHG-RED-67Y',3,1999,0.0,299.85)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1282','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1304', 'in_transit');
select pg_temp.ret_set('FLIP-1237', 'approved');
select pg_temp.ret_set('AMAZ-1313', 'pickup');
select pg_temp.ret_new('SHOP-1247', 'Item arrived damaged', 'manual');
select pg_temp.ret_set('AMAZ-1318', 'pickup');
select pg_temp.ret_new('FLIP-1256', 'Item arrived damaged', 'webhook');
select pg_temp.rto_new('SHOP-1263', 'AWB31000861', 'Address incomplete');
select pg_temp.settle_pay('FLK-STL-20260727', 0.0);
select pg_temp.claim_step('FLIP-1217', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Wed 12 Aug 2026
select pg_temp.day('2026-08-12');
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Krishna Denim Works (ref R124)', 'KDW/26/0309', 1);
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R129)', 'DC-TKF-0169', '[{"sku":"BTEE-BLU-67Y","q":10,"a":9,"r":1},{"sku":"GLEG-BLK-45Y","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1351','Amazon - Seller Central','2026-08-12 17:26+05:30','Aarav Mehta','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1272','Flipkart - Seller Hub','2026-08-12 11:33+05:30','Aarav Mehta','prepaid',4197.0,0.0,209.85,4406.85,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1273','Flipkart - Seller Hub','2026-08-12 10:31+05:30','Amit Sethi','prepaid',1298.0,0.0,64.9,1362.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1274','Flipkart - Seller Hub','2026-08-12 09:44+05:30','Aditi Joshi','cod',1999.0,299.85,84.96,1784.11,'shipped','pending','Delhi','Surat Main Warehouse'),
('FLIP-1275','Flipkart - Seller Hub','2026-08-12 14:35+05:30','Jigar Chauhan','prepaid',2277.0,113.85,108.15,2271.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1276','Flipkart - Seller Hub','2026-08-12 18:42+05:30','Pooja Jain','prepaid',1297.0,0.0,64.85,1361.85,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1283','Shopify - Main Store','2026-08-12 11:23+05:30','Vivek Singh','prepaid',4846.0,484.6,218.08,4579.48,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1277','Flipkart - Seller Hub','2026-08-12 18:04+05:30','Chirag Zaveri','prepaid',14696.0,0.0,2164.54,16860.54,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1352','Amazon - Seller Central','2026-08-12 16:11+05:30','Tanvi Rana','prepaid',2498.0,0.0,124.9,2622.9,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1351','WPAL-WHT-M',1,599,29.95,28.45),
('FLIP-1272','MJNS-BLK-32',1,1399,0.0,69.95),
('FLIP-1272','MJNS-IND-34',2,1399,0.0,139.9),
('FLIP-1273','MTRK-BLK-XL',2,649,0.0,64.9),
('FLIP-1274','GLHG-TEL-67Y',1,1999,299.85,84.96),
('FLIP-1275','MJNS-BLK-34',1,1399,69.95,66.45),
('FLIP-1275','WTOP-WHT-L',1,599,29.95,28.45),
('FLIP-1275','GLEG-BLK-45Y',1,279,13.95,13.25),
('FLIP-1276','WLEG-MAR-M',2,349,0.0,34.9),
('FLIP-1276','WTOP-PCH-S',1,599,0.0,29.95),
('SHOP-1283','MJNS-BLK-34',3,1399,419.7,188.87),
('SHOP-1283','MTRK-BLK-L',1,649,64.9,29.21),
('FLIP-1277','WSAR-BLU-FREE',1,2199,0.0,109.95),
('FLIP-1277','WDRS-FLR-L',1,1499,0.0,74.95),
('FLIP-1277','WLHG-RED-M',2,5499,0.0,1979.64),
('AMAZ-1352','MKUR-WHT-L',1,1099,0.0,54.95),
('AMAZ-1352','MJNS-BLK-30',1,1399,0.0,69.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_set('FLIP-1237', 'pickup');
select pg_temp.ret_set('SHOP-1247', 'approved');
select pg_temp.ret_set('FLIP-1256', 'approved');
select pg_temp.cod_collect(array['SHOP-1270']::text[]);
select pg_temp.settle_pay('SHP-STL-20260803', 0.0);
select pg_temp.retime();

-- Thu 13 Aug 2026
select pg_temp.day('2026-08-13');
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R129)', 'TKF/26/0404', 1);
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R130)', 'DC-TKF-0172', '[{"sku":"MTEE-BLK-M","q":6,"a":6,"r":0},{"sku":"WTOP-PCH-S","q":12,"a":12,"r":0},{"sku":"GLEG-BLK-89Y","q":12,"a":12,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Little Stitch Garments (ref R132)', 'DC-LSG-0115', '[{"sku":"BSHT-GRY-67Y","q":6,"a":6,"r":0},{"sku":"BKUR-MUS-45Y","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Little Stitch Garments (ref R133)', 'DC-LSG-0118', '[{"sku":"WDRS-FLR-L","q":4,"a":4,"r":0},{"sku":"BKUR-CRM-45Y","q":5,"a":5,"r":0},{"sku":"GLHG-TEL-45Y","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1284','Shopify - Main Store','2026-08-13 12:29+05:30','Sanjay Gajera','prepaid',1399.0,139.9,62.96,1322.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1278','Flipkart - Seller Hub','2026-08-13 14:57+05:30','Nikhil Pandey','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1285','Shopify - Main Store','2026-08-13 18:03+05:30','Prachi Kulkarni','prepaid',2175.0,108.75,103.32,2169.57,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1279','Flipkart - Seller Hub','2026-08-13 22:43+05:30','Chirag Zaveri','prepaid',3645.0,0.0,182.25,3827.25,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1286','Shopify - Main Store','2026-08-13 13:43+05:30','Neha Patel','cod',329.0,0.0,16.45,345.45,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1280','Flipkart - Seller Hub','2026-08-13 15:30+05:30','Shreya Banerjee','prepaid',1847.0,0.0,92.35,1939.35,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1287','Shopify - Main Store','2026-08-13 10:52+05:30','Nikhil Pandey','prepaid',3446.0,344.6,155.08,3256.48,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1288','Shopify - Main Store','2026-08-13 09:13+05:30','Manav Joshi','cod',3397.0,339.7,152.88,3210.18,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1289','Shopify - Main Store','2026-08-13 11:11+05:30','Vivek Singh','cod',649.0,0.0,32.45,681.45,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1353','Amazon - Seller Central','2026-08-13 11:30+05:30','Sejal Kapadia','prepaid',3197.0,479.55,135.88,2853.33,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1290','Shopify - Main Store','2026-08-13 10:40+05:30','Anjali Verma','prepaid',1186.0,0.0,59.3,1245.3,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1354','Amazon - Seller Central','2026-08-13 15:47+05:30','Prachi Kulkarni','prepaid',1698.0,0.0,84.9,1782.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1284','MJNS-BLK-34',1,1399,139.9,62.96),
('FLIP-1278','MTRK-BLK-L',1,649,0.0,32.45),
('SHOP-1285','WLEG-BLK-M',2,349,34.9,33.16),
('SHOP-1285','WTOP-WHT-L',2,599,59.9,56.91),
('SHOP-1285','GLEG-PNK-45Y',1,279,13.95,13.25),
('FLIP-1279','BSHF-WHT-89Y',2,599,0.0,59.9),
('FLIP-1279','BKUR-MUS-67Y',1,949,0.0,47.45),
('FLIP-1279','GFRK-LIL-89Y',2,749,0.0,74.9),
('SHOP-1286','BTEE-BLU-67Y',1,329,0.0,16.45),
('FLIP-1280','GFRK-PNK-67Y',2,749,0.0,74.9),
('FLIP-1280','GTOP-WHT-89Y',1,349,0.0,17.45),
('SHOP-1287','BKUR-MUS-45Y',1,949,94.9,42.71),
('SHOP-1287','BSHF-WHT-89Y',1,599,59.9,26.96),
('SHOP-1287','BKUR-CRM-67Y',2,949,189.8,85.41),
('SHOP-1288','MHOD-BLK-M',1,1299,129.9,58.46),
('SHOP-1288','MSHF-SKY-XL',1,999,99.9,44.96),
('SHOP-1288','MKUR-WHT-XL',1,1099,109.9,49.46),
('SHOP-1289','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1353','BSHF-WHT-45Y',1,599,89.85,25.46),
('AMAZ-1353','MCHN-KHK-30',1,1199,179.85,50.96),
('AMAZ-1353','MJNS-IND-34',1,1399,209.85,59.46),
('SHOP-1290','GLEG-PNK-45Y',2,279,0.0,27.9),
('SHOP-1290','GLEG-BLK-89Y',1,279,0.0,13.95),
('SHOP-1290','GTOP-YLW-67Y',1,349,0.0,17.45),
('AMAZ-1354','GFRK-LIL-45Y',1,749,0.0,37.45),
('AMAZ-1354','BKUR-CRM-89Y',1,949,0.0,47.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1286','Bluedart - Surat City'),
('SHOP-1288','Delhivery - Sachin GIDC Surat'),
('SHOP-1289','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1313', 'in_transit');
select pg_temp.ret_set('SHOP-1247', 'pickup');
select pg_temp.ret_set('AMAZ-1318', 'in_transit');
select pg_temp.ret_new('AMAZ-1326', 'Customer changed mind', 'webhook');
select pg_temp.ret_set('FLIP-1256', 'pickup');
select pg_temp.rto_set('SHOP-1263', 'in_transit');
select pg_temp.ret_new('AMAZ-1337', 'Size did not fit', 'webhook');
select pg_temp.rto_new('SHOP-1265', 'AWB31000865', 'Address incomplete');
select pg_temp.cod_collect(array['FLIP-1266']::text[]);
select pg_temp.claim_step('AMAZ-1289', 'lost_shipment', 'claimed', null);
select pg_temp.retime();

-- Fri 14 Aug 2026
select pg_temp.day('2026-08-14');
select pg_temp.grn_new('Weekly replenishment 03 Aug 2026 - Ludhiana Winter Wear Co (ref R126)', 'DC-LWW-0061', '[{"sku":"BTRK-BLK-1011Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R130)', 'TKF/26/0408', 1);
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Little Stitch Garments (ref R132)', 'LSG/26/0278', 1);
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Little Stitch Garments (ref R133)', 'LSG/26/0285', 1);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Shree Ambika Textiles (ref R138)', 'DC-SAT-0124', '[{"sku":"WKRT-PNK-XL","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1291','Shopify - Main Store','2026-08-14 18:06+05:30','Neha Patel','prepaid',1498.0,0.0,74.9,1572.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1355','Amazon - Seller Central','2026-08-14 09:33+05:30','Heena Khan','prepaid',1848.0,0.0,92.4,1940.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1356','Amazon - Seller Central','2026-08-14 17:40+05:30','Yash Vora','prepaid',1399.0,69.95,66.45,1395.5,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1357','Amazon - Seller Central','2026-08-14 12:45+05:30','Kiran Naik','prepaid',698.0,69.8,31.41,659.61,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1291','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1291','MSHC-RED-L',1,899,0.0,44.95),
('AMAZ-1355','MSHF-WHT-L',1,999,0.0,49.95),
('AMAZ-1355','WKRT-PNK-XL',1,849,0.0,42.45),
('AMAZ-1356','MJNS-BLK-30',1,1399,69.95,66.45),
('AMAZ-1357','BSHT-GRY-45Y',2,349,69.8,31.41)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('AMAZ-1304');
select pg_temp.ret_set('FLIP-1237', 'in_transit');
select pg_temp.ret_set('AMAZ-1326', 'approved');
select pg_temp.rto_recv('AMAZ-1328', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1337', 'approved');
select pg_temp.cod_collect(array['FLIP-1265']::text[]);
select pg_temp.cod_collect(array['SHOP-1273']::text[]);
select pg_temp.rto_new('SHOP-1279', 'AWB31000872', 'Delivery attempts exhausted');
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-14AUG', array['SHOP-1246','SHOP-1259']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-14AUG', array['FLIP-1246','SHOP-1255','SHOP-1257','FLIP-1262']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-14AUG', array['SHOP-1256']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-14AUG', array['FLIP-1247','FLIP-1253','FLIP-1255','FLIP-1261']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-14AUG', array['SHOP-1270']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-08-17', 'ICIC000000886185', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-08-17', 'ICIC000000886241', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-08-17', 'ICIC000000886295', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-08-17', 'ICIC000000886327', 0.5);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-08-17', 'ICIC000000886350', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-08-17', 'ICIC000000886371', 1);
select pg_temp.retime();

-- Sat 15 Aug 2026
select pg_temp.day('2026-08-15');
select pg_temp.bill_po('Weekly replenishment 03 Aug 2026 - Ludhiana Winter Wear Co (ref R126)', 'LWW/26/0149', 1);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Krishna Denim Works (ref R131)', 'DC-KDW-0130', '[{"sku":"MJNS-BLK-32","q":12,"a":12,"r":0},{"sku":"MCHN-KHK-30","q":16,"a":16,"r":0},{"sku":"MCHN-OLV-34","q":12,"a":12,"r":0},{"sku":"WJNS-IND-30","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Rajdhani Shirting Mills (ref R135)', 'DC-RSM-0127', '[{"sku":"MBLZ-NVY-40","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Shree Ambika Textiles (ref R137)', 'DC-SAT-0121', '[{"sku":"WKRT-PNK-L","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Shree Ambika Textiles (ref R138)', 'SAT/26/0299', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1292','Shopify - Main Store','2026-08-15 12:30+05:30','Sonal Parekh','cod',12497.0,0.0,2054.59,14551.59,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1281','Flipkart - Seller Hub','2026-08-15 12:24+05:30','Kavya Menon','prepaid',1349.0,202.35,57.33,1203.98,'shipped','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1358','Amazon - Seller Central','2026-08-15 21:55+05:30','Harsh Modi','prepaid',1349.0,134.9,60.71,1274.81,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1359','Amazon - Seller Central','2026-08-15 12:40+05:30','Karan Malhotra','cod',599.0,29.95,28.45,597.5,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1360','Amazon - Seller Central','2026-08-15 22:40+05:30','Aditi Joshi','prepaid',2556.0,127.8,121.42,2549.62,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1292','WLHG-RED-M',2,5499,0.0,1979.64),
('SHOP-1292','WDRS-FLP-S',1,1499,0.0,74.95),
('FLIP-1281','WJNS-BLK-32',1,1349,202.35,57.33),
('AMAZ-1358','WJNS-IND-30',1,1349,134.9,60.71),
('AMAZ-1359','WTOP-PCH-M',1,599,29.95,28.45),
('AMAZ-1360','BTEE-RED-89Y',1,329,16.45,15.63),
('AMAZ-1360','BKUR-MUS-67Y',2,949,94.9,90.16),
('AMAZ-1360','BTEE-RED-45Y',1,329,16.45,15.63)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1292','Xpressbees - Pandesara'),
('AMAZ-1359','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1247', 'in_transit');
select pg_temp.ret_recv('AMAZ-1318');
select pg_temp.ret_set('AMAZ-1326', 'pickup');
select pg_temp.ret_new('FLIP-1254', 'Item arrived damaged', 'webhook');
select pg_temp.ret_set('FLIP-1256', 'in_transit');
select pg_temp.ret_set('AMAZ-1337', 'pickup');
select pg_temp.rto_set('SHOP-1265', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1278']::text[]);
select pg_temp.retime();

-- Sun 16 Aug 2026
select pg_temp.day('2026-08-16');
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Krishna Denim Works (ref R131)', 'KDW/26/0313', 1);
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Rajdhani Shirting Mills (ref R135)', 'RSM/26/0309', 1);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Rajdhani Shirting Mills (ref R136)', 'DC-RSM-0130', '[{"sku":"MSHC-RED-M","q":12,"a":12,"r":0},{"sku":"MKUR-MUS-L","q":6,"a":6,"r":0},{"sku":"MKUR-MUS-XL","q":8,"a":8,"r":0},{"sku":"BSHF-WHT-67Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Shree Ambika Textiles (ref R137)', 'SAT/26/0290', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1293','Shopify - Main Store','2026-08-16 12:37+05:30','Heena Khan','prepaid',1797.0,269.55,76.38,1603.83,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1361','Amazon - Seller Central','2026-08-16 19:32+05:30','Sejal Kapadia','prepaid',1348.0,134.8,60.67,1273.87,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1362','Amazon - Seller Central','2026-08-16 14:53+05:30','Isha Gupta','prepaid',1747.0,0.0,87.35,1834.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1363','Amazon - Seller Central','2026-08-16 10:57+05:30','Karan Malhotra','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1282','Flipkart - Seller Hub','2026-08-16 11:06+05:30','Foram Thakkar','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1283','Flipkart - Seller Hub','2026-08-16 11:21+05:30','Sonal Parekh','prepaid',7933.0,793.3,357.0,7496.7,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1364','Amazon - Seller Central','2026-08-16 12:09+05:30','Prachi Kulkarni','prepaid',1058.0,0.0,52.9,1110.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1365','Amazon - Seller Central','2026-08-16 14:53+05:30','Riya Shah','prepaid',7546.0,1131.9,928.35,7342.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1366','Amazon - Seller Central','2026-08-16 22:04+05:30','Chirag Zaveri','prepaid',2047.0,307.05,87.0,1826.95,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1293','WTOP-WHT-L',2,599,179.7,50.92),
('SHOP-1293','WTOP-WHT-M',1,599,89.85,25.46),
('AMAZ-1361','MTRK-BLK-M',1,649,64.9,29.21),
('AMAZ-1361','MPOL-NVY-XL',1,699,69.9,31.46),
('AMAZ-1362','WTOP-PCH-L',2,599,0.0,59.9),
('AMAZ-1362','GNGT-PNK-67Y',1,549,0.0,27.45),
('AMAZ-1363','MCHN-KHK-30',1,1199,0.0,59.95),
('FLIP-1282','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1283','BTEE-BLU-67Y',3,329,98.7,44.42),
('FLIP-1283','BKUR-MUS-45Y',1,949,94.9,42.71),
('FLIP-1283','GLHG-TEL-89Y',3,1999,599.7,269.87),
('AMAZ-1364','GLEG-BLK-45Y',1,279,0.0,13.95),
('AMAZ-1364','GJNS-IND-45Y',1,779,0.0,38.95),
('AMAZ-1365','WLHG-RED-M',1,5499,824.85,841.35),
('AMAZ-1365','WKRT-PNK-L',1,849,127.35,36.08),
('AMAZ-1365','WPAL-WHT-XL',2,599,179.7,50.92),
('AMAZ-1366','WTOP-PCH-M',1,599,89.85,25.46),
('AMAZ-1366','WTOP-WHT-M',1,599,89.85,25.46),
('AMAZ-1366','WKRT-PNK-XL',1,849,127.35,36.08)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1304', 'good', 'restocked');
select pg_temp.ret_recv('FLIP-1237');
select pg_temp.ret_recv('AMAZ-1313');
select pg_temp.ret_dispo('AMAZ-1318', 'wrong_item', 'claimed');
select pg_temp.ret_set('FLIP-1254', 'approved');
select pg_temp.cod_collect(array['SHOP-1277']::text[]);
select pg_temp.rto_set('SHOP-1279', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1282']::text[]);
select pg_temp.rto_new('FLIP-1274', 'AWB31000889', 'Address incomplete');
select pg_temp.cod_collect(array['SHOP-1289']::text[]);
select pg_temp.cancel_order('FLIP-1281');
select pg_temp.settle_pay('AMZ-STL-20260803', 0.0);
select pg_temp.claim_new('AMAZ-1318', 'other', 1416.56, '2026-09-15');
select pg_temp.retime();

-- Mon 17 Aug 2026
select pg_temp.day('2026-08-17');
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Little Stitch Garments (ref R133)', 'DC-LSG-0121', '[{"sku":"WDRS-FLR-L","q":2,"a":2,"r":0},{"sku":"BKUR-CRM-45Y","q":3,"a":3,"r":0},{"sku":"GLHG-TEL-45Y","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Rajdhani Shirting Mills (ref R136)', 'RSM/26/0314', 1);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Krishna Denim Works (ref R141)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"GJNS-IND-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Krishna Denim Works (ref R142)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-34","q":18}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Little Stitch Garments (ref R143)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"BSHT-GRY-45Y","q":6},{"sku":"BKUR-CRM-89Y","q":6},{"sku":"GLHG-RED-67Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Little Stitch Garments (ref R144)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLP-S","q":8},{"sku":"WDRS-FLP-L","q":6},{"sku":"BKUR-MUS-67Y","q":10},{"sku":"GFRK-LIL-89Y","q":10},{"sku":"GLHG-TEL-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Ludhiana Winter Wear Co (ref R145)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"MHOD-GRY-M","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Rajdhani Shirting Mills (ref R146)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"BSHF-WHT-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Shree Ambika Textiles (ref R147)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WLHG-RED-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Shree Ambika Textiles (ref R148)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WPAL-WHT-XL","q":8},{"sku":"WLHG-RED-M","q":22}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R149)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTRK-BLK-M","q":8},{"sku":"WLEG-MAR-M","q":6},{"sku":"GTOP-YLW-67Y","q":8},{"sku":"GLEG-PNK-45Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 17 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R150)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MPOL-MRN-M","q":8},{"sku":"MPOL-MRN-L","q":8},{"sku":"MTRK-BLK-XL","q":16}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1367','Amazon - Seller Central','2026-08-17 20:47+05:30','Manav Joshi','prepaid',6098.0,0.0,1019.77,7117.77,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1294','Shopify - Main Store','2026-08-17 16:48+05:30','Bhavna Solanki','cod',1957.0,0.0,97.85,2054.85,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1368','Amazon - Seller Central','2026-08-17 11:55+05:30','Nidhi Agarwal','prepaid',599.0,0.0,29.95,628.95,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1284','Flipkart - Seller Hub','2026-08-17 10:28+05:30','Aditi Joshi','prepaid',2598.0,259.8,116.92,2455.12,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1295','Shopify - Main Store','2026-08-17 13:41+05:30','Sejal Kapadia','prepaid',3747.0,374.7,168.62,3540.92,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1296','Shopify - Main Store','2026-08-17 12:06+05:30','Ritu Saxena','prepaid',2398.0,0.0,119.9,2517.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1285','Flipkart - Seller Hub','2026-08-17 20:24+05:30','Jigar Chauhan','cod',2827.0,0.0,141.35,2968.35,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1369','Amazon - Seller Central','2026-08-17 11:42+05:30','Amit Sethi','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1367','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1367','WLHG-RED-M',1,5499,0.0,989.82),
('SHOP-1294','MJNS-IND-32',1,1399,0.0,69.95),
('SHOP-1294','GLEG-PNK-45Y',2,279,0.0,27.9),
('AMAZ-1368','BSHF-WHT-45Y',1,599,0.0,29.95),
('FLIP-1284','MJNS-BLK-32',1,1399,139.9,62.96),
('FLIP-1284','MCHN-OLV-34',1,1199,119.9,53.96),
('SHOP-1295','WJNS-BLK-32',1,1349,134.9,60.71),
('SHOP-1295','MCHN-OLV-30',2,1199,239.8,107.91),
('SHOP-1296','MCHN-KHK-34',2,1199,0.0,119.9),
('FLIP-1285','GLHG-RED-67Y',1,1999,0.0,99.95),
('FLIP-1285','GNGT-PNK-45Y',1,549,0.0,27.45),
('FLIP-1285','GLEG-PNK-45Y',1,279,0.0,13.95),
('AMAZ-1369','BKUR-CRM-89Y',1,949,0.0,47.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1294','Ecom Express - Udhna Hub'),
('FLIP-1285','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1313', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1326', 'in_transit');
select pg_temp.ret_set('FLIP-1254', 'pickup');
select pg_temp.ret_recv('FLIP-1256');
select pg_temp.ret_set('AMAZ-1337', 'in_transit');
select pg_temp.ret_new('SHOP-1271', 'Fabric quality not as expected', 'manual');
select pg_temp.rto_new('SHOP-1281', 'AWB31000885', 'Delivery attempts exhausted');
select pg_temp.ret_new('FLIP-1272', 'Fabric quality not as expected', 'webhook');
select pg_temp.cod_collect(array['SHOP-1288']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260810', '2026-08-10', '2026-08-16', array['AMAZ-1332','AMAZ-1333','AMAZ-1339','AMAZ-1331','AMAZ-1337','AMAZ-1336','AMAZ-1338','AMAZ-1340','AMAZ-1341','AMAZ-1343','AMAZ-1344','AMAZ-1350','AMAZ-1342','AMAZ-1345','AMAZ-1346','AMAZ-1347','AMAZ-1349']::text[], array['AMAZ-1304','AMAZ-1318','AMAZ-1313']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260810', '2026-08-10', '2026-08-16', array['FLIP-1254','FLIP-1259','FLIP-1264','FLIP-1263','FLIP-1269','FLIP-1270','FLIP-1268','FLIP-1267','FLIP-1272','FLIP-1275','FLIP-1277','FLIP-1278','FLIP-1279']::text[], array['FLIP-1237']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260810', '2026-08-10', '2026-08-16', array['SHOP-1268','SHOP-1269','SHOP-1271','SHOP-1274','SHOP-1266','SHOP-1267','SHOP-1275','SHOP-1280','SHOP-1272','SHOP-1276','SHOP-1284','SHOP-1287']::text[], array[]::text[]);
select pg_temp.claim_step('AMAZ-1264', 'damaged_return', 'approved', null);
select pg_temp.retime();

-- Tue 18 Aug 2026
select pg_temp.day('2026-08-18');
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Little Stitch Garments (ref R133)', 'LSG/26/0294', 1);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R139)', 'DC-TKF-0175', '[{"sku":"MTRK-BLK-M","q":6,"a":6,"r":0},{"sku":"GTOP-YLW-67Y","q":8,"a":8,"r":0},{"sku":"GLEG-BLK-45Y","q":10,"a":10,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1297','Shopify - Main Store','2026-08-18 15:11+05:30','Harsh Modi','prepaid',999.0,99.9,44.96,944.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1370','Amazon - Seller Central','2026-08-18 15:33+05:30','Rohit Iyer','prepaid',329.0,16.45,15.63,328.18,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1371','Amazon - Seller Central','2026-08-18 20:32+05:30','Amit Sethi','prepaid',1098.0,109.8,49.41,1037.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1298','Shopify - Main Store','2026-08-18 09:24+05:30','Neha Patel','prepaid',3697.0,184.85,175.61,3687.76,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1372','Amazon - Seller Central','2026-08-18 14:52+05:30','Aarav Mehta','prepaid',2198.0,0.0,109.9,2307.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1286','Flipkart - Seller Hub','2026-08-18 19:47+05:30','Foram Thakkar','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1373','Amazon - Seller Central','2026-08-18 14:35+05:30','Pratik Lad','prepaid',1999.0,99.95,94.95,1994.0,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1374','Amazon - Seller Central','2026-08-18 10:16+05:30','Isha Gupta','prepaid',4123.0,618.45,175.23,3679.78,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1299','Shopify - Main Store','2026-08-18 20:04+05:30','Aditi Joshi','cod',699.0,0.0,34.95,733.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1375','Amazon - Seller Central','2026-08-18 19:40+05:30','Ritu Saxena','prepaid',1798.0,179.8,80.91,1699.11,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1297','MSHF-WHT-XL',1,999,99.9,44.96),
('AMAZ-1370','BTEE-RED-45Y',1,329,16.45,15.63),
('AMAZ-1371','GNGT-PNK-1011Y',2,549,109.8,49.41),
('SHOP-1298','MHOD-BLK-L',1,1299,64.95,61.7),
('SHOP-1298','MCHN-OLV-30',2,1199,119.9,113.91),
('AMAZ-1372','MKUR-MUS-XL',2,1099,0.0,109.9),
('FLIP-1286','GLEG-PNK-67Y',1,279,0.0,13.95),
('AMAZ-1373','GLHG-RED-45Y',1,1999,99.95,94.95),
('AMAZ-1374','WKRT-TEL-L',1,849,127.35,36.08),
('AMAZ-1374','WTOP-PCH-L',2,599,179.7,50.92),
('AMAZ-1374','GLEG-PNK-67Y',1,279,41.85,11.86),
('AMAZ-1374','WTOP-PCH-M',3,599,269.55,76.37),
('SHOP-1299','MPOL-NVY-M',1,699,0.0,34.95),
('AMAZ-1375','MSHC-GRN-L',2,899,179.8,80.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1299','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1237', 'good', 'restocked');
select pg_temp.ret_dispo('FLIP-1256', 'damaged', 'quarantined');
select pg_temp.rto_recv('SHOP-1263', 'good', 'restocked');
select pg_temp.ret_new('FLIP-1264', 'Colour different from photo', 'webhook');
select pg_temp.ret_set('SHOP-1271', 'approved');
select pg_temp.ret_set('FLIP-1272', 'approved');
select pg_temp.rto_set('FLIP-1274', 'in_transit');
select pg_temp.settle_pay('FLK-STL-20260803', 0.0);
select pg_temp.claim_new('FLIP-1256', 'damaged_return', 5053.89, '2026-09-17');
select pg_temp.retime();

-- Wed 19 Aug 2026
select pg_temp.day('2026-08-19');
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R139)', 'TKF/26/0420', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1376','Amazon - Seller Central','2026-08-19 12:15+05:30','Manav Joshi','prepaid',8347.0,0.0,1132.22,9479.22,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1287','Flipkart - Seller Hub','2026-08-19 10:17+05:30','Ritu Saxena','prepaid',4696.0,0.0,234.8,4930.8,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1288','Flipkart - Seller Hub','2026-08-19 13:20+05:30','Neha Patel','prepaid',449.0,0.0,22.45,471.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1289','Flipkart - Seller Hub','2026-08-19 12:15+05:30','Divya Nair','cod',1278.0,191.7,54.31,1140.61,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1377','Amazon - Seller Central','2026-08-19 17:39+05:30','Karan Malhotra','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1290','Flipkart - Seller Hub','2026-08-19 09:59+05:30','Harsh Modi','cod',3897.0,389.7,175.37,3682.67,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1378','Amazon - Seller Central','2026-08-19 09:12+05:30','Pratik Lad','prepaid',2278.0,341.7,96.82,2033.12,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1300','Shopify - Main Store','2026-08-19 12:17+05:30','Heena Khan','prepaid',4147.0,414.7,186.62,3918.92,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1376','WLHG-RED-M',1,5499,0.0,989.82),
('AMAZ-1376','WDRS-FLP-S',1,1499,0.0,74.95),
('AMAZ-1376','WJNS-BLK-30',1,1349,0.0,67.45),
('FLIP-1287','WKRT-PNK-S',2,849,0.0,84.9),
('FLIP-1287','WDRS-FLR-S',1,1499,0.0,74.95),
('FLIP-1287','WDRS-FLP-L',1,1499,0.0,74.95),
('FLIP-1288','MTEE-BLK-XL',1,449,0.0,22.45),
('FLIP-1289','BKUR-CRM-89Y',1,949,142.35,40.33),
('FLIP-1289','BTEE-BLU-67Y',1,329,49.35,13.98),
('AMAZ-1377','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1290','MKUR-WHT-XL',1,1099,109.9,49.46),
('FLIP-1290','MJNS-BLK-32',2,1399,279.8,125.91),
('AMAZ-1378','GJNS-IND-1011Y',1,779,116.85,33.11),
('AMAZ-1378','WDRS-FLP-S',1,1499,224.85,63.71),
('SHOP-1300','MJNS-IND-32',2,1399,279.8,125.91),
('SHOP-1300','WJNS-BLK-32',1,1349,134.9,60.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1290','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('SHOP-1247');
select pg_temp.ret_set('FLIP-1254', 'in_transit');
select pg_temp.ret_set('FLIP-1264', 'approved');
select pg_temp.ret_set('SHOP-1271', 'pickup');
select pg_temp.rto_set('SHOP-1281', 'in_transit');
select pg_temp.ret_set('FLIP-1272', 'pickup');
select pg_temp.cod_collect(array['SHOP-1286']::text[]);
select pg_temp.cod_collect(array['SHOP-1292']::text[]);
select pg_temp.settle_pay('SHP-STL-20260810', 0.0);
select pg_temp.claim_step('AMAZ-1318', 'other', 'claimed', null);
select pg_temp.retime();

-- Thu 20 Aug 2026
select pg_temp.day('2026-08-20');
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Ludhiana Winter Wear Co (ref R134)', 'DC-LWW-0064', '[{"sku":"MHOD-GRY-M","q":8,"a":8,"r":0},{"sku":"BTRK-BLK-1011Y","q":10,"a":9,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 10 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R140)', 'DC-TKF-0178', '[{"sku":"MTEE-BLK-M","q":6,"a":6,"r":0},{"sku":"MPOL-MRN-M","q":10,"a":9,"r":1},{"sku":"MPOL-MRN-L","q":8,"a":8,"r":0},{"sku":"MTRK-BLK-XL","q":12,"a":12,"r":0},{"sku":"WTOP-PCH-S","q":20,"a":20,"r":0},{"sku":"GLEG-BLK-89Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Little Stitch Garments (ref R144)', 'DC-LSG-0127', '[{"sku":"WDRS-FLP-S","q":8,"a":7,"r":1},{"sku":"WDRS-FLP-L","q":6,"a":6,"r":0},{"sku":"BKUR-MUS-67Y","q":10,"a":10,"r":0},{"sku":"GFRK-LIL-89Y","q":10,"a":10,"r":0},{"sku":"GLHG-TEL-89Y","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1301','Shopify - Main Store','2026-08-20 09:57+05:30','Karan Malhotra','cod',2798.0,0.0,139.9,2937.9,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1291','Flipkart - Seller Hub','2026-08-20 21:19+05:30','Amit Sethi','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1292','Flipkart - Seller Hub','2026-08-20 13:33+05:30','Karan Malhotra','prepaid',1448.0,72.4,68.78,1444.38,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1302','Shopify - Main Store','2026-08-20 09:51+05:30','Pratik Lad','prepaid',12497.0,1874.55,1746.4,12368.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1293','Flipkart - Seller Hub','2026-08-20 16:40+05:30','Divya Nair','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1294','Flipkart - Seller Hub','2026-08-20 12:40+05:30','Vipul Gandhi','prepaid',9197.0,0.0,1174.72,10371.72,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1379','Amazon - Seller Central','2026-08-20 22:41+05:30','Sejal Kapadia','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1380','Amazon - Seller Central','2026-08-20 12:47+05:30','Riya Shah','prepaid',5245.0,262.25,249.14,5231.89,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1381','Amazon - Seller Central','2026-08-20 18:39+05:30','Mitul Dave','prepaid',1448.0,0.0,72.4,1520.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1382','Amazon - Seller Central','2026-08-20 10:19+05:30','Vipul Gandhi','prepaid',1898.0,284.7,80.67,1693.97,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1383','Amazon - Seller Central','2026-08-20 22:17+05:30','Sejal Kapadia','prepaid',949.0,142.35,40.33,846.98,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1303','Shopify - Main Store','2026-08-20 10:37+05:30','Nikhil Pandey','cod',2098.0,209.8,94.42,1982.62,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1295','Flipkart - Seller Hub','2026-08-20 09:37+05:30','Chirag Zaveri','prepaid',3245.0,324.5,146.04,3066.54,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1301','MJNS-IND-30',2,1399,0.0,139.9),
('FLIP-1291','WLEG-BLK-M',1,349,0.0,17.45),
('FLIP-1292','WKRT-PNK-XL',1,849,42.45,40.33),
('FLIP-1292','WTOP-WHT-M',1,599,29.95,28.45),
('SHOP-1302','WDRS-FLP-M',1,1499,224.85,63.71),
('SHOP-1302','WLHG-MAG-L',2,5499,1649.7,1682.69),
('FLIP-1293','BTEE-BLU-67Y',1,329,32.9,14.81),
('FLIP-1294','WSAR-GRN-FREE',1,2199,0.0,109.95),
('FLIP-1294','WLHG-RED-L',1,5499,0.0,989.82),
('FLIP-1294','WDRS-FLR-L',1,1499,0.0,74.95),
('AMAZ-1379','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1379','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1380','WJNS-IND-30',3,1349,202.35,192.23),
('AMAZ-1380','WTOP-PCH-L',2,599,59.9,56.91),
('AMAZ-1381','WPAL-YLW-XL',1,599,0.0,29.95),
('AMAZ-1381','WKRT-PNK-XL',1,849,0.0,42.45),
('AMAZ-1382','BKUR-MUS-67Y',2,949,284.7,80.67),
('AMAZ-1383','BKUR-MUS-67Y',1,949,142.35,40.33),
('SHOP-1303','WDRS-FLP-L',1,1499,149.9,67.46),
('SHOP-1303','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1295','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1295','WTOP-WHT-M',2,599,119.8,53.91),
('FLIP-1295','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1295','WKRT-PNK-M',1,849,84.9,38.21)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1301','Xpressbees - Pandesara'),
('SHOP-1303','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1264', 'pickup');
select pg_temp.rto_recv('SHOP-1265', 'damaged', 'quarantined');
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
