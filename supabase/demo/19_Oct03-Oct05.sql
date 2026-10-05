-- 03 Oct to 05 Oct 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Sat 03 Oct 2026
select pg_temp.day('2026-10-03');
select pg_temp.bill_po('Weekly replenishment 28 Sep 2026 - Krishna Denim Works (ref R196)', 'KDW/26/0390', 1);
select pg_temp.bill_po('Weekly replenishment 28 Sep 2026 - Krishna Denim Works (ref R197)', 'KDW/26/0398', 1);
select pg_temp.bill_po('Weekly replenishment 28 Sep 2026 - Little Stitch Garments (ref R199)', 'LSG/26/0384', 1);
select pg_temp.bill_po('Weekly replenishment 28 Sep 2026 - Shree Ambika Textiles (ref R203)', 'SAT/26/0379', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1490','Shopify - Main Store','2026-10-03 14:05+05:30','Rahul Bhatt','prepaid',599.0,59.9,26.96,566.06,'processing','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1625','Amazon - Seller Central','2026-10-03 19:45+05:30','Chirag Zaveri','prepaid',6595.0,1319.0,263.8,5539.8,'pending','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1626','Amazon - Seller Central','2026-10-03 10:19+05:30','Kunal Desai','prepaid',3647.0,364.7,164.12,3446.42,'processing','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1466','Flipkart - Seller Hub','2026-10-03 14:00+05:30','Amit Sethi','prepaid',3996.0,999.0,149.85,3146.85,'processing','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1627','Amazon - Seller Central','2026-10-03 15:29+05:30','Ritu Saxena','prepaid',3596.0,899.0,134.86,2831.86,'processing','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1491','Shopify - Main Store','2026-10-03 19:12+05:30','Sanjay Gajera','prepaid',4997.0,0.0,743.72,5740.72,'processing','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1628','Amazon - Seller Central','2026-10-03 09:01+05:30','Vipul Gandhi','prepaid',1047.0,209.4,41.88,879.48,'shipped','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1467','Flipkart - Seller Hub','2026-10-03 10:51+05:30','Vipul Gandhi','cod',4398.0,439.8,197.91,4156.11,'pending','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1629','Amazon - Seller Central','2026-10-03 22:00+05:30','Pooja Jain','prepaid',2798.0,559.6,111.92,2350.32,'processing','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1468','Flipkart - Seller Hub','2026-10-03 12:58+05:30','Ritu Saxena','cod',5247.0,1311.75,196.77,4132.02,'processing','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1630','Amazon - Seller Central','2026-10-03 17:41+05:30','Foram Thakkar','cod',1448.0,0.0,72.4,1520.4,'processing','pending','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1492','Shopify - Main Store','2026-10-03 14:59+05:30','Divya Nair','cod',599.0,0.0,29.95,628.95,'pending','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1631','Amazon - Seller Central','2026-10-03 14:57+05:30','Tanvi Rana','prepaid',3247.0,0.0,162.35,3409.35,'pending','pending','Delhi','Surat Main Warehouse'),
('FLIP-1469','Flipkart - Seller Hub','2026-10-03 10:33+05:30','Isha Gupta','cod',3185.0,477.75,135.36,2842.61,'processing','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1632','Amazon - Seller Central','2026-10-03 19:54+05:30','Mitul Dave','prepaid',3047.0,0.0,152.35,3199.35,'processing','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1470','Flipkart - Seller Hub','2026-10-03 20:40+05:30','Vivek Singh','cod',1299.0,324.75,48.71,1022.96,'processing','pending','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1633','Amazon - Seller Central','2026-10-03 10:40+05:30','Chirag Zaveri','prepaid',849.0,0.0,42.45,891.45,'processing','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1493','Shopify - Main Store','2026-10-03 15:20+05:30','Tanvi Rana','prepaid',11597.0,0.0,2009.59,13606.59,'processing','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1634','Amazon - Seller Central','2026-10-03 22:42+05:30','Riya Shah','prepaid',1648.0,412.0,61.8,1297.8,'processing','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1635','Amazon - Seller Central','2026-10-03 13:47+05:30','Rahul Bhatt','prepaid',2798.0,279.8,125.92,2644.12,'pending','pending','Uttar Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1490','WTOP-PCH-M',1,599,59.9,26.96),
('AMAZ-1625','MHOD-BLK-M',2,1299,519.6,103.92),
('AMAZ-1625','WJNS-BLK-30',2,1349,539.6,107.92),
('AMAZ-1625','MHOD-BLK-L',1,1299,259.8,51.96),
('AMAZ-1626','WKRT-PNK-L',1,849,84.9,38.21),
('AMAZ-1626','MJNS-BLK-30',2,1399,279.8,125.91),
('FLIP-1466','WDRS-FLP-L',1,1499,374.75,56.21),
('FLIP-1466','WTOP-WHT-L',1,599,149.75,22.46),
('FLIP-1466','BKUR-MUS-67Y',2,949,474.5,71.18),
('AMAZ-1627','BKUR-CRM-89Y',2,949,474.5,71.18),
('AMAZ-1627','WKRT-PNK-M',2,849,424.5,63.68),
('SHOP-1491','MBLZ-NVY-38',1,3799,0.0,683.82),
('SHOP-1491','WTOP-PCH-M',2,599,0.0,59.9),
('AMAZ-1628','WLEG-NVY-M',3,349,209.4,41.88),
('FLIP-1467','WSAR-BLU-FREE',2,2199,439.8,197.91),
('AMAZ-1629','WTOP-PCH-L',1,599,119.8,23.96),
('AMAZ-1629','WSAR-BLU-FREE',1,2199,439.8,87.96),
('FLIP-1468','WSAR-BLU-FREE',2,2199,1099.5,164.93),
('FLIP-1468','WKRT-TEL-M',1,849,212.25,31.84),
('AMAZ-1630','WPAL-YLW-M',1,599,0.0,29.95),
('AMAZ-1630','WKRT-TEL-XL',1,849,0.0,42.45),
('SHOP-1492','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1631','WJNS-IND-30',1,1349,0.0,67.45),
('AMAZ-1631','BKUR-MUS-45Y',2,949,0.0,94.9),
('FLIP-1469','GTOP-WHT-67Y',1,349,52.35,14.83),
('FLIP-1469','GLHG-RED-67Y',1,1999,299.85,84.96),
('FLIP-1469','GLEG-PNK-67Y',3,279,125.55,35.57),
('AMAZ-1632','WLEG-NVY-M',1,349,0.0,17.45),
('AMAZ-1632','WJNS-BLK-30',2,1349,0.0,134.9),
('FLIP-1470','MHOD-GRY-M',1,1299,324.75,48.71),
('AMAZ-1633','WKRT-PNK-S',1,849,0.0,42.45),
('SHOP-1493','WLHG-RED-M',2,5499,0.0,1979.64),
('SHOP-1493','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1634','BSHT-GRY-67Y',1,349,87.25,13.09),
('AMAZ-1634','MHOD-BLK-M',1,1299,324.75,48.71),
('AMAZ-1635','WTOP-PCH-M',1,599,59.9,26.96),
('AMAZ-1635','WSAR-BLU-FREE',1,2199,219.9,98.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1504', 'good', 'restocked');
select pg_temp.ret_dispo('FLIP-1382', 'good', 'restocked');
select pg_temp.ret_recv('SHOP-1420');
select pg_temp.ret_recv('AMAZ-1551');
select pg_temp.rto_recv('SHOP-1450', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1453', 'pickup');
select pg_temp.ret_set('FLIP-1413', 'approved');
select pg_temp.rto_set('AMAZ-1588', 'in_transit');
select pg_temp.retime();

-- Sun 04 Oct 2026
select pg_temp.day('2026-10-04');
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R194)', 'DC-TKF-0217', '[{"sku":"MTRK-BLK-L","q":4,"a":4,"r":0},{"sku":"WTOP-WHT-L","q":5,"a":5,"r":0},{"sku":"WTOP-PCH-L","q":11,"a":11,"r":0},{"sku":"BTEE-RED-89Y","q":5,"a":5,"r":0},{"sku":"GLEG-PNK-89Y","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 28 Sep 2026 - Rajdhani Shirting Mills (ref R201)', 'DC-RSM-0166', '[{"sku":"MSHF-WHT-L","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 28 Sep 2026 - Rajdhani Shirting Mills (ref R202)', 'DC-RSM-0169', '[{"sku":"MKUR-WHT-L","q":12,"a":12,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1636','Amazon - Seller Central','2026-10-04 13:19+05:30','Dev Trivedi','prepaid',1349.0,337.25,50.59,1062.34,'processing','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1637','Amazon - Seller Central','2026-10-04 09:13+05:30','Pratik Lad','prepaid',279.0,41.85,11.86,249.01,'pending','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1638','Amazon - Seller Central','2026-10-04 14:52+05:30','Riya Shah','prepaid',2847.0,569.4,113.88,2391.48,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('SHOP-1494','Shopify - Main Store','2026-10-04 09:21+05:30','Nidhi Agarwal','cod',2398.0,0.0,119.9,2517.9,'processing','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1471','Flipkart - Seller Hub','2026-10-04 15:55+05:30','Sonal Parekh','prepaid',1199.0,239.8,47.96,1007.16,'processing','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1639','Amazon - Seller Central','2026-10-04 22:51+05:30','Anjali Verma','prepaid',2848.0,712.0,106.8,2242.8,'processing','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1472','Flipkart - Seller Hub','2026-10-04 16:37+05:30','Dev Trivedi','prepaid',1548.0,232.2,65.79,1381.59,'processing','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1640','Amazon - Seller Central','2026-10-04 13:26+05:30','Chirag Zaveri','prepaid',1837.0,0.0,91.85,1928.85,'processing','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1641','Amazon - Seller Central','2026-10-04 11:33+05:30','Chirag Zaveri','prepaid',1598.0,239.7,67.92,1426.22,'pending','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1495','Shopify - Main Store','2026-10-04 13:07+05:30','Kiran Naik','prepaid',1897.0,0.0,94.85,1991.85,'cancelled','refunded','Rajasthan','Surat Main Warehouse'),
('FLIP-1473','Flipkart - Seller Hub','2026-10-04 21:25+05:30','Yash Vora','cod',599.0,119.8,23.96,503.16,'processing','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1642','Amazon - Seller Central','2026-10-04 11:29+05:30','Vipul Gandhi','prepaid',4398.0,659.7,186.92,3925.22,'processing','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1496','Shopify - Main Store','2026-10-04 19:55+05:30','Riya Shah','prepaid',928.0,0.0,46.4,974.4,'processing','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1474','Flipkart - Seller Hub','2026-10-04 17:38+05:30','Karan Malhotra','cod',3047.0,304.7,137.13,2879.43,'pending','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1475','Flipkart - Seller Hub','2026-10-04 12:50+05:30','Tanvi Rana','cod',1646.0,411.5,61.72,1296.22,'processing','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1476','Flipkart - Seller Hub','2026-10-04 09:18+05:30','Amit Sethi','prepaid',279.0,27.9,12.56,263.66,'pending','pending','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1477','Flipkart - Seller Hub','2026-10-04 09:46+05:30','Bhavna Solanki','prepaid',6946.0,1041.9,295.2,6199.3,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('FLIP-1478','Flipkart - Seller Hub','2026-10-04 18:34+05:30','Heena Khan','prepaid',1856.0,371.2,74.24,1559.04,'pending','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1643','Amazon - Seller Central','2026-10-04 11:24+05:30','Dev Trivedi','prepaid',1299.0,259.8,51.96,1091.16,'processing','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1497','Shopify - Main Store','2026-10-04 19:25+05:30','Pooja Jain','cod',1199.0,0.0,59.95,1258.95,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('SHOP-1498','Shopify - Main Store','2026-10-04 18:03+05:30','Kiran Naik','prepaid',20895.0,0.0,3189.36,24084.36,'shipped','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1636','WJNS-BLK-30',1,1349,337.25,50.59),
('AMAZ-1637','GLEG-PNK-67Y',1,279,41.85,11.86),
('AMAZ-1638','BKUR-CRM-45Y',3,949,569.4,113.88),
('SHOP-1494','MCHN-OLV-34',2,1199,0.0,119.9),
('FLIP-1471','MCHN-OLV-34',1,1199,239.8,47.96),
('AMAZ-1639','WDRS-FLP-S',1,1499,374.75,56.21),
('AMAZ-1639','WJNS-IND-32',1,1349,337.25,50.59),
('FLIP-1472','WKRT-PNK-M',1,849,127.35,36.08),
('FLIP-1472','MPOL-MRN-XL',1,699,104.85,29.71),
('AMAZ-1640','GLEG-BLK-89Y',1,279,0.0,13.95),
('AMAZ-1640','GJNS-IND-89Y',2,779,0.0,77.9),
('AMAZ-1641','MPOL-MRN-M',1,699,104.85,29.71),
('AMAZ-1641','MSHC-RED-M',1,899,134.85,38.21),
('SHOP-1495','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1495','WLEG-NVY-L',1,349,0.0,17.45),
('SHOP-1495','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1473','WTOP-PCH-L',1,599,119.8,23.96),
('AMAZ-1642','WSAR-GRN-FREE',2,2199,659.7,186.92),
('SHOP-1496','GLEG-BLK-89Y',1,279,0.0,13.95),
('SHOP-1496','MTRK-BLK-L',1,649,0.0,32.45),
('FLIP-1474','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1474','WDRS-FLP-S',1,1499,149.9,67.46),
('FLIP-1474','BKUR-MUS-67Y',1,949,94.9,42.71),
('FLIP-1475','WTOP-PCH-S',1,599,149.75,22.46),
('FLIP-1475','WLEG-MAR-M',3,349,261.75,39.26),
('FLIP-1476','GLEG-PNK-89Y',1,279,27.9,12.56),
('FLIP-1477','WSAR-GRN-FREE',3,2199,989.55,280.37),
('FLIP-1477','WLEG-MAR-L',1,349,52.35,14.83),
('FLIP-1478','GLEG-PNK-89Y',2,279,111.6,22.32),
('FLIP-1478','MTRK-BLK-L',2,649,259.6,51.92),
('AMAZ-1643','MHOD-BLK-L',1,1299,259.8,51.96),
('SHOP-1497','MCHN-OLV-32',1,1199,0.0,59.95),
('SHOP-1498','WLHG-RED-L',3,5499,0.0,2969.46),
('SHOP-1498','WSAR-GRN-FREE',2,2199,0.0,219.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_refund_d2c('SHOP-1412', 'UPI-REFUND-SHOP-1412');
select pg_temp.ret_dispo('SHOP-1420', 'good', 'restocked');
select pg_temp.ret_recv('AMAZ-1527');
select pg_temp.ret_recv('SHOP-1424');
select pg_temp.ret_recv('FLIP-1403');
select pg_temp.ret_set('FLIP-1413', 'pickup');
select pg_temp.ret_new('SHOP-1467', 'Fabric quality not as expected', 'webhook');
select pg_temp.rto_set('FLIP-1441', 'in_transit');
select pg_temp.settle_pay('AMZ-STL-20260921', 0.0);
select pg_temp.retime();

-- Mon 05 Oct 2026
select pg_temp.day('2026-10-05');
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R194)', 'TKF/26/0513', 1);
select pg_temp.bill_po('Weekly replenishment 28 Sep 2026 - Rajdhani Shirting Mills (ref R201)', 'RSM/26/0399', 1);
select pg_temp.bill_po('Weekly replenishment 28 Sep 2026 - Rajdhani Shirting Mills (ref R202)', 'RSM/26/0401', 1);
select pg_temp.po_new('Weekly replenishment 05 Oct 2026 - Krishna Denim Works (ref R207)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MCHN-OLV-32","q":28},{"sku":"GJNS-IND-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 05 Oct 2026 - Little Stitch Garments (ref R208)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"WDRS-FLP-L","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 05 Oct 2026 - Little Stitch Garments (ref R209)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"GLHG-RED-45Y","q":10},{"sku":"GLHG-TEL-89Y","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 05 Oct 2026 - Ludhiana Winter Wear Co (ref R210)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"MHOD-BLK-XL","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 05 Oct 2026 - Shree Ambika Textiles (ref R211)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-XL","q":12},{"sku":"WKRT-TEL-M","q":14},{"sku":"WKRT-TEL-XL","q":10},{"sku":"WSAR-GRN-FREE","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 05 Oct 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R212)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"BTEE-BLU-89Y","q":14}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 05 Oct 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R213)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"BTEE-BLU-45Y","q":6}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1644','Amazon - Seller Central','2026-10-05 20:35+05:30','Prachi Kulkarni','prepaid',3698.0,369.8,166.42,3494.62,'pending','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1479','Flipkart - Seller Hub','2026-10-05 19:30+05:30','Jigar Chauhan','prepaid',2598.0,0.0,129.9,2727.9,'pending','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1645','Amazon - Seller Central','2026-10-05 11:30+05:30','Vipul Gandhi','prepaid',349.0,0.0,17.45,366.45,'pending','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1480','Flipkart - Seller Hub','2026-10-05 12:30+05:30','Isha Gupta','cod',1548.0,0.0,77.4,1625.4,'processing','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1646','Amazon - Seller Central','2026-10-05 22:03+05:30','Tanvi Rana','prepaid',1299.0,0.0,64.95,1363.95,'processing','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1499','Shopify - Main Store','2026-10-05 14:46+05:30','Amit Sethi','cod',599.0,0.0,29.95,628.95,'pending','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1500','Shopify - Main Store','2026-10-05 10:17+05:30','Pooja Jain','cod',1448.0,0.0,72.4,1520.4,'pending','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1647','Amazon - Seller Central','2026-10-05 17:00+05:30','Sonal Parekh','prepaid',5096.0,509.6,229.33,4815.73,'pending','pending','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1501','Shopify - Main Store','2026-10-05 21:23+05:30','Vivek Singh','prepaid',1299.0,0.0,64.95,1363.95,'pending','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1481','Flipkart - Seller Hub','2026-10-05 09:26+05:30','Foram Thakkar','prepaid',279.0,0.0,13.95,292.95,'pending','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1648','Amazon - Seller Central','2026-10-05 14:47+05:30','Rohit Iyer','prepaid',2199.0,0.0,109.95,2308.95,'processing','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1649','Amazon - Seller Central','2026-10-05 17:16+05:30','Aarav Mehta','prepaid',3196.0,319.6,143.83,3020.23,'pending','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1482','Flipkart - Seller Hub','2026-10-05 22:26+05:30','Harsh Modi','prepaid',5247.0,524.7,236.12,4958.42,'pending','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1650','Amazon - Seller Central','2026-10-05 17:59+05:30','Mehul Shukla','prepaid',2297.0,114.85,109.11,2291.26,'pending','pending','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1644','WSAR-GRN-FREE',1,2199,219.9,98.96),
('AMAZ-1644','WDRS-FLR-S',1,1499,149.9,67.46),
('FLIP-1479','MCHN-OLV-32',1,1199,0.0,59.95),
('FLIP-1479','MJNS-IND-34',1,1399,0.0,69.95),
('AMAZ-1645','GTOP-YLW-67Y',1,349,0.0,17.45),
('FLIP-1480','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1480','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1646','MHOD-GRY-M',1,1299,0.0,64.95),
('SHOP-1499','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1500','WTOP-WHT-L',1,599,0.0,29.95),
('SHOP-1500','WKRT-TEL-M',1,849,0.0,42.45),
('AMAZ-1647','MHOD-GRY-M',1,1299,129.9,58.46),
('AMAZ-1647','MCHN-KHK-30',1,1199,119.9,53.96),
('AMAZ-1647','MHOD-BLK-L',2,1299,259.8,116.91),
('SHOP-1501','MHOD-GRY-L',1,1299,0.0,64.95),
('FLIP-1481','GLEG-BLK-67Y',1,279,0.0,13.95),
('AMAZ-1648','WSAR-GRN-FREE',1,2199,0.0,109.95),
('AMAZ-1649','BSHT-GRY-45Y',1,349,34.9,15.71),
('AMAZ-1649','BKUR-CRM-89Y',2,949,189.8,85.41),
('AMAZ-1649','BKUR-MUS-45Y',1,949,94.9,42.71),
('FLIP-1482','WSAR-RED-FREE',2,2199,439.8,197.91),
('FLIP-1482','WKRT-PNK-M',1,849,84.9,38.21),
('AMAZ-1650','MSHC-RED-XL',1,899,44.95,42.7),
('AMAZ-1650','MPOL-MRN-M',2,699,69.9,66.41)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1527', 'good', 'restocked');
select pg_temp.ret_dispo('FLIP-1403', 'good', 'restocked');
select pg_temp.ret_dispo('AMAZ-1551', 'wrong_item', 'claimed');
select pg_temp.ret_set('SHOP-1453', 'in_transit');
select pg_temp.rto_recv('FLIP-1412', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1467', 'approved');
select pg_temp.rto_recv('AMAZ-1576', 'damaged', 'quarantined');
select pg_temp.rto_recv('AMAZ-1579', 'good', 'restocked');
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260928', '2026-09-28', '2026-10-04', array['AMAZ-1560','AMAZ-1562','AMAZ-1568','AMAZ-1563','AMAZ-1564','AMAZ-1566','AMAZ-1570','AMAZ-1572','AMAZ-1578','AMAZ-1565','AMAZ-1569','AMAZ-1577','AMAZ-1587','AMAZ-1580','AMAZ-1584','AMAZ-1586','AMAZ-1589','AMAZ-1592','AMAZ-1593','AMAZ-1573','AMAZ-1575','AMAZ-1599','AMAZ-1594','AMAZ-1595','AMAZ-1596','AMAZ-1600']::text[], array['AMAZ-1477','AMAZ-1504','AMAZ-1551','AMAZ-1527']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260928', '2026-09-28', '2026-10-04', array['FLIP-1414','FLIP-1415','FLIP-1422','FLIP-1413','FLIP-1416','FLIP-1421','FLIP-1424','FLIP-1432','FLIP-1433','FLIP-1434','FLIP-1427','FLIP-1428','FLIP-1436','FLIP-1439','FLIP-1442','FLIP-1444','FLIP-1435','FLIP-1451','FLIP-1445','FLIP-1447','FLIP-1449']::text[], array['FLIP-1389','FLIP-1382','FLIP-1403']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260928', '2026-09-28', '2026-10-04', array['SHOP-1457','SHOP-1463','SHOP-1456','SHOP-1467','SHOP-1472','SHOP-1468','SHOP-1474']::text[], array[]::text[]);
select pg_temp.claim_step('SHOP-1412', 'lost_shipment', 'claimed', null);
select pg_temp.claim_new('AMAZ-1551', 'other', 1992.9, '2026-11-04');
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
