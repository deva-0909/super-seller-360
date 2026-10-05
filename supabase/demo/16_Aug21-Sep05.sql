-- 21 Aug to 05 Sep 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Fri 21 Aug 2026
select pg_temp.day('2026-08-21');
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Ludhiana Winter Wear Co (ref R134)', 'LWW/26/0156', 1);
select pg_temp.bill_po('Weekly replenishment 10 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R140)', 'TKF/26/0422', 1);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Krishna Denim Works (ref R142)', 'DC-KDW-0136', '[{"sku":"MJNS-BLK-34","q":18,"a":18,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Little Stitch Garments (ref R143)', 'DC-LSG-0124', '[{"sku":"BSHT-GRY-45Y","q":6,"a":6,"r":0},{"sku":"BKUR-CRM-89Y","q":6,"a":6,"r":0},{"sku":"GLHG-RED-67Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Little Stitch Garments (ref R144)', 'LSG/26/0306', 1);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Shree Ambika Textiles (ref R147)', 'DC-SAT-0127', '[{"sku":"WLHG-RED-L","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1296','Flipkart - Seller Hub','2026-08-21 18:16+05:30','Karan Malhotra','prepaid',2996.0,0.0,149.8,3145.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1384','Amazon - Seller Central','2026-08-21 20:51+05:30','Mehul Shukla','prepaid',1578.0,0.0,78.9,1656.9,'cancelled','refunded','Delhi','Surat Main Warehouse'),
('AMAZ-1385','Amazon - Seller Central','2026-08-21 19:56+05:30','Rohit Iyer','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1386','Amazon - Seller Central','2026-08-21 13:19+05:30','Vipul Gandhi','prepaid',558.0,55.8,25.12,527.32,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1387','Amazon - Seller Central','2026-08-21 20:00+05:30','Meghna Rao','prepaid',558.0,0.0,27.9,585.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1304','Shopify - Main Store','2026-08-21 09:07+05:30','Aarav Mehta','cod',2798.0,279.8,125.91,2644.11,'shipped','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1305','Shopify - Main Store','2026-08-21 09:45+05:30','Vipul Gandhi','prepaid',1448.0,0.0,72.4,1520.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1297','Flipkart - Seller Hub','2026-08-21 17:30+05:30','Harsh Modi','cod',1098.0,164.7,46.66,979.96,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1306','Shopify - Main Store','2026-08-21 09:09+05:30','Karan Malhotra','prepaid',1948.0,0.0,97.4,2045.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1388','Amazon - Seller Central','2026-08-21 13:03+05:30','Neha Patel','prepaid',837.0,0.0,41.85,878.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1307','Shopify - Main Store','2026-08-21 11:37+05:30','Aarav Mehta','prepaid',1798.0,0.0,89.9,1887.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1308','Shopify - Main Store','2026-08-21 09:31+05:30','Riya Shah','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1389','Amazon - Seller Central','2026-08-21 10:44+05:30','Prachi Kulkarni','prepaid',549.0,0.0,27.45,576.45,'cancelled','refunded','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1309','Shopify - Main Store','2026-08-21 11:11+05:30','Divya Nair','cod',2047.0,102.35,97.24,2041.89,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('AMAZ-1390','Amazon - Seller Central','2026-08-21 14:28+05:30','Kunal Desai','prepaid',698.0,0.0,34.9,732.9,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1298','Flipkart - Seller Hub','2026-08-21 16:34+05:30','Yash Vora','cod',1698.0,0.0,84.9,1782.9,'shipped','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1391','Amazon - Seller Central','2026-08-21 10:54+05:30','Nidhi Agarwal','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1296','WTOP-WHT-L',3,599,0.0,89.85),
('FLIP-1296','MCHN-OLV-34',1,1199,0.0,59.95),
('AMAZ-1384','MHOD-BLK-XL',1,1299,0.0,64.95),
('AMAZ-1384','GLEG-BLK-89Y',1,279,0.0,13.95),
('AMAZ-1385','WTOP-PCH-M',1,599,29.95,28.45),
('AMAZ-1386','GLEG-BLK-67Y',1,279,27.9,12.56),
('AMAZ-1386','GLEG-PNK-67Y',1,279,27.9,12.56),
('AMAZ-1387','GLEG-PNK-67Y',2,279,0.0,27.9),
('SHOP-1304','MJNS-IND-30',2,1399,279.8,125.91),
('SHOP-1305','GFRK-LIL-45Y',1,749,0.0,37.45),
('SHOP-1305','MPOL-NVY-XL',1,699,0.0,34.95),
('FLIP-1297','GFRK-LIL-67Y',1,749,112.35,31.83),
('FLIP-1297','BSHT-NVY-45Y',1,349,52.35,14.83),
('SHOP-1306','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1306','WJNS-BLK-30',1,1349,0.0,67.45),
('AMAZ-1388','GLEG-PNK-67Y',2,279,0.0,27.9),
('AMAZ-1388','GLEG-BLK-89Y',1,279,0.0,13.95),
('SHOP-1307','MSHC-GRN-L',2,899,0.0,89.9),
('SHOP-1308','WTOP-PCH-S',1,599,0.0,29.95),
('SHOP-1308','WTOP-PCH-L',2,599,0.0,59.9),
('AMAZ-1389','GNGT-PNK-67Y',1,549,0.0,27.45),
('SHOP-1309','WTOP-PCH-S',2,599,59.9,56.91),
('SHOP-1309','WKRT-PNK-L',1,849,42.45,40.33),
('AMAZ-1390','WLEG-BLK-M',2,349,0.0,34.9),
('FLIP-1298','WKRT-TEL-M',2,849,0.0,84.9),
('AMAZ-1391','MCHN-OLV-32',1,1199,0.0,59.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1297','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('SHOP-1247', 'damaged', 'quarantined');
select pg_temp.ret_recv('AMAZ-1326');
select pg_temp.ret_recv('AMAZ-1337');
select pg_temp.ret_set('SHOP-1271', 'in_transit');
select pg_temp.rto_recv('SHOP-1279', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1272', 'in_transit');
select pg_temp.ret_new('FLIP-1277', 'Customer changed mind', 'webhook');
select pg_temp.cod_collect(array['AMAZ-1359']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-21AUG', array['FLIP-1266','SHOP-1288']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-21AUG', array['SHOP-1278','SHOP-1282','SHOP-1289']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-21AUG', array['SHOP-1277']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-21AUG', array['SHOP-1273','SHOP-1286']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-21AUG', array['FLIP-1265','SHOP-1292']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-08-24', 'ICIC000000886382', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-08-24', 'ICIC000000886424', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-08-24', 'ICIC000000886479', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-08-24', 'ICIC000000886543', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-08-24', 'ICIC000000886579', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-08-24', 'ICIC000000886675', 1);
select pg_temp.claim_step('FLIP-1256', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Sat 22 Aug 2026
select pg_temp.day('2026-08-22');
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Krishna Denim Works (ref R141)', 'DC-KDW-0133', '[{"sku":"GJNS-IND-45Y","q":6,"a":5,"r":1}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Krishna Denim Works (ref R142)', 'KDW/26/0324', 1);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Little Stitch Garments (ref R143)', 'LSG/26/0296', 1);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Rajdhani Shirting Mills (ref R146)', 'DC-RSM-0133', '[{"sku":"BSHF-WHT-89Y","q":5,"a":5,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Shree Ambika Textiles (ref R147)', 'SAT/26/0309', 1);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Shree Ambika Textiles (ref R148)', 'DC-SAT-0130', '[{"sku":"WPAL-WHT-XL","q":8,"a":8,"r":0},{"sku":"WLHG-RED-M","q":22,"a":22,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1392','Amazon - Seller Central','2026-08-22 22:59+05:30','Heena Khan','prepaid',7304.0,1095.6,310.42,6518.82,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1393','Amazon - Seller Central','2026-08-22 19:17+05:30','Kavya Menon','prepaid',699.0,69.9,31.46,660.56,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1310','Shopify - Main Store','2026-08-22 13:40+05:30','Nikhil Pandey','cod',698.0,0.0,34.9,732.9,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1394','Amazon - Seller Central','2026-08-22 17:36+05:30','Yash Vora','prepaid',599.0,89.85,25.46,534.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1299','Flipkart - Seller Hub','2026-08-22 11:06+05:30','Foram Thakkar','prepaid',2998.0,149.9,142.4,2990.5,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1395','Amazon - Seller Central','2026-08-22 15:40+05:30','Ritu Saxena','prepaid',2698.0,404.7,114.67,2407.97,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('SHOP-1311','Shopify - Main Store','2026-08-22 16:00+05:30','Rohit Iyer','prepaid',2597.0,389.55,110.38,2317.83,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1312','Shopify - Main Store','2026-08-22 20:08+05:30','Shreya Banerjee','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1313','Shopify - Main Store','2026-08-22 21:01+05:30','Vivek Singh','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1396','Amazon - Seller Central','2026-08-22 13:50+05:30','Anjali Verma','prepaid',837.0,0.0,41.85,878.85,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1392','GLHG-TEL-45Y',3,1999,899.55,254.87),
('AMAZ-1392','GFRK-LIL-89Y',1,749,112.35,31.83),
('AMAZ-1392','GLEG-PNK-89Y',1,279,41.85,11.86),
('AMAZ-1392','GLEG-PNK-67Y',1,279,41.85,11.86),
('AMAZ-1393','MPOL-NVY-M',1,699,69.9,31.46),
('SHOP-1310','BSHT-GRY-67Y',2,349,0.0,34.9),
('AMAZ-1394','WPAL-WHT-M',1,599,89.85,25.46),
('FLIP-1299','WDRS-FLP-S',1,1499,74.95,71.2),
('FLIP-1299','WDRS-FLP-L',1,1499,74.95,71.2),
('AMAZ-1395','WJNS-IND-30',2,1349,404.7,114.67),
('SHOP-1311','WTOP-WHT-M',2,599,179.7,50.92),
('SHOP-1311','MJNS-BLK-32',1,1399,209.85,59.46),
('SHOP-1312','MTRK-BLK-XL',1,649,0.0,32.45),
('SHOP-1313','WLEG-NVY-M',1,349,0.0,17.45),
('AMAZ-1396','GLEG-PNK-67Y',3,279,0.0,41.85)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1310','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1326', 'damaged', 'quarantined');
select pg_temp.ret_dispo('AMAZ-1337', 'wrong_item', 'claimed');
select pg_temp.ret_set('FLIP-1264', 'in_transit');
select pg_temp.ret_set('FLIP-1277', 'approved');
select pg_temp.cod_collect(array['SHOP-1294']::text[]);
select pg_temp.rto_new('AMAZ-1368', 'AWB31000892', 'Customer unreachable');
select pg_temp.cod_collect(array['FLIP-1285']::text[]);
select pg_temp.cod_collect(array['FLIP-1290']::text[]);
select pg_temp.claim_new('AMAZ-1326', 'damaged_return', 1259.37, '2026-09-21');
select pg_temp.claim_new('AMAZ-1337', 'other', 534.61, '2026-09-21');
select pg_temp.retime();

-- Sun 23 Aug 2026
select pg_temp.day('2026-08-23');
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Krishna Denim Works (ref R141)', 'KDW/26/0320', 1);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Rajdhani Shirting Mills (ref R146)', 'RSM/26/0321', 1);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Shree Ambika Textiles (ref R148)', 'SAT/26/0313', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1300','Flipkart - Seller Hub','2026-08-23 18:46+05:30','Chirag Zaveri','prepaid',6098.0,609.8,917.8,6406.0,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1301','Flipkart - Seller Hub','2026-08-23 09:20+05:30','Kavya Menon','prepaid',1499.0,149.9,67.46,1416.56,'shipped','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1397','Amazon - Seller Central','2026-08-23 22:43+05:30','Anjali Verma','prepaid',3395.0,509.25,144.3,3030.05,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1314','Shopify - Main Store','2026-08-23 20:57+05:30','Pratik Lad','prepaid',2198.0,0.0,109.9,2307.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1315','Shopify - Main Store','2026-08-23 11:32+05:30','Nikhil Pandey','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1398','Amazon - Seller Central','2026-08-23 15:25+05:30','Sonal Parekh','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1302','Flipkart - Seller Hub','2026-08-23 12:42+05:30','Prachi Kulkarni','prepaid',4646.0,696.9,197.46,4146.56,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1399','Amazon - Seller Central','2026-08-23 19:26+05:30','Yash Vora','prepaid',899.0,134.85,38.21,802.36,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1303','Flipkart - Seller Hub','2026-08-23 22:28+05:30','Kiran Naik','prepaid',1399.0,209.85,59.46,1248.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1304','Flipkart - Seller Hub','2026-08-23 11:19+05:30','Pooja Jain','prepaid',948.0,142.2,40.29,846.09,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1400','Amazon - Seller Central','2026-08-23 20:12+05:30','Sonal Parekh','prepaid',2337.0,0.0,116.85,2453.85,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1300','WLHG-RED-L',1,5499,549.9,890.84),
('FLIP-1300','WTOP-WHT-M',1,599,59.9,26.96),
('FLIP-1301','WDRS-FLP-L',1,1499,149.9,67.46),
('AMAZ-1397','MPOL-MRN-L',1,699,104.85,29.71),
('AMAZ-1397','MCHN-OLV-34',1,1199,179.85,50.96),
('AMAZ-1397','BSHF-WHT-67Y',1,599,89.85,25.46),
('AMAZ-1397','MTEE-WHT-M',2,449,134.7,38.17),
('SHOP-1314','MKUR-WHT-L',2,1099,0.0,109.9),
('SHOP-1315','BTEE-RED-67Y',1,329,0.0,16.45),
('AMAZ-1398','WTOP-WHT-M',2,599,0.0,59.9),
('FLIP-1302','WJNS-BLK-32',3,1349,607.05,172.0),
('FLIP-1302','WTOP-PCH-S',1,599,89.85,25.46),
('AMAZ-1399','MSHC-GRN-L',1,899,134.85,38.21),
('FLIP-1303','MJNS-IND-34',1,1399,209.85,59.46),
('FLIP-1304','WLEG-BLK-M',1,349,52.35,14.83),
('FLIP-1304','WTOP-PCH-L',1,599,89.85,25.46),
('AMAZ-1400','GJNS-IND-45Y',3,779,0.0,116.85)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('FLIP-1254');
select pg_temp.ret_recv('SHOP-1271');
select pg_temp.ret_set('FLIP-1277', 'pickup');
select pg_temp.ret_new('AMAZ-1360', 'Size did not fit', 'webhook');
select pg_temp.cod_collect(array['SHOP-1299']::text[]);
select pg_temp.cod_collect(array['SHOP-1303']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260810', 85.0);
select pg_temp.retime();

-- Mon 24 Aug 2026
select pg_temp.day('2026-08-24');
select pg_temp.po_new('Weekly replenishment 24 Aug 2026 - Krishna Denim Works (ref R151)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MJNS-IND-30","q":6},{"sku":"MCHN-OLV-30","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 24 Aug 2026 - Krishna Denim Works (ref R152)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-IND-32","q":8},{"sku":"MCHN-OLV-30","q":8},{"sku":"WJNS-IND-30","q":10},{"sku":"WJNS-BLK-32","q":10},{"sku":"GJNS-IND-45Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 24 Aug 2026 - Rajdhani Shirting Mills (ref R153)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"BSHF-WHT-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 24 Aug 2026 - Rajdhani Shirting Mills (ref R154)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-GRN-L","q":8},{"sku":"MKUR-WHT-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 24 Aug 2026 - Shree Ambika Textiles (ref R155)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WSAR-GRN-FREE","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 24 Aug 2026 - Shree Ambika Textiles (ref R156)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-TEL-L","q":6},{"sku":"WLHG-MAG-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 24 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R157)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-BLK-XL","q":6},{"sku":"WLEG-BLK-M","q":8},{"sku":"WLEG-MAR-M","q":6},{"sku":"WTOP-WHT-L","q":8},{"sku":"GLEG-PNK-67Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 24 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R158)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-WHT-M","q":8},{"sku":"WTOP-PCH-L","q":24},{"sku":"GLEG-PNK-67Y","q":22}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1401','Amazon - Seller Central','2026-08-24 21:30+05:30','Nidhi Agarwal','prepaid',1198.0,59.9,56.91,1195.01,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1305','Flipkart - Seller Hub','2026-08-24 12:23+05:30','Sanjay Gajera','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1402','Amazon - Seller Central','2026-08-24 10:16+05:30','Aditi Joshi','prepaid',349.0,52.35,14.83,311.48,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1306','Flipkart - Seller Hub','2026-08-24 20:53+05:30','Bhavna Solanki','prepaid',849.0,127.35,36.08,757.73,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1307','Flipkart - Seller Hub','2026-08-24 22:10+05:30','Prachi Kulkarni','prepaid',999.0,49.95,47.45,996.5,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('AMAZ-1403','Amazon - Seller Central','2026-08-24 18:34+05:30','Tanvi Rana','prepaid',749.0,0.0,37.45,786.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1308','Flipkart - Seller Hub','2026-08-24 11:13+05:30','Sejal Kapadia','prepaid',3096.0,154.8,147.06,3088.26,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1316','Shopify - Main Store','2026-08-24 09:51+05:30','Yash Vora','cod',1199.0,179.85,50.96,1070.11,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1317','Shopify - Main Store','2026-08-24 16:44+05:30','Kunal Desai','prepaid',999.0,49.95,47.45,996.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1318','Shopify - Main Store','2026-08-24 11:11+05:30','Sagar Rathod','prepaid',948.0,47.4,45.03,945.63,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1404','Amazon - Seller Central','2026-08-24 12:58+05:30','Dev Trivedi','prepaid',4398.0,219.9,208.91,4387.01,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1405','Amazon - Seller Central','2026-08-24 13:43+05:30','Bhavna Solanki','prepaid',4196.0,209.8,199.31,4185.51,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1309','Flipkart - Seller Hub','2026-08-24 21:08+05:30','Pratik Lad','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1406','Amazon - Seller Central','2026-08-24 21:26+05:30','Bhavna Solanki','prepaid',2847.0,142.35,135.23,2839.88,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1310','Flipkart - Seller Hub','2026-08-24 13:48+05:30','Sonal Parekh','prepaid',3799.0,0.0,683.82,4482.82,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1401','WTOP-PCH-M',2,599,59.9,56.91),
('FLIP-1305','WLEG-MAR-L',1,349,0.0,17.45),
('AMAZ-1402','WLEG-BLK-M',1,349,52.35,14.83),
('FLIP-1306','WKRT-PNK-M',1,849,127.35,36.08),
('FLIP-1307','MSHF-WHT-L',1,999,49.95,47.45),
('AMAZ-1403','GFRK-PNK-67Y',1,749,0.0,37.45),
('FLIP-1308','WTOP-WHT-L',1,599,29.95,28.45),
('FLIP-1308','BKUR-MUS-67Y',2,949,94.9,90.16),
('FLIP-1308','WTOP-PCH-L',1,599,29.95,28.45),
('SHOP-1316','MCHN-OLV-30',1,1199,179.85,50.96),
('SHOP-1317','BTRK-BLK-45Y',1,999,49.95,47.45),
('SHOP-1318','WTOP-PCH-S',1,599,29.95,28.45),
('SHOP-1318','WLEG-NVY-L',1,349,17.45,16.58),
('AMAZ-1404','WSAR-BLU-FREE',2,2199,219.9,208.91),
('AMAZ-1405','MCHN-KHK-30',3,1199,179.85,170.86),
('AMAZ-1405','WTOP-PCH-M',1,599,29.95,28.45),
('FLIP-1309','WKRT-TEL-M',1,849,0.0,42.45),
('AMAZ-1406','BKUR-MUS-89Y',3,949,142.35,135.23),
('FLIP-1310','MBLZ-NVY-40',1,3799,0.0,683.82)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1316','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1247', 'UPI-REFUND-SHOP-1247');
select pg_temp.ret_recv('FLIP-1264');
select pg_temp.ret_dispo('SHOP-1271', 'wrong_item', 'claimed');
select pg_temp.ret_set('AMAZ-1360', 'approved');
select pg_temp.ret_reject('AMAZ-1360');
select pg_temp.rto_set('AMAZ-1368', 'in_transit');
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260817', '2026-08-17', '2026-08-23', array['AMAZ-1348','AMAZ-1357','AMAZ-1351','AMAZ-1352','AMAZ-1358','AMAZ-1353','AMAZ-1354','AMAZ-1356','AMAZ-1355','AMAZ-1360','AMAZ-1362','AMAZ-1363','AMAZ-1365','AMAZ-1369','AMAZ-1364','AMAZ-1361','AMAZ-1366','AMAZ-1367','AMAZ-1370','AMAZ-1375','AMAZ-1371','AMAZ-1372','AMAZ-1374']::text[], array['AMAZ-1326','AMAZ-1337']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260817', '2026-08-17', '2026-08-23', array['FLIP-1273','FLIP-1276','FLIP-1280','FLIP-1282','FLIP-1286','FLIP-1283','FLIP-1284','FLIP-1288','FLIP-1292','FLIP-1294']::text[], array['FLIP-1256','FLIP-1254']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260817', '2026-08-17', '2026-08-23', array['SHOP-1285','SHOP-1283','SHOP-1290','SHOP-1291','SHOP-1296','SHOP-1297','SHOP-1293','SHOP-1295']::text[], array[]::text[]);
select pg_temp.claim_step('AMAZ-1289', 'lost_shipment', 'approved', null);
select pg_temp.claim_new('SHOP-1271', 'other', 996.45, '2026-09-23');
select pg_temp.retime();

-- Tue 25 Aug 2026
select pg_temp.day('2026-08-25');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1407','Amazon - Seller Central','2026-08-25 13:34+05:30','Neha Patel','prepaid',2497.0,249.7,112.37,2359.67,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1319','Shopify - Main Store','2026-08-25 09:24+05:30','Sagar Rathod','cod',1399.0,139.9,62.96,1322.06,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1311','Flipkart - Seller Hub','2026-08-25 20:38+05:30','Karan Malhotra','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1312','Flipkart - Seller Hub','2026-08-25 22:59+05:30','Mehul Shukla','prepaid',2697.0,404.55,114.63,2407.08,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1408','Amazon - Seller Central','2026-08-25 19:12+05:30','Manav Joshi','prepaid',2199.0,0.0,109.95,2308.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1409','Amazon - Seller Central','2026-08-25 11:04+05:30','Neha Patel','prepaid',1657.0,82.85,78.71,1652.86,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1313','Flipkart - Seller Hub','2026-08-25 11:00+05:30','Nidhi Agarwal','prepaid',2227.0,334.05,94.65,1987.6,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1314','Flipkart - Seller Hub','2026-08-25 09:23+05:30','Pratik Lad','prepaid',2896.0,0.0,144.8,3040.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1320','Shopify - Main Store','2026-08-25 09:23+05:30','Nidhi Agarwal','prepaid',1148.0,172.2,48.79,1024.59,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1315','Flipkart - Seller Hub','2026-08-25 09:09+05:30','Divya Nair','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1407','WTOP-PCH-M',2,599,119.8,53.91),
('AMAZ-1407','MHOD-BLK-XL',1,1299,129.9,58.46),
('SHOP-1319','MJNS-BLK-34',1,1399,139.9,62.96),
('FLIP-1311','WLEG-MAR-M',1,349,0.0,17.45),
('FLIP-1312','WDRS-FLP-L',1,1499,224.85,63.71),
('FLIP-1312','WTOP-WHT-M',1,599,89.85,25.46),
('FLIP-1312','WTOP-PCH-S',1,599,89.85,25.46),
('AMAZ-1408','WSAR-GRN-FREE',1,2199,0.0,109.95),
('AMAZ-1409','GJNS-IND-45Y',1,779,38.95,37.0),
('AMAZ-1409','GNGT-PNK-45Y',1,549,27.45,26.08),
('AMAZ-1409','BTEE-BLU-67Y',1,329,16.45,15.63),
('FLIP-1313','WJNS-BLK-28',1,1349,202.35,57.33),
('FLIP-1313','GLEG-BLK-67Y',1,279,41.85,11.86),
('FLIP-1313','WTOP-WHT-L',1,599,89.85,25.46),
('FLIP-1314','WKRT-TEL-M',2,849,0.0,84.9),
('FLIP-1314','WTOP-WHT-L',2,599,0.0,59.9),
('SHOP-1320','GNGT-PNK-89Y',1,549,82.35,23.33),
('SHOP-1320','WTOP-PCH-M',1,599,89.85,25.46),
('FLIP-1315','WTOP-PCH-S',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1319','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1254', 'damaged', 'quarantined');
select pg_temp.rto_recv('SHOP-1281', 'good', 'restocked');
select pg_temp.ret_recv('FLIP-1272');
select pg_temp.ret_set('FLIP-1277', 'in_transit');
select pg_temp.ret_new('FLIP-1282', 'Colour different from photo', 'webhook');
select pg_temp.ret_new('AMAZ-1372', 'Colour different from photo', 'webhook');
select pg_temp.rto_new('FLIP-1289', 'AWB31000902', 'Customer unreachable');
select pg_temp.cod_collect(array['SHOP-1301']::text[]);
select pg_temp.settle_pay('FLK-STL-20260810', 0.0);
select pg_temp.claim_step('AMAZ-1326', 'damaged_return', 'claimed', null);
select pg_temp.claim_new('FLIP-1254', 'damaged_return', 881.37, '2026-09-24');
select pg_temp.claim_step('AMAZ-1337', 'other', 'claimed', null);
select pg_temp.claim_new('AMAZ-1332', 'incorrect_deduction', 85.0, '2026-09-24');
select pg_temp.retime();

-- Wed 26 Aug 2026
select pg_temp.day('2026-08-26');
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Ludhiana Winter Wear Co (ref R145)', 'DC-LWW-0067', '[{"sku":"MHOD-GRY-M","q":5,"a":5,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Rajdhani Shirting Mills (ref R146)', 'DC-RSM-0136', '[{"sku":"BSHF-WHT-89Y","q":3,"a":3,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R149)', 'DC-TKF-0181', '[{"sku":"MTRK-BLK-M","q":8,"a":8,"r":0},{"sku":"WLEG-MAR-M","q":6,"a":6,"r":0},{"sku":"GTOP-YLW-67Y","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-45Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R150)', 'DC-TKF-0184', '[{"sku":"MPOL-MRN-M","q":8,"a":8,"r":0},{"sku":"MPOL-MRN-L","q":8,"a":8,"r":0},{"sku":"MTRK-BLK-XL","q":16,"a":16,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1321','Shopify - Main Store','2026-08-26 16:57+05:30','Meghna Rao','cod',2598.0,0.0,129.9,2727.9,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1322','Shopify - Main Store','2026-08-26 22:58+05:30','Sagar Rathod','cod',698.0,0.0,34.9,732.9,'delivered','pending','Delhi','Surat Main Warehouse'),
('SHOP-1323','Shopify - Main Store','2026-08-26 13:00+05:30','Ritu Saxena','cod',1399.0,69.95,66.45,1395.5,'shipped','pending','Rajasthan','Surat Main Warehouse'),
('AMAZ-1410','Amazon - Seller Central','2026-08-26 10:42+05:30','Sanjay Gajera','prepaid',3695.0,369.5,166.28,3491.78,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1324','Shopify - Main Store','2026-08-26 13:32+05:30','Prachi Kulkarni','cod',949.0,47.45,45.08,946.63,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1316','Flipkart - Seller Hub','2026-08-26 14:35+05:30','Kiran Naik','prepaid',2946.0,0.0,147.3,3093.3,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1411','Amazon - Seller Central','2026-08-26 17:33+05:30','Kavya Menon','prepaid',3396.0,0.0,169.8,3565.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1317','Flipkart - Seller Hub','2026-08-26 21:09+05:30','Pratik Lad','prepaid',5695.0,854.25,242.03,5082.78,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1325','Shopify - Main Store','2026-08-26 19:34+05:30','Sagar Rathod','cod',2697.0,0.0,134.85,2831.85,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1326','Shopify - Main Store','2026-08-26 10:01+05:30','Meghna Rao','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1327','Shopify - Main Store','2026-08-26 13:07+05:30','Heena Khan','prepaid',1398.0,69.9,66.41,1394.51,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1412','Amazon - Seller Central','2026-08-26 22:03+05:30','Nikhil Pandey','prepaid',1307.0,0.0,65.35,1372.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1328','Shopify - Main Store','2026-08-26 15:48+05:30','Mitul Dave','cod',6795.0,0.0,339.75,7134.75,'delivered','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1321','MCHN-OLV-34',1,1199,0.0,59.95),
('SHOP-1321','MJNS-IND-30',1,1399,0.0,69.95),
('SHOP-1322','WLEG-NVY-M',2,349,0.0,34.9),
('SHOP-1323','MJNS-IND-34',1,1399,69.95,66.45),
('AMAZ-1410','MHOD-BLK-XL',1,1299,129.9,58.46),
('AMAZ-1410','WPAL-YLW-M',2,599,119.8,53.91),
('AMAZ-1410','WTOP-PCH-L',2,599,119.8,53.91),
('SHOP-1324','BKUR-MUS-89Y',1,949,47.45,45.08),
('FLIP-1316','MTEE-BLK-M',1,449,0.0,22.45),
('FLIP-1316','MTRK-BLK-M',2,649,0.0,64.9),
('FLIP-1316','MCHN-KHK-30',1,1199,0.0,59.95),
('AMAZ-1411','WKRT-PNK-S',1,849,0.0,42.45),
('AMAZ-1411','WJNS-IND-30',1,1349,0.0,67.45),
('AMAZ-1411','WTOP-PCH-M',2,599,0.0,59.9),
('FLIP-1317','WKRT-PNK-M',1,849,127.35,36.08),
('FLIP-1317','WDRS-FLR-S',3,1499,674.55,191.12),
('FLIP-1317','WLEG-MAR-L',1,349,52.35,14.83),
('SHOP-1325','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1325','WDRS-FLR-S',1,1499,0.0,74.95),
('SHOP-1325','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1326','WTOP-PCH-M',1,599,0.0,29.95),
('SHOP-1327','MPOL-NVY-M',2,699,69.9,66.41),
('AMAZ-1412','GFRK-LIL-89Y',1,749,0.0,37.45),
('AMAZ-1412','GLEG-BLK-45Y',1,279,0.0,13.95),
('AMAZ-1412','GLEG-PNK-89Y',1,279,0.0,13.95),
('SHOP-1328','MJNS-IND-34',1,1399,0.0,69.95),
('SHOP-1328','MCHN-KHK-34',1,1199,0.0,59.95),
('SHOP-1328','MJNS-IND-30',3,1399,0.0,209.85)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1321','Bluedart - Surat City'),
('SHOP-1322','Delhivery - Sachin GIDC Surat'),
('SHOP-1324','Xpressbees - Pandesara'),
('SHOP-1325','DTDC - Ring Road Surat'),
('SHOP-1328','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1264', 'good', 'restocked');
select pg_temp.ret_refund_d2c('SHOP-1271', 'UPI-REFUND-SHOP-1271');
select pg_temp.ret_dispo('FLIP-1272', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1282', 'approved');
select pg_temp.ret_set('AMAZ-1372', 'approved');
select pg_temp.ret_reject('AMAZ-1372');
select pg_temp.ret_new('FLIP-1292', 'Colour different from photo', 'webhook');
select pg_temp.rto_new('SHOP-1304', 'AWB31000935', 'Customer unreachable');
select pg_temp.cod_collect(array['FLIP-1297']::text[]);
select pg_temp.settle_pay('SHP-STL-20260817', 0.0);
select pg_temp.retime();

-- Thu 27 Aug 2026
select pg_temp.day('2026-08-27');
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Ludhiana Winter Wear Co (ref R145)', 'LWW/26/0168', 1);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Rajdhani Shirting Mills (ref R146)', 'RSM/26/0324', 1);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R149)', 'TKF/26/0430', 1);
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R150)', 'TKF/26/0438', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1318','Flipkart - Seller Hub','2026-08-27 17:43+05:30','Neha Patel','prepaid',837.0,0.0,41.85,878.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1319','Flipkart - Seller Hub','2026-08-27 17:14+05:30','Jigar Chauhan','prepaid',5445.0,816.75,231.42,4859.67,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1320','Flipkart - Seller Hub','2026-08-27 10:32+05:30','Riya Shah','prepaid',2598.0,259.8,116.91,2455.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1413','Amazon - Seller Central','2026-08-27 13:39+05:30','Mitul Dave','prepaid',4998.0,749.7,632.21,4880.51,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1414','Amazon - Seller Central','2026-08-27 22:24+05:30','Vipul Gandhi','prepaid',2798.0,0.0,139.9,2937.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1415','Amazon - Seller Central','2026-08-27 09:26+05:30','Shreya Banerjee','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1416','Amazon - Seller Central','2026-08-27 13:12+05:30','Rohit Iyer','prepaid',2198.0,329.7,93.41,1961.71,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1329','Shopify - Main Store','2026-08-27 22:02+05:30','Neha Patel','prepaid',949.0,47.45,45.08,946.63,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1417','Amazon - Seller Central','2026-08-27 09:29+05:30','Foram Thakkar','prepaid',279.0,41.85,11.86,249.01,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1418','Amazon - Seller Central','2026-08-27 18:13+05:30','Pratik Lad','cod',5046.0,0.0,252.3,5298.3,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1419','Amazon - Seller Central','2026-08-27 11:28+05:30','Dev Trivedi','prepaid',1886.0,0.0,94.3,1980.3,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1318','GLEG-BLK-45Y',2,279,0.0,27.9),
('FLIP-1318','GLEG-BLK-89Y',1,279,0.0,13.95),
('FLIP-1319','WKRT-PNK-L',1,849,127.35,36.08),
('FLIP-1319','WJNS-IND-28',2,1349,404.7,114.67),
('FLIP-1319','BKUR-MUS-67Y',2,949,284.7,80.67),
('FLIP-1320','MHOD-BLK-M',2,1299,259.8,116.91),
('AMAZ-1413','MBLZ-NVY-42',1,3799,569.85,581.25),
('AMAZ-1413','MCHN-OLV-34',1,1199,179.85,50.96),
('AMAZ-1414','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1414','WSAR-BLU-FREE',1,2199,0.0,109.95),
('AMAZ-1415','BTEE-BLU-67Y',1,329,0.0,16.45),
('AMAZ-1416','WJNS-IND-28',1,1349,202.35,57.33),
('AMAZ-1416','WKRT-PNK-S',1,849,127.35,36.08),
('SHOP-1329','BKUR-MUS-67Y',1,949,47.45,45.08),
('AMAZ-1417','GLEG-BLK-89Y',1,279,41.85,11.86),
('AMAZ-1418','WJNS-IND-28',1,1349,0.0,67.45),
('AMAZ-1418','WDRS-FLR-S',1,1499,0.0,74.95),
('AMAZ-1418','WKRT-TEL-XL',1,849,0.0,42.45),
('AMAZ-1418','WJNS-BLK-30',1,1349,0.0,67.45),
('AMAZ-1419','GLEG-BLK-89Y',2,279,0.0,27.9),
('AMAZ-1419','GJNS-IND-45Y',1,779,0.0,38.95),
('AMAZ-1419','GNGT-PNK-1011Y',1,549,0.0,27.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1418','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1277');
select pg_temp.ret_set('FLIP-1282', 'pickup');
select pg_temp.rto_recv('AMAZ-1368', 'good', 'restocked');
select pg_temp.ret_new('FLIP-1287', 'Fabric quality not as expected', 'webhook');
select pg_temp.rto_set('FLIP-1289', 'in_transit');
select pg_temp.ret_set('FLIP-1292', 'approved');
select pg_temp.ret_new('AMAZ-1383', 'Item arrived damaged', 'webhook');
select pg_temp.rto_new('FLIP-1298', 'AWB31000944', 'Customer unreachable');
select pg_temp.cod_collect(array['SHOP-1310']::text[]);
select pg_temp.cod_collect(array['SHOP-1316']::text[]);
select pg_temp.claim_step('SHOP-1271', 'other', 'claimed', null);
select pg_temp.retime();

-- Fri 28 Aug 2026
select pg_temp.day('2026-08-28');
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Krishna Denim Works (ref R152)', 'DC-KDW-0142', '[{"sku":"MJNS-IND-32","q":8,"a":8,"r":0},{"sku":"MCHN-OLV-30","q":8,"a":8,"r":0},{"sku":"WJNS-IND-30","q":10,"a":10,"r":0},{"sku":"WJNS-BLK-32","q":10,"a":10,"r":0},{"sku":"GJNS-IND-45Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Rajdhani Shirting Mills (ref R154)', 'DC-RSM-0142', '[{"sku":"MSHC-GRN-L","q":8,"a":8,"r":0},{"sku":"MKUR-WHT-XL","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Shree Ambika Textiles (ref R156)', 'DC-SAT-0136', '[{"sku":"WKRT-TEL-L","q":4,"a":4,"r":0},{"sku":"WLHG-MAG-L","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1330','Shopify - Main Store','2026-08-28 17:25+05:30','Isha Gupta','prepaid',2646.0,264.6,119.08,2500.48,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1420','Amazon - Seller Central','2026-08-28 12:25+05:30','Dev Trivedi','cod',658.0,0.0,32.9,690.9,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1321','Flipkart - Seller Hub','2026-08-28 19:32+05:30','Aarav Mehta','prepaid',1399.0,209.85,59.46,1248.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1331','Shopify - Main Store','2026-08-28 19:02+05:30','Ritu Saxena','prepaid',949.0,47.45,45.08,946.63,'cancelled','refunded','Rajasthan','Surat Main Warehouse'),
('AMAZ-1421','Amazon - Seller Central','2026-08-28 13:02+05:30','Divya Nair','prepaid',2225.0,111.25,105.68,2219.43,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1322','Flipkart - Seller Hub','2026-08-28 12:45+05:30','Anjali Verma','prepaid',599.0,0.0,29.95,628.95,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('AMAZ-1422','Amazon - Seller Central','2026-08-28 15:13+05:30','Kunal Desai','prepaid',899.0,134.85,38.21,802.36,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1423','Amazon - Seller Central','2026-08-28 10:41+05:30','Riya Shah','prepaid',1547.0,232.05,65.75,1380.7,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1424','Amazon - Seller Central','2026-08-28 20:36+05:30','Karan Malhotra','prepaid',1837.0,275.55,78.08,1639.53,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1323','Flipkart - Seller Hub','2026-08-28 10:27+05:30','Kiran Naik','prepaid',1548.0,77.4,73.53,1544.13,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1330','WJNS-BLK-30',1,1349,134.9,60.71),
('SHOP-1330','WLEG-NVY-L',2,349,69.8,31.41),
('SHOP-1330','WTOP-WHT-L',1,599,59.9,26.96),
('AMAZ-1420','BTEE-RED-67Y',2,329,0.0,32.9),
('FLIP-1321','MJNS-BLK-34',1,1399,209.85,59.46),
('SHOP-1331','BKUR-CRM-67Y',1,949,47.45,45.08),
('AMAZ-1421','GLEG-PNK-67Y',1,279,13.95,13.25),
('AMAZ-1421','WTOP-PCH-M',1,599,29.95,28.45),
('AMAZ-1421','WDUP-SLV-FREE',3,449,67.35,63.98),
('FLIP-1322','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1422','MSHC-RED-XL',1,899,134.85,38.21),
('AMAZ-1423','WTOP-PCH-L',1,599,89.85,25.46),
('AMAZ-1423','WLEG-NVY-M',1,349,52.35,14.83),
('AMAZ-1423','WPAL-WHT-XL',1,599,89.85,25.46),
('AMAZ-1424','GLEG-BLK-67Y',1,279,41.85,11.86),
('AMAZ-1424','GJNS-IND-1011Y',2,779,233.7,66.22),
('FLIP-1323','MSHC-RED-XL',1,899,44.95,42.7),
('FLIP-1323','MTRK-BLK-M',1,649,32.45,30.83)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1420','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1277', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1287', 'approved');
select pg_temp.ret_set('FLIP-1292', 'pickup');
select pg_temp.ret_set('AMAZ-1383', 'approved');
select pg_temp.rto_set('SHOP-1304', 'in_transit');
select pg_temp.ret_new('FLIP-1299', 'Customer changed mind', 'webhook');
select pg_temp.rto_new('FLIP-1301', 'AWB31000949', 'Address incomplete');
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-28AUG', array['FLIP-1290']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-28AUG', array['SHOP-1294','SHOP-1303']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-28AUG', array['SHOP-1299']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-28AUG', array['AMAZ-1359']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-28AUG', array['FLIP-1285','SHOP-1301','FLIP-1297']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-08-31', 'ICIC000000886731', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-08-31', 'ICIC000000886800', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-08-31', 'ICIC000000886826', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-08-31', 'ICIC000000886915', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-08-31', 'ICIC000000886960', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-08-31', 'ICIC000000887050', 1);
select pg_temp.claim_recover('AMAZ-1264', 'damaged_return', 'CLAIM-CR-AMAZ-1264');
select pg_temp.claim_step('FLIP-1254', 'damaged_return', 'claimed', null);
select pg_temp.claim_step('AMAZ-1332', 'incorrect_deduction', 'claimed', null);
select pg_temp.retime();

-- Sat 29 Aug 2026
select pg_temp.day('2026-08-29');
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Krishna Denim Works (ref R151)', 'DC-KDW-0139', '[{"sku":"MJNS-IND-30","q":6,"a":6,"r":0},{"sku":"MCHN-OLV-30","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Krishna Denim Works (ref R152)', 'KDW/26/0343', 1);
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Rajdhani Shirting Mills (ref R154)', 'RSM/26/0339', 1);
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Shree Ambika Textiles (ref R155)', 'DC-SAT-0133', '[{"sku":"WSAR-GRN-FREE","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Shree Ambika Textiles (ref R156)', 'SAT/26/0330', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1425','Amazon - Seller Central','2026-08-29 16:06+05:30','Karan Malhotra','prepaid',7494.0,0.0,725.57,8219.57,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1332','Shopify - Main Store','2026-08-29 10:11+05:30','Rahul Bhatt','cod',2547.0,127.35,120.98,2540.63,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1324','Flipkart - Seller Hub','2026-08-29 16:51+05:30','Vivek Singh','prepaid',1399.0,69.95,66.45,1395.5,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1333','Shopify - Main Store','2026-08-29 16:55+05:30','Mehul Shukla','prepaid',1399.0,139.9,62.96,1322.06,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1325','Flipkart - Seller Hub','2026-08-29 20:33+05:30','Amit Sethi','prepaid',3697.0,554.55,157.13,3299.58,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1326','Flipkart - Seller Hub','2026-08-29 14:01+05:30','Dev Trivedi','cod',2998.0,449.7,127.42,2675.72,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('SHOP-1334','Shopify - Main Store','2026-08-29 09:28+05:30','Harsh Modi','prepaid',3296.0,0.0,164.8,3460.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1426','Amazon - Seller Central','2026-08-29 13:31+05:30','Jigar Chauhan','prepaid',4745.0,0.0,237.25,4982.25,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1335','Shopify - Main Store','2026-08-29 10:47+05:30','Amit Sethi','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1425','WDRS-FLR-S',2,1499,0.0,149.9),
('AMAZ-1425','WJKT-BLK-XL',1,2699,0.0,485.82),
('AMAZ-1425','WTOP-PCH-L',3,599,0.0,89.85),
('SHOP-1332','WTOP-WHT-M',1,599,29.95,28.45),
('SHOP-1332','WJNS-BLK-30',1,1349,67.45,64.08),
('SHOP-1332','WTOP-PCH-M',1,599,29.95,28.45),
('FLIP-1324','MJNS-BLK-32',1,1399,69.95,66.45),
('SHOP-1333','MJNS-IND-32',1,1399,139.9,62.96),
('FLIP-1325','MJNS-BLK-32',2,1399,419.7,118.92),
('FLIP-1325','MSHC-GRN-XL',1,899,134.85,38.21),
('FLIP-1326','WDRS-FLR-S',2,1499,449.7,127.42),
('SHOP-1334','MKUR-MUS-M',1,1099,0.0,54.95),
('SHOP-1334','MSHC-RED-M',1,899,0.0,44.95),
('SHOP-1334','MTRK-BLK-M',2,649,0.0,64.9),
('AMAZ-1426','MSHC-GRN-L',3,899,0.0,134.85),
('AMAZ-1426','MTRK-BLK-M',1,649,0.0,32.45),
('AMAZ-1426','MJNS-IND-34',1,1399,0.0,69.95),
('SHOP-1335','BTEE-RED-89Y',1,329,32.9,14.81)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1332','DTDC - Ring Road Surat'),
('FLIP-1326','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1282', 'in_transit');
select pg_temp.ret_set('FLIP-1287', 'pickup');
select pg_temp.ret_set('AMAZ-1383', 'pickup');
select pg_temp.rto_set('FLIP-1298', 'in_transit');
select pg_temp.ret_set('FLIP-1299', 'approved');
select pg_temp.cod_collect(array['SHOP-1328']::text[]);
select pg_temp.retime();

-- Sun 30 Aug 2026
select pg_temp.day('2026-08-30');
select pg_temp.grn_new('Weekly replenishment 17 Aug 2026 - Ludhiana Winter Wear Co (ref R145)', 'DC-LWW-0070', '[{"sku":"MHOD-GRY-M","q":3,"a":3,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Krishna Denim Works (ref R151)', 'KDW/26/0333', 1);
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Rajdhani Shirting Mills (ref R153)', 'DC-RSM-0139', '[{"sku":"BSHF-WHT-45Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Shree Ambika Textiles (ref R155)', 'SAT/26/0318', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1327','Flipkart - Seller Hub','2026-08-30 21:25+05:30','Nidhi Agarwal','prepaid',349.0,52.35,14.83,311.48,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1427','Amazon - Seller Central','2026-08-30 09:08+05:30','Harsh Modi','prepaid',1399.0,69.95,66.45,1395.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1428','Amazon - Seller Central','2026-08-30 18:45+05:30','Nikhil Pandey','prepaid',2396.0,359.4,101.84,2138.44,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1429','Amazon - Seller Central','2026-08-30 13:28+05:30','Kavya Menon','cod',4446.0,0.0,222.3,4668.3,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1430','Amazon - Seller Central','2026-08-30 10:47+05:30','Rohit Iyer','prepaid',1278.0,191.7,54.31,1140.61,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1431','Amazon - Seller Central','2026-08-30 12:29+05:30','Meghna Rao','prepaid',1198.0,179.7,50.92,1069.22,'delivered','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1336','Shopify - Main Store','2026-08-30 10:56+05:30','Jigar Chauhan','prepaid',2277.0,0.0,113.85,2390.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1328','Flipkart - Seller Hub','2026-08-30 20:43+05:30','Vipul Gandhi','cod',5153.0,515.3,231.89,4869.59,'delivered','pending','Delhi','Surat Main Warehouse'),
('SHOP-1337','Shopify - Main Store','2026-08-30 09:16+05:30','Tanvi Rana','prepaid',1926.0,0.0,96.3,2022.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1329','Flipkart - Seller Hub','2026-08-30 12:12+05:30','Vipul Gandhi','prepaid',1349.0,134.9,60.71,1274.81,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1338','Shopify - Main Store','2026-08-30 19:10+05:30','Dev Trivedi','cod',549.0,54.9,24.71,518.81,'shipped','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1432','Amazon - Seller Central','2026-08-30 09:23+05:30','Sanjay Gajera','cod',3347.0,0.0,167.35,3514.35,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1339','Shopify - Main Store','2026-08-30 11:51+05:30','Sejal Kapadia','cod',1547.0,0.0,77.35,1624.35,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1433','Amazon - Seller Central','2026-08-30 17:01+05:30','Rohit Iyer','prepaid',1848.0,0.0,92.4,1940.4,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1327','BSHT-GRY-89Y',1,349,52.35,14.83),
('AMAZ-1427','MJNS-BLK-32',1,1399,69.95,66.45),
('AMAZ-1428','WTOP-PCH-M',2,599,179.7,50.92),
('AMAZ-1428','WTOP-WHT-M',2,599,179.7,50.92),
('AMAZ-1429','MJNS-BLK-32',1,1399,0.0,69.95),
('AMAZ-1429','MSHF-WHT-L',1,999,0.0,49.95),
('AMAZ-1429','MJNS-BLK-30',1,1399,0.0,69.95),
('AMAZ-1429','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1430','BKUR-CRM-89Y',1,949,142.35,40.33),
('AMAZ-1430','BTEE-RED-67Y',1,329,49.35,13.98),
('AMAZ-1431','WTOP-PCH-L',1,599,89.85,25.46),
('AMAZ-1431','WTOP-WHT-M',1,599,89.85,25.46),
('SHOP-1336','WJNS-BLK-30',1,1349,0.0,67.45),
('SHOP-1336','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1336','BTEE-BLU-45Y',1,329,0.0,16.45),
('FLIP-1328','GFRK-PNK-67Y',2,749,149.8,67.41),
('FLIP-1328','GLEG-BLK-67Y',2,279,55.8,25.11),
('FLIP-1328','GLHG-RED-67Y',1,1999,199.9,89.96),
('FLIP-1328','GNGT-PNK-89Y',2,549,109.8,49.41),
('SHOP-1337','GNGT-PNK-1011Y',3,549,0.0,82.35),
('SHOP-1337','GLEG-BLK-89Y',1,279,0.0,13.95),
('FLIP-1329','WJNS-BLK-32',1,1349,134.9,60.71),
('SHOP-1338','GNGT-PNK-45Y',1,549,54.9,24.71),
('AMAZ-1432','MCHN-KHK-30',2,1199,0.0,119.9),
('AMAZ-1432','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1339','BSHT-NVY-45Y',1,349,0.0,17.45),
('SHOP-1339','WTOP-PCH-M',2,599,0.0,59.9),
('AMAZ-1433','MSHC-GRN-M',1,899,0.0,44.95),
('AMAZ-1433','BKUR-MUS-67Y',1,949,0.0,47.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1429','Xpressbees - Pandesara'),
('FLIP-1328','Delhivery - Sachin GIDC Surat'),
('AMAZ-1432','Delhivery - Sachin GIDC Surat'),
('SHOP-1339','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1292', 'in_transit');
select pg_temp.ret_set('FLIP-1299', 'pickup');
select pg_temp.rto_set('FLIP-1301', 'in_transit');
select pg_temp.ret_new('SHOP-1315', 'Size did not fit', 'manual');
select pg_temp.cod_collect(array['SHOP-1321']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260817', 0.0);
select pg_temp.claim_step('AMAZ-1318', 'other', 'approved', 1133.25);
select pg_temp.retime();

-- Mon 31 Aug 2026
select pg_temp.day('2026-08-31');
select pg_temp.bill_po('Weekly replenishment 17 Aug 2026 - Ludhiana Winter Wear Co (ref R145)', 'LWW/26/0170', 1);
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Rajdhani Shirting Mills (ref R153)', 'RSM/26/0331', 1);
select pg_temp.po_new('Weekly replenishment 31 Aug 2026 - Krishna Denim Works (ref R159)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-IND-30","q":10},{"sku":"WJNS-BLK-30","q":12},{"sku":"GJNS-IND-1011Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 31 Aug 2026 - Little Stitch Garments (ref R160)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLR-S","q":22},{"sku":"WDRS-FLP-L","q":8},{"sku":"BSHT-GRY-89Y","q":6},{"sku":"BKUR-CRM-89Y","q":10},{"sku":"BKUR-MUS-67Y","q":14},{"sku":"BKUR-MUS-89Y","q":8},{"sku":"GLHG-RED-67Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 31 Aug 2026 - Ludhiana Winter Wear Co (ref R161)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"MHOD-BLK-M","q":8},{"sku":"MHOD-BLK-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 31 Aug 2026 - Rajdhani Shirting Mills (ref R162)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHC-GRN-L","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 31 Aug 2026 - Shree Ambika Textiles (ref R163)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WPAL-YLW-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 31 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R164)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-BLK-M","q":6},{"sku":"MTEE-BLK-XL","q":6},{"sku":"WLEG-BLK-M","q":10},{"sku":"WTOP-WHT-L","q":10},{"sku":"GLEG-PNK-67Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 31 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R165)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"WTOP-PCH-L","q":38},{"sku":"BTEE-RED-67Y","q":8},{"sku":"GLEG-PNK-67Y","q":18}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1340','Shopify - Main Store','2026-08-31 09:17+05:30','Kavya Menon','prepaid',2798.0,0.0,139.9,2937.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1341','Shopify - Main Store','2026-08-31 11:45+05:30','Aditi Joshi','cod',1297.0,194.55,55.13,1157.58,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1330','Flipkart - Seller Hub','2026-08-31 18:19+05:30','Jigar Chauhan','cod',4347.0,434.7,195.62,4107.92,'shipped','pending','Delhi','Surat Main Warehouse'),
('SHOP-1342','Shopify - Main Store','2026-08-31 12:17+05:30','Shreya Banerjee','cod',8193.0,409.65,389.17,8172.52,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1343','Shopify - Main Store','2026-08-31 15:25+05:30','Sagar Rathod','prepaid',4446.0,222.3,211.18,4434.88,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1434','Amazon - Seller Central','2026-08-31 17:48+05:30','Rohit Iyer','cod',3645.0,182.25,173.14,3635.89,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1435','Amazon - Seller Central','2026-08-31 15:17+05:30','Sanjay Gajera','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1344','Shopify - Main Store','2026-08-31 11:46+05:30','Riya Shah','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1436','Amazon - Seller Central','2026-08-31 17:48+05:30','Vipul Gandhi','prepaid',2198.0,329.7,93.42,1961.72,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1331','Flipkart - Seller Hub','2026-08-31 21:34+05:30','Kunal Desai','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1340','WSAR-RED-FREE',1,2199,0.0,109.95),
('SHOP-1340','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1341','WTOP-PCH-L',1,599,89.85,25.46),
('SHOP-1341','WLEG-NVY-L',2,349,104.7,29.67),
('FLIP-1330','WDRS-FLP-L',2,1499,299.8,134.91),
('FLIP-1330','WJNS-IND-32',1,1349,134.9,60.71),
('SHOP-1342','MCHN-KHK-34',3,1199,179.85,170.86),
('SHOP-1342','MCHN-OLV-32',1,1199,59.95,56.95),
('SHOP-1342','MKUR-WHT-L',2,1099,109.9,104.41),
('SHOP-1342','MCHN-KHK-30',1,1199,59.95,56.95),
('SHOP-1343','GLHG-TEL-67Y',1,1999,99.95,94.95),
('SHOP-1343','MKUR-MUS-XL',1,1099,54.95,52.2),
('SHOP-1343','MTRK-BLK-XL',1,649,32.45,30.83),
('SHOP-1343','MPOL-MRN-L',1,699,34.95,33.2),
('AMAZ-1434','BTRK-BLK-89Y',1,999,49.95,47.45),
('AMAZ-1434','WPAL-YLW-M',2,599,59.9,56.91),
('AMAZ-1434','WKRT-PNK-L',1,849,42.45,40.33),
('AMAZ-1434','WPAL-YLW-XL',1,599,29.95,28.45),
('AMAZ-1435','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1344','WTOP-PCH-M',3,599,0.0,89.85),
('AMAZ-1436','MKUR-WHT-XL',2,1099,329.7,93.42),
('FLIP-1331','WTOP-WHT-M',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1341','Delhivery - Sachin GIDC Surat'),
('SHOP-1342','Bluedart - Surat City'),
('AMAZ-1434','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1287', 'in_transit');
select pg_temp.ret_set('AMAZ-1383', 'in_transit');
select pg_temp.rto_recv('SHOP-1304', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1315', 'approved');
select pg_temp.cod_collect(array['SHOP-1319']::text[]);
select pg_temp.cod_collect(array['SHOP-1322']::text[]);
select pg_temp.rto_new('SHOP-1323', 'AWB31000979', 'Customer unreachable');
select pg_temp.cod_collect(array['SHOP-1325']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260824', '2026-08-24', '2026-08-30', array['AMAZ-1373','AMAZ-1378','AMAZ-1381','AMAZ-1383','AMAZ-1385','AMAZ-1388','AMAZ-1391','AMAZ-1376','AMAZ-1377','AMAZ-1380','AMAZ-1382','AMAZ-1386','AMAZ-1387','AMAZ-1390','AMAZ-1392','AMAZ-1379','AMAZ-1396','AMAZ-1399','AMAZ-1393','AMAZ-1394','AMAZ-1400','AMAZ-1404','AMAZ-1403','AMAZ-1406','AMAZ-1397','AMAZ-1398','AMAZ-1402','AMAZ-1401','AMAZ-1405','AMAZ-1408','AMAZ-1409','AMAZ-1414','AMAZ-1415']::text[], array[]::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260824', '2026-08-24', '2026-08-30', array['FLIP-1295','FLIP-1296','FLIP-1287','FLIP-1291','FLIP-1299','FLIP-1293','FLIP-1302','FLIP-1303','FLIP-1305','FLIP-1300','FLIP-1304','FLIP-1306','FLIP-1309','FLIP-1310','FLIP-1312','FLIP-1316','FLIP-1308','FLIP-1314']::text[], array['FLIP-1264','FLIP-1272','FLIP-1277']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260824', '2026-08-24', '2026-08-30', array['SHOP-1298','SHOP-1300','SHOP-1302','SHOP-1307','SHOP-1308','SHOP-1306','SHOP-1312','SHOP-1311','SHOP-1314','SHOP-1305','SHOP-1315','SHOP-1318','SHOP-1313','SHOP-1317','SHOP-1320','SHOP-1329']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 01 Sep 2026
select pg_temp.day('2026-09-01');
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Shree Ambika Textiles (ref R156)', 'DC-SAT-0139', '[{"sku":"WKRT-TEL-L","q":2,"a":2,"r":0},{"sku":"WLHG-MAG-L","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R158)', 'DC-TKF-0190', '[{"sku":"MTEE-WHT-M","q":5,"a":5,"r":0},{"sku":"WTOP-PCH-L","q":16,"a":16,"r":0},{"sku":"GLEG-PNK-67Y","q":14,"a":14,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1345','Shopify - Main Store','2026-09-01 20:45+05:30','Aarav Mehta','prepaid',2278.0,227.8,102.52,2152.72,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1437','Amazon - Seller Central','2026-09-01 19:01+05:30','Vipul Gandhi','prepaid',1099.0,54.95,52.2,1096.25,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1438','Amazon - Seller Central','2026-09-01 13:11+05:30','Mehul Shukla','cod',649.0,64.9,29.21,613.31,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1439','Amazon - Seller Central','2026-09-01 11:47+05:30','Meghna Rao','prepaid',2698.0,269.8,121.42,2549.62,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1346','Shopify - Main Store','2026-09-01 11:24+05:30','Anjali Verma','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1440','Amazon - Seller Central','2026-09-01 20:51+05:30','Prachi Kulkarni','prepaid',349.0,34.9,15.71,329.81,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1441','Amazon - Seller Central','2026-09-01 19:49+05:30','Aditi Joshi','prepaid',349.0,52.35,14.83,311.48,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1442','Amazon - Seller Central','2026-09-01 09:54+05:30','Mehul Shukla','prepaid',2278.0,113.9,108.2,2272.3,'delivered','paid','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1345','GLHG-RED-89Y',1,1999,199.9,89.96),
('SHOP-1345','GLEG-PNK-67Y',1,279,27.9,12.56),
('AMAZ-1437','MKUR-MUS-M',1,1099,54.95,52.2),
('AMAZ-1438','MTRK-BLK-L',1,649,64.9,29.21),
('AMAZ-1439','MHOD-BLK-XL',1,1299,129.9,58.46),
('AMAZ-1439','MJNS-IND-32',1,1399,139.9,62.96),
('SHOP-1346','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1440','WLEG-MAR-M',1,349,34.9,15.71),
('AMAZ-1441','BSHT-GRY-67Y',1,349,52.35,14.83),
('AMAZ-1442','GJNS-IND-1011Y',1,779,38.95,37.0),
('AMAZ-1442','WDRS-FLP-S',1,1499,74.95,71.2)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1438','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1282');
select pg_temp.ret_new('AMAZ-1379', 'Customer changed mind', 'webhook');
select pg_temp.ret_new('SHOP-1305', 'Size did not fit', 'manual');
select pg_temp.ret_set('FLIP-1299', 'in_transit');
select pg_temp.ret_set('SHOP-1315', 'pickup');
select pg_temp.cod_collect(array['SHOP-1324']::text[]);
select pg_temp.cod_collect(array['AMAZ-1418']::text[]);
select pg_temp.settle_pay('FLK-STL-20260817', -60.0);
select pg_temp.claim_step('FLIP-1256', 'damaged_return', 'approved', null);
select pg_temp.retime();

-- Wed 02 Sep 2026
select pg_temp.day('2026-09-02');
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Shree Ambika Textiles (ref R156)', 'SAT/26/0337', 1);
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R158)', 'TKF/26/0454', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1332','Flipkart - Seller Hub','2026-09-02 11:29+05:30','Sejal Kapadia','prepaid',698.0,0.0,34.9,732.9,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1333','Flipkart - Seller Hub','2026-09-02 21:12+05:30','Jigar Chauhan','prepaid',5246.0,524.6,236.08,4957.48,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1443','Amazon - Seller Central','2026-09-02 09:38+05:30','Neha Patel','prepaid',599.0,89.85,25.46,534.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1444','Amazon - Seller Central','2026-09-02 13:17+05:30','Rohit Iyer','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1445','Amazon - Seller Central','2026-09-02 17:04+05:30','Vipul Gandhi','prepaid',558.0,83.7,23.72,498.02,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1334','Flipkart - Seller Hub','2026-09-02 14:31+05:30','Kiran Naik','prepaid',2698.0,134.9,128.16,2691.26,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1347','Shopify - Main Store','2026-09-02 09:59+05:30','Shreya Banerjee','cod',1798.0,89.9,85.41,1793.51,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('AMAZ-1446','Amazon - Seller Central','2026-09-02 20:56+05:30','Bhavna Solanki','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1335','Flipkart - Seller Hub','2026-09-02 15:23+05:30','Dev Trivedi','prepaid',5425.0,271.25,257.69,5411.44,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1348','Shopify - Main Store','2026-09-02 16:07+05:30','Vivek Singh','prepaid',2697.0,269.7,121.38,2548.68,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1447','Amazon - Seller Central','2026-09-02 16:32+05:30','Sagar Rathod','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1332','WLEG-MAR-M',2,349,0.0,34.9),
('FLIP-1333','WSAR-RED-FREE',1,2199,219.9,98.96),
('FLIP-1333','WKRT-TEL-M',2,849,169.8,76.41),
('FLIP-1333','WJNS-BLK-28',1,1349,134.9,60.71),
('AMAZ-1443','WTOP-PCH-L',1,599,89.85,25.46),
('AMAZ-1444','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1445','GLEG-PNK-67Y',1,279,41.85,11.86),
('AMAZ-1445','GLEG-BLK-89Y',1,279,41.85,11.86),
('FLIP-1334','WJNS-IND-32',2,1349,134.9,128.16),
('SHOP-1347','MSHC-GRN-L',2,899,89.9,85.41),
('AMAZ-1446','WDRS-FLP-M',1,1499,0.0,74.95),
('AMAZ-1446','WTOP-PCH-M',1,599,0.0,29.95),
('FLIP-1335','GLHG-TEL-67Y',2,1999,199.9,189.91),
('FLIP-1335','GLEG-BLK-67Y',1,279,13.95,13.25),
('FLIP-1335','WPAL-YLW-XL',1,599,29.95,28.45),
('FLIP-1335','GNGT-PNK-89Y',1,549,27.45,26.08),
('SHOP-1348','WDRS-FLR-L',1,1499,149.9,67.46),
('SHOP-1348','WTOP-WHT-L',1,599,59.9,26.96),
('SHOP-1348','WTOP-PCH-L',1,599,59.9,26.96),
('AMAZ-1447','WKRT-PNK-S',1,849,0.0,42.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('FLIP-1282', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1379', 'approved');
select pg_temp.ret_set('SHOP-1305', 'approved');
select pg_temp.rto_recv('FLIP-1298', 'good', 'restocked');
select pg_temp.rto_set('SHOP-1323', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1332']::text[]);
select pg_temp.settle_pay('SHP-STL-20260824', 0.0);
select pg_temp.retime();

-- Thu 03 Sep 2026
select pg_temp.day('2026-09-03');
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R157)', 'DC-TKF-0187', '[{"sku":"MTEE-BLK-XL","q":6,"a":6,"r":0},{"sku":"WLEG-BLK-M","q":8,"a":8,"r":0},{"sku":"WLEG-MAR-M","q":6,"a":6,"r":0},{"sku":"WTOP-WHT-L","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-67Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 31 Aug 2026 - Little Stitch Garments (ref R160)', 'DC-LSG-0130', '[{"sku":"WDRS-FLR-S","q":22,"a":22,"r":0},{"sku":"WDRS-FLP-L","q":8,"a":8,"r":0},{"sku":"BSHT-GRY-89Y","q":6,"a":6,"r":0},{"sku":"BKUR-CRM-89Y","q":10,"a":9,"r":1},{"sku":"BKUR-MUS-67Y","q":14,"a":13,"r":1},{"sku":"BKUR-MUS-89Y","q":8,"a":8,"r":0},{"sku":"GLHG-RED-67Y","q":6,"a":5,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 31 Aug 2026 - Shree Ambika Textiles (ref R163)', 'DC-SAT-0142', '[{"sku":"WPAL-YLW-M","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1336','Flipkart - Seller Hub','2026-09-03 15:57+05:30','Amit Sethi','cod',599.0,59.9,26.96,566.06,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1349','Shopify - Main Store','2026-09-03 17:43+05:30','Sonal Parekh','prepaid',349.0,52.35,14.83,311.48,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1350','Shopify - Main Store','2026-09-03 20:28+05:30','Kiran Naik','cod',4044.0,202.2,192.1,4033.9,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('SHOP-1351','Shopify - Main Store','2026-09-03 19:10+05:30','Pratik Lad','cod',329.0,32.9,14.81,310.91,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1352','Shopify - Main Store','2026-09-03 18:24+05:30','Ritu Saxena','prepaid',4696.0,0.0,234.8,4930.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1448','Amazon - Seller Central','2026-09-03 20:05+05:30','Manav Joshi','prepaid',4795.0,719.25,203.8,4279.55,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1353','Shopify - Main Store','2026-09-03 10:37+05:30','Kiran Naik','prepaid',4835.0,241.75,229.67,4822.92,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1449','Amazon - Seller Central','2026-09-03 20:14+05:30','Meghna Rao','prepaid',3146.0,471.9,133.71,2807.81,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1450','Amazon - Seller Central','2026-09-03 11:49+05:30','Yash Vora','prepaid',949.0,142.35,40.33,846.98,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1451','Amazon - Seller Central','2026-09-03 09:04+05:30','Dev Trivedi','prepaid',999.0,0.0,49.95,1048.95,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1336','WPAL-YLW-L',1,599,59.9,26.96),
('SHOP-1349','BSHT-GRY-89Y',1,349,52.35,14.83),
('SHOP-1350','WJNS-BLK-28',1,1349,67.45,64.08),
('SHOP-1350','WTOP-WHT-L',3,599,89.85,85.36),
('SHOP-1350','WDUP-SLV-FREE',2,449,44.9,42.66),
('SHOP-1351','BTEE-RED-45Y',1,329,32.9,14.81),
('SHOP-1352','GTOP-WHT-89Y',2,349,0.0,34.9),
('SHOP-1352','GLHG-RED-67Y',2,1999,0.0,199.9),
('AMAZ-1448','MPOL-MRN-XL',2,699,209.7,59.42),
('AMAZ-1448','MSHF-SKY-XL',2,999,299.7,84.92),
('AMAZ-1448','MJNS-IND-34',1,1399,209.85,59.46),
('SHOP-1353','GLEG-PNK-67Y',2,279,27.9,26.51),
('SHOP-1353','GLHG-TEL-45Y',2,1999,199.9,189.91),
('SHOP-1353','GLEG-BLK-45Y',1,279,13.95,13.25),
('AMAZ-1449','WJNS-IND-32',1,1349,202.35,57.33),
('AMAZ-1449','WTOP-WHT-M',1,599,89.85,25.46),
('AMAZ-1449','WTOP-PCH-L',2,599,179.7,50.92),
('AMAZ-1450','BKUR-CRM-67Y',1,949,142.35,40.33),
('AMAZ-1451','MSHF-SKY-M',1,999,0.0,49.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1336','DTDC - Ring Road Surat'),
('SHOP-1350','DTDC - Ring Road Surat'),
('SHOP-1351','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1287');
select pg_temp.ret_recv('FLIP-1292');
select pg_temp.ret_set('AMAZ-1379', 'pickup');
select pg_temp.ret_recv('AMAZ-1383');
select pg_temp.ret_set('SHOP-1305', 'pickup');
select pg_temp.ret_set('SHOP-1315', 'in_transit');
select pg_temp.cod_collect(array['AMAZ-1420']::text[]);
select pg_temp.cod_collect(array['FLIP-1328']::text[]);
select pg_temp.rto_new('SHOP-1338', 'AWB31000991', 'Address incomplete');
select pg_temp.cod_collect(array['SHOP-1339']::text[]);
select pg_temp.cod_collect(array['SHOP-1341']::text[]);
select pg_temp.claim_new('FLIP-1273', 'excess_deduction', 60.0, '2026-10-03');
select pg_temp.retime();

-- Fri 04 Sep 2026
select pg_temp.day('2026-09-04');
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R157)', 'TKF/26/0449', 1);
select pg_temp.bill_po('Weekly replenishment 31 Aug 2026 - Little Stitch Garments (ref R160)', 'LSG/26/0316', 1);
select pg_temp.bill_po('Weekly replenishment 31 Aug 2026 - Shree Ambika Textiles (ref R163)', 'SAT/26/0339', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1452','Amazon - Seller Central','2026-09-04 21:23+05:30','Jigar Chauhan','prepaid',3347.0,167.35,158.98,3338.63,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1453','Amazon - Seller Central','2026-09-04 19:18+05:30','Kunal Desai','prepaid',9743.0,1461.45,833.88,9115.43,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1454','Amazon - Seller Central','2026-09-04 10:05+05:30','Yash Vora','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1455','Amazon - Seller Central','2026-09-04 20:07+05:30','Shreya Banerjee','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1456','Amazon - Seller Central','2026-09-04 22:30+05:30','Sonal Parekh','prepaid',1798.0,89.9,85.41,1793.51,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1457','Amazon - Seller Central','2026-09-04 09:11+05:30','Kunal Desai','prepaid',1996.0,199.6,89.84,1886.24,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1337','Flipkart - Seller Hub','2026-09-04 19:31+05:30','Jigar Chauhan','cod',558.0,83.7,23.72,498.02,'delivered','pending','Delhi','Surat Main Warehouse'),
('FLIP-1338','Flipkart - Seller Hub','2026-09-04 09:42+05:30','Nidhi Agarwal','prepaid',279.0,27.9,12.56,263.66,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1458','Amazon - Seller Central','2026-09-04 22:21+05:30','Nikhil Pandey','cod',449.0,67.35,19.08,400.73,'delivered','pending','Delhi','Surat Main Warehouse'),
('SHOP-1354','Shopify - Main Store','2026-09-04 19:21+05:30','Chirag Zaveri','prepaid',6197.0,619.7,723.35,6300.65,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1339','Flipkart - Seller Hub','2026-09-04 16:42+05:30','Mitul Dave','prepaid',1748.0,0.0,87.4,1835.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1355','Shopify - Main Store','2026-09-04 12:21+05:30','Pratik Lad','prepaid',5396.0,0.0,269.8,5665.8,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1452','WKRT-TEL-XL',1,849,42.45,40.33),
('AMAZ-1452','MCHN-KHK-30',1,1199,59.95,56.95),
('AMAZ-1452','MHOD-BLK-M',1,1299,64.95,61.7),
('AMAZ-1453','MJNS-BLK-30',1,1399,209.85,59.46),
('AMAZ-1453','MTRK-BLK-L',3,649,292.05,82.75),
('AMAZ-1453','MHOD-BLK-XL',2,1299,389.7,110.42),
('AMAZ-1453','MBLZ-NVY-40',1,3799,569.85,581.25),
('AMAZ-1454','WKRT-TEL-XL',1,849,0.0,42.45),
('AMAZ-1455','WPAL-YLW-XL',1,599,29.95,28.45),
('AMAZ-1456','MSHC-GRN-L',2,899,89.9,85.41),
('AMAZ-1457','WPAL-WHT-M',1,599,59.9,26.96),
('AMAZ-1457','WLEG-MAR-M',1,349,34.9,15.71),
('AMAZ-1457','WDUP-GLD-FREE',1,449,44.9,20.21),
('AMAZ-1457','WPAL-WHT-L',1,599,59.9,26.96),
('FLIP-1337','GLEG-BLK-67Y',2,279,83.7,23.72),
('FLIP-1338','GLEG-PNK-67Y',1,279,27.9,12.56),
('AMAZ-1458','MTEE-WHT-M',1,449,67.35,19.08),
('SHOP-1354','MCHN-OLV-32',2,1199,239.8,107.91),
('SHOP-1354','MBLZ-NVY-40',1,3799,379.9,615.44),
('FLIP-1339','MTRK-BLK-M',1,649,0.0,32.45),
('FLIP-1339','MKUR-MUS-L',1,1099,0.0,54.95),
('SHOP-1355','MJNS-BLK-32',2,1399,0.0,139.9),
('SHOP-1355','MHOD-BLK-L',2,1299,0.0,129.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1337','Delhivery - Sachin GIDC Surat'),
('AMAZ-1458','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1287', 'good', 'restocked');
select pg_temp.ret_dispo('AMAZ-1383', 'damaged', 'quarantined');
select pg_temp.ret_recv('FLIP-1299');
select pg_temp.rto_recv('FLIP-1301', 'good', 'restocked');
select pg_temp.cod_collect(array['FLIP-1326']::text[]);
select pg_temp.cod_collect(array['AMAZ-1432']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-04SEP', array['SHOP-1322']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-04SEP', array['AMAZ-1418']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-04SEP', array['SHOP-1325','SHOP-1332']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-04SEP', array['SHOP-1316','SHOP-1319','SHOP-1321']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-04SEP', array['SHOP-1310','SHOP-1324','SHOP-1328']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-09-07', 'ICIC000000887079', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-09-07', 'ICIC000000887173', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-09-07', 'ICIC000000887246', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-09-07', 'ICIC000000887332', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-09-07', 'ICIC000000887417', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-09-07', 'ICIC000000887505', 1);
select pg_temp.claim_recover('AMAZ-1289', 'lost_shipment', 'CLAIM-CR-AMAZ-1289');
select pg_temp.claim_new('AMAZ-1383', 'damaged_return', 508.19, '2026-10-04');
select pg_temp.retime();

-- Sat 05 Sep 2026
select pg_temp.day('2026-09-05');
select pg_temp.grn_new('Weekly replenishment 24 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R158)', 'DC-TKF-0193', '[{"sku":"MTEE-WHT-M","q":3,"a":3,"r":0},{"sku":"WTOP-PCH-L","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-67Y","q":8,"a":7,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 31 Aug 2026 - Krishna Denim Works (ref R159)', 'DC-KDW-0145', '[{"sku":"MJNS-IND-30","q":10,"a":10,"r":0},{"sku":"WJNS-BLK-30","q":12,"a":12,"r":0},{"sku":"GJNS-IND-1011Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1340','Flipkart - Seller Hub','2026-09-05 15:05+05:30','Pratik Lad','prepaid',3496.0,349.6,157.33,3303.73,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1356','Shopify - Main Store','2026-09-05 09:56+05:30','Rahul Bhatt','cod',1286.0,128.6,57.88,1215.28,'shipped','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1357','Shopify - Main Store','2026-09-05 12:22+05:30','Aarav Mehta','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1341','Flipkart - Seller Hub','2026-09-05 12:02+05:30','Meghna Rao','prepaid',18294.0,0.0,3059.31,21353.31,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1342','Flipkart - Seller Hub','2026-09-05 18:38+05:30','Sejal Kapadia','cod',3296.0,0.0,164.8,3460.8,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1459','Amazon - Seller Central','2026-09-05 15:17+05:30','Sonal Parekh','prepaid',1399.0,139.9,62.96,1322.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1358','Shopify - Main Store','2026-09-05 11:46+05:30','Rohit Iyer','prepaid',949.0,142.35,40.33,846.98,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1343','Flipkart - Seller Hub','2026-09-05 22:58+05:30','Anjali Verma','prepaid',837.0,125.55,35.58,747.03,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1359','Shopify - Main Store','2026-09-05 15:55+05:30','Dev Trivedi','cod',599.0,89.85,25.46,534.61,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1460','Amazon - Seller Central','2026-09-05 10:12+05:30','Sonal Parekh','prepaid',949.0,47.45,45.08,946.63,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1461','Amazon - Seller Central','2026-09-05 12:55+05:30','Tanvi Rana','prepaid',1748.0,0.0,87.4,1835.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1344','Flipkart - Seller Hub','2026-09-05 13:05+05:30','Rahul Bhatt','prepaid',1278.0,127.8,57.52,1207.72,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1360','Shopify - Main Store','2026-09-05 22:58+05:30','Bhavna Solanki','prepaid',1898.0,189.8,85.42,1793.62,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1361','Shopify - Main Store','2026-09-05 19:44+05:30','Sejal Kapadia','cod',279.0,41.85,11.86,249.01,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1345','Flipkart - Seller Hub','2026-09-05 18:51+05:30','Aarav Mehta','prepaid',699.0,0.0,34.95,733.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1362','Shopify - Main Store','2026-09-05 18:36+05:30','Riya Shah','prepaid',4097.0,0.0,204.85,4301.85,'delivered','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1363','Shopify - Main Store','2026-09-05 14:56+05:30','Rahul Bhatt','prepaid',3733.0,559.95,158.67,3331.72,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1364','Shopify - Main Store','2026-09-05 22:08+05:30','Manav Joshi','prepaid',1948.0,97.4,92.53,1943.13,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1462','Amazon - Seller Central','2026-09-05 16:43+05:30','Pratik Lad','cod',1027.0,0.0,51.35,1078.35,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1346','Flipkart - Seller Hub','2026-09-05 21:31+05:30','Vipul Gandhi','prepaid',2199.0,329.85,93.46,1962.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1347','Flipkart - Seller Hub','2026-09-05 17:28+05:30','Kavya Menon','prepaid',279.0,27.9,12.56,263.66,'shipped','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1340','MTRK-BLK-M',1,649,64.9,29.21),
('FLIP-1340','MKUR-WHT-XL',2,1099,219.8,98.91),
('FLIP-1340','MTRK-BLK-L',1,649,64.9,29.21),
('SHOP-1356','GLEG-BLK-67Y',2,279,55.8,25.11),
('SHOP-1356','MTEE-WHT-M',1,449,44.9,20.21),
('SHOP-1356','GLEG-PNK-45Y',1,279,27.9,12.56),
('SHOP-1357','BKUR-CRM-45Y',1,949,0.0,47.45),
('FLIP-1341','WTOP-PCH-S',2,599,0.0,59.9),
('FLIP-1341','WLHG-RED-L',3,5499,0.0,2969.46),
('FLIP-1341','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1342','WPAL-YLW-L',1,599,0.0,29.95),
('FLIP-1342','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1342','WDRS-FLR-L',1,1499,0.0,74.95),
('FLIP-1342','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1459','MJNS-BLK-30',1,1399,139.9,62.96),
('SHOP-1358','BKUR-CRM-89Y',1,949,142.35,40.33),
('FLIP-1343','GLEG-PNK-45Y',2,279,83.7,23.72),
('FLIP-1343','GLEG-BLK-45Y',1,279,41.85,11.86),
('SHOP-1359','WTOP-PCH-L',1,599,89.85,25.46),
('AMAZ-1460','BKUR-MUS-67Y',1,949,47.45,45.08),
('AMAZ-1461','MJNS-BLK-32',1,1399,0.0,69.95),
('AMAZ-1461','BSHT-GRY-45Y',1,349,0.0,17.45),
('FLIP-1344','BTEE-BLU-89Y',1,329,32.9,14.81),
('FLIP-1344','BKUR-MUS-45Y',1,949,94.9,42.71),
('SHOP-1360','MSHF-WHT-XL',1,999,99.9,44.96),
('SHOP-1360','MSHC-GRN-L',1,899,89.9,40.46),
('SHOP-1361','GLEG-BLK-89Y',1,279,41.85,11.86),
('FLIP-1345','MPOL-MRN-XL',1,699,0.0,34.95),
('SHOP-1362','MJNS-IND-32',1,1399,0.0,69.95),
('SHOP-1362','MHOD-BLK-L',1,1299,0.0,64.95),
('SHOP-1362','MJNS-IND-30',1,1399,0.0,69.95),
('SHOP-1363','GLEG-PNK-45Y',2,279,83.7,23.72),
('SHOP-1363','GLEG-BLK-45Y',1,279,41.85,11.86),
('SHOP-1363','GTOP-WHT-89Y',2,349,104.7,29.67),
('SHOP-1363','MKUR-WHT-L',2,1099,329.7,93.42),
('SHOP-1364','WJNS-IND-28',1,1349,67.45,64.08),
('SHOP-1364','WTOP-PCH-S',1,599,29.95,28.45),
('AMAZ-1462','BTEE-RED-89Y',1,329,0.0,16.45),
('AMAZ-1462','BSHT-GRY-45Y',2,349,0.0,34.9),
('FLIP-1346','WSAR-GRN-FREE',1,2199,329.85,93.46),
('FLIP-1347','GLEG-BLK-45Y',1,279,27.9,12.56)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1342','DTDC - Ring Road Surat'),
('SHOP-1359','DTDC - Ring Road Surat'),
('SHOP-1361','Delhivery - Sachin GIDC Surat'),
('AMAZ-1462','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1292', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1379', 'in_transit');
select pg_temp.ret_set('SHOP-1305', 'in_transit');
select pg_temp.ret_dispo('FLIP-1299', 'good', 'restocked');
select pg_temp.ret_new('FLIP-1311', 'Wrong item delivered', 'webhook');
select pg_temp.cod_collect(array['AMAZ-1429']::text[]);
select pg_temp.rto_set('SHOP-1338', 'in_transit');
select pg_temp.rto_new('AMAZ-1436', 'AWB31001016', 'Customer unreachable');
select pg_temp.claim_step('AMAZ-1326', 'damaged_return', 'rejected', null);
select pg_temp.claim_step('AMAZ-1337', 'other', 'approved', null);
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
