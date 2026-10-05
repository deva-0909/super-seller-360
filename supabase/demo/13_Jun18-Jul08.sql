-- 18 Jun to 08 Jul 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Thu 18 Jun 2026
select pg_temp.day('2026-06-18');
select pg_temp.grn_new('Weekly replenishment 08 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R072)', 'DC-TKF-0106', '[{"sku":"WLEG-NVY-M","q":6,"a":6,"r":0},{"sku":"GTOP-WHT-45Y","q":6,"a":6,"r":0},{"sku":"GLEG-BLK-89Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 08 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R073)', 'TKF/26/0267', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1179','Amazon - Seller Central','2026-06-18 11:36+05:30','Nidhi Agarwal','prepaid',699.0,0.0,34.95,733.95,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1144','Shopify - Main Store','2026-06-18 11:48+05:30','Amit Sethi','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1180','Amazon - Seller Central','2026-06-18 14:35+05:30','Sagar Rathod','prepaid',2995.0,299.5,134.78,2830.28,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1181','Amazon - Seller Central','2026-06-18 21:23+05:30','Mitul Dave','prepaid',1116.0,55.8,53.01,1113.21,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1182','Amazon - Seller Central','2026-06-18 22:01+05:30','Vipul Gandhi','prepaid',6395.0,319.75,303.77,6379.02,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1143','Flipkart - Seller Hub','2026-06-18 21:39+05:30','Isha Gupta','prepaid',1627.0,0.0,81.35,1708.35,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1144','Flipkart - Seller Hub','2026-06-18 19:51+05:30','Heena Khan','cod',2847.0,0.0,142.35,2989.35,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1183','Amazon - Seller Central','2026-06-18 13:53+05:30','Harsh Modi','prepaid',948.0,47.4,45.03,945.63,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1184','Amazon - Seller Central','2026-06-18 11:26+05:30','Amit Sethi','prepaid',1298.0,0.0,64.9,1362.9,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1185','Amazon - Seller Central','2026-06-18 16:07+05:30','Nidhi Agarwal','cod',2247.0,0.0,112.35,2359.35,'delivered','pending','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1179','MPOL-NVY-XL',1,699,0.0,34.95),
('SHOP-1144','GLEG-PNK-67Y',1,279,0.0,13.95),
('AMAZ-1180','WTOP-PCH-M',3,599,179.7,80.87),
('AMAZ-1180','WTOP-PCH-L',2,599,119.8,53.91),
('AMAZ-1181','GLEG-PNK-67Y',1,279,13.95,13.25),
('AMAZ-1181','GLEG-BLK-67Y',2,279,27.9,26.51),
('AMAZ-1181','GLEG-BLK-45Y',1,279,13.95,13.25),
('AMAZ-1182','MJNS-BLK-32',2,1399,139.9,132.91),
('AMAZ-1182','MCHN-KHK-34',1,1199,59.95,56.95),
('AMAZ-1182','MCHN-OLV-32',2,1199,119.9,113.91),
('FLIP-1143','GNGT-PNK-45Y',1,549,0.0,27.45),
('FLIP-1143','BTEE-BLU-45Y',1,329,0.0,16.45),
('FLIP-1143','GFRK-LIL-45Y',1,749,0.0,37.45),
('FLIP-1144','BKUR-MUS-45Y',3,949,0.0,142.35),
('AMAZ-1183','WLEG-BLK-L',1,349,17.45,16.58),
('AMAZ-1183','WPAL-WHT-XL',1,599,29.95,28.45),
('AMAZ-1184','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1184','BSHT-GRY-67Y',1,349,0.0,17.45),
('AMAZ-1185','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1185','MHOD-GRY-M',1,1299,0.0,64.95),
('AMAZ-1185','WLEG-BLK-L',1,349,0.0,17.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1144','Xpressbees - Pandesara'),
('AMAZ-1185','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1117', 'UPI-REFUND-SHOP-1117');
select pg_temp.ret_dispo('AMAZ-1128', 'damaged', 'quarantined');
select pg_temp.ret_set('SHOP-1128', 'approved');
select pg_temp.ret_set('SHOP-1132', 'pickup');
select pg_temp.rto_recv('SHOP-1133', 'good', 'restocked');
select pg_temp.rto_set('FLIP-1114', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1120']::text[]);
select pg_temp.claim_new('AMAZ-1128', 'damaged_return', 764.89, '2026-07-18');
select pg_temp.retime();

-- Fri 19 Jun 2026
select pg_temp.day('2026-06-19');
select pg_temp.bill_po('Weekly replenishment 08 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R072)', 'TKF/26/0259', 1);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Rajdhani Shirting Mills (ref R078)', 'DC-RSM-0103', '[{"sku":"MSHF-WHT-XL","q":4,"a":4,"r":0},{"sku":"MSHC-RED-M","q":9,"a":9,"r":0},{"sku":"MSHC-GRN-M","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R079)', 'DC-SAT-0076', '[{"sku":"WPAL-YLW-L","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1186','Amazon - Seller Central','2026-06-19 12:05+05:30','Nidhi Agarwal','prepaid',1349.0,134.9,60.71,1274.81,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1145','Shopify - Main Store','2026-06-19 09:41+05:30','Sejal Kapadia','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1146','Shopify - Main Store','2026-06-19 15:26+05:30','Mitul Dave','cod',599.0,0.0,29.95,628.95,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1147','Shopify - Main Store','2026-06-19 12:13+05:30','Sanjay Gajera','prepaid',878.0,87.8,39.52,829.72,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1145','Flipkart - Seller Hub','2026-06-19 21:15+05:30','Vipul Gandhi','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1187','Amazon - Seller Central','2026-06-19 19:42+05:30','Kunal Desai','prepaid',1898.0,94.9,90.16,1893.26,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1188','Amazon - Seller Central','2026-06-19 22:49+05:30','Kiran Naik','prepaid',5077.0,507.7,672.96,5242.26,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1146','Flipkart - Seller Hub','2026-06-19 09:57+05:30','Anjali Verma','prepaid',4496.0,0.0,224.8,4720.8,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1186','WJNS-BLK-30',1,1349,134.9,60.71),
('SHOP-1145','GTOP-WHT-67Y',1,349,0.0,17.45),
('SHOP-1146','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1147','WTOP-PCH-S',1,599,59.9,26.96),
('SHOP-1147','GLEG-PNK-45Y',1,279,27.9,12.56),
('FLIP-1145','MCHN-OLV-32',1,1199,119.9,53.96),
('AMAZ-1187','BKUR-MUS-67Y',1,949,47.45,45.08),
('AMAZ-1187','BKUR-MUS-45Y',1,949,47.45,45.08),
('AMAZ-1188','BTEE-RED-67Y',1,329,32.9,14.81),
('AMAZ-1188','MBLZ-NVY-40',1,3799,379.9,615.44),
('AMAZ-1188','BKUR-CRM-89Y',1,949,94.9,42.71),
('FLIP-1146','WLEG-MAR-M',1,349,0.0,17.45),
('FLIP-1146','WJNS-BLK-28',1,1349,0.0,67.45),
('FLIP-1146','WTOP-WHT-M',1,599,0.0,29.95),
('FLIP-1146','WSAR-RED-FREE',1,2199,0.0,109.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1146','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('SHOP-1128', 'pickup');
select pg_temp.cod_collect(array['FLIP-1126']::text[]);
select pg_temp.rto_new('SHOP-1139', 'AWB31000480', 'Address incomplete');
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-19JUN', array['AMAZ-1147']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-19JUN', array['SHOP-1134','FLIP-1118','FLIP-1122','SHOP-1138']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-19JUN', array['FLIP-1107','SHOP-1130']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-19JUN', array['SHOP-1131','AMAZ-1165']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-06-22', 'ICIC000000883652', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-06-22', 'ICIC000000883674', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-06-22', 'ICIC000000883746', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-06-22', 'ICIC000000883792', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-06-22', 'ICIC000000883809', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-06-22', 'ICIC000000883847', 1);
select pg_temp.claim_step('AMAZ-1064', 'lost_shipment', 'approved', null);
select pg_temp.retime();

-- Sat 20 Jun 2026
select pg_temp.day('2026-06-20');
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Little Stitch Garments (ref R076)', 'DC-LSG-0091', '[{"sku":"BSHT-NVY-45Y","q":4,"a":4,"r":0},{"sku":"BKUR-CRM-45Y","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Rajdhani Shirting Mills (ref R078)', 'RSM/26/0251', 1);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R079)', 'SAT/26/0185', 1);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R080)', 'DC-SAT-0082', '[{"sku":"WKRT-TEL-XL","q":5,"a":5,"r":0},{"sku":"WLHG-RED-L","q":5,"a":5,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1189','Amazon - Seller Central','2026-06-20 19:18+05:30','Divya Nair','prepaid',599.0,59.9,26.96,566.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1148','Shopify - Main Store','2026-06-20 11:54+05:30','Amit Sethi','cod',3597.0,179.85,170.85,3588.0,'delivered','pending','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1190','Amazon - Seller Central','2026-06-20 22:19+05:30','Vipul Gandhi','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1147','Flipkart - Seller Hub','2026-06-20 18:06+05:30','Pratik Lad','prepaid',2264.0,226.4,101.9,2139.5,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1191','Amazon - Seller Central','2026-06-20 17:02+05:30','Rohit Iyer','prepaid',2897.0,144.85,137.6,2889.75,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1149','Shopify - Main Store','2026-06-20 10:51+05:30','Sonal Parekh','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1150','Shopify - Main Store','2026-06-20 09:55+05:30','Manav Joshi','cod',899.0,0.0,44.95,943.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1148','Flipkart - Seller Hub','2026-06-20 11:01+05:30','Nikhil Pandey','prepaid',2396.0,0.0,119.8,2515.8,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1189','WTOP-PCH-M',1,599,59.9,26.96),
('SHOP-1148','MSHC-GRN-M',1,899,44.95,42.7),
('SHOP-1148','MHOD-GRY-L',1,1299,64.95,61.7),
('SHOP-1148','MJNS-IND-32',1,1399,69.95,66.45),
('AMAZ-1190','WTOP-PCH-L',3,599,0.0,89.85),
('FLIP-1147','BTEE-BLU-89Y',3,329,98.7,44.42),
('FLIP-1147','BTEE-BLU-67Y',1,329,32.9,14.81),
('FLIP-1147','BSHT-GRY-89Y',1,349,34.9,15.71),
('FLIP-1147','BSHF-WHT-1011Y',1,599,59.9,26.96),
('AMAZ-1191','MCHN-OLV-32',1,1199,59.95,56.95),
('AMAZ-1191','MPOL-MRN-L',1,699,34.95,33.2),
('AMAZ-1191','MSHF-WHT-XL',1,999,49.95,47.45),
('SHOP-1149','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1150','MSHC-GRN-XL',1,899,0.0,44.95),
('FLIP-1148','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1148','WPAL-YLW-XL',3,599,0.0,89.85)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1148','Xpressbees - Pandesara'),
('SHOP-1150','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1098');
select pg_temp.ret_recv('SHOP-1121');
select pg_temp.ret_recv('AMAZ-1140');
select pg_temp.rto_recv('SHOP-1129', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1132', 'in_transit');
select pg_temp.ret_new('AMAZ-1160', 'Size did not fit', 'webhook');
select pg_temp.ret_new('AMAZ-1164', 'Colour different from photo', 'webhook');
select pg_temp.retime();

-- Sun 21 Jun 2026
select pg_temp.day('2026-06-21');
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Krishna Denim Works (ref R074)', 'DC-KDW-0088', '[{"sku":"WJNS-BLK-32","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Krishna Denim Works (ref R075)', 'DC-KDW-0091', '[{"sku":"MCHN-OLV-32","q":8,"a":8,"r":0},{"sku":"WJNS-BLK-28","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Little Stitch Garments (ref R076)', 'LSG/26/0221', 1);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R080)', 'SAT/26/0198', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1151','Shopify - Main Store','2026-06-21 11:37+05:30','Foram Thakkar','cod',558.0,0.0,27.9,585.9,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1152','Shopify - Main Store','2026-06-21 13:11+05:30','Prachi Kulkarni','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1192','Amazon - Seller Central','2026-06-21 11:45+05:30','Sanjay Gajera','prepaid',349.0,34.9,15.71,329.81,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1149','Flipkart - Seller Hub','2026-06-21 21:16+05:30','Kiran Naik','prepaid',949.0,94.9,42.71,896.81,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1193','Amazon - Seller Central','2026-06-21 15:06+05:30','Heena Khan','prepaid',1948.0,97.4,92.53,1943.13,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1194','Amazon - Seller Central','2026-06-21 17:25+05:30','Nikhil Pandey','prepaid',3344.0,0.0,167.2,3511.2,'delivered','paid','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1151','GLEG-BLK-89Y',1,279,0.0,13.95),
('SHOP-1151','GLEG-PNK-67Y',1,279,0.0,13.95),
('SHOP-1152','GTOP-WHT-89Y',1,349,0.0,17.45),
('AMAZ-1192','WLEG-BLK-L',1,349,34.9,15.71),
('FLIP-1149','BKUR-CRM-89Y',1,949,94.9,42.71),
('AMAZ-1193','WJNS-BLK-30',1,1349,67.45,64.08),
('AMAZ-1193','WTOP-PCH-M',1,599,29.95,28.45),
('AMAZ-1194','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1194','WKRT-PNK-M',1,849,0.0,42.45),
('AMAZ-1194','WLEG-BLK-L',2,349,0.0,34.9),
('AMAZ-1194','WTOP-PCH-M',2,599,0.0,59.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1151','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1098', 'good', 'restocked');
select pg_temp.ret_dispo('AMAZ-1140', 'missing', 'claimed');
select pg_temp.ret_set('SHOP-1128', 'in_transit');
select pg_temp.ret_new('AMAZ-1158', 'Item arrived damaged', 'webhook');
select pg_temp.ret_set('AMAZ-1160', 'approved');
select pg_temp.ret_set('AMAZ-1164', 'approved');
select pg_temp.rto_set('SHOP-1139', 'in_transit');
select pg_temp.ret_new('SHOP-1140', 'Wrong item delivered', 'webhook');
select pg_temp.cod_collect(array['FLIP-1128']::text[]);
select pg_temp.cod_collect(array['AMAZ-1185']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260608', 0.0);
select pg_temp.claim_step('AMAZ-1128', 'damaged_return', 'claimed', null);
select pg_temp.claim_new('AMAZ-1140', 'lost_shipment', 2045.4, '2026-07-21');
select pg_temp.retime();

-- Mon 22 Jun 2026
select pg_temp.day('2026-06-22');
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Krishna Denim Works (ref R074)', 'KDW/26/0213', 1);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Krishna Denim Works (ref R075)', 'KDW/26/0224', 1);
select pg_temp.po_new('Weekly replenishment 22 Jun 2026 - Krishna Denim Works (ref R083)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-IND-34","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 22 Jun 2026 - Little Stitch Garments (ref R084)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"BSHT-GRY-67Y","q":6},{"sku":"BKUR-CRM-89Y","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 22 Jun 2026 - Ludhiana Winter Wear Co (ref R085)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"BTRK-BLK-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 22 Jun 2026 - Rajdhani Shirting Mills (ref R086)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHC-GRN-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 22 Jun 2026 - Rajdhani Shirting Mills (ref R087)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-GRN-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 22 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R088)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"WTOP-PCH-L","q":14},{"sku":"BTEE-BLU-89Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 22 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R089)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTEE-WHT-L","q":6},{"sku":"MPOL-NVY-XL","q":6},{"sku":"MPOL-MRN-XL","q":6},{"sku":"WTOP-PCH-M","q":22},{"sku":"GTOP-YLW-67Y","q":6}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1153','Shopify - Main Store','2026-06-22 13:19+05:30','Aarav Mehta','prepaid',10998.0,0.0,1979.64,12977.64,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1154','Shopify - Main Store','2026-06-22 14:15+05:30','Ritu Saxena','cod',6595.0,329.75,313.26,6578.51,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1150','Flipkart - Seller Hub','2026-06-22 14:40+05:30','Aarav Mehta','prepaid',2477.0,0.0,123.85,2600.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1195','Amazon - Seller Central','2026-06-22 15:18+05:30','Nikhil Pandey','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1196','Amazon - Seller Central','2026-06-22 11:43+05:30','Isha Gupta','prepaid',1596.0,79.8,75.82,1592.02,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1155','Shopify - Main Store','2026-06-22 15:27+05:30','Karan Malhotra','prepaid',2199.0,0.0,109.95,2308.95,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1153','WLHG-MAG-M',2,5499,0.0,1979.64),
('SHOP-1154','MJNS-IND-34',3,1399,209.85,199.36),
('SHOP-1154','MCHN-OLV-34',1,1199,59.95,56.95),
('SHOP-1154','MCHN-OLV-30',1,1199,59.95,56.95),
('FLIP-1150','WKRT-PNK-M',2,849,0.0,84.9),
('FLIP-1150','GJNS-IND-45Y',1,779,0.0,38.95),
('AMAZ-1195','WPAL-WHT-L',1,599,0.0,29.95),
('AMAZ-1196','WLEG-MAR-M',2,349,34.9,33.16),
('AMAZ-1196','MTEE-WHT-M',2,449,44.9,42.66),
('SHOP-1155','WSAR-RED-FREE',1,2199,0.0,109.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1154','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('SHOP-1121', 'damaged', 'quarantined');
select pg_temp.ret_recv('SHOP-1132');
select pg_temp.ret_new('AMAZ-1156', 'Size did not fit', 'webhook');
select pg_temp.ret_set('AMAZ-1158', 'approved');
select pg_temp.ret_set('AMAZ-1160', 'pickup');
select pg_temp.ret_new('AMAZ-1162', 'Wrong item delivered', 'webhook');
select pg_temp.ret_set('AMAZ-1164', 'pickup');
select pg_temp.ret_set('SHOP-1140', 'approved');
select pg_temp.cod_collect(array['FLIP-1130']::text[]);
select pg_temp.cod_collect(array['FLIP-1131']::text[]);
select pg_temp.cod_collect(array['FLIP-1132']::text[]);
select pg_temp.cod_collect(array['FLIP-1140']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260615', '2026-06-15', '2026-06-21', array['AMAZ-1156','AMAZ-1154','AMAZ-1162','AMAZ-1163','AMAZ-1158','AMAZ-1166','AMAZ-1157','AMAZ-1159','AMAZ-1160','AMAZ-1161','AMAZ-1164','AMAZ-1168','AMAZ-1169','AMAZ-1173','AMAZ-1172','AMAZ-1175','AMAZ-1167','AMAZ-1170','AMAZ-1176','AMAZ-1171','AMAZ-1177','AMAZ-1178','AMAZ-1182']::text[], array['AMAZ-1118','AMAZ-1128','AMAZ-1140']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260615', '2026-06-15', '2026-06-21', array['FLIP-1115','FLIP-1119','FLIP-1123','FLIP-1125','FLIP-1121','FLIP-1124','FLIP-1127','FLIP-1129','FLIP-1133','FLIP-1136','FLIP-1141']::text[], array['FLIP-1098']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260615', '2026-06-15', '2026-06-21', array['SHOP-1135','SHOP-1137','SHOP-1136','SHOP-1140','SHOP-1143','SHOP-1141','SHOP-1142']::text[], array[]::text[]);
select pg_temp.claim_recover('AMAZ-1076', 'other', 'CLAIM-CR-AMAZ-1076');
select pg_temp.retime();

-- Tue 23 Jun 2026
select pg_temp.day('2026-06-23');
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Rajdhani Shirting Mills (ref R078)', 'DC-RSM-0106', '[{"sku":"MSHF-WHT-XL","q":2,"a":2,"r":0},{"sku":"MSHC-RED-M","q":5,"a":5,"r":0},{"sku":"MSHC-GRN-M","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R079)', 'DC-SAT-0079', '[{"sku":"WPAL-YLW-L","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R081)', 'DC-TKF-0112', '[{"sku":"WLEG-NVY-M","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R082)', 'DC-TKF-0115', '[{"sku":"MTEE-WHT-L","q":4,"a":4,"r":0},{"sku":"MPOL-NVY-M","q":4,"a":4,"r":0},{"sku":"GTOP-YLW-67Y","q":4,"a":4,"r":0},{"sku":"GLEG-BLK-89Y","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1156','Shopify - Main Store','2026-06-23 10:12+05:30','Isha Gupta','cod',2395.0,0.0,119.75,2514.75,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1197','Amazon - Seller Central','2026-06-23 13:22+05:30','Bhavna Solanki','prepaid',4295.0,214.75,204.01,4284.26,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1198','Amazon - Seller Central','2026-06-23 20:43+05:30','Dev Trivedi','prepaid',1199.0,59.95,56.95,1196.0,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1199','Amazon - Seller Central','2026-06-23 12:25+05:30','Mitul Dave','prepaid',1448.0,0.0,72.4,1520.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1200','Amazon - Seller Central','2026-06-23 19:19+05:30','Divya Nair','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1157','Shopify - Main Store','2026-06-23 18:42+05:30','Anjali Verma','cod',3097.0,309.7,139.38,2926.68,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1151','Flipkart - Seller Hub','2026-06-23 22:36+05:30','Yash Vora','prepaid',3997.0,0.0,199.85,4196.85,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1156','GJNS-IND-67Y',2,779,0.0,77.9),
('SHOP-1156','GLEG-PNK-89Y',3,279,0.0,41.85),
('AMAZ-1197','MKUR-MUS-M',1,1099,54.95,52.2),
('AMAZ-1197','MJNS-BLK-30',1,1399,69.95,66.45),
('AMAZ-1197','MTEE-BLK-L',2,449,44.9,42.66),
('AMAZ-1197','MSHC-GRN-M',1,899,44.95,42.7),
('AMAZ-1198','MCHN-OLV-34',1,1199,59.95,56.95),
('AMAZ-1199','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1199','WKRT-PNK-M',1,849,0.0,42.45),
('AMAZ-1200','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1157','GLHG-TEL-67Y',1,1999,199.9,89.96),
('SHOP-1157','GFRK-PNK-45Y',1,749,74.9,33.71),
('SHOP-1157','GTOP-WHT-67Y',1,349,34.9,15.71),
('FLIP-1151','MJNS-BLK-34',2,1399,0.0,139.9),
('FLIP-1151','MCHN-OLV-34',1,1199,0.0,59.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1156','Xpressbees - Pandesara'),
('SHOP-1157','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1121', 'UPI-REFUND-SHOP-1121');
select pg_temp.ret_set('AMAZ-1156', 'approved');
select pg_temp.ret_set('AMAZ-1158', 'pickup');
select pg_temp.ret_set('AMAZ-1162', 'approved');
select pg_temp.ret_new('AMAZ-1166', 'Item arrived damaged', 'webhook');
select pg_temp.ret_set('SHOP-1140', 'pickup');
select pg_temp.cod_collect(array['FLIP-1142']::text[]);
select pg_temp.cod_collect(array['FLIP-1144']::text[]);
select pg_temp.cod_collect(array['SHOP-1150']::text[]);
select pg_temp.settle_pay('FLK-STL-20260608', 0.0);
select pg_temp.claim_step('AMAZ-1099', 'incorrect_deduction', 'approved', 256.0);
select pg_temp.retime();

-- Wed 24 Jun 2026
select pg_temp.day('2026-06-24');
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Little Stitch Garments (ref R076)', 'DC-LSG-0094', '[{"sku":"BSHT-NVY-45Y","q":2,"a":2,"r":0},{"sku":"BKUR-CRM-45Y","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Rajdhani Shirting Mills (ref R078)', 'RSM/26/0260', 1);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R079)', 'SAT/26/0191', 1);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R080)', 'DC-SAT-0085', '[{"sku":"WKRT-TEL-XL","q":3,"a":3,"r":0},{"sku":"WLHG-RED-L","q":3,"a":3,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R081)', 'TKF/26/0271', 1);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R082)', 'TKF/26/0278', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1201','Amazon - Seller Central','2026-06-24 16:30+05:30','Bhavna Solanki','prepaid',1328.0,0.0,66.4,1394.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1158','Shopify - Main Store','2026-06-24 21:32+05:30','Heena Khan','prepaid',698.0,0.0,34.9,732.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1159','Shopify - Main Store','2026-06-24 10:00+05:30','Nidhi Agarwal','cod',1657.0,0.0,82.85,1739.85,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1152','Flipkart - Seller Hub','2026-06-24 19:43+05:30','Harsh Modi','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1153','Flipkart - Seller Hub','2026-06-24 17:17+05:30','Rohit Iyer','prepaid',1948.0,0.0,97.4,2045.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1201','BTRK-BLK-67Y',1,999,0.0,49.95),
('AMAZ-1201','BTEE-RED-89Y',1,329,0.0,16.45),
('SHOP-1158','GTOP-WHT-45Y',2,349,0.0,34.9),
('SHOP-1159','BTRK-BLK-45Y',1,999,0.0,49.95),
('SHOP-1159','BTEE-RED-89Y',2,329,0.0,32.9),
('FLIP-1152','BKUR-CRM-89Y',1,949,0.0,47.45),
('FLIP-1153','WTOP-PCH-S',1,599,0.0,29.95),
('FLIP-1153','WJNS-IND-28',1,1349,0.0,67.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1159','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('SHOP-1132', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1156', 'pickup');
select pg_temp.ret_new('AMAZ-1159', 'Fabric quality not as expected', 'webhook');
select pg_temp.ret_set('AMAZ-1160', 'in_transit');
select pg_temp.ret_set('AMAZ-1162', 'pickup');
select pg_temp.ret_set('AMAZ-1164', 'in_transit');
select pg_temp.ret_set('AMAZ-1166', 'approved');
select pg_temp.ret_new('FLIP-1138', 'Item arrived damaged', 'webhook');
select pg_temp.settle_pay('SHP-STL-20260615', 0.0);
select pg_temp.claim_step('AMAZ-1140', 'lost_shipment', 'claimed', null);
select pg_temp.retime();

-- Thu 25 Jun 2026
select pg_temp.day('2026-06-25');
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Krishna Denim Works (ref R075)', 'DC-KDW-0094', '[{"sku":"MCHN-OLV-32","q":4,"a":4,"r":0},{"sku":"WJNS-BLK-28","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Little Stitch Garments (ref R076)', 'LSG/26/0231', 1);
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Ludhiana Winter Wear Co (ref R077)', 'DC-LWW-0049', '[{"sku":"BTRK-BLK-89Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Shree Ambika Textiles (ref R080)', 'SAT/26/0206', 1);
select pg_temp.grn_new('Weekly replenishment 22 Jun 2026 - Little Stitch Garments (ref R084)', 'DC-LSG-0097', '[{"sku":"BSHT-GRY-67Y","q":6,"a":6,"r":0},{"sku":"BKUR-CRM-89Y","q":12,"a":12,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1202','Amazon - Seller Central','2026-06-25 20:51+05:30','Riya Shah','prepaid',1298.0,0.0,64.9,1362.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1203','Amazon - Seller Central','2026-06-25 14:28+05:30','Aarav Mehta','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1204','Amazon - Seller Central','2026-06-25 21:57+05:30','Chirag Zaveri','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1154','Flipkart - Seller Hub','2026-06-25 16:23+05:30','Sagar Rathod','prepaid',4446.0,0.0,222.3,4668.3,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('FLIP-1155','Flipkart - Seller Hub','2026-06-25 15:56+05:30','Pooja Jain','cod',928.0,0.0,46.4,974.4,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1205','Amazon - Seller Central','2026-06-25 16:57+05:30','Anjali Verma','cod',5855.0,585.5,707.97,5977.47,'shipped','pending','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1202','GNGT-PNK-1011Y',1,549,0.0,27.45),
('AMAZ-1202','GFRK-LIL-45Y',1,749,0.0,37.45),
('AMAZ-1203','BKUR-CRM-89Y',2,949,0.0,94.9),
('AMAZ-1204','GLEG-PNK-67Y',1,279,0.0,13.95),
('FLIP-1154','MCHN-KHK-30',2,1199,0.0,119.9),
('FLIP-1154','MTRK-BLK-XL',1,649,0.0,32.45),
('FLIP-1154','MJNS-BLK-32',1,1399,0.0,69.95),
('FLIP-1155','BTEE-BLU-67Y',1,329,0.0,16.45),
('FLIP-1155','BSHF-WHT-1011Y',1,599,0.0,29.95),
('AMAZ-1205','GNGT-PNK-67Y',1,549,54.9,24.71),
('AMAZ-1205','BKUR-CRM-89Y',1,949,94.9,42.71),
('AMAZ-1205','MBLZ-NVY-38',1,3799,379.9,615.44),
('AMAZ-1205','GLEG-PNK-67Y',2,279,55.8,25.11)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1155','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('SHOP-1128');
select pg_temp.ret_set('AMAZ-1158', 'in_transit');
select pg_temp.ret_set('AMAZ-1159', 'approved');
select pg_temp.ret_new('AMAZ-1161', 'Item arrived damaged', 'webhook');
select pg_temp.ret_set('AMAZ-1166', 'pickup');
select pg_temp.ret_set('SHOP-1140', 'in_transit');
select pg_temp.ret_set('FLIP-1138', 'approved');
select pg_temp.cod_collect(array['SHOP-1146']::text[]);
select pg_temp.cod_collect(array['SHOP-1148']::text[]);
select pg_temp.retime();

-- Fri 26 Jun 2026
select pg_temp.day('2026-06-26');
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Krishna Denim Works (ref R075)', 'KDW/26/0229', 1);
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Ludhiana Winter Wear Co (ref R077)', 'LWW/26/0121', 1);
select pg_temp.bill_po('Weekly replenishment 22 Jun 2026 - Little Stitch Garments (ref R084)', 'LSG/26/0236', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1156','Flipkart - Seller Hub','2026-06-26 17:31+05:30','Anjali Verma','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1156','WTOP-WHT-M',1,599,29.95,28.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('SHOP-1128', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1156', 'in_transit');
select pg_temp.ret_set('AMAZ-1159', 'pickup');
select pg_temp.ret_recv('AMAZ-1160');
select pg_temp.ret_set('AMAZ-1161', 'approved');
select pg_temp.ret_set('AMAZ-1162', 'in_transit');
select pg_temp.rto_recv('SHOP-1139', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1138', 'pickup');
select pg_temp.cod_collect(array['SHOP-1151']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-26JUN', array['FLIP-1128','FLIP-1140','AMAZ-1185']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-26JUN', array['FLIP-1126','FLIP-1131']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-26JUN', array['FLIP-1120','FLIP-1132','SHOP-1150']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-26JUN', array['FLIP-1130','FLIP-1142','FLIP-1144']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-06-29', 'ICIC000000883861', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-06-29', 'ICIC000000883908', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-06-29', 'ICIC000000883996', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-06-29', 'ICIC000000884053', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-06-29', 'ICIC000000884077', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-06-29', 'ICIC000000884105', 1);
select pg_temp.claim_step('AMAZ-1104', 'damaged_return', 'approved', 1121.9);
select pg_temp.retime();

-- Sat 27 Jun 2026
select pg_temp.day('2026-06-27');
select pg_temp.grn_new('Weekly replenishment 15 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R082)', 'DC-TKF-0118', '[{"sku":"MTEE-WHT-L","q":2,"a":2,"r":0},{"sku":"MPOL-NVY-M","q":2,"a":2,"r":0},{"sku":"GTOP-YLW-67Y","q":2,"a":2,"r":0},{"sku":"GLEG-BLK-89Y","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 22 Jun 2026 - Krishna Denim Works (ref R083)', 'DC-KDW-0097', '[{"sku":"MJNS-IND-34","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 22 Jun 2026 - Rajdhani Shirting Mills (ref R086)', 'DC-RSM-0109', '[{"sku":"MSHC-GRN-M","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 22 Jun 2026 - Rajdhani Shirting Mills (ref R087)', 'DC-RSM-0115', '[{"sku":"MSHC-GRN-XL","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1157','Flipkart - Seller Hub','2026-06-27 09:32+05:30','Kavya Menon','prepaid',549.0,0.0,27.45,576.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1158','Flipkart - Seller Hub','2026-06-27 10:29+05:30','Foram Thakkar','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1206','Amazon - Seller Central','2026-06-27 15:59+05:30','Pooja Jain','prepaid',1048.0,0.0,52.4,1100.4,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1207','Amazon - Seller Central','2026-06-27 20:47+05:30','Kiran Naik','prepaid',1377.0,0.0,68.85,1445.85,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1157','GNGT-PNK-1011Y',1,549,0.0,27.45),
('FLIP-1158','GTOP-WHT-67Y',1,349,0.0,17.45),
('AMAZ-1206','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1206','WDUP-SLV-FREE',1,449,0.0,22.45),
('AMAZ-1207','GLEG-BLK-67Y',1,279,0.0,13.95),
('AMAZ-1207','GFRK-PNK-67Y',1,749,0.0,37.45),
('AMAZ-1207','GTOP-YLW-89Y',1,349,0.0,17.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_refund_d2c('SHOP-1132', 'UPI-REFUND-SHOP-1132');
select pg_temp.ret_recv('AMAZ-1158');
select pg_temp.ret_dispo('AMAZ-1160', 'wrong_item', 'claimed');
select pg_temp.ret_set('AMAZ-1161', 'pickup');
select pg_temp.ret_recv('AMAZ-1164');
select pg_temp.ret_set('AMAZ-1166', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1154']::text[]);
select pg_temp.claim_recover('FLIP-1066', 'damaged_return', 'CLAIM-CR-FLIP-1066');
select pg_temp.claim_new('AMAZ-1160', 'other', 3184.82, '2026-07-27');
select pg_temp.retime();

-- Sun 28 Jun 2026
select pg_temp.day('2026-06-28');
select pg_temp.bill_po('Weekly replenishment 15 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R082)', 'TKF/26/0283', 1);
select pg_temp.bill_po('Weekly replenishment 22 Jun 2026 - Krishna Denim Works (ref R083)', 'KDW/26/0233', 1);
select pg_temp.bill_po('Weekly replenishment 22 Jun 2026 - Rajdhani Shirting Mills (ref R086)', 'RSM/26/0261', 1);
select pg_temp.bill_po('Weekly replenishment 22 Jun 2026 - Rajdhani Shirting Mills (ref R087)', 'RSM/26/0276', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1160','Shopify - Main Store','2026-06-28 19:45+05:30','Bhavna Solanki','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1161','Shopify - Main Store','2026-06-28 11:23+05:30','Rahul Bhatt','prepaid',8245.0,824.5,1014.42,8434.92,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1162','Shopify - Main Store','2026-06-28 14:16+05:30','Sonal Parekh','prepaid',9696.0,0.0,1199.67,10895.67,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1163','Shopify - Main Store','2026-06-28 19:18+05:30','Kavya Menon','cod',2146.0,107.3,101.94,2140.64,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1208','Amazon - Seller Central','2026-06-28 21:01+05:30','Chirag Zaveri','prepaid',849.0,84.9,38.21,802.31,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1164','Shopify - Main Store','2026-06-28 17:06+05:30','Aarav Mehta','cod',1328.0,0.0,66.4,1394.4,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1165','Shopify - Main Store','2026-06-28 19:21+05:30','Kiran Naik','cod',6098.0,0.0,1019.77,7117.77,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1209','Amazon - Seller Central','2026-06-28 11:27+05:30','Karan Malhotra','prepaid',3346.0,0.0,167.3,3513.3,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1159','Flipkart - Seller Hub','2026-06-28 11:54+05:30','Rohit Iyer','prepaid',4497.0,0.0,224.85,4721.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1160','Flipkart - Seller Hub','2026-06-28 17:49+05:30','Vivek Singh','cod',1797.0,0.0,89.85,1886.85,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1210','Amazon - Seller Central','2026-06-28 12:25+05:30','Mehul Shukla','prepaid',2396.0,0.0,119.8,2515.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1211','Amazon - Seller Central','2026-06-28 18:54+05:30','Kavya Menon','prepaid',987.0,0.0,49.35,1036.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1161','Flipkart - Seller Hub','2026-06-28 10:23+05:30','Kiran Naik','prepaid',3247.0,324.7,146.12,3068.42,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1166','Shopify - Main Store','2026-06-28 11:14+05:30','Rahul Bhatt','cod',599.0,29.95,28.45,597.5,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1212','Amazon - Seller Central','2026-06-28 13:11+05:30','Aarav Mehta','prepaid',3197.0,0.0,159.85,3356.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1213','Amazon - Seller Central','2026-06-28 17:02+05:30','Chirag Zaveri','prepaid',1499.0,149.9,67.46,1416.56,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1160','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1161','WKRT-PNK-S',2,849,169.8,76.41),
('SHOP-1161','WLHG-RED-M',1,5499,549.9,890.84),
('SHOP-1161','WTOP-WHT-L',1,599,59.9,26.96),
('SHOP-1161','WDUP-GLD-FREE',1,449,44.9,20.21),
('SHOP-1162','WJNS-IND-32',1,1349,0.0,67.45),
('SHOP-1162','WDRS-FLR-L',1,1499,0.0,74.95),
('SHOP-1162','WJNS-BLK-28',1,1349,0.0,67.45),
('SHOP-1162','WLHG-RED-L',1,5499,0.0,989.82),
('SHOP-1163','WTOP-WHT-M',2,599,59.9,56.91),
('SHOP-1163','WTOP-WHT-L',1,599,29.95,28.45),
('SHOP-1163','BSHT-GRY-89Y',1,349,17.45,16.58),
('AMAZ-1208','WKRT-TEL-XL',1,849,84.9,38.21),
('SHOP-1164','GJNS-IND-45Y',1,779,0.0,38.95),
('SHOP-1164','GNGT-PNK-1011Y',1,549,0.0,27.45),
('SHOP-1165','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1165','WLHG-MAG-L',1,5499,0.0,989.82),
('AMAZ-1209','WDRS-FLP-S',1,1499,0.0,74.95),
('AMAZ-1209','GFRK-LIL-89Y',2,749,0.0,74.9),
('AMAZ-1209','BSHT-GRY-67Y',1,349,0.0,17.45),
('FLIP-1159','WDRS-FLP-L',2,1499,0.0,149.9),
('FLIP-1159','WDRS-FLP-S',1,1499,0.0,74.95),
('FLIP-1160','WTOP-PCH-S',2,599,0.0,59.9),
('FLIP-1160','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1210','WTOP-WHT-M',3,599,0.0,89.85),
('AMAZ-1210','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1211','BTEE-RED-45Y',3,329,0.0,49.35),
('FLIP-1161','MJNS-IND-34',2,1399,279.8,125.91),
('FLIP-1161','MTEE-BLK-M',1,449,44.9,20.21),
('SHOP-1166','WPAL-YLW-L',1,599,29.95,28.45),
('AMAZ-1212','MSHC-RED-L',2,899,0.0,89.9),
('AMAZ-1212','MJNS-IND-34',1,1399,0.0,69.95),
('AMAZ-1213','WDRS-FLP-M',1,1499,149.9,67.46)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1163','Delhivery - Sachin GIDC Surat'),
('SHOP-1164','Ecom Express - Udhna Hub'),
('SHOP-1165','Xpressbees - Pandesara'),
('FLIP-1160','Delhivery - Sachin GIDC Surat'),
('SHOP-1166','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1158', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1159', 'in_transit');
select pg_temp.ret_recv('AMAZ-1162');
select pg_temp.ret_dispo('AMAZ-1164', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1138', 'in_transit');
select pg_temp.ret_new('FLIP-1148', 'Colour different from photo', 'webhook');
select pg_temp.cod_collect(array['SHOP-1157']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260615', 0.0);
select pg_temp.claim_step('AMAZ-1116', 'damaged_return', 'approved', null);
select pg_temp.claim_new('AMAZ-1158', 'damaged_return', 659.61, '2026-07-28');
select pg_temp.retime();

-- Mon 29 Jun 2026
select pg_temp.day('2026-06-29');
select pg_temp.po_new('Weekly replenishment 29 Jun 2026 - Krishna Denim Works (ref R090)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MJNS-BLK-30","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 29 Jun 2026 - Little Stitch Garments (ref R091)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"GNGT-PNK-67Y","q":6},{"sku":"GNGT-PNK-1011Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 29 Jun 2026 - Shree Ambika Textiles (ref R092)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WKRT-PNK-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 29 Jun 2026 - Shree Ambika Textiles (ref R093)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WDUP-GLD-FREE","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 29 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R094)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-BLK-L","q":6},{"sku":"WTOP-PCH-L","q":14}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 29 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R095)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MPOL-MRN-XL","q":6},{"sku":"WTOP-WHT-M","q":28},{"sku":"WTOP-PCH-M","q":20},{"sku":"WTOP-PCH-L","q":18},{"sku":"GTOP-WHT-67Y","q":6},{"sku":"GLEG-BLK-67Y","q":12}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1167','Shopify - Main Store','2026-06-29 15:29+05:30','Shreya Banerjee','cod',1607.0,80.35,76.34,1602.99,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1214','Amazon - Seller Central','2026-06-29 14:29+05:30','Aditi Joshi','prepaid',3176.0,0.0,158.8,3334.8,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1215','Amazon - Seller Central','2026-06-29 21:45+05:30','Yash Vora','prepaid',3996.0,399.6,179.83,3776.23,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1168','Shopify - Main Store','2026-06-29 15:09+05:30','Foram Thakkar','prepaid',977.0,48.85,46.41,974.56,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1169','Shopify - Main Store','2026-06-29 11:51+05:30','Meghna Rao','prepaid',2948.0,0.0,147.4,3095.4,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1170','Shopify - Main Store','2026-06-29 17:34+05:30','Ritu Saxena','prepaid',3997.0,0.0,199.85,4196.85,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1167','BTEE-RED-45Y',2,329,32.9,31.26),
('SHOP-1167','BKUR-MUS-45Y',1,949,47.45,45.08),
('AMAZ-1214','BKUR-MUS-45Y',3,949,0.0,142.35),
('AMAZ-1214','BTEE-RED-89Y',1,329,0.0,16.45),
('AMAZ-1215','MPOL-NVY-XL',2,699,139.8,62.91),
('AMAZ-1215','MCHN-OLV-34',1,1199,119.9,53.96),
('AMAZ-1215','MJNS-IND-32',1,1399,139.9,62.96),
('SHOP-1168','GTOP-YLW-89Y',2,349,34.9,33.16),
('SHOP-1168','GLEG-PNK-45Y',1,279,13.95,13.25),
('SHOP-1169','GLHG-TEL-67Y',1,1999,0.0,99.95),
('SHOP-1169','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1170','MJNS-BLK-30',2,1399,0.0,139.9),
('SHOP-1170','MCHN-OLV-30',1,1199,0.0,59.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1167','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1128', 'UPI-REFUND-SHOP-1128');
select pg_temp.ret_recv('AMAZ-1156');
select pg_temp.ret_set('AMAZ-1161', 'in_transit');
select pg_temp.ret_recv('AMAZ-1166');
select pg_temp.ret_recv('SHOP-1140');
select pg_temp.ret_new('AMAZ-1188', 'Fabric quality not as expected', 'webhook');
select pg_temp.ret_set('FLIP-1148', 'approved');
select pg_temp.cod_collect(array['SHOP-1156']::text[]);
select pg_temp.rto_new('AMAZ-1205', 'AWB31000512', 'Delivery attempts exhausted');
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260622', '2026-06-22', '2026-06-28', array['AMAZ-1174','AMAZ-1188','AMAZ-1179','AMAZ-1180','AMAZ-1184','AMAZ-1186','AMAZ-1187','AMAZ-1191','AMAZ-1181','AMAZ-1183','AMAZ-1192','AMAZ-1196','AMAZ-1189','AMAZ-1190','AMAZ-1193','AMAZ-1194','AMAZ-1199','AMAZ-1195']::text[], array['AMAZ-1160','AMAZ-1158','AMAZ-1164','AMAZ-1162']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260622', '2026-06-22', '2026-06-28', array['FLIP-1134','FLIP-1135','FLIP-1137','FLIP-1138','FLIP-1139','FLIP-1145','FLIP-1146','FLIP-1143','FLIP-1147','FLIP-1148','FLIP-1149','FLIP-1150','FLIP-1151','FLIP-1152','FLIP-1153']::text[], array[]::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260622', '2026-06-22', '2026-06-28', array['SHOP-1144','SHOP-1149','SHOP-1145','SHOP-1147','SHOP-1152','SHOP-1153','SHOP-1155']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 30 Jun 2026
select pg_temp.day('2026-06-30');
select pg_temp.adjust('MSHC-GRN-M', 'Mumbai Fulfilment Center', -1);
select pg_temp.adjust('BKUR-CRM-89Y', 'Surat Main Warehouse', -1);
select pg_temp.adjust('WDUP-SLV-FREE', 'Surat Main Warehouse', -2);
select pg_temp.adjust('BKUR-CRM-89Y', 'Mumbai Fulfilment Center', -1);
select pg_temp.adjust('MTEE-WHT-XL', 'Surat Main Warehouse', -1);
select pg_temp.adjust('WLEG-BLK-M', 'Mumbai Fulfilment Center', -1);
select pg_temp.adjust('BSHT-GRY-89Y', 'Surat Main Warehouse', 1);
select pg_temp.adjust('MPOL-MRN-XL', 'Mumbai Fulfilment Center', -2);
select pg_temp.adjust('BKUR-MUS-45Y', 'Surat Main Warehouse', -1);
select pg_temp.adjust('GLEG-BLK-89Y', 'Mumbai Fulfilment Center', -1);
select pg_temp.adjust('WPAL-YLW-M', 'Surat Main Warehouse', -1);
select pg_temp.adjust('MHOD-BLK-M', 'Surat Main Warehouse', -1);
select pg_temp.adjust('WKRT-PNK-M', 'Surat Main Warehouse', -1);
select pg_temp.adjust('MJNS-IND-34', 'Surat Main Warehouse', -1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1162','Flipkart - Seller Hub','2026-06-30 20:39+05:30','Heena Khan','cod',6993.0,0.0,349.65,7342.65,'shipped','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1216','Amazon - Seller Central','2026-06-30 17:06+05:30','Mitul Dave','prepaid',2798.0,0.0,139.9,2937.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1171','Shopify - Main Store','2026-06-30 21:42+05:30','Dev Trivedi','cod',899.0,44.95,42.7,896.75,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('SHOP-1172','Shopify - Main Store','2026-06-30 19:22+05:30','Vivek Singh','cod',628.0,62.8,28.27,593.47,'shipped','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1217','Amazon - Seller Central','2026-06-30 21:09+05:30','Sagar Rathod','prepaid',1448.0,0.0,72.4,1520.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1218','Amazon - Seller Central','2026-06-30 19:20+05:30','Rahul Bhatt','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1162','MJNS-BLK-34',2,1399,0.0,139.9),
('FLIP-1162','WTOP-PCH-L',3,599,0.0,89.85),
('FLIP-1162','MCHN-KHK-30',2,1199,0.0,119.9),
('AMAZ-1216','MJNS-IND-32',2,1399,0.0,139.9),
('SHOP-1171','MSHC-RED-L',1,899,44.95,42.7),
('SHOP-1172','GTOP-WHT-67Y',1,349,34.9,15.71),
('SHOP-1172','GLEG-BLK-45Y',1,279,27.9,12.56),
('AMAZ-1217','WKRT-TEL-L',1,849,0.0,42.45),
('AMAZ-1217','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1218','WLEG-BLK-L',1,349,0.0,17.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1171','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1159');
select pg_temp.ret_dispo('AMAZ-1162', 'good', 'restocked');
select pg_temp.ret_dispo('AMAZ-1166', 'damaged', 'quarantined');
select pg_temp.ret_dispo('SHOP-1140', 'good', 'restocked');
select pg_temp.ret_new('AMAZ-1183', 'Colour different from photo', 'webhook');
select pg_temp.ret_set('AMAZ-1188', 'approved');
select pg_temp.ret_set('FLIP-1148', 'pickup');
select pg_temp.ret_new('AMAZ-1199', 'Customer changed mind', 'webhook');
select pg_temp.cod_collect(array['SHOP-1159']::text[]);
select pg_temp.cod_collect(array['FLIP-1155']::text[]);
select pg_temp.settle_pay('FLK-STL-20260615', 140.0);
select pg_temp.claim_recover('AMAZ-1064', 'lost_shipment', 'CLAIM-CR-AMAZ-1064');
select pg_temp.claim_step('AMAZ-1160', 'other', 'claimed', null);
select pg_temp.claim_new('AMAZ-1166', 'damaged_return', 660.24, '2026-07-30');
select pg_temp.retime();

-- Wed 01 Jul 2026
select pg_temp.day('2026-07-01');
select pg_temp.grn_new('Weekly replenishment 22 Jun 2026 - Ludhiana Winter Wear Co (ref R085)', 'DC-LWW-0052', '[{"sku":"BTRK-BLK-89Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 22 Jun 2026 - Rajdhani Shirting Mills (ref R086)', 'DC-RSM-0112', '[{"sku":"MSHC-GRN-M","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 22 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R088)', 'DC-TKF-0121', '[{"sku":"WTOP-PCH-L","q":14,"a":14,"r":0},{"sku":"BTEE-BLU-89Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 22 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R089)', 'DC-TKF-0124', '[{"sku":"MTEE-WHT-L","q":6,"a":6,"r":0},{"sku":"MPOL-NVY-XL","q":6,"a":6,"r":0},{"sku":"MPOL-MRN-XL","q":6,"a":6,"r":0},{"sku":"WTOP-PCH-M","q":22,"a":22,"r":0},{"sku":"GTOP-YLW-67Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1163','Flipkart - Seller Hub','2026-07-01 16:26+05:30','Ritu Saxena','prepaid',10295.0,1029.5,1352.26,10617.76,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1219','Amazon - Seller Central','2026-07-01 15:22+05:30','Ritu Saxena','cod',3597.0,0.0,179.85,3776.85,'delivered','pending','West Bengal','Surat Main Warehouse'),
('AMAZ-1220','Amazon - Seller Central','2026-07-01 11:38+05:30','Sejal Kapadia','cod',1698.0,0.0,84.9,1782.9,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1164','Flipkart - Seller Hub','2026-07-01 14:27+05:30','Dev Trivedi','cod',2298.0,114.9,109.15,2292.25,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1221','Amazon - Seller Central','2026-07-01 18:46+05:30','Yash Vora','prepaid',2935.0,0.0,146.75,3081.75,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1222','Amazon - Seller Central','2026-07-01 22:52+05:30','Sonal Parekh','cod',2947.0,0.0,147.35,3094.35,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1223','Amazon - Seller Central','2026-07-01 15:20+05:30','Sonal Parekh','prepaid',2598.0,259.8,116.92,2455.12,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1173','Shopify - Main Store','2026-07-01 15:30+05:30','Sonal Parekh','cod',1349.0,0.0,67.45,1416.45,'delivered','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1163','WTOP-PCH-S',1,599,59.9,26.96),
('FLIP-1163','MBLZ-NVY-40',2,3799,759.8,1230.88),
('FLIP-1163','MCHN-KHK-30',1,1199,119.9,53.96),
('FLIP-1163','MSHC-GRN-L',1,899,89.9,40.46),
('AMAZ-1219','MCHN-KHK-30',3,1199,0.0,179.85),
('AMAZ-1220','WKRT-PNK-S',2,849,0.0,84.9),
('FLIP-1164','MJNS-IND-34',1,1399,69.95,66.45),
('FLIP-1164','MSHC-RED-M',1,899,44.95,42.7),
('AMAZ-1221','WPAL-YLW-XL',1,599,0.0,29.95),
('AMAZ-1221','WJNS-IND-28',1,1349,0.0,67.45),
('AMAZ-1221','BTEE-BLU-67Y',3,329,0.0,49.35),
('AMAZ-1222','MKUR-WHT-L',1,1099,0.0,54.95),
('AMAZ-1222','MCHN-KHK-34',1,1199,0.0,59.95),
('AMAZ-1222','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1223','MJNS-BLK-32',1,1399,139.9,62.96),
('AMAZ-1223','MCHN-KHK-30',1,1199,119.9,53.96),
('SHOP-1173','WJNS-IND-32',1,1349,0.0,67.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1219','DTDC - Ring Road Surat'),
('AMAZ-1220','Delhivery - Sachin GIDC Surat'),
('FLIP-1164','Ecom Express - Udhna Hub'),
('AMAZ-1222','Xpressbees - Pandesara'),
('SHOP-1173','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1156', 'good', 'restocked');
select pg_temp.ret_recv('FLIP-1138');
select pg_temp.ret_set('AMAZ-1183', 'approved');
select pg_temp.ret_set('AMAZ-1188', 'pickup');
select pg_temp.ret_set('AMAZ-1199', 'approved');
select pg_temp.rto_set('AMAZ-1205', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1164']::text[]);
select pg_temp.settle_pay('SHP-STL-20260622', 0.0);
select pg_temp.claim_step('AMAZ-1158', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Thu 02 Jul 2026
select pg_temp.day('2026-07-02');
select pg_temp.bill_po('Weekly replenishment 22 Jun 2026 - Ludhiana Winter Wear Co (ref R085)', 'LWW/26/0132', 1);
select pg_temp.bill_po('Weekly replenishment 22 Jun 2026 - Rajdhani Shirting Mills (ref R086)', 'RSM/26/0274', 1);
select pg_temp.bill_po('Weekly replenishment 22 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R088)', 'TKF/26/0294', 1);
select pg_temp.bill_po('Weekly replenishment 22 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R089)', 'TKF/26/0301', 1);
select pg_temp.grn_new('Weekly replenishment 29 Jun 2026 - Shree Ambika Textiles (ref R093)', 'DC-SAT-0094', '[{"sku":"WDUP-GLD-FREE","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1174','Shopify - Main Store','2026-07-02 17:22+05:30','Sagar Rathod','prepaid',5244.0,524.4,235.99,4955.59,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1175','Shopify - Main Store','2026-07-02 10:48+05:30','Aarav Mehta','prepaid',1448.0,72.4,68.78,1444.38,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1165','Flipkart - Seller Hub','2026-07-02 12:28+05:30','Aarav Mehta','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1224','Amazon - Seller Central','2026-07-02 14:42+05:30','Rohit Iyer','prepaid',279.0,27.9,12.56,263.66,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1166','Flipkart - Seller Hub','2026-07-02 12:27+05:30','Chirag Zaveri','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1225','Amazon - Seller Central','2026-07-02 18:55+05:30','Anjali Verma','prepaid',3146.0,0.0,157.3,3303.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1226','Amazon - Seller Central','2026-07-02 13:01+05:30','Sonal Parekh','prepaid',3297.0,0.0,164.85,3461.85,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1174','MTRK-BLK-XL',3,649,194.7,87.62),
('SHOP-1174','MCHN-OLV-32',2,1199,239.8,107.91),
('SHOP-1174','MSHC-GRN-XL',1,899,89.9,40.46),
('SHOP-1175','WKRT-TEL-XL',1,849,42.45,40.33),
('SHOP-1175','WTOP-PCH-S',1,599,29.95,28.45),
('FLIP-1165','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1224','GLEG-BLK-67Y',1,279,27.9,12.56),
('FLIP-1166','WTOP-WHT-L',1,599,0.0,29.95),
('AMAZ-1225','WJNS-IND-28',1,1349,0.0,67.45),
('AMAZ-1225','WPAL-WHT-L',1,599,0.0,29.95),
('AMAZ-1225','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1225','WTOP-WHT-M',1,599,0.0,29.95),
('AMAZ-1226','MJNS-IND-32',1,1399,0.0,69.95),
('AMAZ-1226','MPOL-MRN-M',1,699,0.0,34.95),
('AMAZ-1226','MCHN-OLV-34',1,1199,0.0,59.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1159', 'good', 'restocked');
select pg_temp.ret_recv('AMAZ-1161');
select pg_temp.ret_set('AMAZ-1183', 'pickup');
select pg_temp.ret_set('FLIP-1148', 'in_transit');
select pg_temp.ret_set('AMAZ-1199', 'pickup');
select pg_temp.claim_step('AMAZ-1128', 'damaged_return', 'approved', null);
select pg_temp.claim_new('FLIP-1115', 'incorrect_deduction', 140.0, '2026-08-01');
select pg_temp.retime();

-- Fri 03 Jul 2026
select pg_temp.day('2026-07-03');
select pg_temp.grn_new('Weekly replenishment 29 Jun 2026 - Shree Ambika Textiles (ref R092)', 'DC-SAT-0088', '[{"sku":"WKRT-PNK-M","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 29 Jun 2026 - Shree Ambika Textiles (ref R093)', 'SAT/26/0228', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1167','Flipkart - Seller Hub','2026-07-03 09:11+05:30','Chirag Zaveri','prepaid',1047.0,0.0,52.35,1099.35,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1227','Amazon - Seller Central','2026-07-03 10:36+05:30','Aarav Mehta','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1228','Amazon - Seller Central','2026-07-03 18:52+05:30','Jigar Chauhan','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1176','Shopify - Main Store','2026-07-03 10:06+05:30','Prachi Kulkarni','prepaid',2495.0,0.0,124.75,2619.75,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1177','Shopify - Main Store','2026-07-03 11:18+05:30','Kavya Menon','cod',4796.0,479.6,215.83,4532.23,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1168','Flipkart - Seller Hub','2026-07-03 19:57+05:30','Chirag Zaveri','cod',1656.0,0.0,82.8,1738.8,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1178','Shopify - Main Store','2026-07-03 15:29+05:30','Amit Sethi','prepaid',2996.0,0.0,149.8,3145.8,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('SHOP-1179','Shopify - Main Store','2026-07-03 11:06+05:30','Foram Thakkar','cod',6197.0,0.0,1024.72,7221.72,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1169','Flipkart - Seller Hub','2026-07-03 10:07+05:30','Yash Vora','prepaid',2598.0,0.0,129.9,2727.9,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1167','WLEG-BLK-M',3,349,0.0,52.35),
('AMAZ-1227','GLEG-BLK-67Y',1,279,0.0,13.95),
('AMAZ-1228','GLEG-PNK-67Y',1,279,0.0,13.95),
('SHOP-1176','WTOP-PCH-S',3,599,0.0,89.85),
('SHOP-1176','WLEG-MAR-M',1,349,0.0,17.45),
('SHOP-1176','WLEG-MAR-L',1,349,0.0,17.45),
('SHOP-1177','BTRK-BLK-67Y',1,999,99.9,44.96),
('SHOP-1177','MCHN-OLV-30',1,1199,119.9,53.96),
('SHOP-1177','MHOD-GRY-L',2,1299,259.8,116.91),
('FLIP-1168','GLEG-PNK-45Y',2,279,0.0,27.9),
('FLIP-1168','GTOP-WHT-67Y',1,349,0.0,17.45),
('FLIP-1168','GFRK-LIL-45Y',1,749,0.0,37.45),
('SHOP-1178','WJNS-BLK-30',1,1349,0.0,67.45),
('SHOP-1178','WDUP-GLD-FREE',1,449,0.0,22.45),
('SHOP-1178','WTOP-WHT-M',2,599,0.0,59.9),
('SHOP-1179','WLHG-RED-L',1,5499,0.0,989.82),
('SHOP-1179','WLEG-NVY-M',2,349,0.0,34.9),
('FLIP-1169','GLHG-TEL-89Y',1,1999,0.0,99.95),
('FLIP-1169','WTOP-PCH-L',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1177','Delhivery - Sachin GIDC Surat'),
('SHOP-1179','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1140', 'UPI-REFUND-SHOP-1140');
select pg_temp.ret_dispo('FLIP-1138', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1188', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1165']::text[]);
select pg_temp.cod_collect(array['SHOP-1167']::text[]);
select pg_temp.cod_collect(array['SHOP-1171']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-03JUL', array['SHOP-1146','SHOP-1157']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-03JUL', array['SHOP-1151','SHOP-1159','FLIP-1155','SHOP-1164']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-03JUL', array['SHOP-1154']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-03JUL', array['SHOP-1148','SHOP-1156']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-07-06', 'ICIC000000884133', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-07-06', 'ICIC000000884207', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-07-06', 'ICIC000000884284', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-07-06', 'ICIC000000884330', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-07-06', 'ICIC000000884344', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-07-06', 'ICIC000000884412', 1);
select pg_temp.claim_step('AMAZ-1166', 'damaged_return', 'claimed', null);
select pg_temp.claim_new('FLIP-1138', 'damaged_return', 2291.82, '2026-08-02');
select pg_temp.retime();

-- Sat 04 Jul 2026
select pg_temp.day('2026-07-04');
select pg_temp.grn_new('Weekly replenishment 29 Jun 2026 - Little Stitch Garments (ref R091)', 'DC-LSG-0100', '[{"sku":"GNGT-PNK-67Y","q":6,"a":6,"r":0},{"sku":"GNGT-PNK-1011Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 29 Jun 2026 - Shree Ambika Textiles (ref R092)', 'SAT/26/0213', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1170','Flipkart - Seller Hub','2026-07-04 09:22+05:30','Ritu Saxena','prepaid',2598.0,0.0,129.9,2727.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1229','Amazon - Seller Central','2026-07-04 18:31+05:30','Dev Trivedi','prepaid',6194.0,309.7,294.22,6178.52,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1180','Shopify - Main Store','2026-07-04 19:58+05:30','Prachi Kulkarni','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1230','Amazon - Seller Central','2026-07-04 14:50+05:30','Harsh Modi','prepaid',3397.0,0.0,169.85,3566.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1231','Amazon - Seller Central','2026-07-04 20:35+05:30','Divya Nair','prepaid',2497.0,124.85,118.61,2490.76,'cancelled','refunded','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1181','Shopify - Main Store','2026-07-04 11:17+05:30','Sagar Rathod','prepaid',1298.0,0.0,64.9,1362.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1232','Amazon - Seller Central','2026-07-04 18:38+05:30','Riya Shah','prepaid',3946.0,0.0,197.3,4143.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1233','Amazon - Seller Central','2026-07-04 09:18+05:30','Anjali Verma','prepaid',2398.0,0.0,119.9,2517.9,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1234','Amazon - Seller Central','2026-07-04 20:31+05:30','Sonal Parekh','prepaid',1349.0,0.0,67.45,1416.45,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1170','MCHN-OLV-34',1,1199,0.0,59.95),
('FLIP-1170','MJNS-BLK-34',1,1399,0.0,69.95),
('AMAZ-1229','MCHN-KHK-30',2,1199,119.9,113.91),
('AMAZ-1229','MJNS-BLK-30',1,1399,69.95,66.45),
('AMAZ-1229','MSHF-WHT-L',1,999,49.95,47.45),
('AMAZ-1229','MPOL-MRN-M',2,699,69.9,66.41),
('SHOP-1180','WTOP-PCH-M',1,599,29.95,28.45),
('AMAZ-1230','MCHN-KHK-34',2,1199,0.0,119.9),
('AMAZ-1230','MSHF-SKY-M',1,999,0.0,49.95),
('AMAZ-1231','WPAL-YLW-M',1,599,29.95,28.45),
('AMAZ-1231','BKUR-CRM-45Y',2,949,94.9,90.16),
('SHOP-1181','MTRK-BLK-M',1,649,0.0,32.45),
('SHOP-1181','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1232','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1232','MSHF-WHT-XL',1,999,0.0,49.95),
('AMAZ-1232','MJNS-BLK-32',1,1399,0.0,69.95),
('AMAZ-1232','MSHC-RED-M',1,899,0.0,44.95),
('AMAZ-1233','MCHN-KHK-30',1,1199,0.0,59.95),
('AMAZ-1233','MCHN-KHK-34',1,1199,0.0,59.95),
('AMAZ-1234','WJNS-IND-28',1,1349,0.0,67.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1161', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1183', 'in_transit');
select pg_temp.ret_set('AMAZ-1199', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1163']::text[]);
select pg_temp.cod_collect(array['FLIP-1160']::text[]);
select pg_temp.cod_collect(array['SHOP-1166']::text[]);
select pg_temp.cod_collect(array['FLIP-1164']::text[]);
select pg_temp.claim_recover('AMAZ-1099', 'incorrect_deduction', 'CLAIM-CR-AMAZ-1099');
select pg_temp.claim_new('AMAZ-1161', 'damaged_return', 1374.76, '2026-08-03');
select pg_temp.retime();

-- Sun 05 Jul 2026
select pg_temp.day('2026-07-05');
select pg_temp.grn_new('Weekly replenishment 29 Jun 2026 - Krishna Denim Works (ref R090)', 'DC-KDW-0100', '[{"sku":"MJNS-BLK-30","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 29 Jun 2026 - Little Stitch Garments (ref R091)', 'LSG/26/0245', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1235','Amazon - Seller Central','2026-07-05 15:17+05:30','Kiran Naik','prepaid',3146.0,157.3,149.44,3138.14,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1236','Amazon - Seller Central','2026-07-05 14:02+05:30','Rohit Iyer','prepaid',558.0,0.0,27.9,585.9,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1182','Shopify - Main Store','2026-07-05 15:05+05:30','Harsh Modi','prepaid',3797.0,0.0,189.85,3986.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1171','Flipkart - Seller Hub','2026-07-05 15:34+05:30','Ritu Saxena','prepaid',2297.0,114.85,109.11,2291.26,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1172','Flipkart - Seller Hub','2026-07-05 14:00+05:30','Shreya Banerjee','prepaid',349.0,17.45,16.58,348.13,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1237','Amazon - Seller Central','2026-07-05 16:56+05:30','Tanvi Rana','prepaid',1947.0,97.35,92.48,1942.13,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1173','Flipkart - Seller Hub','2026-07-05 13:10+05:30','Harsh Modi','prepaid',279.0,0.0,13.95,292.95,'shipped','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1174','Flipkart - Seller Hub','2026-07-05 11:23+05:30','Amit Sethi','prepaid',1698.0,84.9,80.66,1693.76,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1175','Flipkart - Seller Hub','2026-07-05 17:53+05:30','Sagar Rathod','prepaid',2646.0,264.6,119.08,2500.48,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1235','WJNS-IND-32',1,1349,67.45,64.08),
('AMAZ-1235','WTOP-PCH-L',1,599,29.95,28.45),
('AMAZ-1235','WTOP-PCH-M',2,599,59.9,56.91),
('AMAZ-1236','GLEG-BLK-67Y',1,279,0.0,13.95),
('AMAZ-1236','GLEG-BLK-89Y',1,279,0.0,13.95),
('SHOP-1182','MJNS-IND-32',1,1399,0.0,69.95),
('SHOP-1182','MCHN-KHK-34',2,1199,0.0,119.9),
('FLIP-1171','WKRT-PNK-S',2,849,84.9,80.66),
('FLIP-1171','WTOP-PCH-L',1,599,29.95,28.45),
('FLIP-1172','WLEG-MAR-M',1,349,17.45,16.58),
('AMAZ-1237','MTRK-BLK-M',3,649,97.35,92.48),
('FLIP-1173','GLEG-PNK-67Y',1,279,0.0,13.95),
('FLIP-1174','WKRT-TEL-M',2,849,84.9,80.66),
('FLIP-1175','WKRT-TEL-M',2,849,169.8,76.41),
('FLIP-1175','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1175','WLEG-BLK-M',1,349,34.9,15.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.rto_recv('AMAZ-1205', 'good', 'restocked');
select pg_temp.rto_new('SHOP-1172', 'AWB31000533', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['AMAZ-1219']::text[]);
select pg_temp.cod_collect(array['AMAZ-1222']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260622', 0.0);
select pg_temp.claim_step('AMAZ-1140', 'lost_shipment', 'approved', 1636.32);
select pg_temp.claim_step('FLIP-1115', 'incorrect_deduction', 'claimed', null);
select pg_temp.retime();

-- Mon 06 Jul 2026
select pg_temp.day('2026-07-06');
select pg_temp.bill_po('Weekly replenishment 29 Jun 2026 - Krishna Denim Works (ref R090)', 'KDW/26/0244', 1);
select pg_temp.po_new('Weekly replenishment 06 Jul 2026 - Krishna Denim Works (ref R096)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MJNS-BLK-34","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Jul 2026 - Krishna Denim Works (ref R097)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-34","q":8},{"sku":"MCHN-KHK-30","q":14},{"sku":"MCHN-KHK-34","q":14}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Jul 2026 - Ludhiana Winter Wear Co (ref R098)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"BTRK-BLK-67Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Jul 2026 - Shree Ambika Textiles (ref R099)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WKRT-PNK-S","q":6},{"sku":"WPAL-YLW-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Jul 2026 - Shree Ambika Textiles (ref R100)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-TEL-M","q":6},{"sku":"WPAL-WHT-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R101)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTEE-BLK-L","q":6},{"sku":"MPOL-NVY-XL","q":6},{"sku":"GTOP-WHT-67Y","q":6},{"sku":"GLEG-PNK-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 06 Jul 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R102)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MPOL-MRN-M","q":8},{"sku":"MTRK-BLK-XL","q":10},{"sku":"WTOP-WHT-M","q":32},{"sku":"WTOP-PCH-L","q":22},{"sku":"GTOP-YLW-89Y","q":8},{"sku":"GTOP-WHT-67Y","q":8},{"sku":"GLEG-BLK-67Y","q":16}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1238','Amazon - Seller Central','2026-07-06 15:16+05:30','Nikhil Pandey','prepaid',2197.0,0.0,109.85,2306.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1239','Amazon - Seller Central','2026-07-06 17:03+05:30','Vivek Singh','prepaid',749.0,0.0,37.45,786.45,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1176','Flipkart - Seller Hub','2026-07-06 12:23+05:30','Sonal Parekh','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1183','Shopify - Main Store','2026-07-06 19:37+05:30','Jigar Chauhan','prepaid',2198.0,109.9,104.4,2192.5,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1184','Shopify - Main Store','2026-07-06 15:30+05:30','Karan Malhotra','prepaid',329.0,16.45,15.63,328.18,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1177','Flipkart - Seller Hub','2026-07-06 20:18+05:30','Sonal Parekh','prepaid',1278.0,0.0,63.9,1341.9,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1240','Amazon - Seller Central','2026-07-06 17:29+05:30','Bhavna Solanki','prepaid',1948.0,0.0,97.4,2045.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1185','Shopify - Main Store','2026-07-06 12:30+05:30','Pooja Jain','cod',1399.0,139.9,62.96,1322.06,'shipped','pending','Delhi','Surat Main Warehouse'),
('SHOP-1186','Shopify - Main Store','2026-07-06 16:27+05:30','Isha Gupta','cod',1349.0,0.0,67.45,1416.45,'shipped','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1238','WTOP-PCH-M',2,599,0.0,59.9),
('AMAZ-1238','BTRK-BLK-67Y',1,999,0.0,49.95),
('AMAZ-1239','GFRK-LIL-89Y',1,749,0.0,37.45),
('FLIP-1176','MSHC-RED-XL',1,899,0.0,44.95),
('FLIP-1176','MCHN-OLV-32',1,1199,0.0,59.95),
('SHOP-1183','MHOD-GRY-M',1,1299,64.95,61.7),
('SHOP-1183','MSHC-RED-L',1,899,44.95,42.7),
('SHOP-1184','BTEE-BLU-89Y',1,329,16.45,15.63),
('FLIP-1177','BKUR-MUS-67Y',1,949,0.0,47.45),
('FLIP-1177','BTEE-BLU-89Y',1,329,0.0,16.45),
('AMAZ-1240','WPAL-WHT-M',1,599,0.0,29.95),
('AMAZ-1240','WJNS-BLK-30',1,1349,0.0,67.45),
('SHOP-1185','MJNS-IND-34',1,1399,139.9,62.96),
('SHOP-1186','WJNS-IND-32',1,1349,0.0,67.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('FLIP-1148');
select pg_temp.rto_new('FLIP-1162', 'AWB31000530', 'Customer refused delivery');
select pg_temp.cod_collect(array['SHOP-1173']::text[]);
select pg_temp.cod_collect(array['SHOP-1177']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260629', '2026-06-29', '2026-07-05', array['AMAZ-1197','AMAZ-1198','AMAZ-1200','AMAZ-1201','AMAZ-1202','AMAZ-1203','AMAZ-1204','AMAZ-1206','AMAZ-1208','AMAZ-1211','AMAZ-1212','AMAZ-1215','AMAZ-1207','AMAZ-1209','AMAZ-1217','AMAZ-1210','AMAZ-1213','AMAZ-1214','AMAZ-1218','AMAZ-1221','AMAZ-1216']::text[], array['AMAZ-1156','AMAZ-1166','AMAZ-1159','AMAZ-1161']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260629', '2026-06-29', '2026-07-05', array['FLIP-1156','FLIP-1157','FLIP-1158','FLIP-1159','FLIP-1161']::text[], array['FLIP-1138']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260629', '2026-06-29', '2026-07-05', array['SHOP-1158','SHOP-1162','SHOP-1170','SHOP-1160','SHOP-1161','SHOP-1168','SHOP-1169']::text[], array[]::text[]);
select pg_temp.claim_step('FLIP-1138', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Tue 07 Jul 2026
select pg_temp.day('2026-07-07');
select pg_temp.grn_new('Weekly replenishment 29 Jun 2026 - Shree Ambika Textiles (ref R092)', 'DC-SAT-0091', '[{"sku":"WKRT-PNK-M","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 29 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R095)', 'DC-TKF-0130', '[{"sku":"MPOL-MRN-XL","q":6,"a":6,"r":0},{"sku":"WTOP-WHT-M","q":28,"a":28,"r":0},{"sku":"WTOP-PCH-M","q":20,"a":20,"r":0},{"sku":"WTOP-PCH-L","q":18,"a":18,"r":0},{"sku":"GTOP-WHT-67Y","q":6,"a":6,"r":0},{"sku":"GLEG-BLK-67Y","q":12,"a":11,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1241','Amazon - Seller Central','2026-07-07 14:42+05:30','Vivek Singh','prepaid',4457.0,445.7,645.05,4656.35,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1178','Flipkart - Seller Hub','2026-07-07 18:20+05:30','Dev Trivedi','prepaid',779.0,38.95,37.0,777.05,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1179','Flipkart - Seller Hub','2026-07-07 14:32+05:30','Heena Khan','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1187','Shopify - Main Store','2026-07-07 09:23+05:30','Kunal Desai','prepaid',5994.0,0.0,299.7,6293.7,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1242','Amazon - Seller Central','2026-07-07 13:01+05:30','Pooja Jain','prepaid',3697.0,0.0,184.85,3881.85,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1243','Amazon - Seller Central','2026-07-07 09:57+05:30','Jigar Chauhan','prepaid',2306.0,115.3,109.54,2300.24,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1244','Amazon - Seller Central','2026-07-07 10:09+05:30','Foram Thakkar','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1180','Flipkart - Seller Hub','2026-07-07 14:10+05:30','Prachi Kulkarni','prepaid',1028.0,102.8,46.27,971.47,'delivered','paid','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1241','MBLZ-NVY-40',1,3799,379.9,615.44),
('AMAZ-1241','BTEE-RED-89Y',2,329,65.8,29.61),
('FLIP-1178','GJNS-IND-1011Y',1,779,38.95,37.0),
('FLIP-1179','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1187','MSHF-WHT-XL',3,999,0.0,149.85),
('SHOP-1187','MCHN-OLV-32',1,1199,0.0,59.95),
('SHOP-1187','MSHC-RED-XL',1,899,0.0,44.95),
('SHOP-1187','MSHC-RED-L',1,899,0.0,44.95),
('AMAZ-1242','MSHC-GRN-L',1,899,0.0,44.95),
('AMAZ-1242','WPAL-WHT-M',1,599,0.0,29.95),
('AMAZ-1242','WSAR-GRN-FREE',1,2199,0.0,109.95),
('AMAZ-1243','GNGT-PNK-67Y',1,549,27.45,26.08),
('AMAZ-1243','MCHN-KHK-30',1,1199,59.95,56.95),
('AMAZ-1243','GLEG-BLK-89Y',2,279,27.9,26.51),
('AMAZ-1244','MCHN-OLV-32',1,1199,119.9,53.96),
('FLIP-1180','GLEG-BLK-45Y',1,279,27.9,12.56),
('FLIP-1180','GFRK-LIL-45Y',1,749,74.9,33.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('AMAZ-1188');
select pg_temp.ret_recv('AMAZ-1199');
select pg_temp.ret_new('AMAZ-1203', 'Colour different from photo', 'webhook');
select pg_temp.ret_new('AMAZ-1204', 'Size did not fit', 'webhook');
select pg_temp.rto_set('SHOP-1172', 'in_transit');
select pg_temp.cod_collect(array['AMAZ-1220']::text[]);
select pg_temp.settle_pay('FLK-STL-20260622', 0.0);
select pg_temp.claim_step('AMAZ-1161', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Wed 08 Jul 2026
select pg_temp.day('2026-07-08');
select pg_temp.bill_po('Weekly replenishment 29 Jun 2026 - Shree Ambika Textiles (ref R092)', 'SAT/26/0225', 1);
select pg_temp.grn_new('Weekly replenishment 29 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R094)', 'DC-TKF-0127', '[{"sku":"MTEE-BLK-L","q":6,"a":6,"r":0},{"sku":"WTOP-PCH-L","q":14,"a":14,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 29 Jun 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R095)', 'TKF/26/0313', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1245','Amazon - Seller Central','2026-07-08 22:06+05:30','Harsh Modi','prepaid',2246.0,0.0,112.3,2358.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1246','Amazon - Seller Central','2026-07-08 19:07+05:30','Vipul Gandhi','prepaid',449.0,44.9,20.21,424.31,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1181','Flipkart - Seller Hub','2026-07-08 22:05+05:30','Kunal Desai','prepaid',948.0,47.4,45.03,945.63,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1247','Amazon - Seller Central','2026-07-08 15:41+05:30','Foram Thakkar','prepaid',4497.0,0.0,224.85,4721.85,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1188','Shopify - Main Store','2026-07-08 09:02+05:30','Sonal Parekh','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1248','Amazon - Seller Central','2026-07-08 17:01+05:30','Harsh Modi','prepaid',6794.0,0.0,339.7,7133.7,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1189','Shopify - Main Store','2026-07-08 15:56+05:30','Ritu Saxena','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1249','Amazon - Seller Central','2026-07-08 14:42+05:30','Kunal Desai','prepaid',849.0,42.45,40.33,846.88,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1250','Amazon - Seller Central','2026-07-08 11:15+05:30','Dev Trivedi','prepaid',1198.0,0.0,59.9,1257.9,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1251','Amazon - Seller Central','2026-07-08 22:31+05:30','Sagar Rathod','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1190','Shopify - Main Store','2026-07-08 14:28+05:30','Karan Malhotra','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1245','WTOP-PCH-L',3,599,0.0,89.85),
('AMAZ-1245','MTEE-BLK-XL',1,449,0.0,22.45),
('AMAZ-1246','WDUP-SLV-FREE',1,449,44.9,20.21),
('FLIP-1181','WTOP-WHT-L',1,599,29.95,28.45),
('FLIP-1181','WLEG-MAR-L',1,349,17.45,16.58),
('AMAZ-1247','WDRS-FLP-S',3,1499,0.0,224.85),
('SHOP-1188','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1248','MSHF-WHT-L',2,999,0.0,99.9),
('AMAZ-1248','MJNS-IND-32',1,1399,0.0,69.95),
('AMAZ-1248','MCHN-OLV-34',1,1199,0.0,59.95),
('AMAZ-1248','MKUR-WHT-XL',2,1099,0.0,109.9),
('SHOP-1189','GLEG-PNK-45Y',1,279,0.0,13.95),
('AMAZ-1249','WKRT-PNK-XL',1,849,42.45,40.33),
('AMAZ-1250','WPAL-WHT-L',2,599,0.0,59.9),
('AMAZ-1251','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1251','WDRS-FLP-M',1,1499,0.0,74.95),
('SHOP-1190','BTEE-RED-45Y',1,329,0.0,16.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('AMAZ-1183');
select pg_temp.ret_dispo('AMAZ-1188', 'good', 'restocked');
select pg_temp.ret_dispo('FLIP-1148', 'good', 'restocked');
select pg_temp.ret_dispo('AMAZ-1199', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1203', 'approved');
select pg_temp.ret_set('AMAZ-1204', 'approved');
select pg_temp.rto_set('FLIP-1162', 'in_transit');
select pg_temp.rto_new('FLIP-1168', 'AWB31000543', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['SHOP-1179']::text[]);
select pg_temp.settle_pay('SHP-STL-20260629', 0.0);
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
