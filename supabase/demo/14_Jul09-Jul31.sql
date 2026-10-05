-- 09 Jul to 31 Jul 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Thu 09 Jul 2026
select pg_temp.day('2026-07-09');
select pg_temp.bill_po('Weekly replenishment 29 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R094)', 'TKF/26/0309', 1);
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Shree Ambika Textiles (ref R100)', 'DC-SAT-0100', '[{"sku":"WKRT-TEL-M","q":6,"a":6,"r":0},{"sku":"WPAL-WHT-L","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1182','Flipkart - Seller Hub','2026-07-09 22:56+05:30','Riya Shah','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1183','Flipkart - Seller Hub','2026-07-09 10:08+05:30','Riya Shah','prepaid',13096.0,0.0,2084.54,15180.54,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1184','Flipkart - Seller Hub','2026-07-09 22:38+05:30','Pratik Lad','prepaid',828.0,0.0,41.4,869.4,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1185','Flipkart - Seller Hub','2026-07-09 10:48+05:30','Foram Thakkar','cod',3047.0,0.0,152.35,3199.35,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1252','Amazon - Seller Central','2026-07-09 15:05+05:30','Anjali Verma','prepaid',2098.0,104.9,99.65,2092.75,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1191','Shopify - Main Store','2026-07-09 11:38+05:30','Yash Vora','prepaid',2798.0,0.0,139.9,2937.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1253','Amazon - Seller Central','2026-07-09 21:56+05:30','Pooja Jain','prepaid',1199.0,59.95,56.95,1196.0,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1192','Shopify - Main Store','2026-07-09 11:42+05:30','Pratik Lad','cod',4295.0,0.0,214.75,4509.75,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1254','Amazon - Seller Central','2026-07-09 12:56+05:30','Rahul Bhatt','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1255','Amazon - Seller Central','2026-07-09 09:43+05:30','Heena Khan','prepaid',1448.0,0.0,72.4,1520.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1256','Amazon - Seller Central','2026-07-09 11:34+05:30','Rahul Bhatt','prepaid',878.0,0.0,43.9,921.9,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1182','GLEG-BLK-45Y',1,279,0.0,13.95),
('FLIP-1183','WDRS-FLP-S',1,1499,0.0,74.95),
('FLIP-1183','WTOP-WHT-M',1,599,0.0,29.95),
('FLIP-1183','WLHG-RED-L',2,5499,0.0,1979.64),
('FLIP-1184','GNGT-PNK-45Y',1,549,0.0,27.45),
('FLIP-1184','GLEG-BLK-67Y',1,279,0.0,13.95),
('FLIP-1185','MCHN-OLV-34',1,1199,0.0,59.95),
('FLIP-1185','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1185','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1252','WTOP-WHT-M',1,599,29.95,28.45),
('AMAZ-1252','WDRS-FLR-S',1,1499,74.95,71.2),
('SHOP-1191','MJNS-IND-32',2,1399,0.0,139.9),
('AMAZ-1253','MCHN-OLV-32',1,1199,59.95,56.95),
('SHOP-1192','MSHC-GRN-M',2,899,0.0,89.9),
('SHOP-1192','MCHN-KHK-30',1,1199,0.0,59.95),
('SHOP-1192','MTRK-BLK-M',2,649,0.0,64.9),
('AMAZ-1254','MJNS-IND-34',1,1399,0.0,69.95),
('AMAZ-1255','WKRT-TEL-L',1,849,0.0,42.45),
('AMAZ-1255','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1256','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1256','GLEG-PNK-89Y',1,279,0.0,13.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1185','Xpressbees - Pandesara'),
('SHOP-1192','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1203', 'pickup');
select pg_temp.ret_set('AMAZ-1204', 'pickup');
select pg_temp.claim_recover('AMAZ-1116', 'damaged_return', 'CLAIM-CR-AMAZ-1116');
select pg_temp.retime();

-- Fri 10 Jul 2026
select pg_temp.day('2026-07-10');
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Shree Ambika Textiles (ref R099)', 'DC-SAT-0097', '[{"sku":"WKRT-PNK-S","q":6,"a":6,"r":0},{"sku":"WPAL-YLW-XL","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Shree Ambika Textiles (ref R100)', 'SAT/26/0245', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1186','Flipkart - Seller Hub','2026-07-10 22:00+05:30','Kiran Naik','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1193','Shopify - Main Store','2026-07-10 20:50+05:30','Prachi Kulkarni','prepaid',3497.0,349.7,157.38,3304.68,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1194','Shopify - Main Store','2026-07-10 18:06+05:30','Sanjay Gajera','cod',749.0,0.0,37.45,786.45,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1195','Shopify - Main Store','2026-07-10 19:22+05:30','Dev Trivedi','prepaid',878.0,0.0,43.9,921.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1257','Amazon - Seller Central','2026-07-10 19:55+05:30','Vipul Gandhi','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1258','Amazon - Seller Central','2026-07-10 10:20+05:30','Divya Nair','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1186','WTOP-WHT-M',2,599,0.0,59.9),
('FLIP-1186','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1193','MJNS-IND-30',1,1399,139.9,62.96),
('SHOP-1193','MCHN-OLV-32',1,1199,119.9,53.96),
('SHOP-1193','MSHC-GRN-L',1,899,89.9,40.46),
('SHOP-1194','GFRK-LIL-89Y',1,749,0.0,37.45),
('SHOP-1195','WTOP-PCH-M',1,599,0.0,29.95),
('SHOP-1195','GLEG-PNK-89Y',1,279,0.0,13.95),
('AMAZ-1257','MPOL-NVY-XL',1,699,0.0,34.95),
('AMAZ-1257','MJNS-IND-34',1,1399,0.0,69.95),
('AMAZ-1258','WKRT-PNK-XL',1,849,0.0,42.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1194','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1183', 'good', 'restocked');
select pg_temp.rto_set('FLIP-1168', 'in_transit');
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-10JUL', array['SHOP-1163','FLIP-1160','AMAZ-1220','SHOP-1177']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-10JUL', array['FLIP-1164','SHOP-1179']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-10JUL', array['AMAZ-1219']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-10JUL', array['SHOP-1166','SHOP-1173']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-10JUL', array['SHOP-1165','SHOP-1167','SHOP-1171','AMAZ-1222']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-07-13', 'ICIC000000884468', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-07-13', 'ICIC000000884480', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-07-13', 'ICIC000000884509', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-07-13', 'ICIC000000884592', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-07-13', 'ICIC000000884622', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-07-13', 'ICIC000000884674', 1);
select pg_temp.claim_new('FLIP-1114', 'lost_shipment', 22140.81, '2026-08-09');
select pg_temp.retime();

-- Sat 11 Jul 2026
select pg_temp.day('2026-07-11');
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Krishna Denim Works (ref R097)', 'DC-KDW-0106', '[{"sku":"MJNS-BLK-34","q":8,"a":8,"r":0},{"sku":"MCHN-KHK-30","q":14,"a":14,"r":0},{"sku":"MCHN-KHK-34","q":14,"a":14,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Shree Ambika Textiles (ref R099)', 'SAT/26/0236', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1196','Shopify - Main Store','2026-07-11 10:53+05:30','Pratik Lad','prepaid',3799.0,189.95,649.63,4258.68,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1197','Shopify - Main Store','2026-07-11 09:29+05:30','Mitul Dave','prepaid',3396.0,0.0,169.8,3565.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1259','Amazon - Seller Central','2026-07-11 14:56+05:30','Sonal Parekh','prepaid',899.0,0.0,44.95,943.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1198','Shopify - Main Store','2026-07-11 18:59+05:30','Anjali Verma','cod',329.0,0.0,16.45,345.45,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1187','Flipkart - Seller Hub','2026-07-11 09:10+05:30','Kavya Menon','prepaid',3745.0,374.5,168.53,3539.03,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1260','Amazon - Seller Central','2026-07-11 11:53+05:30','Isha Gupta','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1199','Shopify - Main Store','2026-07-11 11:00+05:30','Foram Thakkar','prepaid',4196.0,0.0,209.8,4405.8,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1261','Amazon - Seller Central','2026-07-11 21:08+05:30','Chirag Zaveri','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1196','MBLZ-NVY-40',1,3799,189.95,649.63),
('SHOP-1197','MPOL-NVY-M',1,699,0.0,34.95),
('SHOP-1197','MSHC-RED-XL',3,899,0.0,134.85),
('AMAZ-1259','MSHC-RED-XL',1,899,0.0,44.95),
('SHOP-1198','BTEE-RED-67Y',1,329,0.0,16.45),
('FLIP-1187','MTEE-BLK-XL',3,449,134.7,60.62),
('FLIP-1187','MCHN-OLV-34',2,1199,239.8,107.91),
('AMAZ-1260','GLEG-BLK-67Y',1,279,0.0,13.95),
('SHOP-1199','WTOP-PCH-L',2,599,0.0,59.9),
('SHOP-1199','WDRS-FLR-L',1,1499,0.0,74.95),
('SHOP-1199','WDRS-FLP-L',1,1499,0.0,74.95),
('AMAZ-1261','WTOP-WHT-M',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_set('AMAZ-1203', 'in_transit');
select pg_temp.ret_set('AMAZ-1204', 'in_transit');
select pg_temp.rto_new('FLIP-1173', 'AWB31000546', 'Address incomplete');
select pg_temp.rto_new('SHOP-1185', 'AWB31000584', 'Customer unreachable');
select pg_temp.rto_new('SHOP-1186', 'AWB31000593', 'Customer unreachable');
select pg_temp.claim_step('AMAZ-1160', 'other', 'approved', null);
select pg_temp.retime();

-- Sun 12 Jul 2026
select pg_temp.day('2026-07-12');
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Krishna Denim Works (ref R096)', 'DC-KDW-0103', '[{"sku":"MJNS-BLK-34","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Krishna Denim Works (ref R097)', 'KDW/26/0257', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1188','Flipkart - Seller Hub','2026-07-12 20:53+05:30','Kiran Naik','prepaid',3597.0,359.7,161.88,3399.18,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1200','Shopify - Main Store','2026-07-12 22:54+05:30','Prachi Kulkarni','prepaid',3197.0,319.7,143.87,3021.17,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1262','Amazon - Seller Central','2026-07-12 18:23+05:30','Tanvi Rana','prepaid',1198.0,119.8,53.91,1132.11,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1201','Shopify - Main Store','2026-07-12 12:33+05:30','Amit Sethi','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1202','Shopify - Main Store','2026-07-12 17:56+05:30','Anjali Verma','cod',1399.0,0.0,69.95,1468.95,'shipped','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1188','MJNS-IND-34',1,1399,139.9,62.96),
('FLIP-1188','MCHN-KHK-30',1,1199,119.9,53.96),
('FLIP-1188','MSHF-WHT-L',1,999,99.9,44.96),
('SHOP-1200','MSHC-RED-L',2,899,179.8,80.91),
('SHOP-1200','MJNS-IND-32',1,1399,139.9,62.96),
('AMAZ-1262','WTOP-PCH-L',2,599,119.8,53.91),
('SHOP-1201','BSHF-WHT-1011Y',1,599,0.0,29.95),
('SHOP-1202','MJNS-IND-30',1,1399,0.0,69.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.cod_collect(array['FLIP-1185']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260629', 0.0);
select pg_temp.claim_step('AMAZ-1158', 'damaged_return', 'rejected', null);
select pg_temp.retime();

-- Mon 13 Jul 2026
select pg_temp.day('2026-07-13');
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Krishna Denim Works (ref R096)', 'KDW/26/0250', 1);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Krishna Denim Works (ref R103)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MJNS-IND-34","q":10},{"sku":"WJNS-BLK-30","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Krishna Denim Works (ref R104)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-IND-30","q":6},{"sku":"MCHN-OLV-32","q":20}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Little Stitch Garments (ref R105)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"WDRS-FLP-S","q":6},{"sku":"GFRK-LIL-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Little Stitch Garments (ref R106)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"GNGT-PNK-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Ludhiana Winter Wear Co (ref R107)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"BTRK-BLK-67Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Rajdhani Shirting Mills (ref R108)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MKUR-WHT-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Rajdhani Shirting Mills (ref R109)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHF-WHT-XL","q":8},{"sku":"MSHC-RED-L","q":14},{"sku":"MSHC-RED-XL","q":14}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Shree Ambika Textiles (ref R110)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WKRT-PNK-XL","q":8},{"sku":"WDUP-SLV-FREE","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Shree Ambika Textiles (ref R111)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-TEL-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R112)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MPOL-NVY-XL","q":8},{"sku":"GTOP-WHT-67Y","q":6},{"sku":"GLEG-PNK-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 13 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R113)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-BLK-XL","q":8},{"sku":"MPOL-MRN-M","q":8},{"sku":"MTRK-BLK-M","q":10},{"sku":"MTRK-BLK-XL","q":10},{"sku":"GTOP-YLW-89Y","q":8}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1263','Amazon - Seller Central','2026-07-13 12:35+05:30','Ritu Saxena','prepaid',2798.0,0.0,139.9,2937.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1203','Shopify - Main Store','2026-07-13 15:14+05:30','Heena Khan','prepaid',698.0,0.0,34.9,732.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1204','Shopify - Main Store','2026-07-13 09:21+05:30','Sagar Rathod','prepaid',3127.0,0.0,156.35,3283.35,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1189','Flipkart - Seller Hub','2026-07-13 18:35+05:30','Bhavna Solanki','prepaid',1498.0,0.0,74.9,1572.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1264','Amazon - Seller Central','2026-07-13 19:35+05:30','Rahul Bhatt','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1205','Shopify - Main Store','2026-07-13 21:32+05:30','Kunal Desai','prepaid',1896.0,0.0,94.8,1990.8,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1263','WPAL-YLW-M',1,599,0.0,29.95),
('AMAZ-1263','WSAR-GRN-FREE',1,2199,0.0,109.95),
('SHOP-1203','GTOP-WHT-67Y',2,349,0.0,34.9),
('SHOP-1204','BTEE-BLU-67Y',1,329,0.0,16.45),
('SHOP-1204','MJNS-IND-34',2,1399,0.0,139.9),
('FLIP-1189','GNGT-PNK-45Y',1,549,0.0,27.45),
('FLIP-1189','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1264','MCHN-KHK-30',1,1199,0.0,59.95),
('SHOP-1205','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1205','WLEG-NVY-M',2,349,0.0,34.9),
('SHOP-1205','WPAL-WHT-L',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.rto_recv('SHOP-1172', 'good', 'restocked');
select pg_temp.ret_new('FLIP-1167', 'Fabric quality not as expected', 'webhook');
select pg_temp.rto_set('FLIP-1173', 'in_transit');
select pg_temp.rto_set('SHOP-1185', 'in_transit');
select pg_temp.rto_set('SHOP-1186', 'in_transit');
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260706', '2026-07-06', '2026-07-12', array['AMAZ-1223','AMAZ-1224','AMAZ-1225','AMAZ-1229','AMAZ-1230','AMAZ-1234','AMAZ-1226','AMAZ-1228','AMAZ-1232','AMAZ-1227','AMAZ-1233','AMAZ-1236','AMAZ-1235','AMAZ-1237','AMAZ-1239','AMAZ-1240','AMAZ-1244','AMAZ-1245','AMAZ-1247','AMAZ-1238','AMAZ-1242','AMAZ-1243','AMAZ-1248','AMAZ-1251']::text[], array['AMAZ-1188','AMAZ-1199','AMAZ-1183']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260706', '2026-07-06', '2026-07-12', array['FLIP-1163','FLIP-1167','FLIP-1165','FLIP-1166','FLIP-1169','FLIP-1171','FLIP-1172','FLIP-1170','FLIP-1175','FLIP-1176','FLIP-1177','FLIP-1174','FLIP-1179','FLIP-1180','FLIP-1178','FLIP-1181']::text[], array['FLIP-1148']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260706', '2026-07-06', '2026-07-12', array['SHOP-1175','SHOP-1181','SHOP-1174','SHOP-1176','SHOP-1180','SHOP-1183','SHOP-1184','SHOP-1182','SHOP-1188','SHOP-1189','SHOP-1190','SHOP-1191']::text[], array[]::text[]);
select pg_temp.claim_step('FLIP-1114', 'lost_shipment', 'claimed', null);
select pg_temp.retime();

-- Tue 14 Jul 2026
select pg_temp.day('2026-07-14');
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R101)', 'DC-TKF-0133', '[{"sku":"MTEE-BLK-L","q":4,"a":4,"r":0},{"sku":"MPOL-NVY-XL","q":4,"a":4,"r":0},{"sku":"GTOP-WHT-67Y","q":4,"a":4,"r":0},{"sku":"GLEG-PNK-45Y","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1190','Flipkart - Seller Hub','2026-07-14 12:09+05:30','Rahul Bhatt','prepaid',2247.0,0.0,112.35,2359.35,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1191','Flipkart - Seller Hub','2026-07-14 21:37+05:30','Dev Trivedi','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1265','Amazon - Seller Central','2026-07-14 20:10+05:30','Neha Patel','cod',1499.0,0.0,74.95,1573.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1206','Shopify - Main Store','2026-07-14 19:00+05:30','Rohit Iyer','cod',949.0,0.0,47.45,996.45,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1190','BKUR-MUS-67Y',2,949,0.0,94.9),
('FLIP-1190','BSHT-GRY-89Y',1,349,0.0,17.45),
('FLIP-1191','GLEG-BLK-89Y',1,279,0.0,13.95),
('AMAZ-1265','WDRS-FLR-S',1,1499,0.0,74.95),
('SHOP-1206','BKUR-CRM-89Y',1,949,0.0,47.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1265','DTDC - Ring Road Surat'),
('SHOP-1206','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1203');
select pg_temp.rto_recv('FLIP-1162', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1167', 'approved');
select pg_temp.ret_new('FLIP-1181', 'Customer changed mind', 'webhook');
select pg_temp.rto_new('AMAZ-1250', 'AWB31000622', 'Address incomplete');
select pg_temp.settle_pay('FLK-STL-20260629', 0.0);
select pg_temp.claim_step('AMAZ-1166', 'damaged_return', 'approved', null);
select pg_temp.retime();

-- Wed 15 Jul 2026
select pg_temp.day('2026-07-15');
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R101)', 'TKF/26/0323', 1);
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R102)', 'DC-TKF-0139', '[{"sku":"MPOL-MRN-M","q":5,"a":5,"r":0},{"sku":"MTRK-BLK-XL","q":6,"a":6,"r":0},{"sku":"WTOP-WHT-M","q":21,"a":21,"r":0},{"sku":"WTOP-PCH-L","q":14,"a":14,"r":0},{"sku":"GTOP-YLW-89Y","q":5,"a":5,"r":0},{"sku":"GTOP-WHT-67Y","q":5,"a":5,"r":0},{"sku":"GLEG-BLK-67Y","q":10,"a":10,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1192','Flipkart - Seller Hub','2026-07-15 21:00+05:30','Foram Thakkar','prepaid',898.0,89.8,40.41,848.61,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1207','Shopify - Main Store','2026-07-15 12:29+05:30','Dev Trivedi','cod',329.0,0.0,16.45,345.45,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1193','Flipkart - Seller Hub','2026-07-15 13:14+05:30','Riya Shah','prepaid',2498.0,0.0,124.9,2622.9,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1194','Flipkart - Seller Hub','2026-07-15 14:27+05:30','Amit Sethi','prepaid',3526.0,176.3,167.48,3517.18,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1195','Flipkart - Seller Hub','2026-07-15 18:35+05:30','Kunal Desai','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1196','Flipkart - Seller Hub','2026-07-15 15:36+05:30','Bhavna Solanki','prepaid',2798.0,0.0,139.9,2937.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1208','Shopify - Main Store','2026-07-15 12:53+05:30','Aarav Mehta','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1209','Shopify - Main Store','2026-07-15 15:56+05:30','Karan Malhotra','prepaid',5499.0,549.9,890.84,5839.94,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1192','MTEE-WHT-M',2,449,89.8,40.41),
('SHOP-1207','BTEE-BLU-67Y',1,329,0.0,16.45),
('FLIP-1193','MJNS-BLK-34',1,1399,0.0,69.95),
('FLIP-1193','MKUR-MUS-XL',1,1099,0.0,54.95),
('FLIP-1194','MTRK-BLK-L',1,649,32.45,30.83),
('FLIP-1194','MJNS-IND-34',1,1399,69.95,66.45),
('FLIP-1194','GLEG-BLK-45Y',1,279,13.95,13.25),
('FLIP-1194','MCHN-KHK-30',1,1199,59.95,56.95),
('FLIP-1195','BSHT-GRY-67Y',1,349,0.0,17.45),
('FLIP-1196','MJNS-BLK-34',2,1399,0.0,139.9),
('SHOP-1208','MTRK-BLK-M',1,649,0.0,32.45),
('SHOP-1209','WLHG-MAG-M',1,5499,549.9,890.84)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1203', 'good', 'restocked');
select pg_temp.ret_recv('AMAZ-1204');
select pg_temp.ret_set('FLIP-1167', 'pickup');
select pg_temp.ret_set('FLIP-1181', 'approved');
select pg_temp.cod_collect(array['SHOP-1192']::text[]);
select pg_temp.rto_new('SHOP-1198', 'AWB31000651', 'Customer unreachable');
select pg_temp.settle_pay('SHP-STL-20260706', 0.0);
select pg_temp.retime();

-- Thu 16 Jul 2026
select pg_temp.day('2026-07-16');
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R102)', 'TKF/26/0333', 1);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Shree Ambika Textiles (ref R110)', 'DC-SAT-0103', '[{"sku":"WKRT-PNK-XL","q":8,"a":8,"r":0},{"sku":"WDUP-SLV-FREE","q":6,"a":5,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1197','Flipkart - Seller Hub','2026-07-16 14:20+05:30','Shreya Banerjee','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1266','Amazon - Seller Central','2026-07-16 21:55+05:30','Manav Joshi','prepaid',1798.0,0.0,89.9,1887.9,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1198','Flipkart - Seller Hub','2026-07-16 12:17+05:30','Sonal Parekh','prepaid',2598.0,0.0,129.9,2727.9,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1267','Amazon - Seller Central','2026-07-16 17:42+05:30','Nikhil Pandey','prepaid',1307.0,0.0,65.35,1372.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1210','Shopify - Main Store','2026-07-16 19:18+05:30','Ritu Saxena','prepaid',1297.0,0.0,64.85,1361.85,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1199','Flipkart - Seller Hub','2026-07-16 11:27+05:30','Harsh Modi','prepaid',779.0,38.95,37.0,777.05,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1200','Flipkart - Seller Hub','2026-07-16 22:56+05:30','Riya Shah','prepaid',2547.0,0.0,127.35,2674.35,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1201','Flipkart - Seller Hub','2026-07-16 12:58+05:30','Aarav Mehta','prepaid',649.0,64.9,29.21,613.31,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1211','Shopify - Main Store','2026-07-16 17:42+05:30','Kunal Desai','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1202','Flipkart - Seller Hub','2026-07-16 22:11+05:30','Isha Gupta','cod',3896.0,0.0,194.8,4090.8,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1203','Flipkart - Seller Hub','2026-07-16 15:54+05:30','Nikhil Pandey','prepaid',5196.0,0.0,259.8,5455.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1268','Amazon - Seller Central','2026-07-16 20:04+05:30','Chirag Zaveri','prepaid',1999.0,199.9,89.96,1889.06,'delivered','paid','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1197','WLEG-MAR-L',1,349,0.0,17.45),
('AMAZ-1266','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1266','WKRT-PNK-M',1,849,0.0,42.45),
('FLIP-1198','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1198','MJNS-IND-34',1,1399,0.0,69.95),
('AMAZ-1267','GFRK-LIL-89Y',1,749,0.0,37.45),
('AMAZ-1267','GLEG-PNK-67Y',2,279,0.0,27.9),
('SHOP-1210','WLEG-BLK-L',2,349,0.0,34.9),
('SHOP-1210','WPAL-WHT-XL',1,599,0.0,29.95),
('FLIP-1199','GJNS-IND-45Y',1,779,38.95,37.0),
('FLIP-1200','MTRK-BLK-XL',1,649,0.0,32.45),
('FLIP-1200','MPOL-MRN-M',1,699,0.0,34.95),
('FLIP-1200','MCHN-OLV-34',1,1199,0.0,59.95),
('FLIP-1201','MTRK-BLK-M',1,649,64.9,29.21),
('SHOP-1211','BTEE-BLU-89Y',1,329,32.9,14.81),
('FLIP-1202','WJNS-IND-28',1,1349,0.0,67.45),
('FLIP-1202','WKRT-PNK-S',3,849,0.0,127.35),
('FLIP-1203','MJNS-IND-34',2,1399,0.0,139.9),
('FLIP-1203','MCHN-OLV-32',2,1199,0.0,119.9),
('AMAZ-1268','GLHG-RED-67Y',1,1999,199.9,89.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1202','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1181', 'pickup');
select pg_temp.rto_set('AMAZ-1250', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1194']::text[]);
select pg_temp.rto_new('SHOP-1202', 'AWB31000656', 'Address incomplete');
select pg_temp.claim_recover('AMAZ-1140', 'lost_shipment', 'CLAIM-CR-AMAZ-1140');
select pg_temp.claim_step('FLIP-1115', 'incorrect_deduction', 'approved', null);
select pg_temp.retime();

-- Fri 17 Jul 2026
select pg_temp.day('2026-07-17');
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Ludhiana Winter Wear Co (ref R098)', 'DC-LWW-0055', '[{"sku":"BTRK-BLK-67Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Krishna Denim Works (ref R103)', 'DC-KDW-0109', '[{"sku":"MJNS-IND-34","q":10,"a":9,"r":1},{"sku":"WJNS-BLK-30","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Krishna Denim Works (ref R104)', 'DC-KDW-0112', '[{"sku":"MJNS-IND-30","q":6,"a":6,"r":0},{"sku":"MCHN-OLV-32","q":20,"a":20,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Little Stitch Garments (ref R106)', 'DC-LSG-0106', '[{"sku":"GNGT-PNK-45Y","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Shree Ambika Textiles (ref R110)', 'SAT/26/0253', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1269','Amazon - Seller Central','2026-07-17 11:43+05:30','Sonal Parekh','prepaid',1349.0,0.0,67.45,1416.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1270','Amazon - Seller Central','2026-07-17 17:09+05:30','Rohit Iyer','prepaid',849.0,84.9,38.21,802.31,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1212','Shopify - Main Store','2026-07-17 17:25+05:30','Aarav Mehta','cod',899.0,89.9,40.46,849.56,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('AMAZ-1271','Amazon - Seller Central','2026-07-17 10:15+05:30','Dev Trivedi','prepaid',329.0,16.45,15.63,328.18,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1213','Shopify - Main Store','2026-07-17 20:45+05:30','Kiran Naik','prepaid',1198.0,119.8,53.91,1132.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1214','Shopify - Main Store','2026-07-17 15:24+05:30','Anjali Verma','prepaid',349.0,34.9,15.71,329.81,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1272','Amazon - Seller Central','2026-07-17 11:22+05:30','Dev Trivedi','prepaid',2896.0,0.0,144.8,3040.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1269','WJNS-IND-32',1,1349,0.0,67.45),
('AMAZ-1270','WKRT-PNK-L',1,849,84.9,38.21),
('SHOP-1212','MSHC-RED-M',1,899,89.9,40.46),
('AMAZ-1271','BTEE-RED-45Y',1,329,16.45,15.63),
('SHOP-1213','WPAL-YLW-M',2,599,119.8,53.91),
('SHOP-1214','GTOP-WHT-89Y',1,349,34.9,15.71),
('AMAZ-1272','WPAL-YLW-XL',2,599,0.0,59.9),
('AMAZ-1272','WKRT-PNK-M',2,849,0.0,84.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1204', 'damaged', 'quarantined');
select pg_temp.ret_set('FLIP-1167', 'in_transit');
select pg_temp.rto_recv('FLIP-1173', 'good', 'restocked');
select pg_temp.ret_new('AMAZ-1251', 'Fabric quality not as expected', 'webhook');
select pg_temp.rto_set('SHOP-1198', 'in_transit');
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-17JUL', array['FLIP-1185','SHOP-1192']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-07-20', 'ICIC000000884687', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-07-20', 'ICIC000000884742', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-07-20', 'ICIC000000884774', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-07-20', 'ICIC000000884830', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-07-20', 'ICIC000000884897', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-07-20', 'ICIC000000884983', 1);
select pg_temp.claim_step('FLIP-1138', 'damaged_return', 'approved', 1833.46);
select pg_temp.claim_new('AMAZ-1204', 'damaged_return', 175.77, '2026-08-16');
select pg_temp.retime();

-- Sat 18 Jul 2026
select pg_temp.day('2026-07-18');
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Ludhiana Winter Wear Co (ref R098)', 'LWW/26/0139', 1);
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R101)', 'DC-TKF-0136', '[{"sku":"MTEE-BLK-L","q":2,"a":2,"r":0},{"sku":"MPOL-NVY-XL","q":2,"a":2,"r":0},{"sku":"GTOP-WHT-67Y","q":2,"a":2,"r":0},{"sku":"GLEG-PNK-45Y","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Krishna Denim Works (ref R103)', 'KDW/26/0267', 1);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Krishna Denim Works (ref R104)', 'KDW/26/0270', 1);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Little Stitch Garments (ref R105)', 'DC-LSG-0103', '[{"sku":"WDRS-FLP-S","q":6,"a":5,"r":1},{"sku":"GFRK-LIL-45Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Little Stitch Garments (ref R106)', 'LSG/26/0255', 1);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Rajdhani Shirting Mills (ref R109)', 'DC-RSM-0121', '[{"sku":"MSHF-WHT-XL","q":8,"a":8,"r":0},{"sku":"MSHC-RED-L","q":14,"a":14,"r":0},{"sku":"MSHC-RED-XL","q":14,"a":14,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Shree Ambika Textiles (ref R111)', 'DC-SAT-0106', '[{"sku":"WKRT-TEL-L","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1215','Shopify - Main Store','2026-07-18 12:50+05:30','Pratik Lad','prepaid',2198.0,219.8,98.91,2077.11,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('AMAZ-1273','Amazon - Seller Central','2026-07-18 14:13+05:30','Bhavna Solanki','prepaid',1499.0,149.9,67.46,1416.56,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1204','Flipkart - Seller Hub','2026-07-18 19:02+05:30','Sagar Rathod','prepaid',2976.0,0.0,148.8,3124.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1216','Shopify - Main Store','2026-07-18 13:42+05:30','Karan Malhotra','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1217','Shopify - Main Store','2026-07-18 21:07+05:30','Ritu Saxena','prepaid',449.0,22.45,21.33,447.88,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1274','Amazon - Seller Central','2026-07-18 19:48+05:30','Pooja Jain','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1275','Amazon - Seller Central','2026-07-18 11:49+05:30','Neha Patel','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1205','Flipkart - Seller Hub','2026-07-18 16:00+05:30','Aditi Joshi','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1276','Amazon - Seller Central','2026-07-18 09:09+05:30','Riya Shah','prepaid',1297.0,64.85,61.61,1293.76,'shipped','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1215','MKUR-WHT-XL',2,1099,219.8,98.91),
('AMAZ-1273','WDRS-FLP-S',1,1499,149.9,67.46),
('FLIP-1204','MSHC-RED-M',3,899,0.0,134.85),
('FLIP-1204','GLEG-PNK-89Y',1,279,0.0,13.95),
('SHOP-1216','MCHN-OLV-32',1,1199,0.0,59.95),
('SHOP-1217','MTEE-WHT-M',1,449,22.45,21.33),
('AMAZ-1274','BTEE-RED-45Y',1,329,32.9,14.81),
('AMAZ-1275','GLEG-PNK-89Y',1,279,0.0,13.95),
('FLIP-1205','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1205','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1276','WPAL-WHT-M',1,599,29.95,28.45),
('AMAZ-1276','WLEG-MAR-M',2,349,34.9,33.16)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_set('FLIP-1181', 'in_transit');
select pg_temp.ret_set('AMAZ-1251', 'approved');
select pg_temp.rto_set('SHOP-1202', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1206']::text[]);
select pg_temp.claim_step('AMAZ-1161', 'damaged_return', 'rejected', null);
select pg_temp.retime();

-- Sun 19 Jul 2026
select pg_temp.day('2026-07-19');
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R101)', 'TKF/26/0330', 1);
select pg_temp.grn_new('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R102)', 'DC-TKF-0142', '[{"sku":"MPOL-MRN-M","q":3,"a":3,"r":0},{"sku":"MTRK-BLK-XL","q":4,"a":4,"r":0},{"sku":"WTOP-WHT-M","q":11,"a":11,"r":0},{"sku":"WTOP-PCH-L","q":8,"a":8,"r":0},{"sku":"GTOP-YLW-89Y","q":3,"a":3,"r":0},{"sku":"GTOP-WHT-67Y","q":3,"a":3,"r":0},{"sku":"GLEG-BLK-67Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Little Stitch Garments (ref R105)', 'LSG/26/0250', 1);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Rajdhani Shirting Mills (ref R108)', 'DC-RSM-0118', '[{"sku":"MKUR-WHT-XL","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Rajdhani Shirting Mills (ref R109)', 'RSM/26/0292', 1);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Shree Ambika Textiles (ref R111)', 'SAT/26/0259', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1206','Flipkart - Seller Hub','2026-07-19 13:18+05:30','Pratik Lad','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1218','Shopify - Main Store','2026-07-19 14:13+05:30','Nidhi Agarwal','prepaid',3799.0,0.0,683.82,4482.82,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1277','Amazon - Seller Central','2026-07-19 10:52+05:30','Sanjay Gajera','prepaid',899.0,0.0,44.95,943.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1219','Shopify - Main Store','2026-07-19 16:29+05:30','Karan Malhotra','cod',2098.0,0.0,104.9,2202.9,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1278','Amazon - Seller Central','2026-07-19 10:52+05:30','Nidhi Agarwal','prepaid',649.0,64.9,29.21,613.31,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1279','Amazon - Seller Central','2026-07-19 22:31+05:30','Neha Patel','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1220','Shopify - Main Store','2026-07-19 17:48+05:30','Pratik Lad','prepaid',3496.0,0.0,174.8,3670.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1207','Flipkart - Seller Hub','2026-07-19 20:07+05:30','Mehul Shukla','cod',4046.0,404.6,182.08,3823.48,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1280','Amazon - Seller Central','2026-07-19 18:20+05:30','Ritu Saxena','prepaid',1028.0,51.4,48.83,1025.43,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1208','Flipkart - Seller Hub','2026-07-19 11:15+05:30','Mitul Dave','prepaid',3425.0,0.0,171.25,3596.25,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1206','WLEG-BLK-M',1,349,0.0,17.45),
('SHOP-1218','MBLZ-NVY-38',1,3799,0.0,683.82),
('AMAZ-1277','MSHC-GRN-M',1,899,0.0,44.95),
('SHOP-1219','WPAL-WHT-M',1,599,0.0,29.95),
('SHOP-1219','WDRS-FLP-S',1,1499,0.0,74.95),
('AMAZ-1278','MTRK-BLK-L',1,649,64.9,29.21),
('AMAZ-1279','BTEE-BLU-67Y',1,329,0.0,16.45),
('SHOP-1220','BTRK-BLK-1011Y',1,999,0.0,49.95),
('SHOP-1220','BKUR-MUS-89Y',1,949,0.0,47.45),
('SHOP-1220','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1220','BSHF-WHT-89Y',1,599,0.0,29.95),
('FLIP-1207','GTOP-YLW-67Y',1,349,34.9,15.71),
('FLIP-1207','MHOD-BLK-M',1,1299,129.9,58.46),
('FLIP-1207','MCHN-KHK-30',2,1199,239.8,107.91),
('AMAZ-1280','GFRK-LIL-45Y',1,749,37.45,35.58),
('AMAZ-1280','GLEG-BLK-89Y',1,279,13.95,13.25),
('FLIP-1208','GLEG-BLK-45Y',1,279,0.0,13.95),
('FLIP-1208','MCHN-KHK-30',1,1199,0.0,59.95),
('FLIP-1208','MTRK-BLK-L',3,649,0.0,97.35)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1219','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1167');
select pg_temp.rto_recv('SHOP-1185', 'good', 'restocked');
select pg_temp.rto_recv('SHOP-1186', 'good', 'restocked');
select pg_temp.rto_recv('AMAZ-1250', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1251', 'pickup');
select pg_temp.cod_collect(array['AMAZ-1265']::text[]);
select pg_temp.cod_collect(array['FLIP-1202']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260706', 0.0);
select pg_temp.retime();

-- Mon 20 Jul 2026
select pg_temp.day('2026-07-20');
select pg_temp.bill_po('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R102)', 'TKF/26/0339', 1);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Rajdhani Shirting Mills (ref R108)', 'RSM/26/0285', 1);
select pg_temp.po_new('Weekly replenishment 20 Jul 2026 - Krishna Denim Works (ref R114)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-IND-34","q":16}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Jul 2026 - Shree Ambika Textiles (ref R115)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-S","q":12},{"sku":"WPAL-YLW-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R116)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-WHT-M","q":6},{"sku":"BTEE-RED-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R117)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-BLK-XL","q":8},{"sku":"MTEE-WHT-M","q":6},{"sku":"MTRK-BLK-M","q":8},{"sku":"MTRK-BLK-L","q":6},{"sku":"WLEG-MAR-M","q":6},{"sku":"WLEG-NVY-M","q":6}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1281','Amazon - Seller Central','2026-07-20 11:01+05:30','Aditi Joshi','prepaid',658.0,65.8,29.61,621.81,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1209','Flipkart - Seller Hub','2026-07-20 15:47+05:30','Karan Malhotra','cod',2398.0,0.0,119.9,2517.9,'shipped','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1221','Shopify - Main Store','2026-07-20 21:45+05:30','Bhavna Solanki','cod',329.0,32.9,14.81,310.91,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1222','Shopify - Main Store','2026-07-20 21:49+05:30','Yash Vora','cod',899.0,0.0,44.95,943.95,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1210','Flipkart - Seller Hub','2026-07-20 12:36+05:30','Rohit Iyer','cod',4046.0,0.0,202.3,4248.3,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1211','Flipkart - Seller Hub','2026-07-20 17:22+05:30','Aditi Joshi','prepaid',1547.0,0.0,77.35,1624.35,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1223','Shopify - Main Store','2026-07-20 20:34+05:30','Foram Thakkar','cod',1399.0,139.9,62.96,1322.06,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1282','Amazon - Seller Central','2026-07-20 15:31+05:30','Aditi Joshi','prepaid',1499.0,149.9,67.46,1416.56,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1281','BTEE-BLU-89Y',2,329,65.8,29.61),
('FLIP-1209','MCHN-OLV-34',1,1199,0.0,59.95),
('FLIP-1209','MCHN-KHK-30',1,1199,0.0,59.95),
('SHOP-1221','BTEE-BLU-67Y',1,329,32.9,14.81),
('SHOP-1222','MSHC-GRN-L',1,899,0.0,44.95),
('FLIP-1210','WDRS-FLP-S',1,1499,0.0,74.95),
('FLIP-1210','WJNS-IND-28',1,1349,0.0,67.45),
('FLIP-1210','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1211','WTOP-PCH-S',2,599,0.0,59.9),
('FLIP-1211','WLEG-BLK-M',1,349,0.0,17.45),
('SHOP-1223','MJNS-BLK-30',1,1399,139.9,62.96),
('AMAZ-1282','WDRS-FLP-M',1,1499,149.9,67.46)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1221','Xpressbees - Pandesara'),
('SHOP-1222','Xpressbees - Pandesara'),
('FLIP-1210','Ecom Express - Udhna Hub'),
('SHOP-1223','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1167', 'good', 'restocked');
select pg_temp.ret_recv('FLIP-1181');
select pg_temp.rto_recv('SHOP-1198', 'damaged', 'quarantined');
select pg_temp.rto_new('SHOP-1207', 'AWB31000675', 'Customer refused delivery');
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260713', '2026-07-13', '2026-07-19', array['AMAZ-1241','AMAZ-1253','AMAZ-1254','AMAZ-1256','AMAZ-1246','AMAZ-1249','AMAZ-1252','AMAZ-1257','AMAZ-1255','AMAZ-1258','AMAZ-1259','AMAZ-1260','AMAZ-1263','AMAZ-1261','AMAZ-1264','AMAZ-1262','AMAZ-1268']::text[], array['AMAZ-1203','AMAZ-1204']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260713', '2026-07-13', '2026-07-19', array['FLIP-1186','FLIP-1182','FLIP-1183','FLIP-1184','FLIP-1187','FLIP-1188','FLIP-1191','FLIP-1192','FLIP-1193','FLIP-1194','FLIP-1189','FLIP-1195','FLIP-1198','FLIP-1200','FLIP-1201']::text[], array['FLIP-1167']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260713', '2026-07-13', '2026-07-19', array['SHOP-1187','SHOP-1193','SHOP-1199','SHOP-1195','SHOP-1196','SHOP-1197','SHOP-1201','SHOP-1205','SHOP-1200','SHOP-1203','SHOP-1204','SHOP-1211']::text[], array[]::text[]);
select pg_temp.claim_step('AMAZ-1204', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Tue 21 Jul 2026
select pg_temp.day('2026-07-21');
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Little Stitch Garments (ref R106)', 'DC-LSG-0109', '[{"sku":"GNGT-PNK-45Y","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R112)', 'DC-TKF-0145', '[{"sku":"MPOL-NVY-XL","q":8,"a":8,"r":0},{"sku":"GTOP-WHT-67Y","q":6,"a":6,"r":0},{"sku":"GLEG-PNK-45Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1212','Flipkart - Seller Hub','2026-07-21 11:49+05:30','Dev Trivedi','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1283','Amazon - Seller Central','2026-07-21 15:07+05:30','Yash Vora','prepaid',11847.0,0.0,2022.09,13869.09,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1213','Flipkart - Seller Hub','2026-07-21 16:11+05:30','Tanvi Rana','cod',10145.0,0.0,1222.12,11367.12,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1224','Shopify - Main Store','2026-07-21 21:44+05:30','Sonal Parekh','prepaid',1777.0,0.0,88.85,1865.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1225','Shopify - Main Store','2026-07-21 21:57+05:30','Heena Khan','prepaid',1399.0,69.95,66.45,1395.5,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1284','Amazon - Seller Central','2026-07-21 12:24+05:30','Amit Sethi','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1214','Flipkart - Seller Hub','2026-07-21 22:27+05:30','Sanjay Gajera','cod',749.0,0.0,37.45,786.45,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1226','Shopify - Main Store','2026-07-21 09:02+05:30','Riya Shah','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1227','Shopify - Main Store','2026-07-21 21:12+05:30','Chirag Zaveri','prepaid',899.0,0.0,44.95,943.95,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1212','MCHN-OLV-32',1,1199,0.0,59.95),
('AMAZ-1283','WKRT-TEL-L',1,849,0.0,42.45),
('AMAZ-1283','WLHG-RED-M',2,5499,0.0,1979.64),
('FLIP-1213','WJNS-BLK-32',1,1349,0.0,67.45),
('FLIP-1213','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1213','WLHG-RED-M',1,5499,0.0,989.82),
('FLIP-1213','WJNS-IND-28',2,1349,0.0,134.9),
('SHOP-1224','GLEG-PNK-67Y',1,279,0.0,13.95),
('SHOP-1224','GFRK-PNK-67Y',2,749,0.0,74.9),
('SHOP-1225','MJNS-IND-32',1,1399,69.95,66.45),
('AMAZ-1284','WPAL-WHT-XL',1,599,0.0,29.95),
('FLIP-1214','GFRK-LIL-67Y',1,749,0.0,37.45),
('SHOP-1226','WTOP-PCH-L',1,599,29.95,28.45),
('SHOP-1227','MSHC-GRN-XL',1,899,0.0,44.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1213','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1251', 'in_transit');
select pg_temp.ret_new('SHOP-1205', 'Item arrived damaged', 'manual');
select pg_temp.ret_new('FLIP-1191', 'Fabric quality not as expected', 'webhook');
select pg_temp.settle_pay('FLK-STL-20260706', 0.0);
select pg_temp.retime();

-- Wed 22 Jul 2026
select pg_temp.day('2026-07-22');
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Little Stitch Garments (ref R106)', 'LSG/26/0264', 1);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Ludhiana Winter Wear Co (ref R107)', 'DC-LWW-0058', '[{"sku":"BTRK-BLK-67Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R112)', 'TKF/26/0350', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1215','Flipkart - Seller Hub','2026-07-22 19:32+05:30','Neha Patel','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1285','Amazon - Seller Central','2026-07-22 10:06+05:30','Sonal Parekh','prepaid',3745.0,0.0,187.25,3932.25,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1286','Amazon - Seller Central','2026-07-22 09:13+05:30','Dev Trivedi','prepaid',6448.0,0.0,1037.27,7485.27,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1228','Shopify - Main Store','2026-07-22 18:45+05:30','Mitul Dave','prepaid',1116.0,0.0,55.8,1171.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1229','Shopify - Main Store','2026-07-22 17:05+05:30','Meghna Rao','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1216','Flipkart - Seller Hub','2026-07-22 20:10+05:30','Anjali Verma','prepaid',1698.0,84.9,80.66,1693.76,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1230','Shopify - Main Store','2026-07-22 10:40+05:30','Sagar Rathod','cod',349.0,0.0,17.45,366.45,'cancelled','failed','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1287','Amazon - Seller Central','2026-07-22 15:13+05:30','Riya Shah','prepaid',558.0,0.0,27.9,585.9,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1215','MJNS-BLK-34',1,1399,0.0,69.95),
('AMAZ-1285','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1285','WKRT-PNK-M',3,849,0.0,127.35),
('AMAZ-1285','WPAL-WHT-XL',1,599,0.0,29.95),
('AMAZ-1286','BKUR-CRM-45Y',1,949,0.0,47.45),
('AMAZ-1286','WLHG-RED-M',1,5499,0.0,989.82),
('SHOP-1228','GLEG-PNK-45Y',2,279,0.0,27.9),
('SHOP-1228','GLEG-PNK-67Y',2,279,0.0,27.9),
('SHOP-1229','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1216','WLEG-MAR-M',1,349,17.45,16.58),
('FLIP-1216','WJNS-IND-32',1,1349,67.45,64.08),
('SHOP-1230','WLEG-MAR-L',1,349,0.0,17.45),
('AMAZ-1287','GLEG-BLK-67Y',2,279,0.0,27.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('FLIP-1181', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1205', 'approved');
select pg_temp.ret_new('FLIP-1190', 'Fabric quality not as expected', 'webhook');
select pg_temp.ret_set('FLIP-1191', 'approved');
select pg_temp.rto_set('SHOP-1207', 'in_transit');
select pg_temp.ret_new('AMAZ-1268', 'Size did not fit', 'webhook');
select pg_temp.rto_new('AMAZ-1276', 'AWB31000699', 'Customer refused delivery');
select pg_temp.settle_pay('SHP-STL-20260713', 0.0);
select pg_temp.claim_recover('AMAZ-1160', 'other', 'CLAIM-CR-AMAZ-1160');
select pg_temp.retime();

-- Thu 23 Jul 2026
select pg_temp.day('2026-07-23');
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Ludhiana Winter Wear Co (ref R107)', 'LWW/26/0143', 1);
select pg_temp.grn_new('Weekly replenishment 13 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R113)', 'DC-TKF-0148', '[{"sku":"MTEE-BLK-XL","q":8,"a":8,"r":0},{"sku":"MPOL-MRN-M","q":8,"a":7,"r":1},{"sku":"MTRK-BLK-M","q":10,"a":10,"r":0},{"sku":"MTRK-BLK-XL","q":10,"a":10,"r":0},{"sku":"GTOP-YLW-89Y","q":8,"a":7,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 20 Jul 2026 - Shree Ambika Textiles (ref R115)', 'DC-SAT-0109', '[{"sku":"WKRT-PNK-S","q":12,"a":12,"r":0},{"sku":"WPAL-YLW-M","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1288','Amazon - Seller Central','2026-07-23 16:19+05:30','Heena Khan','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1217','Flipkart - Seller Hub','2026-07-23 16:31+05:30','Rohit Iyer','prepaid',948.0,0.0,47.4,995.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1231','Shopify - Main Store','2026-07-23 13:53+05:30','Rahul Bhatt','cod',1897.0,189.7,85.37,1792.67,'cancelled','failed','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1289','Amazon - Seller Central','2026-07-23 21:58+05:30','Kunal Desai','prepaid',1848.0,0.0,92.4,1940.4,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1232','Shopify - Main Store','2026-07-23 21:33+05:30','Bhavna Solanki','cod',1398.0,69.9,66.41,1394.51,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1218','Flipkart - Seller Hub','2026-07-23 11:56+05:30','Anjali Verma','prepaid',1896.0,0.0,94.8,1990.8,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1219','Flipkart - Seller Hub','2026-07-23 16:42+05:30','Divya Nair','cod',3147.0,314.7,141.63,2973.93,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1233','Shopify - Main Store','2026-07-23 14:35+05:30','Aditi Joshi','prepaid',5695.0,0.0,284.75,5979.75,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1288','WTOP-WHT-M',2,599,0.0,59.9),
('FLIP-1217','WLEG-BLK-M',1,349,0.0,17.45),
('FLIP-1217','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1231','MTRK-BLK-L',2,649,129.8,58.41),
('SHOP-1231','WTOP-PCH-L',1,599,59.9,26.96),
('AMAZ-1289','MTEE-WHT-M',1,449,0.0,22.45),
('AMAZ-1289','MJNS-BLK-30',1,1399,0.0,69.95),
('SHOP-1232','MTEE-BLK-XL',1,449,22.45,21.33),
('SHOP-1232','BKUR-MUS-45Y',1,949,47.45,45.08),
('FLIP-1218','WTOP-WHT-M',2,599,0.0,59.9),
('FLIP-1218','WLEG-BLK-M',1,349,0.0,17.45),
('FLIP-1218','WLEG-MAR-M',1,349,0.0,17.45),
('FLIP-1219','MJNS-BLK-32',1,1399,139.9,62.96),
('FLIP-1219','MTRK-BLK-M',1,649,64.9,29.21),
('FLIP-1219','MKUR-WHT-XL',1,1099,109.9,49.46),
('SHOP-1233','WDRS-FLR-L',3,1499,0.0,224.85),
('SHOP-1233','WTOP-PCH-M',2,599,0.0,59.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1232','Bluedart - Surat City'),
('FLIP-1219','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1205', 'pickup');
select pg_temp.ret_set('FLIP-1190', 'approved');
select pg_temp.ret_set('FLIP-1191', 'pickup');
select pg_temp.ret_set('AMAZ-1268', 'approved');
select pg_temp.rto_new('FLIP-1207', 'AWB31000723', 'Address incomplete');
select pg_temp.retime();

-- Fri 24 Jul 2026
select pg_temp.day('2026-07-24');
select pg_temp.bill_po('Weekly replenishment 13 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R113)', 'TKF/26/0355', 1);
select pg_temp.grn_new('Weekly replenishment 20 Jul 2026 - Krishna Denim Works (ref R114)', 'DC-KDW-0115', '[{"sku":"MJNS-IND-34","q":16,"a":16,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 20 Jul 2026 - Shree Ambika Textiles (ref R115)', 'SAT/26/0263', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1220','Flipkart - Seller Hub','2026-07-24 10:43+05:30','Riya Shah','prepaid',2598.0,0.0,129.9,2727.9,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1234','Shopify - Main Store','2026-07-24 14:55+05:30','Mehul Shukla','cod',849.0,84.9,38.21,802.31,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1235','Shopify - Main Store','2026-07-24 10:51+05:30','Rohit Iyer','prepaid',948.0,0.0,47.4,995.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1221','Flipkart - Seller Hub','2026-07-24 20:10+05:30','Sejal Kapadia','cod',6393.0,639.3,287.69,6041.39,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1236','Shopify - Main Store','2026-07-24 09:45+05:30','Meghna Rao','cod',649.0,0.0,32.45,681.45,'cancelled','failed','Rajasthan','Surat Main Warehouse'),
('AMAZ-1290','Amazon - Seller Central','2026-07-24 09:18+05:30','Aarav Mehta','prepaid',599.0,59.9,26.96,566.06,'delivered','paid','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1220','MCHN-KHK-30',1,1199,0.0,59.95),
('FLIP-1220','MJNS-IND-34',1,1399,0.0,69.95),
('SHOP-1234','WKRT-PNK-M',1,849,84.9,38.21),
('SHOP-1235','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1235','WLEG-MAR-L',1,349,0.0,17.45),
('FLIP-1221','MTEE-BLK-M',2,449,89.8,40.41),
('FLIP-1221','MJNS-BLK-34',3,1399,419.7,188.87),
('FLIP-1221','MTRK-BLK-M',2,649,129.8,58.41),
('SHOP-1236','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1290','WTOP-WHT-M',1,599,59.9,26.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1221','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1251');
select pg_temp.ret_new('SHOP-1200', 'Item arrived damaged', 'webhook');
select pg_temp.rto_recv('SHOP-1202', 'good', 'restocked');
select pg_temp.ret_new('AMAZ-1264', 'Fabric quality not as expected', 'webhook');
select pg_temp.ret_set('FLIP-1190', 'pickup');
select pg_temp.ret_new('FLIP-1195', 'Size did not fit', 'webhook');
select pg_temp.ret_set('AMAZ-1268', 'pickup');
select pg_temp.ret_new('AMAZ-1269', 'Colour different from photo', 'webhook');
select pg_temp.rto_set('AMAZ-1276', 'in_transit');
select pg_temp.ret_new('AMAZ-1280', 'Colour different from photo', 'webhook');
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-24JUL', array['SHOP-1206']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-24JUL', array['SHOP-1194','AMAZ-1265','FLIP-1202']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-07-27', 'ICIC000000885068', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-07-27', 'ICIC000000885137', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-07-27', 'ICIC000000885218', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-07-27', 'ICIC000000885290', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-07-27', 'ICIC000000885331', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-07-27', 'ICIC000000885343', 1);
select pg_temp.claim_step('FLIP-1114', 'lost_shipment', 'approved', null);
select pg_temp.retime();

-- Sat 25 Jul 2026
select pg_temp.day('2026-07-25');
select pg_temp.bill_po('Weekly replenishment 20 Jul 2026 - Krishna Denim Works (ref R114)', 'KDW/26/0276', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1237','Shopify - Main Store','2026-07-25 12:59+05:30','Meghna Rao','prepaid',549.0,0.0,27.45,576.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1238','Shopify - Main Store','2026-07-25 19:20+05:30','Foram Thakkar','prepaid',2698.0,0.0,134.9,2832.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1291','Amazon - Seller Central','2026-07-25 12:27+05:30','Amit Sethi','cod',1199.0,0.0,59.95,1258.95,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('AMAZ-1292','Amazon - Seller Central','2026-07-25 21:46+05:30','Yash Vora','cod',2576.0,257.6,115.94,2434.34,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1222','Flipkart - Seller Hub','2026-07-25 22:15+05:30','Dev Trivedi','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1293','Amazon - Seller Central','2026-07-25 17:42+05:30','Nikhil Pandey','prepaid',2047.0,204.7,92.12,1934.42,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1239','Shopify - Main Store','2026-07-25 12:40+05:30','Rahul Bhatt','prepaid',1349.0,134.9,60.71,1274.81,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1237','GNGT-PNK-89Y',1,549,0.0,27.45),
('SHOP-1238','WJNS-BLK-30',2,1349,0.0,134.9),
('AMAZ-1291','MCHN-OLV-32',1,1199,0.0,59.95),
('AMAZ-1292','MTRK-BLK-L',1,649,64.9,29.21),
('AMAZ-1292','MSHC-GRN-M',1,899,89.9,40.46),
('AMAZ-1292','MPOL-NVY-XL',1,699,69.9,31.46),
('AMAZ-1292','BTEE-BLU-67Y',1,329,32.9,14.81),
('FLIP-1222','WLEG-BLK-M',1,349,0.0,17.45),
('AMAZ-1293','WKRT-PNK-XL',1,849,84.9,38.21),
('AMAZ-1293','WTOP-PCH-M',2,599,119.8,53.91),
('SHOP-1239','WJNS-BLK-32',1,1349,134.9,60.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1292','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1251', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1200', 'approved');
select pg_temp.ret_set('AMAZ-1264', 'approved');
select pg_temp.ret_set('SHOP-1205', 'in_transit');
select pg_temp.ret_set('FLIP-1191', 'in_transit');
select pg_temp.ret_set('FLIP-1195', 'approved');
select pg_temp.ret_set('AMAZ-1269', 'approved');
select pg_temp.cod_collect(array['SHOP-1219']::text[]);
select pg_temp.rto_set('FLIP-1207', 'in_transit');
select pg_temp.ret_set('AMAZ-1280', 'approved');
select pg_temp.cod_collect(array['SHOP-1222']::text[]);
select pg_temp.cod_collect(array['FLIP-1210']::text[]);
select pg_temp.cod_collect(array['SHOP-1223']::text[]);
select pg_temp.rto_new('FLIP-1214', 'AWB31000755', 'Customer refused delivery');
select pg_temp.claim_recover('AMAZ-1166', 'damaged_return', 'CLAIM-CR-AMAZ-1166');
select pg_temp.retime();

-- Sun 26 Jul 2026
select pg_temp.day('2026-07-26');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1240','Shopify - Main Store','2026-07-26 19:37+05:30','Dev Trivedi','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1223','Flipkart - Seller Hub','2026-07-26 19:53+05:30','Sagar Rathod','cod',2606.0,0.0,130.3,2736.3,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1294','Amazon - Seller Central','2026-07-26 21:17+05:30','Harsh Modi','prepaid',2896.0,0.0,144.8,3040.8,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1224','Flipkart - Seller Hub','2026-07-26 20:29+05:30','Heena Khan','prepaid',2396.0,0.0,119.8,2515.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1225','Flipkart - Seller Hub','2026-07-26 13:33+05:30','Vivek Singh','cod',2596.0,129.8,123.31,2589.51,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1226','Flipkart - Seller Hub','2026-07-26 19:54+05:30','Yash Vora','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1227','Flipkart - Seller Hub','2026-07-26 12:16+05:30','Prachi Kulkarni','cod',628.0,0.0,31.4,659.4,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1295','Amazon - Seller Central','2026-07-26 17:49+05:30','Riya Shah','cod',2497.0,249.7,112.37,2359.67,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1296','Amazon - Seller Central','2026-07-26 18:48+05:30','Sanjay Gajera','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1297','Amazon - Seller Central','2026-07-26 11:47+05:30','Jigar Chauhan','prepaid',3997.0,0.0,199.85,4196.85,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1298','Amazon - Seller Central','2026-07-26 18:38+05:30','Rohit Iyer','prepaid',8594.0,0.0,923.57,9517.57,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1228','Flipkart - Seller Hub','2026-07-26 12:52+05:30','Ritu Saxena','prepaid',899.0,0.0,44.95,943.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1240','MTRK-BLK-XL',1,649,0.0,32.45),
('FLIP-1223','BTRK-BLK-89Y',1,999,0.0,49.95),
('FLIP-1223','BTEE-BLU-45Y',2,329,0.0,32.9),
('FLIP-1223','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1294','WPAL-WHT-M',2,599,0.0,59.9),
('AMAZ-1294','WKRT-PNK-M',2,849,0.0,84.9),
('FLIP-1224','WTOP-WHT-L',2,599,0.0,59.9),
('FLIP-1224','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1225','MTRK-BLK-L',1,649,32.45,30.83),
('FLIP-1225','MTRK-BLK-XL',3,649,97.35,92.48),
('FLIP-1226','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1226','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1227','GLEG-BLK-45Y',1,279,0.0,13.95),
('FLIP-1227','WLEG-MAR-L',1,349,0.0,17.45),
('AMAZ-1295','BKUR-CRM-67Y',2,949,189.8,85.41),
('AMAZ-1295','WTOP-WHT-M',1,599,59.9,26.96),
('AMAZ-1296','MJNS-BLK-32',1,1399,0.0,69.95),
('AMAZ-1297','MCHN-KHK-34',1,1199,0.0,59.95),
('AMAZ-1297','MJNS-BLK-32',2,1399,0.0,139.9),
('AMAZ-1298','MSHC-RED-XL',3,899,0.0,134.85),
('AMAZ-1298','MCHN-KHK-30',1,1199,0.0,59.95),
('AMAZ-1298','MBLZ-NVY-40',1,3799,0.0,683.82),
('AMAZ-1298','MSHC-RED-L',1,899,0.0,44.95),
('FLIP-1228','MSHC-RED-XL',1,899,0.0,44.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1223','Xpressbees - Pandesara'),
('FLIP-1225','Bluedart - Surat City'),
('FLIP-1227','Xpressbees - Pandesara'),
('AMAZ-1295','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1200', 'pickup');
select pg_temp.ret_set('AMAZ-1264', 'pickup');
select pg_temp.ret_set('FLIP-1190', 'in_transit');
select pg_temp.ret_set('FLIP-1195', 'pickup');
select pg_temp.ret_set('AMAZ-1268', 'in_transit');
select pg_temp.ret_set('AMAZ-1269', 'pickup');
select pg_temp.ret_set('AMAZ-1280', 'pickup');
select pg_temp.rto_new('FLIP-1209', 'AWB31000752', 'Address incomplete');
select pg_temp.cod_collect(array['SHOP-1221']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260713', 0.0);
select pg_temp.retime();

-- Mon 27 Jul 2026
select pg_temp.day('2026-07-27');
select pg_temp.po_new('Weekly replenishment 27 Jul 2026 - Krishna Denim Works (ref R118)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-30","q":10},{"sku":"WJNS-IND-28","q":12},{"sku":"WJNS-IND-32","q":8},{"sku":"WJNS-BLK-30","q":6},{"sku":"WJNS-BLK-32","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Jul 2026 - Shree Ambika Textiles (ref R119)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WKRT-PNK-M","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Jul 2026 - Shree Ambika Textiles (ref R120)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WPAL-WHT-M","q":8},{"sku":"WLHG-RED-M","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R121)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-WHT-M","q":6},{"sku":"BTEE-BLU-67Y","q":8},{"sku":"BTEE-RED-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 27 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R122)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-BLK-M","q":6},{"sku":"MTEE-WHT-M","q":6},{"sku":"MTRK-BLK-L","q":10},{"sku":"WLEG-MAR-M","q":8},{"sku":"WLEG-NVY-M","q":6}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1229','Flipkart - Seller Hub','2026-07-27 14:16+05:30','Amit Sethi','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1241','Shopify - Main Store','2026-07-27 17:09+05:30','Rahul Bhatt','cod',329.0,0.0,16.45,345.45,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1299','Amazon - Seller Central','2026-07-27 19:09+05:30','Amit Sethi','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1300','Amazon - Seller Central','2026-07-27 22:21+05:30','Mehul Shukla','prepaid',837.0,0.0,41.85,878.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1230','Flipkart - Seller Hub','2026-07-27 22:12+05:30','Jigar Chauhan','cod',2646.0,132.3,125.69,2639.39,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1231','Flipkart - Seller Hub','2026-07-27 10:11+05:30','Heena Khan','prepaid',3597.0,179.85,170.86,3588.01,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1301','Amazon - Seller Central','2026-07-27 21:02+05:30','Rahul Bhatt','prepaid',599.0,0.0,29.95,628.95,'shipped','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1242','Shopify - Main Store','2026-07-27 14:11+05:30','Mehul Shukla','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1302','Amazon - Seller Central','2026-07-27 17:40+05:30','Yash Vora','prepaid',1586.0,0.0,79.3,1665.3,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1243','Shopify - Main Store','2026-07-27 14:54+05:30','Vipul Gandhi','cod',3297.0,329.7,148.38,3115.68,'delivered','pending','West Bengal','Surat Main Warehouse'),
('AMAZ-1303','Amazon - Seller Central','2026-07-27 18:31+05:30','Ritu Saxena','prepaid',699.0,0.0,34.95,733.95,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1229','WTOP-PCH-S',2,599,0.0,59.9),
('SHOP-1241','BTEE-BLU-89Y',1,329,0.0,16.45),
('AMAZ-1299','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1300','GLEG-BLK-67Y',1,279,0.0,13.95),
('AMAZ-1300','GLEG-BLK-45Y',1,279,0.0,13.95),
('AMAZ-1300','GLEG-BLK-89Y',1,279,0.0,13.95),
('FLIP-1230','WKRT-PNK-M',1,849,42.45,40.33),
('FLIP-1230','WTOP-WHT-L',1,599,29.95,28.45),
('FLIP-1230','WTOP-PCH-S',2,599,59.9,56.91),
('FLIP-1231','MCHN-KHK-30',1,1199,59.95,56.95),
('FLIP-1231','MCHN-OLV-34',2,1199,119.9,113.91),
('AMAZ-1301','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1242','MJNS-IND-34',1,1399,0.0,69.95),
('AMAZ-1302','GFRK-LIL-45Y',1,749,0.0,37.45),
('AMAZ-1302','GLEG-BLK-89Y',3,279,0.0,41.85),
('SHOP-1243','MCHN-KHK-30',1,1199,119.9,53.96),
('SHOP-1243','MPOL-MRN-L',1,699,69.9,31.46),
('SHOP-1243','MJNS-BLK-30',1,1399,139.9,62.96),
('AMAZ-1303','MPOL-MRN-M',1,699,0.0,34.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1241','Ecom Express - Udhna Hub'),
('FLIP-1230','Bluedart - Surat City'),
('SHOP-1243','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_recv('SHOP-1207', 'good', 'restocked');
select pg_temp.cod_collect(array['FLIP-1213']::text[]);
select pg_temp.rto_set('FLIP-1214', 'in_transit');
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260720', '2026-07-20', '2026-07-26', array['AMAZ-1266','AMAZ-1267','AMAZ-1270','AMAZ-1275','AMAZ-1269','AMAZ-1271','AMAZ-1272','AMAZ-1277','AMAZ-1279','AMAZ-1280','AMAZ-1274','AMAZ-1273','AMAZ-1278','AMAZ-1282','AMAZ-1284','AMAZ-1285','AMAZ-1281','AMAZ-1287']::text[], array['AMAZ-1251']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260720', '2026-07-20', '2026-07-26', array['FLIP-1190','FLIP-1203','FLIP-1196','FLIP-1199','FLIP-1197','FLIP-1205','FLIP-1208','FLIP-1204','FLIP-1206','FLIP-1212','FLIP-1211','FLIP-1216','FLIP-1218']::text[], array['FLIP-1181']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260720', '2026-07-20', '2026-07-26', array['SHOP-1209','SHOP-1210','SHOP-1213','SHOP-1208','SHOP-1214','SHOP-1216','SHOP-1218','SHOP-1217','SHOP-1220','SHOP-1225','SHOP-1224','SHOP-1227','SHOP-1229']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 28 Jul 2026
select pg_temp.day('2026-07-28');
select pg_temp.grn_new('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R116)', 'DC-TKF-0151', '[{"sku":"MTEE-WHT-M","q":4,"a":4,"r":0},{"sku":"BTEE-RED-45Y","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1304','Amazon - Seller Central','2026-07-28 21:45+05:30','Neha Patel','prepaid',2197.0,0.0,109.85,2306.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1232','Flipkart - Seller Hub','2026-07-28 15:58+05:30','Isha Gupta','prepaid',1198.0,59.9,56.91,1195.01,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1244','Shopify - Main Store','2026-07-28 11:57+05:30','Vipul Gandhi','cod',7297.0,364.85,1025.73,7957.88,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1305','Amazon - Seller Central','2026-07-28 15:51+05:30','Dev Trivedi','prepaid',1607.0,0.0,80.35,1687.35,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1233','Flipkart - Seller Hub','2026-07-28 12:17+05:30','Nidhi Agarwal','prepaid',4096.0,0.0,204.8,4300.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1306','Amazon - Seller Central','2026-07-28 15:50+05:30','Bhavna Solanki','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1234','Flipkart - Seller Hub','2026-07-28 20:18+05:30','Yash Vora','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1304','MSHF-WHT-XL',1,999,0.0,49.95),
('AMAZ-1304','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1232','BSHF-WHT-89Y',2,599,59.9,56.91),
('SHOP-1244','MCHN-KHK-30',1,1199,59.95,56.95),
('SHOP-1244','WTOP-PCH-L',1,599,29.95,28.45),
('SHOP-1244','WLHG-MAG-M',1,5499,274.95,940.33),
('AMAZ-1305','GNGT-PNK-89Y',1,549,0.0,27.45),
('AMAZ-1305','GJNS-IND-45Y',1,779,0.0,38.95),
('AMAZ-1305','GLEG-BLK-89Y',1,279,0.0,13.95),
('FLIP-1233','MJNS-BLK-34',1,1399,0.0,69.95),
('FLIP-1233','MSHC-RED-XL',3,899,0.0,134.85),
('AMAZ-1306','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1234','WTOP-WHT-L',2,599,0.0,59.9),
('FLIP-1234','WTOP-PCH-L',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1244','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1200', 'in_transit');
select pg_temp.ret_set('AMAZ-1264', 'in_transit');
select pg_temp.ret_recv('SHOP-1205');
select pg_temp.ret_recv('FLIP-1191');
select pg_temp.ret_set('FLIP-1195', 'in_transit');
select pg_temp.ret_set('AMAZ-1269', 'in_transit');
select pg_temp.rto_recv('AMAZ-1276', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1280', 'in_transit');
select pg_temp.rto_set('FLIP-1209', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1232']::text[]);
select pg_temp.cod_collect(array['FLIP-1219']::text[]);
select pg_temp.settle_pay('FLK-STL-20260713', 0.0);
select pg_temp.claim_recover('FLIP-1138', 'damaged_return', 'CLAIM-CR-FLIP-1138');
select pg_temp.retime();

-- Wed 29 Jul 2026
select pg_temp.day('2026-07-29');
select pg_temp.bill_po('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R116)', 'TKF/26/0364', 1);
select pg_temp.grn_new('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R117)', 'DC-TKF-0157', '[{"sku":"MTEE-BLK-XL","q":5,"a":5,"r":0},{"sku":"MTEE-WHT-M","q":4,"a":4,"r":0},{"sku":"MTRK-BLK-M","q":5,"a":5,"r":0},{"sku":"MTRK-BLK-L","q":4,"a":4,"r":0},{"sku":"WLEG-MAR-M","q":4,"a":4,"r":0},{"sku":"WLEG-NVY-M","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1307','Amazon - Seller Central','2026-07-29 09:12+05:30','Aarav Mehta','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1308','Amazon - Seller Central','2026-07-29 11:15+05:30','Shreya Banerjee','prepaid',1548.0,0.0,77.4,1625.4,'cancelled','refunded','Rajasthan','Surat Main Warehouse'),
('FLIP-1235','Flipkart - Seller Hub','2026-07-29 15:11+05:30','Foram Thakkar','prepaid',2227.0,0.0,111.35,2338.35,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1245','Shopify - Main Store','2026-07-29 17:10+05:30','Ritu Saxena','prepaid',1648.0,164.8,74.17,1557.37,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1309','Amazon - Seller Central','2026-07-29 22:48+05:30','Yash Vora','prepaid',1278.0,0.0,63.9,1341.9,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1236','Flipkart - Seller Hub','2026-07-29 14:33+05:30','Aditi Joshi','prepaid',2996.0,299.6,134.84,2831.24,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1237','Flipkart - Seller Hub','2026-07-29 09:15+05:30','Yash Vora','prepaid',9395.0,469.75,915.44,9840.69,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1238','Flipkart - Seller Hub','2026-07-29 22:24+05:30','Nikhil Pandey','prepaid',1377.0,0.0,68.85,1445.85,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1310','Amazon - Seller Central','2026-07-29 14:50+05:30','Kunal Desai','cod',2297.0,229.7,103.37,2170.67,'delivered','pending','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1307','WKRT-PNK-M',1,849,0.0,42.45),
('AMAZ-1308','BKUR-MUS-89Y',1,949,0.0,47.45),
('AMAZ-1308','WTOP-PCH-M',1,599,0.0,29.95),
('FLIP-1235','BKUR-MUS-67Y',2,949,0.0,94.9),
('FLIP-1235','BTEE-BLU-89Y',1,329,0.0,16.45),
('SHOP-1245','MCHN-OLV-30',1,1199,119.9,53.96),
('SHOP-1245','MTEE-WHT-L',1,449,44.9,20.21),
('AMAZ-1309','BKUR-CRM-67Y',1,949,0.0,47.45),
('AMAZ-1309','BTEE-BLU-67Y',1,329,0.0,16.45),
('FLIP-1236','MCHN-KHK-30',1,1199,119.9,53.96),
('FLIP-1236','WLEG-MAR-M',1,349,34.9,15.71),
('FLIP-1236','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1236','WKRT-PNK-L',1,849,84.9,38.21),
('FLIP-1237','MJNS-BLK-32',3,1399,209.85,199.36),
('FLIP-1237','MBLZ-NVY-40',1,3799,189.95,649.63),
('FLIP-1237','MJNS-IND-34',1,1399,69.95,66.45),
('FLIP-1238','GTOP-YLW-45Y',1,349,0.0,17.45),
('FLIP-1238','GLEG-BLK-45Y',1,279,0.0,13.95),
('FLIP-1238','GFRK-LIL-67Y',1,749,0.0,37.45),
('AMAZ-1310','WKRT-TEL-L',2,849,169.8,76.41),
('AMAZ-1310','WPAL-WHT-L',1,599,59.9,26.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1310','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('SHOP-1205', 'damaged', 'quarantined');
select pg_temp.ret_dispo('FLIP-1191', 'good', 'restocked');
select pg_temp.cod_collect(array['AMAZ-1295']::text[]);
select pg_temp.settle_pay('SHP-STL-20260720', 0.0);
select pg_temp.retime();

-- Thu 30 Jul 2026
select pg_temp.day('2026-07-30');
select pg_temp.bill_po('Weekly replenishment 20 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R117)', 'TKF/26/0377', 1);
select pg_temp.grn_new('Weekly replenishment 27 Jul 2026 - Shree Ambika Textiles (ref R119)', 'DC-SAT-0112', '[{"sku":"WKRT-PNK-M","q":10,"a":10,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1239','Flipkart - Seller Hub','2026-07-30 17:12+05:30','Yash Vora','prepaid',329.0,16.45,15.63,328.18,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1240','Flipkart - Seller Hub','2026-07-30 11:38+05:30','Amit Sethi','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1311','Amazon - Seller Central','2026-07-30 21:55+05:30','Neha Patel','prepaid',5694.0,0.0,284.7,5978.7,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1312','Amazon - Seller Central','2026-07-30 15:11+05:30','Shreya Banerjee','prepaid',1948.0,0.0,97.4,2045.4,'delivered','paid','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1239','BTEE-RED-89Y',1,329,16.45,15.63),
('FLIP-1240','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1311','BKUR-MUS-45Y',3,949,0.0,142.35),
('AMAZ-1311','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1311','BKUR-MUS-89Y',2,949,0.0,94.9),
('AMAZ-1312','WJNS-IND-32',1,1349,0.0,67.45),
('AMAZ-1312','WTOP-PCH-L',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('FLIP-1190');
select pg_temp.ret_recv('AMAZ-1268');
select pg_temp.ret_recv('AMAZ-1269');
select pg_temp.rto_new('SHOP-1234', 'AWB31000789', 'Customer unreachable');
select pg_temp.cod_collect(array['FLIP-1221']::text[]);
select pg_temp.cod_collect(array['FLIP-1223']::text[]);
select pg_temp.cod_collect(array['FLIP-1225']::text[]);
select pg_temp.retime();

-- Fri 31 Jul 2026
select pg_temp.day('2026-07-31');
select pg_temp.bill_po('Weekly replenishment 27 Jul 2026 - Shree Ambika Textiles (ref R119)', 'SAT/26/0269', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1313','Amazon - Seller Central','2026-07-31 22:13+05:30','Manav Joshi','prepaid',1399.0,0.0,69.95,1468.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1241','Flipkart - Seller Hub','2026-07-31 15:50+05:30','Mehul Shukla','cod',1998.0,0.0,99.9,2097.9,'delivered','pending','West Bengal','Surat Main Warehouse'),
('SHOP-1246','Shopify - Main Store','2026-07-31 16:44+05:30','Shreya Banerjee','cod',1199.0,0.0,59.95,1258.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1242','Flipkart - Seller Hub','2026-07-31 13:07+05:30','Shreya Banerjee','prepaid',279.0,13.95,13.25,278.3,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1247','Shopify - Main Store','2026-07-31 09:33+05:30','Isha Gupta','prepaid',2315.0,115.75,109.97,2309.22,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1243','Flipkart - Seller Hub','2026-07-31 10:08+05:30','Sagar Rathod','prepaid',2698.0,0.0,134.9,2832.9,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1314','Amazon - Seller Central','2026-07-31 19:08+05:30','Ritu Saxena','prepaid',349.0,17.45,16.58,348.13,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1313','MJNS-BLK-32',1,1399,0.0,69.95),
('FLIP-1241','MKUR-WHT-XL',1,1099,0.0,54.95),
('FLIP-1241','MSHC-RED-M',1,899,0.0,44.95),
('SHOP-1246','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1242','GLEG-PNK-89Y',1,279,13.95,13.25),
('SHOP-1247','BTEE-BLU-67Y',1,329,16.45,15.63),
('SHOP-1247','BTEE-BLU-89Y',2,329,32.9,31.26),
('SHOP-1247','BTRK-BLK-1011Y',1,999,49.95,47.45),
('SHOP-1247','BTEE-RED-67Y',1,329,16.45,15.63),
('FLIP-1243','WJNS-BLK-32',2,1349,0.0,134.9),
('AMAZ-1314','BSHT-NVY-89Y',1,349,17.45,16.58)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1241','Bluedart - Surat City'),
('SHOP-1246','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1205', 'UPI-REFUND-SHOP-1205');
select pg_temp.ret_dispo('FLIP-1190', 'damaged', 'quarantined');
select pg_temp.ret_new('AMAZ-1278', 'Fabric quality not as expected', 'webhook');
select pg_temp.rto_recv('FLIP-1207', 'good', 'restocked');
select pg_temp.ret_recv('AMAZ-1280');
select pg_temp.rto_recv('FLIP-1209', 'good', 'restocked');
select pg_temp.cod_collect(array['AMAZ-1292']::text[]);
select pg_temp.cod_collect(array['FLIP-1227']::text[]);
select pg_temp.cod_collect(array['SHOP-1241']::text[]);
select pg_temp.cod_collect(array['SHOP-1244']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-31JUL', array['SHOP-1219','FLIP-1219']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-31JUL', array['FLIP-1210','AMAZ-1295']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-31JUL', array['SHOP-1223','SHOP-1232']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-31JUL', array['SHOP-1221','SHOP-1222','FLIP-1213']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-08-03', 'ICIC000000885423', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-08-03', 'ICIC000000885506', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-08-03', 'ICIC000000885568', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-08-03', 'ICIC000000885657', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-08-03', 'ICIC000000885690', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-08-03', 'ICIC000000885713', 1);
select pg_temp.claim_step('AMAZ-1204', 'damaged_return', 'approved', null);
select pg_temp.claim_new('FLIP-1190', 'damaged_return', 1415.61, '2026-08-30');
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
