-- 06 Sep to 19 Sep 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Sun 06 Sep 2026
select pg_temp.day('2026-09-06');
select pg_temp.bill_po('Weekly replenishment 24 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R158)', 'TKF/26/0461', 1);
select pg_temp.bill_po('Weekly replenishment 31 Aug 2026 - Krishna Denim Works (ref R159)', 'KDW/26/0349', 1);
select pg_temp.grn_new('Weekly replenishment 31 Aug 2026 - Rajdhani Shirting Mills (ref R162)', 'DC-RSM-0145', '[{"sku":"MSHC-GRN-L","q":10,"a":10,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1463','Amazon - Seller Central','2026-09-06 14:03+05:30','Mitul Dave','cod',599.0,29.95,28.45,597.5,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1365','Shopify - Main Store','2026-09-06 18:23+05:30','Meghna Rao','prepaid',2047.0,0.0,102.35,2149.35,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1366','Shopify - Main Store','2026-09-06 20:28+05:30','Kunal Desai','prepaid',1349.0,0.0,67.45,1416.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1367','Shopify - Main Store','2026-09-06 12:51+05:30','Heena Khan','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1348','Flipkart - Seller Hub','2026-09-06 13:47+05:30','Rohit Iyer','prepaid',2646.0,0.0,132.3,2778.3,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1349','Flipkart - Seller Hub','2026-09-06 17:52+05:30','Ritu Saxena','prepaid',2057.0,0.0,102.85,2159.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1368','Shopify - Main Store','2026-09-06 18:23+05:30','Neha Patel','prepaid',599.0,89.85,25.46,534.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1464','Amazon - Seller Central','2026-09-06 21:12+05:30','Dev Trivedi','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1369','Shopify - Main Store','2026-09-06 13:22+05:30','Pooja Jain','cod',749.0,0.0,37.45,786.45,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1350','Flipkart - Seller Hub','2026-09-06 12:26+05:30','Pooja Jain','prepaid',1999.0,0.0,99.95,2098.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1351','Flipkart - Seller Hub','2026-09-06 18:32+05:30','Vipul Gandhi','prepaid',11847.0,1777.05,1718.77,11788.72,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1370','Shopify - Main Store','2026-09-06 12:44+05:30','Heena Khan','cod',1199.0,0.0,59.95,1258.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1465','Amazon - Seller Central','2026-09-06 10:04+05:30','Prachi Kulkarni','prepaid',4396.0,0.0,219.8,4615.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1371','Shopify - Main Store','2026-09-06 15:33+05:30','Neha Patel','prepaid',1347.0,0.0,67.35,1414.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1352','Flipkart - Seller Hub','2026-09-06 13:57+05:30','Nidhi Agarwal','cod',1647.0,82.35,78.24,1642.89,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1372','Shopify - Main Store','2026-09-06 16:49+05:30','Divya Nair','cod',279.0,27.9,12.56,263.66,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1373','Shopify - Main Store','2026-09-06 13:07+05:30','Harsh Modi','prepaid',1199.0,179.85,50.96,1070.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1353','Flipkart - Seller Hub','2026-09-06 17:55+05:30','Prachi Kulkarni','prepaid',2147.0,0.0,107.35,2254.35,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1374','Shopify - Main Store','2026-09-06 19:54+05:30','Neha Patel','prepaid',1058.0,52.9,50.25,1055.35,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1466','Amazon - Seller Central','2026-09-06 15:55+05:30','Divya Nair','prepaid',4596.0,0.0,229.8,4825.8,'delivered','paid','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1463','WTOP-PCH-L',1,599,29.95,28.45),
('SHOP-1365','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1365','WPAL-YLW-L',1,599,0.0,29.95),
('SHOP-1365','WKRT-TEL-L',1,849,0.0,42.45),
('SHOP-1366','WJNS-IND-28',1,1349,0.0,67.45),
('SHOP-1367','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1348','WTOP-PCH-S',1,599,0.0,29.95),
('FLIP-1348','WLEG-MAR-M',1,349,0.0,17.45),
('FLIP-1348','WKRT-PNK-L',2,849,0.0,84.9),
('FLIP-1349','GJNS-IND-45Y',1,779,0.0,38.95),
('FLIP-1349','BKUR-MUS-45Y',1,949,0.0,47.45),
('FLIP-1349','BTEE-BLU-45Y',1,329,0.0,16.45),
('SHOP-1368','WTOP-PCH-M',1,599,89.85,25.46),
('AMAZ-1464','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1369','GFRK-PNK-67Y',1,749,0.0,37.45),
('FLIP-1350','GLHG-RED-89Y',1,1999,0.0,99.95),
('FLIP-1351','WKRT-PNK-S',1,849,127.35,36.08),
('FLIP-1351','WLHG-RED-L',2,5499,1649.7,1682.69),
('SHOP-1370','MCHN-OLV-34',1,1199,0.0,59.95),
('AMAZ-1465','WKRT-TEL-L',2,849,0.0,84.9),
('AMAZ-1465','WJNS-IND-30',2,1349,0.0,134.9),
('SHOP-1371','MTEE-BLK-L',3,449,0.0,67.35),
('FLIP-1352','BSHT-GRY-67Y',2,349,34.9,33.16),
('FLIP-1352','BKUR-MUS-67Y',1,949,47.45,45.08),
('SHOP-1372','GLEG-PNK-89Y',1,279,27.9,12.56),
('SHOP-1373','MCHN-KHK-30',1,1199,179.85,50.96),
('FLIP-1353','BKUR-CRM-89Y',1,949,0.0,47.45),
('FLIP-1353','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1353','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1374','GLEG-BLK-45Y',1,279,13.95,13.25),
('SHOP-1374','GJNS-IND-1011Y',1,779,38.95,37.0),
('AMAZ-1466','MCHN-KHK-30',3,1199,0.0,179.85),
('AMAZ-1466','MSHF-SKY-XL',1,999,0.0,49.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1463','Ecom Express - Udhna Hub'),
('SHOP-1369','Xpressbees - Pandesara'),
('SHOP-1370','Ecom Express - Udhna Hub'),
('FLIP-1352','Bluedart - Surat City'),
('SHOP-1372','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_new('AMAZ-1407', 'Customer changed mind', 'webhook');
select pg_temp.ret_set('FLIP-1311', 'approved');
select pg_temp.ret_new('SHOP-1333', 'Customer changed mind', 'manual');
select pg_temp.rto_new('FLIP-1330', 'AWB31001000', 'Address incomplete');
select pg_temp.cod_collect(array['SHOP-1342']::text[]);
select pg_temp.cod_collect(array['AMAZ-1434']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260824', 0.0);
select pg_temp.claim_step('FLIP-1273', 'excess_deduction', 'claimed', null);
select pg_temp.retime();

-- Mon 07 Sep 2026
select pg_temp.day('2026-09-07');
select pg_temp.bill_po('Weekly replenishment 31 Aug 2026 - Rajdhani Shirting Mills (ref R162)', 'RSM/26/0347', 1);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Krishna Denim Works (ref R166)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"WJNS-BLK-28","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Little Stitch Garments (ref R167)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"WDRS-FLR-L","q":6},{"sku":"BSHT-GRY-45Y","q":8},{"sku":"BSHT-GRY-67Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Little Stitch Garments (ref R168)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"GLHG-TEL-67Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Ludhiana Winter Wear Co (ref R169)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"MHOD-BLK-M","q":10},{"sku":"MHOD-BLK-L","q":6},{"sku":"MHOD-BLK-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Rajdhani Shirting Mills (ref R170)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MKUR-WHT-L","q":6},{"sku":"MKUR-WHT-XL","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Rajdhani Shirting Mills (ref R171)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MKUR-WHT-L","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Shree Ambika Textiles (ref R172)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WPAL-YLW-XL","q":6},{"sku":"WSAR-RED-FREE","q":6},{"sku":"WSAR-GRN-FREE","q":6},{"sku":"WLHG-RED-L","q":14},{"sku":"WDUP-SLV-FREE","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R173)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-BLK-M","q":6},{"sku":"WLEG-NVY-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 07 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R174)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-BLK-L","q":6},{"sku":"WTOP-WHT-L","q":18},{"sku":"WTOP-PCH-M","q":26},{"sku":"BTEE-RED-67Y","q":6},{"sku":"GTOP-WHT-89Y","q":6}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1354','Flipkart - Seller Hub','2026-09-07 15:45+05:30','Aarav Mehta','prepaid',2386.0,0.0,119.3,2505.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1375','Shopify - Main Store','2026-09-07 11:09+05:30','Karan Malhotra','prepaid',2754.0,0.0,137.7,2891.7,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1355','Flipkart - Seller Hub','2026-09-07 16:41+05:30','Kiran Naik','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1376','Shopify - Main Store','2026-09-07 17:19+05:30','Jigar Chauhan','prepaid',3495.0,0.0,174.75,3669.75,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1356','Flipkart - Seller Hub','2026-09-07 09:23+05:30','Aarav Mehta','prepaid',899.0,134.85,38.21,802.36,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1377','Shopify - Main Store','2026-09-07 17:37+05:30','Prachi Kulkarni','cod',1326.0,132.6,59.68,1253.08,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1357','Flipkart - Seller Hub','2026-09-07 12:36+05:30','Karan Malhotra','prepaid',5344.0,0.0,267.2,5611.2,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1467','Amazon - Seller Central','2026-09-07 18:29+05:30','Chirag Zaveri','prepaid',1058.0,52.9,50.25,1055.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1468','Amazon - Seller Central','2026-09-07 15:11+05:30','Kiran Naik','cod',849.0,0.0,42.45,891.45,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1378','Shopify - Main Store','2026-09-07 12:04+05:30','Harsh Modi','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1358','Flipkart - Seller Hub','2026-09-07 21:09+05:30','Foram Thakkar','prepaid',5034.0,251.7,239.12,5021.42,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1359','Flipkart - Seller Hub','2026-09-07 09:29+05:30','Meghna Rao','prepaid',3247.0,162.35,154.23,3238.88,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1360','Flipkart - Seller Hub','2026-09-07 21:26+05:30','Meghna Rao','prepaid',4845.0,484.5,218.04,4578.54,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1354','MJNS-BLK-32',1,1399,0.0,69.95),
('FLIP-1354','BTEE-BLU-67Y',3,329,0.0,49.35),
('SHOP-1375','GLEG-PNK-89Y',2,279,0.0,27.9),
('SHOP-1375','GNGT-PNK-67Y',3,549,0.0,82.35),
('SHOP-1375','GNGT-PNK-45Y',1,549,0.0,27.45),
('FLIP-1355','GLEG-PNK-89Y',1,279,0.0,13.95),
('SHOP-1376','WKRT-PNK-S',2,849,0.0,84.9),
('SHOP-1376','WTOP-PCH-M',2,599,0.0,59.9),
('SHOP-1376','WTOP-PCH-S',1,599,0.0,29.95),
('FLIP-1356','MSHC-GRN-L',1,899,134.85,38.21),
('SHOP-1377','GTOP-WHT-67Y',3,349,104.7,47.12),
('SHOP-1377','GLEG-BLK-89Y',1,279,27.9,12.56),
('FLIP-1357','WJNS-BLK-28',1,1349,0.0,67.45),
('FLIP-1357','MKUR-MUS-XL',2,1099,0.0,109.9),
('FLIP-1357','WTOP-PCH-S',2,599,0.0,59.9),
('FLIP-1357','WPAL-YLW-L',1,599,0.0,29.95),
('AMAZ-1467','GJNS-IND-89Y',1,779,38.95,37.0),
('AMAZ-1467','GLEG-BLK-89Y',1,279,13.95,13.25),
('AMAZ-1468','WKRT-PNK-S',1,849,0.0,42.45),
('SHOP-1378','BTEE-RED-45Y',1,329,32.9,14.81),
('FLIP-1358','GTOP-WHT-67Y',2,349,34.9,33.16),
('FLIP-1358','GJNS-IND-45Y',3,779,116.85,111.01),
('FLIP-1358','GLHG-TEL-89Y',1,1999,99.95,94.95),
('FLIP-1359','MJNS-BLK-32',1,1399,69.95,66.45),
('FLIP-1359','MTEE-BLK-XL',1,449,22.45,21.33),
('FLIP-1359','MJNS-BLK-34',1,1399,69.95,66.45),
('FLIP-1360','MCHN-OLV-34',1,1199,119.9,53.96),
('FLIP-1360','BKUR-MUS-67Y',2,949,189.8,85.41),
('FLIP-1360','BJNS-IND-89Y',1,799,79.9,35.96),
('FLIP-1360','BKUR-CRM-89Y',1,949,94.9,42.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1377','DTDC - Ring Road Surat'),
('AMAZ-1468','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('SHOP-1315');
select pg_temp.ret_set('AMAZ-1407', 'approved');
select pg_temp.ret_set('FLIP-1311', 'pickup');
select pg_temp.ret_set('SHOP-1333', 'approved');
select pg_temp.rto_set('AMAZ-1436', 'in_transit');
select pg_temp.cod_collect(array['AMAZ-1438']::text[]);
select pg_temp.cod_collect(array['SHOP-1350']::text[]);
select pg_temp.cod_collect(array['FLIP-1337']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260831', '2026-08-31', '2026-09-06', array['AMAZ-1407','AMAZ-1412','AMAZ-1413','AMAZ-1417','AMAZ-1424','AMAZ-1410','AMAZ-1411','AMAZ-1416','AMAZ-1419','AMAZ-1421','AMAZ-1426','AMAZ-1422','AMAZ-1427','AMAZ-1423','AMAZ-1425','AMAZ-1430','AMAZ-1431','AMAZ-1433','AMAZ-1439','AMAZ-1441','AMAZ-1428','AMAZ-1440','AMAZ-1442','AMAZ-1447','AMAZ-1435','AMAZ-1444','AMAZ-1446','AMAZ-1450']::text[], array['AMAZ-1383']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260831', '2026-08-31', '2026-09-06', array['FLIP-1311','FLIP-1313','FLIP-1315','FLIP-1320','FLIP-1321','FLIP-1323','FLIP-1317','FLIP-1318','FLIP-1319','FLIP-1325','FLIP-1324','FLIP-1327','FLIP-1329','FLIP-1332','FLIP-1335','FLIP-1331']::text[], array['FLIP-1282','FLIP-1287','FLIP-1292','FLIP-1299']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260831', '2026-08-31', '2026-09-06', array['SHOP-1326','SHOP-1327','SHOP-1334','SHOP-1330','SHOP-1335','SHOP-1333','SHOP-1340','SHOP-1343','SHOP-1336','SHOP-1337','SHOP-1345','SHOP-1344','SHOP-1349']::text[], array[]::text[]);
select pg_temp.claim_step('SHOP-1271', 'other', 'approved', 797.16);
select pg_temp.claim_step('AMAZ-1383', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Tue 08 Sep 2026
select pg_temp.day('2026-09-08');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1361','Flipkart - Seller Hub','2026-09-08 13:31+05:30','Pratik Lad','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1379','Shopify - Main Store','2026-09-08 16:50+05:30','Anjali Verma','cod',279.0,0.0,13.95,292.95,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1469','Amazon - Seller Central','2026-09-08 20:35+05:30','Heena Khan','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1380','Shopify - Main Store','2026-09-08 16:02+05:30','Sanjay Gajera','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1381','Shopify - Main Store','2026-09-08 09:33+05:30','Mitul Dave','prepaid',2148.0,0.0,107.4,2255.4,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1362','Flipkart - Seller Hub','2026-09-08 09:53+05:30','Aarav Mehta','cod',1748.0,0.0,87.4,1835.4,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1470','Amazon - Seller Central','2026-09-08 11:57+05:30','Yash Vora','cod',279.0,27.9,12.56,263.66,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1382','Shopify - Main Store','2026-09-08 16:55+05:30','Manav Joshi','prepaid',599.0,89.85,25.46,534.61,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1363','Flipkart - Seller Hub','2026-09-08 09:30+05:30','Sanjay Gajera','cod',1199.0,59.95,56.95,1196.0,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1364','Flipkart - Seller Hub','2026-09-08 15:53+05:30','Aarav Mehta','cod',2498.0,249.8,112.42,2360.62,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1383','Shopify - Main Store','2026-09-08 16:57+05:30','Mehul Shukla','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1384','Shopify - Main Store','2026-09-08 21:42+05:30','Mehul Shukla','prepaid',1797.0,179.7,80.87,1698.17,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1361','MCHN-KHK-30',1,1199,119.9,53.96),
('SHOP-1379','GLEG-PNK-89Y',1,279,0.0,13.95),
('AMAZ-1469','WTOP-WHT-M',1,599,29.95,28.45),
('SHOP-1380','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1381','WKRT-PNK-L',1,849,0.0,42.45),
('SHOP-1381','MHOD-BLK-L',1,1299,0.0,64.95),
('FLIP-1362','GNGT-PNK-89Y',1,549,0.0,27.45),
('FLIP-1362','MCHN-OLV-32',1,1199,0.0,59.95),
('AMAZ-1470','GLEG-PNK-89Y',1,279,27.9,12.56),
('SHOP-1382','WPAL-YLW-L',1,599,89.85,25.46),
('FLIP-1363','MCHN-OLV-34',1,1199,59.95,56.95),
('FLIP-1364','MCHN-OLV-32',1,1199,119.9,53.96),
('FLIP-1364','MHOD-GRY-M',1,1299,129.9,58.46),
('SHOP-1383','MCHN-OLV-34',1,1199,0.0,59.95),
('SHOP-1384','WTOP-PCH-L',2,599,119.8,53.91),
('SHOP-1384','WTOP-WHT-L',1,599,59.9,26.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1379','Bluedart - Surat City'),
('FLIP-1362','DTDC - Ring Road Surat'),
('AMAZ-1470','DTDC - Ring Road Surat'),
('FLIP-1363','Ecom Express - Udhna Hub'),
('FLIP-1364','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('SHOP-1305');
select pg_temp.ret_set('AMAZ-1407', 'pickup');
select pg_temp.rto_recv('SHOP-1323', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1333', 'pickup');
select pg_temp.rto_set('FLIP-1330', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1336']::text[]);
select pg_temp.cod_collect(array['SHOP-1351']::text[]);
select pg_temp.settle_pay('FLK-STL-20260824', 0.0);
select pg_temp.claim_step('FLIP-1254', 'damaged_return', 'approved', null);
select pg_temp.claim_step('AMAZ-1332', 'incorrect_deduction', 'rejected', null);
select pg_temp.retime();

-- Wed 09 Sep 2026
select pg_temp.day('2026-09-09');
select pg_temp.grn_new('Weekly replenishment 31 Aug 2026 - Ludhiana Winter Wear Co (ref R161)', 'DC-LWW-0073', '[{"sku":"MHOD-BLK-M","q":8,"a":8,"r":0},{"sku":"MHOD-BLK-XL","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 31 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R164)', 'DC-TKF-0196', '[{"sku":"MTEE-BLK-M","q":6,"a":6,"r":0},{"sku":"MTEE-BLK-XL","q":6,"a":6,"r":0},{"sku":"WLEG-BLK-M","q":10,"a":10,"r":0},{"sku":"WTOP-WHT-L","q":10,"a":10,"r":0},{"sku":"GLEG-PNK-67Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 31 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R165)', 'DC-TKF-0199', '[{"sku":"WTOP-PCH-L","q":38,"a":38,"r":0},{"sku":"BTEE-RED-67Y","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-67Y","q":18,"a":17,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1471','Amazon - Seller Central','2026-09-09 21:33+05:30','Jigar Chauhan','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1365','Flipkart - Seller Hub','2026-09-09 20:02+05:30','Tanvi Rana','prepaid',6594.0,0.0,329.7,6923.7,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1472','Amazon - Seller Central','2026-09-09 10:29+05:30','Pratik Lad','prepaid',349.0,34.9,15.71,329.81,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1473','Amazon - Seller Central','2026-09-09 10:36+05:30','Karan Malhotra','prepaid',5245.0,524.5,236.04,4956.54,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1366','Flipkart - Seller Hub','2026-09-09 20:31+05:30','Mitul Dave','cod',3796.0,189.8,180.31,3786.51,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1385','Shopify - Main Store','2026-09-09 20:17+05:30','Rohit Iyer','prepaid',999.0,99.9,44.96,944.06,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1367','Flipkart - Seller Hub','2026-09-09 20:33+05:30','Foram Thakkar','cod',3096.0,0.0,154.8,3250.8,'delivered','pending','Delhi','Surat Main Warehouse'),
('FLIP-1368','Flipkart - Seller Hub','2026-09-09 22:31+05:30','Yash Vora','prepaid',4048.0,202.4,525.61,4371.21,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1386','Shopify - Main Store','2026-09-09 11:27+05:30','Nikhil Pandey','cod',5499.0,824.85,841.35,5515.5,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('AMAZ-1474','Amazon - Seller Central','2026-09-09 09:41+05:30','Manav Joshi','prepaid',2398.0,119.9,113.91,2392.01,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1369','Flipkart - Seller Hub','2026-09-09 16:13+05:30','Mehul Shukla','cod',599.0,0.0,29.95,628.95,'cancelled','failed','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1475','Amazon - Seller Central','2026-09-09 12:48+05:30','Harsh Modi','prepaid',1848.0,0.0,92.4,1940.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1370','Flipkart - Seller Hub','2026-09-09 11:02+05:30','Rahul Bhatt','prepaid',4845.0,242.25,230.14,4832.89,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1471','MCHN-OLV-32',1,1199,0.0,59.95),
('AMAZ-1471','MSHC-RED-M',1,899,0.0,44.95),
('FLIP-1365','WKRT-PNK-XL',2,849,0.0,84.9),
('FLIP-1365','WKRT-TEL-M',1,849,0.0,42.45),
('FLIP-1365','WJNS-BLK-32',3,1349,0.0,202.35),
('AMAZ-1472','WLEG-BLK-L',1,349,34.9,15.71),
('AMAZ-1473','WJNS-IND-28',3,1349,404.7,182.12),
('AMAZ-1473','WTOP-PCH-L',1,599,59.9,26.96),
('AMAZ-1473','WTOP-PCH-M',1,599,59.9,26.96),
('FLIP-1366','BKUR-MUS-67Y',3,949,142.35,135.23),
('FLIP-1366','BKUR-MUS-45Y',1,949,47.45,45.08),
('SHOP-1385','BTRK-BLK-45Y',1,999,99.9,44.96),
('FLIP-1367','BSHF-WHT-89Y',2,599,0.0,59.9),
('FLIP-1367','BKUR-CRM-89Y',2,949,0.0,94.9),
('FLIP-1368','WJNS-IND-28',1,1349,67.45,64.08),
('FLIP-1368','WJKT-BLK-M',1,2699,134.95,461.53),
('SHOP-1386','WLHG-MAG-M',1,5499,824.85,841.35),
('AMAZ-1474','MCHN-OLV-34',2,1199,119.9,113.91),
('FLIP-1369','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1475','MCHN-KHK-34',1,1199,0.0,59.95),
('AMAZ-1475','MTRK-BLK-L',1,649,0.0,32.45),
('FLIP-1370','WTOP-WHT-M',2,599,59.9,56.91),
('FLIP-1370','WTOP-PCH-S',1,599,29.95,28.45),
('FLIP-1370','WKRT-TEL-M',1,849,42.45,40.33),
('FLIP-1370','WSAR-BLU-FREE',1,2199,109.95,104.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1366','Ecom Express - Udhna Hub'),
('FLIP-1367','Xpressbees - Pandesara'),
('SHOP-1386','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1379');
select pg_temp.ret_dispo('SHOP-1305', 'good', 'restocked');
select pg_temp.ret_dispo('SHOP-1315', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1311', 'in_transit');
select pg_temp.cod_collect(array['AMAZ-1458']::text[]);
select pg_temp.cod_collect(array['SHOP-1369']::text[]);
select pg_temp.settle_pay('SHP-STL-20260831', 0.0);
select pg_temp.claim_new('FLIP-1274', 'lost_shipment', 1784.11, '2026-10-09');
select pg_temp.retime();

-- Thu 10 Sep 2026
select pg_temp.day('2026-09-10');
select pg_temp.bill_po('Weekly replenishment 31 Aug 2026 - Ludhiana Winter Wear Co (ref R161)', 'LWW/26/0182', 1);
select pg_temp.bill_po('Weekly replenishment 31 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R164)', 'TKF/26/0464', 1);
select pg_temp.bill_po('Weekly replenishment 31 Aug 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R165)', 'TKF/26/0475', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1387','Shopify - Main Store','2026-09-10 15:27+05:30','Sejal Kapadia','prepaid',1047.0,157.05,44.5,934.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1388','Shopify - Main Store','2026-09-10 22:48+05:30','Bhavna Solanki','prepaid',2197.0,109.85,104.36,2191.51,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1476','Amazon - Seller Central','2026-09-10 18:57+05:30','Nikhil Pandey','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1389','Shopify - Main Store','2026-09-10 10:29+05:30','Amit Sethi','cod',1998.0,0.0,99.9,2097.9,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1477','Amazon - Seller Central','2026-09-10 11:44+05:30','Mitul Dave','prepaid',1198.0,119.8,53.91,1132.11,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1478','Amazon - Seller Central','2026-09-10 10:27+05:30','Isha Gupta','prepaid',1399.0,69.95,66.45,1395.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1390','Shopify - Main Store','2026-09-10 11:57+05:30','Rohit Iyer','prepaid',1199.0,179.85,50.96,1070.11,'cancelled','refunded','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1479','Amazon - Seller Central','2026-09-10 12:50+05:30','Jigar Chauhan','prepaid',3196.0,0.0,159.8,3355.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1480','Amazon - Seller Central','2026-09-10 19:04+05:30','Ritu Saxena','prepaid',1116.0,55.8,53.02,1113.22,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1481','Amazon - Seller Central','2026-09-10 15:22+05:30','Kiran Naik','prepaid',2805.0,0.0,140.25,2945.25,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1391','Shopify - Main Store','2026-09-10 17:31+05:30','Rahul Bhatt','prepaid',5096.0,0.0,254.8,5350.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1392','Shopify - Main Store','2026-09-10 20:44+05:30','Pratik Lad','prepaid',2798.0,279.8,125.91,2644.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1482','Amazon - Seller Central','2026-09-10 15:10+05:30','Divya Nair','prepaid',3336.0,333.6,150.14,3152.54,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1371','Flipkart - Seller Hub','2026-09-10 10:52+05:30','Vipul Gandhi','prepaid',5244.0,524.4,235.99,4955.59,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1483','Amazon - Seller Central','2026-09-10 15:00+05:30','Heena Khan','prepaid',6995.0,1049.25,717.09,6662.84,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1484','Amazon - Seller Central','2026-09-10 16:29+05:30','Vipul Gandhi','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1387','WLEG-NVY-M',3,349,157.05,44.5),
('SHOP-1388','WTOP-WHT-L',2,599,59.9,56.91),
('SHOP-1388','MSHF-WHT-L',1,999,49.95,47.45),
('AMAZ-1476','WKRT-PNK-XL',1,849,0.0,42.45),
('SHOP-1389','MSHC-RED-XL',1,899,0.0,44.95),
('SHOP-1389','MKUR-WHT-L',1,1099,0.0,54.95),
('AMAZ-1477','WTOP-PCH-L',2,599,119.8,53.91),
('AMAZ-1478','MJNS-BLK-32',1,1399,69.95,66.45),
('SHOP-1390','MCHN-OLV-30',1,1199,179.85,50.96),
('AMAZ-1479','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1479','MSHC-GRN-M',1,899,0.0,44.95),
('AMAZ-1479','MPOL-MRN-M',1,699,0.0,34.95),
('AMAZ-1479','MSHF-WHT-L',1,999,0.0,49.95),
('AMAZ-1480','GLEG-BLK-67Y',2,279,27.9,26.51),
('AMAZ-1480','GLEG-BLK-89Y',2,279,27.9,26.51),
('AMAZ-1481','GLEG-PNK-67Y',2,279,0.0,27.9),
('AMAZ-1481','MTRK-BLK-L',2,649,0.0,64.9),
('AMAZ-1481','BKUR-MUS-67Y',1,949,0.0,47.45),
('SHOP-1391','MCHN-OLV-30',1,1199,0.0,59.95),
('SHOP-1391','MJNS-IND-30',1,1399,0.0,69.95),
('SHOP-1391','MCHN-OLV-34',1,1199,0.0,59.95),
('SHOP-1391','MHOD-GRY-M',1,1299,0.0,64.95),
('SHOP-1392','MJNS-BLK-30',2,1399,279.8,125.91),
('AMAZ-1482','GLHG-RED-67Y',1,1999,199.9,89.96),
('AMAZ-1482','GLEG-PNK-89Y',1,279,27.9,12.56),
('AMAZ-1482','GJNS-IND-89Y',1,779,77.9,35.06),
('AMAZ-1482','GLEG-BLK-89Y',1,279,27.9,12.56),
('FLIP-1371','GNGT-PNK-89Y',3,549,164.7,74.12),
('FLIP-1371','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1371','WDRS-FLR-L',2,1499,299.8,134.91),
('AMAZ-1483','MPOL-NVY-M',2,699,209.7,59.42),
('AMAZ-1483','MSHC-RED-M',2,899,269.7,76.42),
('AMAZ-1483','MBLZ-NVY-38',1,3799,569.85,581.25),
('AMAZ-1484','BTEE-BLU-89Y',1,329,0.0,16.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1389','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1407', 'in_transit');
select pg_temp.ret_set('SHOP-1333', 'in_transit');
select pg_temp.rto_recv('SHOP-1338', 'good', 'restocked');
select pg_temp.rto_recv('AMAZ-1436', 'good', 'restocked');
select pg_temp.ret_new('AMAZ-1442', 'Customer changed mind', 'webhook');
select pg_temp.cod_collect(array['FLIP-1342']::text[]);
select pg_temp.cod_collect(array['SHOP-1359']::text[]);
select pg_temp.cod_collect(array['AMAZ-1462']::text[]);
select pg_temp.rto_new('FLIP-1347', 'AWB31001048', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['AMAZ-1463']::text[]);
select pg_temp.cod_collect(array['SHOP-1370']::text[]);
select pg_temp.claim_recover('AMAZ-1318', 'other', 'CLAIM-CR-AMAZ-1318');
select pg_temp.retime();

-- Fri 11 Sep 2026
select pg_temp.day('2026-09-11');
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Shree Ambika Textiles (ref R172)', 'DC-SAT-0145', '[{"sku":"WPAL-YLW-XL","q":6,"a":6,"r":0},{"sku":"WSAR-RED-FREE","q":6,"a":5,"r":1},{"sku":"WSAR-GRN-FREE","q":6,"a":6,"r":0},{"sku":"WLHG-RED-L","q":14,"a":14,"r":0},{"sku":"WDUP-SLV-FREE","q":8,"a":7,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1393','Shopify - Main Store','2026-09-11 13:49+05:30','Vipul Gandhi','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1485','Amazon - Seller Central','2026-09-11 20:31+05:30','Meghna Rao','prepaid',3496.0,524.4,148.59,3120.19,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1394','Shopify - Main Store','2026-09-11 21:24+05:30','Divya Nair','prepaid',4546.0,454.6,204.58,4295.98,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1395','Shopify - Main Store','2026-09-11 11:14+05:30','Foram Thakkar','prepaid',11847.0,0.0,2022.09,13869.09,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1396','Shopify - Main Store','2026-09-11 21:05+05:30','Sagar Rathod','prepaid',1306.0,65.3,62.04,1302.74,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1486','Amazon - Seller Central','2026-09-11 16:34+05:30','Rahul Bhatt','prepaid',2498.0,0.0,124.9,2622.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1487','Amazon - Seller Central','2026-09-11 12:05+05:30','Riya Shah','cod',1999.0,99.95,94.95,1994.0,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1372','Flipkart - Seller Hub','2026-09-11 18:42+05:30','Riya Shah','cod',2098.0,0.0,104.9,2202.9,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1373','Flipkart - Seller Hub','2026-09-11 11:45+05:30','Aarav Mehta','prepaid',3646.0,364.6,164.08,3445.48,'shipped','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1488','Amazon - Seller Central','2026-09-11 18:47+05:30','Neha Patel','prepaid',1848.0,92.4,87.78,1843.38,'shipped','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1489','Amazon - Seller Central','2026-09-11 10:54+05:30','Kavya Menon','cod',349.0,17.45,16.58,348.13,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1374','Flipkart - Seller Hub','2026-09-11 13:36+05:30','Anjali Verma','cod',279.0,0.0,13.95,292.95,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('SHOP-1397','Shopify - Main Store','2026-09-11 18:03+05:30','Prachi Kulkarni','prepaid',1278.0,0.0,63.9,1341.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1398','Shopify - Main Store','2026-09-11 20:44+05:30','Aarav Mehta','prepaid',1199.0,59.95,56.95,1196.0,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1399','Shopify - Main Store','2026-09-11 11:26+05:30','Amit Sethi','prepaid',949.0,142.35,40.33,846.98,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1393','BKUR-CRM-89Y',1,949,0.0,47.45),
('AMAZ-1485','MPOL-NVY-XL',2,699,209.7,59.42),
('AMAZ-1485','MSHC-GRN-L',1,899,134.85,38.21),
('AMAZ-1485','MCHN-OLV-32',1,1199,179.85,50.96),
('SHOP-1394','BKUR-MUS-67Y',1,949,94.9,42.71),
('SHOP-1394','MJNS-IND-34',2,1399,279.8,125.91),
('SHOP-1394','BJNS-IND-1011Y',1,799,79.9,35.96),
('SHOP-1395','WLHG-RED-L',2,5499,0.0,1979.64),
('SHOP-1395','WKRT-PNK-S',1,849,0.0,42.45),
('SHOP-1396','BSHT-NVY-67Y',2,349,34.9,33.16),
('SHOP-1396','GLEG-BLK-89Y',1,279,13.95,13.25),
('SHOP-1396','BTEE-RED-45Y',1,329,16.45,15.63),
('AMAZ-1486','MCHN-OLV-34',1,1199,0.0,59.95),
('AMAZ-1486','MHOD-BLK-XL',1,1299,0.0,64.95),
('AMAZ-1487','GLHG-TEL-89Y',1,1999,99.95,94.95),
('FLIP-1372','WDRS-FLP-L',1,1499,0.0,74.95),
('FLIP-1372','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1373','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1373','WJNS-BLK-32',1,1349,134.9,60.71),
('FLIP-1373','WKRT-PNK-S',2,849,169.8,76.41),
('AMAZ-1488','WDRS-FLP-S',1,1499,74.95,71.2),
('AMAZ-1488','WLEG-MAR-M',1,349,17.45,16.58),
('AMAZ-1489','BSHT-GRY-67Y',1,349,17.45,16.58),
('FLIP-1374','GLEG-PNK-67Y',1,279,0.0,13.95),
('SHOP-1397','BTEE-BLU-67Y',1,329,0.0,16.45),
('SHOP-1397','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1398','MCHN-OLV-34',1,1199,59.95,56.95),
('SHOP-1399','BKUR-CRM-89Y',1,949,142.35,40.33)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1487','Bluedart - Surat City'),
('FLIP-1372','Delhivery - Sachin GIDC Surat'),
('AMAZ-1489','DTDC - Ring Road Surat'),
('FLIP-1374','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1379', 'missing', 'claimed');
select pg_temp.ret_new('AMAZ-1435', 'Size did not fit', 'webhook');
select pg_temp.ret_set('AMAZ-1442', 'approved');
select pg_temp.rto_new('SHOP-1356', 'AWB31001038', 'Customer unreachable');
select pg_temp.cod_collect(array['SHOP-1361']::text[]);
select pg_temp.rto_new('FLIP-1348', 'AWB31001062', 'Customer unreachable');
select pg_temp.cod_collect(array['FLIP-1362']::text[]);
select pg_temp.cod_collect(array['AMAZ-1470']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-11SEP', array['AMAZ-1420','FLIP-1328','AMAZ-1432','SHOP-1339','SHOP-1341','FLIP-1337']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-11SEP', array['FLIP-1326']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-11SEP', array['FLIP-1336','SHOP-1350','SHOP-1351']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-11SEP', array['SHOP-1342','AMAZ-1434','AMAZ-1438']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-11SEP', array['AMAZ-1429','AMAZ-1458','SHOP-1369']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-09-14', 'ICIC000000887522', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-09-14', 'ICIC000000887594', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-09-14', 'ICIC000000887657', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-09-14', 'ICIC000000887684', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-09-14', 'ICIC000000887774', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-09-14', 'ICIC000000887846', 1);
select pg_temp.claim_new('AMAZ-1379', 'lost_shipment', 1257.9, '2026-10-11');
select pg_temp.retime();

-- Sat 12 Sep 2026
select pg_temp.day('2026-09-12');
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Krishna Denim Works (ref R166)', 'DC-KDW-0148', '[{"sku":"WJNS-BLK-28","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Little Stitch Garments (ref R167)', 'DC-LSG-0133', '[{"sku":"WDRS-FLR-L","q":4,"a":4,"r":0},{"sku":"BSHT-GRY-45Y","q":5,"a":5,"r":0},{"sku":"BSHT-GRY-67Y","q":6,"a":5,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Little Stitch Garments (ref R168)', 'DC-LSG-0139', '[{"sku":"GLHG-TEL-67Y","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Rajdhani Shirting Mills (ref R171)', 'DC-RSM-0151', '[{"sku":"MKUR-WHT-L","q":8,"a":7,"r":1}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Shree Ambika Textiles (ref R172)', 'SAT/26/0348', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1490','Amazon - Seller Central','2026-09-12 16:35+05:30','Sagar Rathod','prepaid',4947.0,742.05,210.25,4415.2,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1375','Flipkart - Seller Hub','2026-09-12 13:33+05:30','Meghna Rao','prepaid',599.0,59.9,26.96,566.06,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1491','Amazon - Seller Central','2026-09-12 14:20+05:30','Rahul Bhatt','prepaid',4556.0,227.8,216.42,4544.62,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1492','Amazon - Seller Central','2026-09-12 17:31+05:30','Sanjay Gajera','prepaid',987.0,49.35,46.88,984.53,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1493','Amazon - Seller Central','2026-09-12 17:06+05:30','Riya Shah','prepaid',2077.0,0.0,103.85,2180.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1400','Shopify - Main Store','2026-09-12 15:00+05:30','Bhavna Solanki','cod',2098.0,209.8,94.42,1982.62,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1376','Flipkart - Seller Hub','2026-09-12 10:57+05:30','Sanjay Gajera','prepaid',5323.0,798.45,226.24,4750.79,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1377','Flipkart - Seller Hub','2026-09-12 14:16+05:30','Chirag Zaveri','prepaid',10094.0,1514.1,1036.64,9616.54,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1494','Amazon - Seller Central','2026-09-12 14:06+05:30','Rohit Iyer','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1401','Shopify - Main Store','2026-09-12 20:18+05:30','Tanvi Rana','prepaid',949.0,47.45,45.08,946.63,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1402','Shopify - Main Store','2026-09-12 16:19+05:30','Vipul Gandhi','cod',329.0,32.9,14.81,310.91,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('AMAZ-1495','Amazon - Seller Central','2026-09-12 18:35+05:30','Chirag Zaveri','prepaid',3597.0,539.55,152.88,3210.33,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1496','Amazon - Seller Central','2026-09-12 21:55+05:30','Jigar Chauhan','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1403','Shopify - Main Store','2026-09-12 15:26+05:30','Bhavna Solanki','prepaid',1099.0,164.85,46.71,980.86,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1497','Amazon - Seller Central','2026-09-12 21:20+05:30','Nidhi Agarwal','prepaid',5847.0,584.7,707.61,5969.91,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1378','Flipkart - Seller Hub','2026-09-12 20:57+05:30','Riya Shah','prepaid',2598.0,259.8,116.91,2455.11,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1404','Shopify - Main Store','2026-09-12 13:39+05:30','Mehul Shukla','prepaid',1698.0,254.7,72.17,1515.47,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1498','Amazon - Seller Central','2026-09-12 11:01+05:30','Nikhil Pandey','prepaid',1448.0,0.0,72.4,1520.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1499','Amazon - Seller Central','2026-09-12 22:16+05:30','Anjali Verma','prepaid',1299.0,0.0,64.95,1363.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1500','Amazon - Seller Central','2026-09-12 09:33+05:30','Isha Gupta','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1379','Flipkart - Seller Hub','2026-09-12 15:48+05:30','Jigar Chauhan','prepaid',2747.0,0.0,137.35,2884.35,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1501','Amazon - Seller Central','2026-09-12 13:28+05:30','Sanjay Gajera','prepaid',599.0,89.85,25.46,534.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1502','Amazon - Seller Central','2026-09-12 13:54+05:30','Ritu Saxena','prepaid',949.0,47.45,45.08,946.63,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1490','WSAR-GRN-FREE',2,2199,659.7,186.92),
('AMAZ-1490','GNGT-PNK-67Y',1,549,82.35,23.33),
('FLIP-1375','WTOP-WHT-L',1,599,59.9,26.96),
('AMAZ-1491','GLHG-RED-67Y',2,1999,199.9,189.91),
('AMAZ-1491','GLEG-BLK-67Y',2,279,27.9,26.51),
('AMAZ-1492','BTEE-RED-89Y',3,329,49.35,46.88),
('AMAZ-1493','GFRK-PNK-67Y',1,749,0.0,37.45),
('AMAZ-1493','GJNS-IND-89Y',1,779,0.0,38.95),
('AMAZ-1493','GNGT-PNK-89Y',1,549,0.0,27.45),
('SHOP-1400','MCHN-OLV-30',1,1199,119.9,53.96),
('SHOP-1400','MSHC-RED-XL',1,899,89.9,40.46),
('FLIP-1376','BKUR-MUS-67Y',2,949,284.7,80.67),
('FLIP-1376','BKUR-MUS-45Y',2,949,284.7,80.67),
('FLIP-1376','BTEE-BLU-67Y',1,329,49.35,13.98),
('FLIP-1376','BSHF-WHT-89Y',2,599,179.7,50.92),
('FLIP-1377','MHOD-BLK-M',1,1299,194.85,55.21),
('FLIP-1377','WTOP-WHT-L',3,599,269.55,76.37),
('FLIP-1377','WLHG-RED-L',1,5499,824.85,841.35),
('FLIP-1377','WDRS-FLP-S',1,1499,224.85,63.71),
('AMAZ-1494','BKUR-MUS-89Y',2,949,0.0,94.9),
('SHOP-1401','BKUR-CRM-45Y',1,949,47.45,45.08),
('SHOP-1402','BTEE-BLU-67Y',1,329,32.9,14.81),
('AMAZ-1495','MCHN-KHK-30',2,1199,359.7,101.92),
('AMAZ-1495','MCHN-OLV-32',1,1199,179.85,50.96),
('AMAZ-1496','MJNS-BLK-30',1,1399,0.0,69.95),
('SHOP-1403','MKUR-WHT-XL',1,1099,164.85,46.71),
('AMAZ-1497','MBLZ-NVY-40',1,3799,379.9,615.44),
('AMAZ-1497','WKRT-TEL-XL',1,849,84.9,38.21),
('AMAZ-1497','MCHN-OLV-32',1,1199,119.9,53.96),
('FLIP-1378','MHOD-BLK-M',2,1299,259.8,116.91),
('SHOP-1404','WTOP-WHT-M',1,599,89.85,25.46),
('SHOP-1404','MKUR-WHT-XL',1,1099,164.85,46.71),
('AMAZ-1498','WKRT-PNK-M',1,849,0.0,42.45),
('AMAZ-1498','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1499','MHOD-BLK-M',1,1299,0.0,64.95),
('AMAZ-1500','WLEG-MAR-M',1,349,0.0,17.45),
('FLIP-1379','MTRK-BLK-L',1,649,0.0,32.45),
('FLIP-1379','MCHN-KHK-30',1,1199,0.0,59.95),
('FLIP-1379','MSHC-GRN-L',1,899,0.0,44.95),
('AMAZ-1501','BSHF-WHT-67Y',1,599,89.85,25.46),
('AMAZ-1502','BKUR-MUS-67Y',1,949,47.45,45.08)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1400','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1305', 'UPI-REFUND-SHOP-1305');
select pg_temp.ret_refund_d2c('SHOP-1315', 'UPI-REFUND-SHOP-1315');
select pg_temp.ret_recv('AMAZ-1407');
select pg_temp.ret_set('AMAZ-1435', 'approved');
select pg_temp.ret_set('AMAZ-1442', 'pickup');
select pg_temp.ret_new('AMAZ-1445', 'Colour different from photo', 'webhook');
select pg_temp.ret_new('SHOP-1364', 'Colour different from photo', 'webhook');
select pg_temp.rto_set('FLIP-1347', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1352']::text[]);
select pg_temp.cod_collect(array['SHOP-1372']::text[]);
select pg_temp.cod_collect(array['SHOP-1377']::text[]);
select pg_temp.cod_collect(array['FLIP-1363']::text[]);
select pg_temp.cod_collect(array['SHOP-1386']::text[]);
select pg_temp.claim_recover('FLIP-1256', 'damaged_return', 'CLAIM-CR-FLIP-1256');
select pg_temp.claim_step('FLIP-1274', 'lost_shipment', 'claimed', null);
select pg_temp.retime();

-- Sun 13 Sep 2026
select pg_temp.day('2026-09-13');
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Krishna Denim Works (ref R166)', 'KDW/26/0358', 1);
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Little Stitch Garments (ref R167)', 'LSG/26/0322', 1);
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Little Stitch Garments (ref R168)', 'LSG/26/0334', 1);
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Rajdhani Shirting Mills (ref R170)', 'DC-RSM-0148', '[{"sku":"MKUR-WHT-L","q":6,"a":6,"r":0},{"sku":"MKUR-WHT-XL","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Rajdhani Shirting Mills (ref R171)', 'RSM/26/0359', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1380','Flipkart - Seller Hub','2026-09-13 22:12+05:30','Neha Patel','prepaid',3594.0,539.1,152.74,3207.64,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1503','Amazon - Seller Central','2026-09-13 13:44+05:30','Vipul Gandhi','prepaid',3046.0,0.0,152.3,3198.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1504','Amazon - Seller Central','2026-09-13 18:20+05:30','Vipul Gandhi','prepaid',599.0,59.9,26.96,566.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1405','Shopify - Main Store','2026-09-13 10:35+05:30','Aarav Mehta','cod',2178.0,108.9,103.45,2172.55,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1381','Flipkart - Seller Hub','2026-09-13 14:28+05:30','Foram Thakkar','prepaid',4398.0,659.7,186.92,3925.22,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1382','Flipkart - Seller Hub','2026-09-13 16:53+05:30','Amit Sethi','prepaid',4277.0,641.55,181.78,3817.23,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1383','Flipkart - Seller Hub','2026-09-13 11:59+05:30','Neha Patel','prepaid',3797.0,0.0,189.85,3986.85,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1505','Amazon - Seller Central','2026-09-13 10:15+05:30','Manav Joshi','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1506','Amazon - Seller Central','2026-09-13 10:21+05:30','Pooja Jain','prepaid',1698.0,0.0,84.9,1782.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1507','Amazon - Seller Central','2026-09-13 17:40+05:30','Pooja Jain','prepaid',1548.0,154.8,69.67,1462.87,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1508','Amazon - Seller Central','2026-09-13 20:04+05:30','Foram Thakkar','prepaid',1728.0,259.2,73.44,1542.24,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1384','Flipkart - Seller Hub','2026-09-13 09:03+05:30','Amit Sethi','prepaid',2798.0,0.0,139.9,2937.9,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1509','Amazon - Seller Central','2026-09-13 18:27+05:30','Riya Shah','prepaid',349.0,17.45,16.58,348.13,'shipped','paid','Delhi','Surat Main Warehouse'),
('SHOP-1406','Shopify - Main Store','2026-09-13 14:21+05:30','Amit Sethi','cod',558.0,0.0,27.9,585.9,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1385','Flipkart - Seller Hub','2026-09-13 11:24+05:30','Vipul Gandhi','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1386','Flipkart - Seller Hub','2026-09-13 12:38+05:30','Vipul Gandhi','prepaid',3297.0,0.0,164.85,3461.85,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1510','Amazon - Seller Central','2026-09-13 13:29+05:30','Aarav Mehta','prepaid',2745.0,274.5,123.54,2594.04,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1511','Amazon - Seller Central','2026-09-13 13:07+05:30','Anjali Verma','prepaid',558.0,55.8,25.12,527.32,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1387','Flipkart - Seller Hub','2026-09-13 21:46+05:30','Yash Vora','prepaid',3327.0,332.7,149.73,3144.03,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1407','Shopify - Main Store','2026-09-13 22:40+05:30','Mitul Dave','prepaid',3797.0,379.7,170.88,3588.18,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1408','Shopify - Main Store','2026-09-13 19:36+05:30','Amit Sethi','prepaid',658.0,32.9,31.26,656.36,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1512','Amazon - Seller Central','2026-09-13 21:10+05:30','Aditi Joshi','prepaid',5105.0,510.5,229.74,4824.24,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1513','Amazon - Seller Central','2026-09-13 09:29+05:30','Amit Sethi','prepaid',4103.0,205.15,194.91,4092.76,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1388','Flipkart - Seller Hub','2026-09-13 13:21+05:30','Ritu Saxena','cod',1797.0,89.85,85.36,1792.51,'delivered','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1380','WTOP-PCH-L',3,599,269.55,76.37),
('FLIP-1380','WTOP-WHT-L',3,599,269.55,76.37),
('AMAZ-1503','WTOP-PCH-L',2,599,0.0,59.9),
('AMAZ-1503','WDUP-SLV-FREE',1,449,0.0,22.45),
('AMAZ-1503','MJNS-IND-34',1,1399,0.0,69.95),
('AMAZ-1504','WTOP-PCH-M',1,599,59.9,26.96),
('SHOP-1405','GJNS-IND-89Y',1,779,38.95,37.0),
('SHOP-1405','MJNS-BLK-32',1,1399,69.95,66.45),
('FLIP-1381','WSAR-RED-FREE',2,2199,659.7,186.92),
('FLIP-1382','GLEG-BLK-67Y',1,279,41.85,11.86),
('FLIP-1382','GLHG-RED-89Y',1,1999,299.85,84.96),
('FLIP-1382','GLHG-RED-45Y',1,1999,299.85,84.96),
('FLIP-1383','MHOD-BLK-M',2,1299,0.0,129.9),
('FLIP-1383','MCHN-KHK-30',1,1199,0.0,59.95),
('AMAZ-1505','BKUR-MUS-89Y',1,949,0.0,47.45),
('AMAZ-1506','WJNS-BLK-30',1,1349,0.0,67.45),
('AMAZ-1506','WLEG-BLK-M',1,349,0.0,17.45),
('AMAZ-1507','MSHC-GRN-L',1,899,89.9,40.46),
('AMAZ-1507','MTRK-BLK-M',1,649,64.9,29.21),
('AMAZ-1508','MJNS-BLK-32',1,1399,209.85,59.46),
('AMAZ-1508','BTEE-BLU-89Y',1,329,49.35,13.98),
('FLIP-1384','MJNS-BLK-34',2,1399,0.0,139.9),
('AMAZ-1509','BSHT-NVY-89Y',1,349,17.45,16.58),
('SHOP-1406','GLEG-PNK-67Y',2,279,0.0,27.9),
('FLIP-1385','BKUR-CRM-89Y',2,949,0.0,94.9),
('FLIP-1386','MTRK-BLK-L',2,649,0.0,64.9),
('FLIP-1386','GLHG-TEL-89Y',1,1999,0.0,99.95),
('AMAZ-1510','WTOP-WHT-M',3,599,179.7,80.87),
('AMAZ-1510','WTOP-PCH-L',1,599,59.9,26.96),
('AMAZ-1510','WLEG-NVY-M',1,349,34.9,15.71),
('AMAZ-1511','GLEG-BLK-67Y',1,279,27.9,12.56),
('AMAZ-1511','GLEG-BLK-89Y',1,279,27.9,12.56),
('FLIP-1387','WSAR-GRN-FREE',1,2199,219.9,98.96),
('FLIP-1387','GLEG-PNK-45Y',1,279,27.9,12.56),
('FLIP-1387','WKRT-PNK-M',1,849,84.9,38.21),
('SHOP-1407','MJNS-IND-32',1,1399,139.9,62.96),
('SHOP-1407','MCHN-KHK-30',1,1199,119.9,53.96),
('SHOP-1407','MCHN-OLV-34',1,1199,119.9,53.96),
('SHOP-1408','BTEE-BLU-89Y',2,329,32.9,31.26),
('AMAZ-1512','GLEG-PNK-67Y',1,279,27.9,12.56),
('AMAZ-1512','GNGT-PNK-1011Y',1,549,54.9,24.71),
('AMAZ-1512','GLEG-BLK-67Y',1,279,27.9,12.56),
('AMAZ-1512','GLHG-TEL-45Y',2,1999,399.8,179.91),
('AMAZ-1513','GLEG-PNK-89Y',2,279,27.9,26.51),
('AMAZ-1513','GFRK-LIL-45Y',2,749,74.9,71.16),
('AMAZ-1513','GTOP-YLW-67Y',2,349,34.9,33.16),
('AMAZ-1513','WJNS-BLK-30',1,1349,67.45,64.08),
('FLIP-1388','WTOP-WHT-M',1,599,29.95,28.45),
('FLIP-1388','WTOP-PCH-S',2,599,59.9,56.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1405','Bluedart - Surat City'),
('SHOP-1406','Bluedart - Surat City'),
('FLIP-1388','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1311');
select pg_temp.rto_recv('FLIP-1330', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1435', 'pickup');
select pg_temp.ret_set('AMAZ-1445', 'approved');
select pg_temp.rto_set('SHOP-1356', 'in_transit');
select pg_temp.ret_new('SHOP-1363', 'Size did not fit', 'webhook');
select pg_temp.ret_set('SHOP-1364', 'approved');
select pg_temp.rto_set('FLIP-1348', 'in_transit');
select pg_temp.cod_collect(array['AMAZ-1468']::text[]);
select pg_temp.cod_collect(array['SHOP-1379']::text[]);
select pg_temp.cod_collect(array['FLIP-1364']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260831', 0.0);
select pg_temp.retime();

-- Mon 14 Sep 2026
select pg_temp.day('2026-09-14');
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Rajdhani Shirting Mills (ref R170)', 'RSM/26/0356', 1);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Krishna Denim Works (ref R175)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MCHN-KHK-30","q":12},{"sku":"GJNS-IND-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Krishna Denim Works (ref R176)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-30","q":8},{"sku":"MJNS-BLK-32","q":20},{"sku":"MCHN-OLV-32","q":12},{"sku":"WJNS-IND-28","q":16},{"sku":"WJNS-BLK-32","q":12},{"sku":"GJNS-IND-89Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Little Stitch Garments (ref R177)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"BKUR-CRM-89Y","q":12},{"sku":"BKUR-MUS-67Y","q":10},{"sku":"GLHG-TEL-89Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Little Stitch Garments (ref R178)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLP-S","q":10},{"sku":"BSHT-NVY-67Y","q":6},{"sku":"BKUR-CRM-89Y","q":12},{"sku":"GLHG-RED-67Y","q":14},{"sku":"GLHG-RED-89Y","q":6},{"sku":"GLHG-TEL-45Y","q":8},{"sku":"GNGT-PNK-67Y","q":8},{"sku":"GNGT-PNK-89Y","q":14},{"sku":"GNGT-PNK-1011Y","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Ludhiana Winter Wear Co (ref R179)', 'Ludhiana Winter Wear Co', 'Mumbai Fulfilment Center', '[{"sku":"MHOD-BLK-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Ludhiana Winter Wear Co (ref R180)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"MHOD-BLK-M","q":10},{"sku":"MHOD-BLK-L","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Rajdhani Shirting Mills (ref R181)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-GRN-L","q":12},{"sku":"MKUR-MUS-XL","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Shree Ambika Textiles (ref R182)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-S","q":12},{"sku":"WKRT-PNK-L","q":6},{"sku":"WKRT-TEL-M","q":10},{"sku":"WKRT-TEL-XL","q":6},{"sku":"WPAL-YLW-L","q":6},{"sku":"WSAR-RED-FREE","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R183)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"WLEG-NVY-L","q":6},{"sku":"WTOP-PCH-L","q":26},{"sku":"BTEE-RED-89Y","q":8},{"sku":"GLEG-PNK-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 14 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R184)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-BLK-L","q":6},{"sku":"WLEG-NVY-M","q":8},{"sku":"WTOP-WHT-L","q":26},{"sku":"WTOP-PCH-M","q":28},{"sku":"GTOP-WHT-89Y","q":6},{"sku":"GLEG-BLK-67Y","q":22},{"sku":"GLEG-PNK-89Y","q":12}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1389','Flipkart - Seller Hub','2026-09-14 17:31+05:30','Kavya Menon','prepaid',2348.0,0.0,117.4,2465.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1514','Amazon - Seller Central','2026-09-14 13:53+05:30','Shreya Banerjee','prepaid',3148.0,314.8,141.67,2974.87,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1409','Shopify - Main Store','2026-09-14 10:50+05:30','Vivek Singh','prepaid',4395.0,0.0,219.75,4614.75,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1410','Shopify - Main Store','2026-09-14 18:53+05:30','Foram Thakkar','cod',7597.0,379.85,1039.98,8257.13,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1390','Flipkart - Seller Hub','2026-09-14 16:36+05:30','Heena Khan','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1391','Flipkart - Seller Hub','2026-09-14 17:27+05:30','Pooja Jain','prepaid',4296.0,214.8,204.06,4285.26,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1392','Flipkart - Seller Hub','2026-09-14 18:21+05:30','Heena Khan','cod',1698.0,254.7,72.17,1515.47,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1411','Shopify - Main Store','2026-09-14 20:18+05:30','Aarav Mehta','prepaid',3197.0,0.0,159.85,3356.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1412','Shopify - Main Store','2026-09-14 12:09+05:30','Kunal Desai','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1393','Flipkart - Seller Hub','2026-09-14 17:11+05:30','Neha Patel','cod',5499.0,0.0,989.82,6488.82,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1413','Shopify - Main Store','2026-09-14 14:18+05:30','Sonal Parekh','prepaid',349.0,52.35,14.83,311.48,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1389','MJNS-IND-34',1,1399,0.0,69.95),
('FLIP-1389','BKUR-MUS-45Y',1,949,0.0,47.45),
('AMAZ-1514','BKUR-MUS-45Y',1,949,94.9,42.71),
('AMAZ-1514','WSAR-GRN-FREE',1,2199,219.9,98.96),
('SHOP-1409','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1409','GNGT-PNK-89Y',2,549,0.0,54.9),
('SHOP-1409','WJNS-BLK-30',2,1349,0.0,134.9),
('SHOP-1410','WLHG-RED-M',1,5499,274.95,940.33),
('SHOP-1410','WTOP-PCH-M',1,599,29.95,28.45),
('SHOP-1410','WDRS-FLR-S',1,1499,74.95,71.2),
('FLIP-1390','BTEE-BLU-89Y',1,329,32.9,14.81),
('FLIP-1391','MSHC-RED-XL',1,899,44.95,42.7),
('FLIP-1391','MJNS-BLK-34',2,1399,139.9,132.91),
('FLIP-1391','WTOP-WHT-M',1,599,29.95,28.45),
('FLIP-1392','WKRT-PNK-XL',2,849,254.7,72.17),
('SHOP-1411','WDRS-FLP-L',1,1499,0.0,74.95),
('SHOP-1411','WKRT-TEL-M',2,849,0.0,84.9),
('SHOP-1412','MCHN-KHK-30',1,1199,0.0,59.95),
('SHOP-1412','MPOL-MRN-XL',1,699,0.0,34.95),
('FLIP-1393','WLHG-RED-M',1,5499,0.0,989.82),
('SHOP-1413','BSHT-GRY-45Y',1,349,52.35,14.83)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1410','Delhivery - Sachin GIDC Surat'),
('FLIP-1392','Delhivery - Sachin GIDC Surat'),
('FLIP-1393','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1407', 'damaged', 'quarantined');
select pg_temp.ret_dispo('FLIP-1311', 'good', 'restocked');
select pg_temp.ret_recv('SHOP-1333');
select pg_temp.ret_set('AMAZ-1442', 'in_transit');
select pg_temp.ret_set('AMAZ-1445', 'pickup');
select pg_temp.ret_set('SHOP-1363', 'approved');
select pg_temp.ret_set('SHOP-1364', 'pickup');
select pg_temp.ret_new('SHOP-1366', 'Colour different from photo', 'manual');
select pg_temp.ret_new('SHOP-1374', 'Size did not fit', 'webhook');
select pg_temp.ret_new('FLIP-1354', 'Colour different from photo', 'webhook');
select pg_temp.cod_collect(array['FLIP-1367']::text[]);
select pg_temp.cod_collect(array['SHOP-1389']::text[]);
select pg_temp.cod_collect(array['AMAZ-1489']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260907', '2026-09-07', '2026-09-13', array['AMAZ-1437','AMAZ-1443','AMAZ-1454','AMAZ-1445','AMAZ-1449','AMAZ-1453','AMAZ-1455','AMAZ-1456','AMAZ-1460','AMAZ-1448','AMAZ-1451','AMAZ-1457','AMAZ-1459','AMAZ-1465','AMAZ-1452','AMAZ-1461','AMAZ-1464','AMAZ-1466','AMAZ-1467','AMAZ-1473','AMAZ-1474','AMAZ-1478','AMAZ-1479','AMAZ-1480']::text[], array['AMAZ-1379','AMAZ-1407']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260907', '2026-09-07', '2026-09-13', array['FLIP-1333','FLIP-1334','FLIP-1339','FLIP-1345','FLIP-1350','FLIP-1351','FLIP-1353','FLIP-1338','FLIP-1340','FLIP-1341','FLIP-1344','FLIP-1355','FLIP-1359','FLIP-1343','FLIP-1346','FLIP-1349','FLIP-1354','FLIP-1356','FLIP-1357','FLIP-1358','FLIP-1360']::text[], array['FLIP-1311']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260907', '2026-09-07', '2026-09-13', array['SHOP-1346','SHOP-1348','SHOP-1355','SHOP-1363','SHOP-1352','SHOP-1353','SHOP-1360','SHOP-1364','SHOP-1365','SHOP-1371','SHOP-1374','SHOP-1354','SHOP-1357','SHOP-1366','SHOP-1358','SHOP-1362','SHOP-1375','SHOP-1376','SHOP-1382','SHOP-1367','SHOP-1368','SHOP-1373','SHOP-1378','SHOP-1380','SHOP-1381','SHOP-1383','SHOP-1384','SHOP-1388']::text[], array[]::text[]);
select pg_temp.claim_step('AMAZ-1379', 'lost_shipment', 'claimed', null);
select pg_temp.claim_new('AMAZ-1407', 'damaged_return', 1415.8, '2026-10-14');
select pg_temp.retime();

-- Tue 15 Sep 2026
select pg_temp.day('2026-09-15');
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R174)', 'DC-TKF-0205', '[{"sku":"MTEE-BLK-L","q":6,"a":6,"r":0},{"sku":"WTOP-WHT-L","q":18,"a":18,"r":0},{"sku":"WTOP-PCH-M","q":26,"a":26,"r":0},{"sku":"BTEE-RED-67Y","q":6,"a":6,"r":0},{"sku":"GTOP-WHT-89Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1414','Shopify - Main Store','2026-09-15 21:45+05:30','Foram Thakkar','prepaid',948.0,142.2,40.29,846.09,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1415','Shopify - Main Store','2026-09-15 17:33+05:30','Bhavna Solanki','cod',4155.0,0.0,207.75,4362.75,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1515','Amazon - Seller Central','2026-09-15 19:48+05:30','Rahul Bhatt','prepaid',3397.0,339.7,152.87,3210.17,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1416','Shopify - Main Store','2026-09-15 18:12+05:30','Vivek Singh','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1394','Flipkart - Seller Hub','2026-09-15 19:43+05:30','Foram Thakkar','cod',599.0,89.85,25.46,534.61,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1516','Amazon - Seller Central','2026-09-15 22:34+05:30','Heena Khan','prepaid',4104.0,615.6,174.43,3662.83,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1417','Shopify - Main Store','2026-09-15 22:31+05:30','Isha Gupta','prepaid',1998.0,99.9,94.91,1993.01,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1517','Amazon - Seller Central','2026-09-15 16:50+05:30','Sejal Kapadia','prepaid',3996.0,0.0,199.8,4195.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1518','Amazon - Seller Central','2026-09-15 13:06+05:30','Heena Khan','prepaid',749.0,0.0,37.45,786.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1395','Flipkart - Seller Hub','2026-09-15 16:27+05:30','Kunal Desai','prepaid',4095.0,0.0,204.75,4299.75,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1519','Amazon - Seller Central','2026-09-15 19:18+05:30','Vipul Gandhi','prepaid',2398.0,359.7,101.92,2140.22,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1418','Shopify - Main Store','2026-09-15 10:02+05:30','Isha Gupta','prepaid',7197.0,1079.55,913.52,7030.97,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1396','Flipkart - Seller Hub','2026-09-15 12:01+05:30','Nidhi Agarwal','prepaid',3148.0,157.4,149.53,3140.13,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1520','Amazon - Seller Central','2026-09-15 09:17+05:30','Isha Gupta','prepaid',7196.0,0.0,359.8,7555.8,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1414','WTOP-PCH-L',1,599,89.85,25.46),
('SHOP-1414','BSHT-GRY-89Y',1,349,52.35,14.83),
('SHOP-1415','MTRK-BLK-M',1,649,0.0,32.45),
('SHOP-1415','WKRT-TEL-M',1,849,0.0,42.45),
('SHOP-1415','GLHG-TEL-89Y',1,1999,0.0,99.95),
('SHOP-1415','BTEE-RED-89Y',2,329,0.0,32.9),
('AMAZ-1515','MCHN-OLV-32',2,1199,239.8,107.91),
('AMAZ-1515','MSHF-WHT-L',1,999,99.9,44.96),
('SHOP-1416','BTEE-BLU-45Y',1,329,0.0,16.45),
('FLIP-1394','WTOP-WHT-M',1,599,89.85,25.46),
('AMAZ-1516','BTEE-BLU-67Y',2,329,98.7,27.97),
('AMAZ-1516','BSHF-WHT-67Y',1,599,89.85,25.46),
('AMAZ-1516','BKUR-MUS-89Y',3,949,427.05,121.0),
('SHOP-1417','MSHF-WHT-L',2,999,99.9,94.91),
('AMAZ-1517','WKRT-PNK-M',1,849,0.0,42.45),
('AMAZ-1517','WJNS-IND-32',2,1349,0.0,134.9),
('AMAZ-1517','WDUP-SLV-FREE',1,449,0.0,22.45),
('AMAZ-1518','GFRK-LIL-45Y',1,749,0.0,37.45),
('FLIP-1395','WSAR-RED-FREE',1,2199,0.0,109.95),
('FLIP-1395','WLEG-BLK-M',2,349,0.0,34.9),
('FLIP-1395','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1395','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1519','MCHN-OLV-34',2,1199,359.7,101.92),
('SHOP-1418','WTOP-PCH-L',1,599,89.85,25.46),
('SHOP-1418','MKUR-WHT-XL',1,1099,164.85,46.71),
('SHOP-1418','WLHG-RED-L',1,5499,824.85,841.35),
('FLIP-1396','BKUR-MUS-67Y',1,949,47.45,45.08),
('FLIP-1396','WSAR-RED-FREE',1,2199,109.95,104.45),
('AMAZ-1520','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1520','WSAR-GRN-FREE',3,2199,0.0,329.85)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1415','Ecom Express - Udhna Hub'),
('FLIP-1394','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('SHOP-1333', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1435', 'in_transit');
select pg_temp.ret_new('FLIP-1340', 'Size did not fit', 'webhook');
select pg_temp.ret_set('SHOP-1363', 'pickup');
select pg_temp.ret_set('SHOP-1366', 'approved');
select pg_temp.ret_set('SHOP-1374', 'approved');
select pg_temp.ret_new('AMAZ-1466', 'Colour different from photo', 'webhook');
select pg_temp.ret_set('FLIP-1354', 'approved');
select pg_temp.cod_collect(array['FLIP-1366']::text[]);
select pg_temp.settle_pay('FLK-STL-20260831', 0.0);
select pg_temp.retime();

-- Wed 16 Sep 2026
select pg_temp.day('2026-09-16');
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Little Stitch Garments (ref R167)', 'DC-LSG-0136', '[{"sku":"WDRS-FLR-L","q":2,"a":2,"r":0},{"sku":"BSHT-GRY-45Y","q":3,"a":3,"r":0},{"sku":"BSHT-GRY-67Y","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R174)', 'TKF/26/0485', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1419','Shopify - Main Store','2026-09-16 14:53+05:30','Rahul Bhatt','cod',1307.0,0.0,65.35,1372.35,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('AMAZ-1521','Amazon - Seller Central','2026-09-16 09:31+05:30','Riya Shah','prepaid',2398.0,239.8,107.91,2266.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1397','Flipkart - Seller Hub','2026-09-16 18:32+05:30','Pratik Lad','cod',949.0,47.45,45.08,946.63,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1522','Amazon - Seller Central','2026-09-16 14:22+05:30','Vipul Gandhi','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1523','Amazon - Seller Central','2026-09-16 17:04+05:30','Pooja Jain','prepaid',2297.0,0.0,114.85,2411.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1524','Amazon - Seller Central','2026-09-16 15:40+05:30','Karan Malhotra','prepaid',1907.0,0.0,95.35,2002.35,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1420','Shopify - Main Store','2026-09-16 10:24+05:30','Rohit Iyer','prepaid',5499.0,0.0,989.82,6488.82,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1421','Shopify - Main Store','2026-09-16 15:25+05:30','Karan Malhotra','cod',1299.0,129.9,58.46,1227.56,'delivered','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1419','GLEG-PNK-67Y',1,279,0.0,13.95),
('SHOP-1419','GLEG-BLK-67Y',1,279,0.0,13.95),
('SHOP-1419','GFRK-PNK-67Y',1,749,0.0,37.45),
('AMAZ-1521','MCHN-OLV-34',2,1199,239.8,107.91),
('FLIP-1397','BKUR-MUS-45Y',1,949,47.45,45.08),
('AMAZ-1522','MJNS-IND-32',1,1399,0.0,69.95),
('AMAZ-1523','WLEG-NVY-M',1,349,0.0,17.45),
('AMAZ-1523','WJNS-IND-30',1,1349,0.0,67.45),
('AMAZ-1523','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1524','GTOP-YLW-67Y',1,349,0.0,17.45),
('AMAZ-1524','GJNS-IND-45Y',2,779,0.0,77.9),
('SHOP-1420','WLHG-RED-L',1,5499,0.0,989.82),
('SHOP-1421','MHOD-GRY-M',1,1299,129.9,58.46)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1397','DTDC - Ring Road Surat'),
('SHOP-1421','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1442');
select pg_temp.ret_set('AMAZ-1445', 'in_transit');
select pg_temp.ret_set('FLIP-1340', 'approved');
select pg_temp.ret_set('SHOP-1364', 'in_transit');
select pg_temp.ret_set('SHOP-1366', 'pickup');
select pg_temp.ret_new('AMAZ-1465', 'Colour different from photo', 'webhook');
select pg_temp.ret_set('SHOP-1374', 'pickup');
select pg_temp.ret_set('AMAZ-1466', 'approved');
select pg_temp.ret_set('FLIP-1354', 'pickup');
select pg_temp.cod_collect(array['AMAZ-1487']::text[]);
select pg_temp.rto_new('FLIP-1373', 'AWB31001091', 'Delivery attempts exhausted');
select pg_temp.rto_new('AMAZ-1488', 'AWB31001128', 'Customer unreachable');
select pg_temp.cod_collect(array['FLIP-1374']::text[]);
select pg_temp.cod_collect(array['SHOP-1400']::text[]);
select pg_temp.settle_pay('SHP-STL-20260907', 0.0);
select pg_temp.claim_recover('AMAZ-1337', 'other', 'CLAIM-CR-AMAZ-1337');
select pg_temp.retime();

-- Thu 17 Sep 2026
select pg_temp.day('2026-09-17');
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Little Stitch Garments (ref R167)', 'LSG/26/0330', 1);
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Ludhiana Winter Wear Co (ref R169)', 'DC-LWW-0076', '[{"sku":"MHOD-BLK-M","q":10,"a":10,"r":0},{"sku":"MHOD-BLK-L","q":6,"a":6,"r":0},{"sku":"MHOD-BLK-XL","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 07 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R173)', 'DC-TKF-0202', '[{"sku":"MTEE-BLK-M","q":6,"a":6,"r":0},{"sku":"WLEG-NVY-L","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Little Stitch Garments (ref R178)', 'DC-LSG-0145', '[{"sku":"WDRS-FLP-S","q":10,"a":10,"r":0},{"sku":"BSHT-NVY-67Y","q":6,"a":6,"r":0},{"sku":"BKUR-CRM-89Y","q":12,"a":12,"r":0},{"sku":"GLHG-RED-67Y","q":14,"a":13,"r":1},{"sku":"GLHG-RED-89Y","q":6,"a":6,"r":0},{"sku":"GLHG-TEL-45Y","q":8,"a":8,"r":0},{"sku":"GNGT-PNK-67Y","q":8,"a":8,"r":0},{"sku":"GNGT-PNK-89Y","q":14,"a":14,"r":0},{"sku":"GNGT-PNK-1011Y","q":10,"a":10,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1525','Amazon - Seller Central','2026-09-17 21:32+05:30','Rahul Bhatt','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1398','Flipkart - Seller Hub','2026-09-17 13:53+05:30','Yash Vora','prepaid',4277.0,427.7,192.47,4041.77,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1526','Amazon - Seller Central','2026-09-17 15:27+05:30','Vivek Singh','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1399','Flipkart - Seller Hub','2026-09-17 10:54+05:30','Rahul Bhatt','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1527','Amazon - Seller Central','2026-09-17 11:55+05:30','Vivek Singh','prepaid',4394.0,439.4,197.74,4152.34,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1400','Flipkart - Seller Hub','2026-09-17 15:55+05:30','Nikhil Pandey','prepaid',949.0,142.35,40.33,846.98,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1422','Shopify - Main Store','2026-09-17 13:56+05:30','Isha Gupta','cod',1399.0,0.0,69.95,1468.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1401','Flipkart - Seller Hub','2026-09-17 14:00+05:30','Kavya Menon','prepaid',3397.0,0.0,169.85,3566.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1423','Shopify - Main Store','2026-09-17 10:36+05:30','Tanvi Rana','cod',1748.0,0.0,87.4,1835.4,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1528','Amazon - Seller Central','2026-09-17 15:18+05:30','Jigar Chauhan','prepaid',1299.0,129.9,58.46,1227.56,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1424','Shopify - Main Store','2026-09-17 10:24+05:30','Yash Vora','prepaid',899.0,89.9,40.46,849.56,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1402','Flipkart - Seller Hub','2026-09-17 21:18+05:30','Tanvi Rana','prepaid',3695.0,554.25,157.05,3297.8,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1525','WPAL-WHT-L',2,599,0.0,59.9),
('FLIP-1398','GLHG-TEL-67Y',2,1999,399.8,179.91),
('FLIP-1398','GLEG-BLK-45Y',1,279,27.9,12.56),
('AMAZ-1526','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1399','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1527','GLEG-BLK-67Y',2,279,55.8,25.11),
('AMAZ-1527','GLEG-BLK-89Y',1,279,27.9,12.56),
('AMAZ-1527','GLHG-RED-45Y',1,1999,199.9,89.96),
('AMAZ-1527','GJNS-IND-1011Y',2,779,155.8,70.11),
('FLIP-1400','BKUR-MUS-45Y',1,949,142.35,40.33),
('SHOP-1422','MJNS-BLK-34',1,1399,0.0,69.95),
('FLIP-1401','MJNS-BLK-32',1,1399,0.0,69.95),
('FLIP-1401','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1401','BJNS-IND-89Y',1,799,0.0,39.95),
('SHOP-1423','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1423','BJNS-IND-45Y',1,799,0.0,39.95),
('AMAZ-1528','MHOD-BLK-XL',1,1299,129.9,58.46),
('SHOP-1424','MSHC-RED-XL',1,899,89.9,40.46),
('FLIP-1402','WTOP-WHT-L',2,599,179.7,50.92),
('FLIP-1402','MHOD-BLK-M',1,1299,194.85,55.21),
('FLIP-1402','WTOP-WHT-M',2,599,179.7,50.92)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1422','Ecom Express - Udhna Hub'),
('SHOP-1423','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1435');
select pg_temp.ret_new('SHOP-1354', 'Customer changed mind', 'webhook');
select pg_temp.ret_set('FLIP-1340', 'pickup');
select pg_temp.ret_set('SHOP-1363', 'in_transit');
select pg_temp.rto_recv('FLIP-1347', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1465', 'approved');
select pg_temp.ret_set('AMAZ-1466', 'pickup');
select pg_temp.cod_collect(array['FLIP-1372']::text[]);
select pg_temp.rto_new('AMAZ-1509', 'AWB31001158', 'Customer unreachable');
select pg_temp.cod_collect(array['FLIP-1388']::text[]);
select pg_temp.claim_step('FLIP-1273', 'excess_deduction', 'approved', null);
select pg_temp.claim_step('AMAZ-1407', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Fri 18 Sep 2026
select pg_temp.day('2026-09-18');
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Ludhiana Winter Wear Co (ref R169)', 'LWW/26/0190', 1);
select pg_temp.bill_po('Weekly replenishment 07 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R173)', 'TKF/26/0479', 1);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Little Stitch Garments (ref R177)', 'DC-LSG-0142', '[{"sku":"BKUR-CRM-89Y","q":12,"a":12,"r":0},{"sku":"BKUR-MUS-67Y","q":10,"a":9,"r":1},{"sku":"GLHG-TEL-89Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Little Stitch Garments (ref R178)', 'LSG/26/0345', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1425','Shopify - Main Store','2026-09-18 16:48+05:30','Sonal Parekh','cod',1999.0,199.9,89.96,1889.06,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1426','Shopify - Main Store','2026-09-18 18:23+05:30','Pooja Jain','cod',329.0,0.0,16.45,345.45,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1403','Flipkart - Seller Hub','2026-09-18 18:22+05:30','Foram Thakkar','prepaid',1299.0,194.85,55.21,1159.36,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1529','Amazon - Seller Central','2026-09-18 12:00+05:30','Prachi Kulkarni','prepaid',6746.0,1011.9,706.5,6440.6,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1530','Amazon - Seller Central','2026-09-18 19:29+05:30','Chirag Zaveri','prepaid',4695.0,704.25,199.55,4190.3,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1427','Shopify - Main Store','2026-09-18 22:22+05:30','Kiran Naik','cod',999.0,0.0,49.95,1048.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1428','Shopify - Main Store','2026-09-18 09:14+05:30','Tanvi Rana','prepaid',549.0,0.0,27.45,576.45,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1429','Shopify - Main Store','2026-09-18 20:08+05:30','Neha Patel','prepaid',1499.0,0.0,74.95,1573.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1430','Shopify - Main Store','2026-09-18 19:37+05:30','Manav Joshi','cod',2506.0,0.0,125.3,2631.3,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1531','Amazon - Seller Central','2026-09-18 14:02+05:30','Isha Gupta','prepaid',978.0,97.8,44.02,924.22,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1532','Amazon - Seller Central','2026-09-18 12:43+05:30','Isha Gupta','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1533','Amazon - Seller Central','2026-09-18 22:15+05:30','Sagar Rathod','prepaid',1897.0,94.85,90.11,1892.26,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1534','Amazon - Seller Central','2026-09-18 19:33+05:30','Mehul Shukla','prepaid',3796.0,379.6,170.83,3587.23,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1535','Amazon - Seller Central','2026-09-18 16:08+05:30','Sanjay Gajera','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1431','Shopify - Main Store','2026-09-18 12:37+05:30','Yash Vora','prepaid',4398.0,0.0,219.9,4617.9,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1425','GLHG-RED-45Y',1,1999,199.9,89.96),
('SHOP-1426','BTEE-BLU-89Y',1,329,0.0,16.45),
('FLIP-1403','MHOD-BLK-M',1,1299,194.85,55.21),
('AMAZ-1529','MJNS-BLK-32',1,1399,209.85,59.46),
('AMAZ-1529','MBLZ-NVY-38',1,3799,569.85,581.25),
('AMAZ-1529','MCHN-OLV-34',1,1199,179.85,50.96),
('AMAZ-1529','WLEG-BLK-M',1,349,52.35,14.83),
('AMAZ-1530','MCHN-KHK-30',1,1199,179.85,50.96),
('AMAZ-1530','MSHC-GRN-M',2,899,269.7,76.42),
('AMAZ-1530','MSHF-WHT-XL',1,999,149.85,42.46),
('AMAZ-1530','MPOL-NVY-M',1,699,104.85,29.71),
('SHOP-1427','BTRK-BLK-45Y',1,999,0.0,49.95),
('SHOP-1428','GNGT-PNK-89Y',1,549,0.0,27.45),
('SHOP-1429','WDRS-FLR-L',1,1499,0.0,74.95),
('SHOP-1430','BTEE-BLU-67Y',2,329,0.0,32.9),
('SHOP-1430','MSHC-RED-XL',1,899,0.0,44.95),
('SHOP-1430','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1531','MPOL-MRN-M',1,699,69.9,31.46),
('AMAZ-1531','GLEG-BLK-67Y',1,279,27.9,12.56),
('AMAZ-1532','GLEG-BLK-45Y',1,279,0.0,13.95),
('AMAZ-1533','WTOP-PCH-L',1,599,29.95,28.45),
('AMAZ-1533','MTRK-BLK-L',2,649,64.9,61.66),
('AMAZ-1534','BKUR-CRM-45Y',3,949,284.7,128.12),
('AMAZ-1534','BKUR-MUS-89Y',1,949,94.9,42.71),
('AMAZ-1535','GLEG-PNK-89Y',1,279,0.0,13.95),
('SHOP-1431','WSAR-GRN-FREE',2,2199,0.0,219.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1425','DTDC - Ring Road Surat'),
('SHOP-1426','Xpressbees - Pandesara'),
('SHOP-1427','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1333', 'UPI-REFUND-SHOP-1333');
select pg_temp.ret_dispo('AMAZ-1435', 'good', 'restocked');
select pg_temp.ret_dispo('AMAZ-1442', 'missing', 'claimed');
select pg_temp.ret_set('SHOP-1354', 'approved');
select pg_temp.rto_recv('SHOP-1356', 'good', 'restocked');
select pg_temp.ret_recv('SHOP-1364');
select pg_temp.ret_set('SHOP-1366', 'in_transit');
select pg_temp.ret_set('AMAZ-1465', 'pickup');
select pg_temp.ret_set('SHOP-1374', 'in_transit');
select pg_temp.ret_set('FLIP-1354', 'in_transit');
select pg_temp.rto_set('FLIP-1373', 'in_transit');
select pg_temp.rto_set('AMAZ-1488', 'in_transit');
select pg_temp.ret_new('AMAZ-1491', 'Size did not fit', 'webhook');
select pg_temp.cod_collect(array['SHOP-1405']::text[]);
select pg_temp.cod_collect(array['SHOP-1406']::text[]);
select pg_temp.cod_collect(array['FLIP-1393']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-18SEP', array['SHOP-1361','AMAZ-1468','SHOP-1386','SHOP-1400']::text[], 124.51);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-18SEP', array['AMAZ-1463','SHOP-1370','FLIP-1363','FLIP-1364','FLIP-1366']::text[], 298.75);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-18SEP', array['FLIP-1342','SHOP-1359','SHOP-1372','SHOP-1377','FLIP-1362','AMAZ-1470','AMAZ-1489']::text[], 450.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-18SEP', array['AMAZ-1462','FLIP-1352','SHOP-1379','SHOP-1389','AMAZ-1487']::text[], 450.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-18SEP', array['FLIP-1367','FLIP-1374']::text[], 450.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-09-21', 'ICIC000000887863', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-09-21', 'ICIC000000887884', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-09-21', 'ICIC000000887906', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-09-21', 'ICIC000000887920', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-09-21', 'ICIC000000888006', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-09-21', 'ICIC000000888088', 1);
select pg_temp.claim_recover('SHOP-1271', 'other', 'CLAIM-CR-SHOP-1271');
select pg_temp.claim_new('FLIP-1289', 'lost_shipment', 1140.61, '2026-10-18');
select pg_temp.claim_step('AMAZ-1383', 'damaged_return', 'rejected', null);
select pg_temp.claim_new('AMAZ-1442', 'lost_shipment', 2272.3, '2026-10-18');
select pg_temp.retime();

-- Sat 19 Sep 2026
select pg_temp.day('2026-09-19');
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Krishna Denim Works (ref R175)', 'DC-KDW-0151', '[{"sku":"MCHN-KHK-30","q":12,"a":12,"r":0},{"sku":"GJNS-IND-45Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Krishna Denim Works (ref R176)', 'DC-KDW-0154', '[{"sku":"MJNS-BLK-30","q":5,"a":5,"r":0},{"sku":"MJNS-BLK-32","q":13,"a":13,"r":0},{"sku":"MCHN-OLV-32","q":8,"a":8,"r":0},{"sku":"WJNS-IND-28","q":10,"a":10,"r":0},{"sku":"WJNS-BLK-32","q":8,"a":8,"r":0},{"sku":"GJNS-IND-89Y","q":6,"a":5,"r":1}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Little Stitch Garments (ref R177)', 'LSG/26/0341', 1);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Shree Ambika Textiles (ref R182)', 'DC-SAT-0148', '[{"sku":"WKRT-PNK-S","q":12,"a":12,"r":0},{"sku":"WKRT-PNK-L","q":6,"a":5,"r":1},{"sku":"WKRT-TEL-M","q":10,"a":9,"r":1},{"sku":"WKRT-TEL-XL","q":6,"a":6,"r":0},{"sku":"WPAL-YLW-L","q":6,"a":6,"r":0},{"sku":"WSAR-RED-FREE","q":6,"a":5,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1536','Amazon - Seller Central','2026-09-19 19:34+05:30','Rohit Iyer','cod',349.0,0.0,17.45,366.45,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1404','Flipkart - Seller Hub','2026-09-19 19:19+05:30','Foram Thakkar','prepaid',3097.0,0.0,154.85,3251.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1537','Amazon - Seller Central','2026-09-19 17:20+05:30','Manav Joshi','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1405','Flipkart - Seller Hub','2026-09-19 09:44+05:30','Prachi Kulkarni','cod',2198.0,329.7,93.42,1961.72,'shipped','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1432','Shopify - Main Store','2026-09-19 21:48+05:30','Meghna Rao','cod',2778.0,0.0,138.9,2916.9,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1433','Shopify - Main Store','2026-09-19 18:52+05:30','Mitul Dave','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1538','Amazon - Seller Central','2026-09-19 12:40+05:30','Dev Trivedi','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1434','Shopify - Main Store','2026-09-19 20:51+05:30','Bhavna Solanki','cod',1398.0,209.7,59.42,1247.72,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1539','Amazon - Seller Central','2026-09-19 16:30+05:30','Meghna Rao','prepaid',599.0,89.85,25.46,534.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1540','Amazon - Seller Central','2026-09-19 18:31+05:30','Vipul Gandhi','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1435','Shopify - Main Store','2026-09-19 19:15+05:30','Kunal Desai','cod',599.0,0.0,29.95,628.95,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1406','Flipkart - Seller Hub','2026-09-19 13:27+05:30','Heena Khan','cod',3096.0,154.8,147.06,3088.26,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1541','Amazon - Seller Central','2026-09-19 16:05+05:30','Sagar Rathod','prepaid',3497.0,0.0,174.85,3671.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1542','Amazon - Seller Central','2026-09-19 19:07+05:30','Harsh Modi','prepaid',1698.0,0.0,84.9,1782.9,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1407','Flipkart - Seller Hub','2026-09-19 14:26+05:30','Neha Patel','prepaid',1826.0,0.0,91.3,1917.3,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1543','Amazon - Seller Central','2026-09-19 10:05+05:30','Tanvi Rana','cod',2698.0,134.9,128.16,2691.26,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1544','Amazon - Seller Central','2026-09-19 18:18+05:30','Kunal Desai','prepaid',8546.0,0.0,1142.17,9688.17,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1436','Shopify - Main Store','2026-09-19 18:34+05:30','Nikhil Pandey','cod',6197.0,619.7,922.25,6499.55,'delivered','pending','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1536','WLEG-MAR-M',1,349,0.0,17.45),
('FLIP-1404','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1404','MHOD-BLK-XL',1,1299,0.0,64.95),
('FLIP-1404','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1537','WTOP-WHT-M',2,599,0.0,59.9),
('FLIP-1405','MKUR-WHT-XL',2,1099,329.7,93.42),
('SHOP-1432','GLHG-TEL-89Y',1,1999,0.0,99.95),
('SHOP-1432','GJNS-IND-67Y',1,779,0.0,38.95),
('SHOP-1433','MPOL-MRN-XL',1,699,0.0,34.95),
('SHOP-1433','MCHN-OLV-34',1,1199,0.0,59.95),
('AMAZ-1538','WLEG-BLK-M',1,349,0.0,17.45),
('AMAZ-1538','WKRT-PNK-S',1,849,0.0,42.45),
('SHOP-1434','MPOL-NVY-M',2,699,209.7,59.42),
('AMAZ-1539','WTOP-PCH-M',1,599,89.85,25.46),
('AMAZ-1540','WLEG-BLK-M',1,349,0.0,17.45),
('AMAZ-1540','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1540','WKRT-PNK-M',1,849,0.0,42.45),
('SHOP-1435','WPAL-YLW-L',1,599,0.0,29.95),
('FLIP-1406','WTOP-WHT-M',3,599,89.85,85.36),
('FLIP-1406','MHOD-BLK-M',1,1299,64.95,61.7),
('AMAZ-1541','WSAR-BLU-FREE',1,2199,0.0,109.95),
('AMAZ-1541','MTRK-BLK-M',2,649,0.0,64.9),
('AMAZ-1542','WKRT-PNK-S',1,849,0.0,42.45),
('AMAZ-1542','WKRT-TEL-L',1,849,0.0,42.45),
('FLIP-1407','WKRT-PNK-M',1,849,0.0,42.45),
('FLIP-1407','BSHT-GRY-89Y',2,349,0.0,34.9),
('FLIP-1407','GLEG-BLK-89Y',1,279,0.0,13.95),
('AMAZ-1543','WJNS-IND-28',2,1349,134.9,128.16),
('AMAZ-1544','WLHG-RED-M',1,5499,0.0,989.82),
('AMAZ-1544','WLEG-MAR-M',1,349,0.0,17.45),
('AMAZ-1544','WJNS-IND-30',2,1349,0.0,134.9),
('SHOP-1436','WLHG-RED-L',1,5499,549.9,890.84),
('SHOP-1436','WLEG-BLK-M',2,349,69.8,31.41)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1536','Xpressbees - Pandesara'),
('SHOP-1432','Delhivery - Sachin GIDC Surat'),
('SHOP-1434','Ecom Express - Udhna Hub'),
('SHOP-1435','DTDC - Ring Road Surat'),
('FLIP-1406','DTDC - Ring Road Surat'),
('AMAZ-1543','Bluedart - Surat City'),
('SHOP-1436','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1354', 'pickup');
select pg_temp.ret_set('FLIP-1340', 'in_transit');
select pg_temp.ret_dispo('SHOP-1364', 'good', 'restocked');
select pg_temp.rto_recv('FLIP-1348', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1466', 'in_transit');
select pg_temp.ret_set('AMAZ-1491', 'approved');
select pg_temp.rto_set('AMAZ-1509', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1410']::text[]);
select pg_temp.cod_collect(array['FLIP-1392']::text[]);
select pg_temp.cod_collect(array['FLIP-1394']::text[]);
select pg_temp.cod_collect(array['FLIP-1397']::text[]);
select pg_temp.claim_recover('FLIP-1254', 'damaged_return', 'CLAIM-CR-FLIP-1254');
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
