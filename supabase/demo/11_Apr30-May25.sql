-- 30 Apr to 25 May 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Thu 30 Apr 2026
select pg_temp.day('2026-04-30');
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Krishna Denim Works (ref R019)', 'KDW/26/0138', 1);
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R025)', 'TKF/26/0145', 1);
select pg_temp.grn_new('Weekly replenishment 20 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R026)', 'DC-TKF-0061', '[{"sku":"WTOP-WHT-M","q":22,"a":21,"r":1},{"sku":"WTOP-WHT-L","q":18,"a":18,"r":0},{"sku":"WTOP-PCH-S","q":14,"a":14,"r":0},{"sku":"WTOP-PCH-M","q":8,"a":8,"r":0},{"sku":"BTEE-BLU-45Y","q":8,"a":8,"r":0},{"sku":"BTEE-BLU-67Y","q":18,"a":17,"r":1},{"sku":"BTEE-RED-45Y","q":10,"a":10,"r":0},{"sku":"BTEE-RED-89Y","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Shree Ambika Textiles (ref R031)', 'DC-SAT-0052', '[{"sku":"WLHG-MAG-M","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1044','Amazon - Seller Central','2026-04-30 09:54+05:30','Ritu Saxena','prepaid',2095.0,209.5,94.29,1979.79,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1045','Amazon - Seller Central','2026-04-30 22:13+05:30','Vipul Gandhi','prepaid',599.0,59.9,26.96,566.06,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1046','Amazon - Seller Central','2026-04-30 18:11+05:30','Divya Nair','prepaid',1199.0,59.95,56.95,1196.0,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1047','Amazon - Seller Central','2026-04-30 22:24+05:30','Nidhi Agarwal','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1044','WDUP-SLV-FREE',1,449,44.9,20.21),
('AMAZ-1044','WTOP-PCH-M',1,599,59.9,26.96),
('AMAZ-1044','WLEG-MAR-M',1,349,34.9,15.71),
('AMAZ-1044','WLEG-BLK-L',2,349,69.8,31.41),
('AMAZ-1045','WTOP-PCH-L',1,599,59.9,26.96),
('AMAZ-1046','MCHN-OLV-34',1,1199,59.95,56.95),
('AMAZ-1047','MCHN-KHK-34',1,1199,119.9,53.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_set('FLIP-1034', 'in_transit');
select pg_temp.ret_set('FLIP-1035', 'approved');
select pg_temp.cod_collect(array['SHOP-1047']::text[]);
select pg_temp.cod_collect(array['SHOP-1049']::text[]);
select pg_temp.cod_collect(array['SHOP-1052']::text[]);
select pg_temp.retime();

-- Fri 01 May 2026
select pg_temp.day('2026-05-01');
select pg_temp.bill_po('Weekly replenishment 20 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R026)', 'TKF/26/0150', 1);
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Little Stitch Garments (ref R029)', 'DC-LSG-0064', '[{"sku":"WDRS-FLP-S","q":6,"a":6,"r":0},{"sku":"BKUR-MUS-67Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Shree Ambika Textiles (ref R031)', 'SAT/26/0128', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1050','Flipkart - Seller Hub','2026-05-01 12:11+05:30','Tanvi Rana','prepaid',13996.0,0.0,2129.54,16125.54,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1057','Shopify - Main Store','2026-05-01 19:06+05:30','Rohit Iyer','cod',329.0,0.0,16.45,345.45,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1058','Shopify - Main Store','2026-05-01 19:47+05:30','Jigar Chauhan','cod',1198.0,119.8,53.91,1132.11,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1048','Amazon - Seller Central','2026-05-01 21:41+05:30','Amit Sethi','prepaid',2076.0,103.8,98.61,2070.81,'delivered','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1049','Amazon - Seller Central','2026-05-01 12:34+05:30','Rahul Bhatt','cod',599.0,0.0,29.95,628.95,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1050','Amazon - Seller Central','2026-05-01 18:44+05:30','Nikhil Pandey','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1059','Shopify - Main Store','2026-05-01 21:51+05:30','Dev Trivedi','prepaid',6593.0,329.65,313.18,6576.53,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1051','Flipkart - Seller Hub','2026-05-01 19:31+05:30','Ritu Saxena','cod',558.0,0.0,27.9,585.9,'shipped','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1051','Amazon - Seller Central','2026-05-01 11:54+05:30','Foram Thakkar','prepaid',1548.0,77.4,73.53,1544.13,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1050','WLHG-RED-M',2,5499,0.0,1979.64),
('FLIP-1050','WDRS-FLP-S',2,1499,0.0,149.9),
('SHOP-1057','BTEE-BLU-67Y',1,329,0.0,16.45),
('SHOP-1058','WTOP-PCH-L',2,599,119.8,53.91),
('AMAZ-1048','WTOP-PCH-M',2,599,59.9,56.91),
('AMAZ-1048','GLEG-BLK-67Y',1,279,13.95,13.25),
('AMAZ-1048','WTOP-PCH-L',1,599,29.95,28.45),
('AMAZ-1049','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1050','WKRT-TEL-L',1,849,0.0,42.45),
('AMAZ-1050','WLEG-NVY-M',1,349,0.0,17.45),
('AMAZ-1050','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1059','MTRK-BLK-M',2,649,64.9,61.66),
('SHOP-1059','MSHF-WHT-XL',2,999,99.9,94.91),
('SHOP-1059','MCHN-OLV-30',2,1199,119.9,113.91),
('SHOP-1059','MSHC-RED-XL',1,899,44.95,42.7),
('FLIP-1051','GLEG-BLK-45Y',2,279,0.0,27.9),
('AMAZ-1051','MSHC-RED-XL',1,899,44.95,42.7),
('AMAZ-1051','MTRK-BLK-L',1,649,32.45,30.83)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1057','DTDC - Ring Road Surat'),
('SHOP-1058','Xpressbees - Pandesara'),
('AMAZ-1049','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1035', 'pickup');
select pg_temp.ret_set('SHOP-1037', 'in_transit');
select pg_temp.rto_set('AMAZ-1036', 'in_transit');
select pg_temp.rto_new('SHOP-1053', 'AWB31000090', 'Customer refused delivery');
select pg_temp.cod_collect(array['SHOP-1055']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-01MAY', array['SHOP-1039','FLIP-1045','SHOP-1046']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-01MAY', array['SHOP-1032','FLIP-1041','SHOP-1042','SHOP-1045']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-01MAY', array['FLIP-1037']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-01MAY', array['FLIP-1043']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-05-04', 'ICIC000000881248', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-05-04', 'ICIC000000881298', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-05-04', 'ICIC000000881321', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-05-04', 'ICIC000000881348', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-05-04', 'ICIC000000881389', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-05-04', 'ICIC000000881419', 1);
select pg_temp.retime();

-- Sat 02 May 2026
select pg_temp.day('2026-05-02');
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Krishna Denim Works (ref R027)', 'DC-KDW-0058', '[{"sku":"WJNS-IND-28","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Little Stitch Garments (ref R028)', 'DC-LSG-0061', '[{"sku":"GFRK-LIL-89Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Little Stitch Garments (ref R029)', 'LSG/26/0160', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1052','Amazon - Seller Central','2026-05-02 21:57+05:30','Aditi Joshi','prepaid',5105.0,255.25,242.49,5092.24,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1053','Amazon - Seller Central','2026-05-02 19:27+05:30','Vivek Singh','prepaid',2947.0,147.35,139.98,2939.63,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1060','Shopify - Main Store','2026-05-02 19:34+05:30','Pooja Jain','prepaid',2398.0,0.0,119.9,2517.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1052','Flipkart - Seller Hub','2026-05-02 09:16+05:30','Rahul Bhatt','prepaid',558.0,0.0,27.9,585.9,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1052','GLEG-BLK-45Y',1,279,13.95,13.25),
('AMAZ-1052','GNGT-PNK-89Y',1,549,27.45,26.08),
('AMAZ-1052','GLEG-BLK-67Y',1,279,13.95,13.25),
('AMAZ-1052','GLHG-TEL-45Y',2,1999,199.9,189.91),
('AMAZ-1053','MTRK-BLK-L',1,649,32.45,30.83),
('AMAZ-1053','MSHC-RED-XL',1,899,44.95,42.7),
('AMAZ-1053','MJNS-IND-32',1,1399,69.95,66.45),
('SHOP-1060','MCHN-OLV-34',2,1199,0.0,119.9),
('FLIP-1052','GLEG-PNK-45Y',2,279,0.0,27.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_refund_d2c('SHOP-1020', 'UPI-REFUND-SHOP-1020');
select pg_temp.ret_recv('FLIP-1034');
select pg_temp.ret_new('FLIP-1040', 'Customer changed mind', 'webhook');
select pg_temp.ret_new('SHOP-1036', 'Fabric quality not as expected', 'webhook');
select pg_temp.retime();

-- Sun 03 May 2026
select pg_temp.day('2026-05-03');
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Krishna Denim Works (ref R027)', 'KDW/26/0148', 1);
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Little Stitch Garments (ref R028)', 'LSG/26/0153', 1);
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Rajdhani Shirting Mills (ref R030)', 'DC-RSM-0061', '[{"sku":"MSHC-RED-L","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1054','Amazon - Seller Central','2026-05-03 15:26+05:30','Nikhil Pandey','prepaid',8893.0,0.0,444.65,9337.65,'delivered','paid','Rajasthan','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1054','MSHC-RED-M',1,899,0.0,44.95),
('AMAZ-1054','MJNS-IND-34',3,1399,0.0,209.85),
('AMAZ-1054','MJNS-BLK-32',1,1399,0.0,69.95),
('AMAZ-1054','MCHN-OLV-34',2,1199,0.0,119.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('FLIP-1034', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1035', 'in_transit');
select pg_temp.ret_set('FLIP-1040', 'approved');
select pg_temp.ret_set('SHOP-1036', 'approved');
select pg_temp.ret_recv('SHOP-1037');
select pg_temp.rto_set('SHOP-1053', 'in_transit');
select pg_temp.settle_pay('AMZ-STL-20260420', 0.0);
select pg_temp.retime();

-- Mon 04 May 2026
select pg_temp.day('2026-05-04');
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Rajdhani Shirting Mills (ref R030)', 'RSM/26/0150', 1);
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Shree Ambika Textiles (ref R031)', 'DC-SAT-0055', '[{"sku":"WLHG-MAG-M","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 04 May 2026 - Krishna Denim Works (ref R034)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-IND-32","q":10},{"sku":"MJNS-IND-34","q":12},{"sku":"MCHN-OLV-30","q":6},{"sku":"MCHN-OLV-34","q":18}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 04 May 2026 - Rajdhani Shirting Mills (ref R035)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHC-RED-XL","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 04 May 2026 - Rajdhani Shirting Mills (ref R036)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-RED-XL","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 04 May 2026 - Shree Ambika Textiles (ref R037)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WLHG-RED-M","q":6},{"sku":"WDUP-SLV-FREE","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 04 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R038)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"BTEE-RED-67Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 04 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R039)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTRK-BLK-M","q":8},{"sku":"MTRK-BLK-L","q":8},{"sku":"WLEG-MAR-L","q":6},{"sku":"WTOP-PCH-M","q":10},{"sku":"WTOP-PCH-L","q":10},{"sku":"GLEG-BLK-45Y","q":8}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1055','Amazon - Seller Central','2026-05-04 22:56+05:30','Sejal Kapadia','prepaid',2896.0,0.0,144.8,3040.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1053','Flipkart - Seller Hub','2026-05-04 21:15+05:30','Sejal Kapadia','prepaid',1399.0,139.9,62.96,1322.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1054','Flipkart - Seller Hub','2026-05-04 20:35+05:30','Harsh Modi','prepaid',1297.0,129.7,58.37,1225.67,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1056','Amazon - Seller Central','2026-05-04 22:16+05:30','Foram Thakkar','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1061','Shopify - Main Store','2026-05-04 15:03+05:30','Sonal Parekh','cod',1947.0,97.35,92.49,1942.14,'shipped','pending','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1055','Flipkart - Seller Hub','2026-05-04 17:57+05:30','Sagar Rathod','cod',948.0,94.8,42.67,895.87,'delivered','pending','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1055','WKRT-PNK-M',2,849,0.0,84.9),
('AMAZ-1055','WTOP-PCH-M',2,599,0.0,59.9),
('FLIP-1053','MJNS-BLK-32',1,1399,139.9,62.96),
('FLIP-1054','WLEG-MAR-L',2,349,69.8,31.41),
('FLIP-1054','WTOP-WHT-L',1,599,59.9,26.96),
('AMAZ-1056','BKUR-MUS-45Y',1,949,0.0,47.45),
('SHOP-1061','MTRK-BLK-M',1,649,32.45,30.83),
('SHOP-1061','MTRK-BLK-L',2,649,64.9,61.66),
('FLIP-1055','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1055','WLEG-MAR-L',1,349,34.9,15.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1055','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1040', 'pickup');
select pg_temp.ret_set('SHOP-1036', 'pickup');
select pg_temp.ret_new('FLIP-1047', 'Size did not fit', 'webhook');
select pg_temp.rto_new('AMAZ-1043', 'AWB31000101', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['AMAZ-1049']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260427', '2026-04-27', '2026-05-03', array['AMAZ-1030','AMAZ-1033','AMAZ-1034','AMAZ-1031','AMAZ-1032','AMAZ-1037','AMAZ-1038','AMAZ-1035','AMAZ-1041','AMAZ-1039','AMAZ-1040','AMAZ-1046']::text[], array[]::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260427', '2026-04-27', '2026-05-03', array['FLIP-1044','FLIP-1046','FLIP-1047','FLIP-1048']::text[], array['FLIP-1034']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260427', '2026-04-27', '2026-05-03', array['SHOP-1041','SHOP-1040','SHOP-1043','SHOP-1044','SHOP-1048','SHOP-1050','SHOP-1051','SHOP-1056']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 05 May 2026
select pg_temp.day('2026-05-05');
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Shree Ambika Textiles (ref R031)', 'SAT/26/0138', 1);
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R033)', 'DC-TKF-0067', '[{"sku":"WTOP-PCH-S","q":8,"a":8,"r":0},{"sku":"WTOP-PCH-M","q":4,"a":4,"r":0},{"sku":"BTEE-BLU-45Y","q":4,"a":4,"r":0},{"sku":"BTEE-RED-45Y","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1057','Amazon - Seller Central','2026-05-05 09:44+05:30','Sanjay Gajera','prepaid',3426.0,342.6,154.18,3237.58,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1062','Shopify - Main Store','2026-05-05 21:59+05:30','Kunal Desai','prepaid',1999.0,99.95,94.95,1994.0,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1063','Shopify - Main Store','2026-05-05 13:01+05:30','Sonal Parekh','cod',1797.0,89.85,85.35,1792.5,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1064','Shopify - Main Store','2026-05-05 12:18+05:30','Harsh Modi','cod',329.0,0.0,16.45,345.45,'shipped','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1056','Flipkart - Seller Hub','2026-05-05 12:56+05:30','Nidhi Agarwal','cod',749.0,0.0,37.45,786.45,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1058','Amazon - Seller Central','2026-05-05 09:40+05:30','Rohit Iyer','prepaid',3647.0,0.0,182.35,3829.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1065','Shopify - Main Store','2026-05-05 11:19+05:30','Riya Shah','cod',4495.0,224.75,213.52,4483.77,'shipped','pending','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1057','MCHN-KHK-30',2,1199,239.8,107.91),
('AMAZ-1057','GFRK-PNK-67Y',1,749,74.9,33.71),
('AMAZ-1057','GLEG-PNK-89Y',1,279,27.9,12.56),
('SHOP-1062','GLHG-RED-67Y',1,1999,99.95,94.95),
('SHOP-1063','WTOP-PCH-L',1,599,29.95,28.45),
('SHOP-1063','WTOP-PCH-M',1,599,29.95,28.45),
('SHOP-1063','WPAL-WHT-M',1,599,29.95,28.45),
('SHOP-1064','BTEE-BLU-67Y',1,329,0.0,16.45),
('FLIP-1056','GFRK-PNK-67Y',1,749,0.0,37.45),
('AMAZ-1058','BKUR-MUS-89Y',1,949,0.0,47.45),
('AMAZ-1058','WJNS-IND-32',2,1349,0.0,134.9),
('SHOP-1065','WJNS-IND-28',2,1349,134.9,128.16),
('SHOP-1065','WTOP-WHT-M',2,599,59.9,56.91),
('SHOP-1065','WTOP-PCH-S',1,599,29.95,28.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1063','Xpressbees - Pandesara'),
('FLIP-1056','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1035');
select pg_temp.ret_dispo('SHOP-1037', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1047', 'approved');
select pg_temp.cod_collect(array['SHOP-1057']::text[]);
select pg_temp.cod_collect(array['SHOP-1058']::text[]);
select pg_temp.settle_pay('FLK-STL-20260420', 0.0);
select pg_temp.retime();

-- Wed 06 May 2026
select pg_temp.day('2026-05-06');
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R033)', 'TKF/26/0166', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1066','Shopify - Main Store','2026-05-06 22:05+05:30','Neha Patel','prepaid',6845.0,342.25,325.13,6827.88,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1059','Amazon - Seller Central','2026-05-06 11:34+05:30','Aditi Joshi','prepaid',3054.0,305.4,137.44,2886.04,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1060','Amazon - Seller Central','2026-05-06 14:23+05:30','Isha Gupta','prepaid',2677.0,0.0,133.85,2810.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1057','Flipkart - Seller Hub','2026-05-06 20:17+05:30','Divya Nair','prepaid',2598.0,0.0,129.9,2727.9,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1066','MJNS-IND-30',1,1399,69.95,66.45),
('SHOP-1066','WJNS-IND-32',3,1349,202.35,192.23),
('SHOP-1066','MJNS-IND-32',1,1399,69.95,66.45),
('AMAZ-1059','BTEE-BLU-45Y',2,329,65.8,29.61),
('AMAZ-1059','WTOP-PCH-M',3,599,179.7,80.87),
('AMAZ-1059','WTOP-PCH-L',1,599,59.9,26.96),
('AMAZ-1060','MCHN-KHK-30',2,1199,0.0,119.9),
('AMAZ-1060','GLEG-BLK-67Y',1,279,0.0,13.95),
('FLIP-1057','MCHN-KHK-30',1,1199,0.0,59.95),
('FLIP-1057','MJNS-BLK-32',1,1399,0.0,69.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_set('FLIP-1040', 'in_transit');
select pg_temp.ret_set('SHOP-1036', 'in_transit');
select pg_temp.rto_recv('AMAZ-1036', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1047', 'pickup');
select pg_temp.rto_set('AMAZ-1043', 'in_transit');
select pg_temp.ret_new('AMAZ-1045', 'Item arrived damaged', 'webhook');
select pg_temp.rto_new('FLIP-1051', 'AWB31000122', 'Delivery attempts exhausted');
select pg_temp.settle_pay('SHP-STL-20260427', 0.0);
select pg_temp.retime();

-- Thu 07 May 2026
select pg_temp.day('2026-05-07');
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Rajdhani Shirting Mills (ref R030)', 'DC-RSM-0064', '[{"sku":"MSHC-RED-L","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R032)', 'DC-TKF-0064', '[{"sku":"WTOP-PCH-M","q":8,"a":7,"r":1},{"sku":"BTEE-RED-67Y","q":6,"a":6,"r":0},{"sku":"BTEE-RED-89Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1061','Amazon - Seller Central','2026-05-07 09:33+05:30','Meghna Rao','prepaid',658.0,65.8,29.61,621.81,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1067','Shopify - Main Store','2026-05-07 14:43+05:30','Meghna Rao','prepaid',349.0,0.0,17.45,366.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1068','Shopify - Main Store','2026-05-07 15:45+05:30','Meghna Rao','prepaid',2278.0,0.0,113.9,2391.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1058','Flipkart - Seller Hub','2026-05-07 14:06+05:30','Kiran Naik','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1061','BTEE-BLU-89Y',2,329,65.8,29.61),
('SHOP-1067','BSHT-NVY-67Y',1,349,0.0,17.45),
('SHOP-1068','GLEG-BLK-67Y',1,279,0.0,13.95),
('SHOP-1068','GLHG-RED-67Y',1,1999,0.0,99.95),
('FLIP-1058','MCHN-OLV-32',1,1199,119.9,53.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('FLIP-1035', 'good', 'restocked');
select pg_temp.ret_refund_d2c('SHOP-1037', 'UPI-REFUND-SHOP-1037');
select pg_temp.rto_recv('SHOP-1053', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1045', 'approved');
select pg_temp.retime();

-- Fri 08 May 2026
select pg_temp.day('2026-05-08');
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Rajdhani Shirting Mills (ref R030)', 'RSM/26/0160', 1);
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R032)', 'TKF/26/0158', 1);
select pg_temp.grn_new('Weekly replenishment 04 May 2026 - Krishna Denim Works (ref R034)', 'DC-KDW-0061', '[{"sku":"MJNS-IND-32","q":10,"a":10,"r":0},{"sku":"MJNS-IND-34","q":12,"a":12,"r":0},{"sku":"MCHN-OLV-30","q":6,"a":6,"r":0},{"sku":"MCHN-OLV-34","q":18,"a":18,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 04 May 2026 - Rajdhani Shirting Mills (ref R036)', 'DC-RSM-0073', '[{"sku":"MSHC-RED-XL","q":10,"a":10,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 04 May 2026 - Shree Ambika Textiles (ref R037)', 'DC-SAT-0058', '[{"sku":"WLHG-RED-M","q":6,"a":6,"r":0},{"sku":"WDUP-SLV-FREE","q":6,"a":5,"r":1}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1062','Amazon - Seller Central','2026-05-08 17:05+05:30','Ritu Saxena','prepaid',329.0,16.45,15.63,328.18,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1069','Shopify - Main Store','2026-05-08 19:46+05:30','Sanjay Gajera','cod',2598.0,129.9,123.4,2591.5,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1070','Shopify - Main Store','2026-05-08 09:12+05:30','Tanvi Rana','prepaid',349.0,0.0,17.45,366.45,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('SHOP-1071','Shopify - Main Store','2026-05-08 12:05+05:30','Jigar Chauhan','cod',3694.0,369.4,166.24,3490.84,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1059','Flipkart - Seller Hub','2026-05-08 09:03+05:30','Aditi Joshi','cod',5645.0,564.5,254.04,5334.54,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1060','Flipkart - Seller Hub','2026-05-08 11:07+05:30','Kavya Menon','prepaid',7496.0,0.0,374.8,7870.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1063','Amazon - Seller Central','2026-05-08 16:26+05:30','Kavya Menon','prepaid',3048.0,0.0,152.4,3200.4,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1064','Amazon - Seller Central','2026-05-08 16:09+05:30','Divya Nair','prepaid',5546.0,0.0,277.3,5823.3,'shipped','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1062','BTEE-RED-45Y',1,329,16.45,15.63),
('SHOP-1069','MCHN-OLV-34',1,1199,59.95,56.95),
('SHOP-1069','MJNS-IND-32',1,1399,69.95,66.45),
('SHOP-1070','BSHT-NVY-89Y',1,349,0.0,17.45),
('SHOP-1071','WTOP-WHT-M',2,599,119.8,53.91),
('SHOP-1071','WKRT-PNK-M',2,849,169.8,76.41),
('SHOP-1071','WDUP-GLD-FREE',1,449,44.9,20.21),
('SHOP-1071','WLEG-MAR-M',1,349,34.9,15.71),
('FLIP-1059','MJNS-BLK-32',1,1399,139.9,62.96),
('FLIP-1059','MTRK-BLK-L',1,649,64.9,29.21),
('FLIP-1059','MCHN-KHK-30',2,1199,239.8,107.91),
('FLIP-1059','MCHN-OLV-32',1,1199,119.9,53.96),
('FLIP-1060','WDRS-FLP-S',1,1499,0.0,74.95),
('FLIP-1060','GLHG-RED-45Y',3,1999,0.0,299.85),
('AMAZ-1063','WSAR-BLU-FREE',1,2199,0.0,109.95),
('AMAZ-1063','WKRT-TEL-XL',1,849,0.0,42.45),
('AMAZ-1064','WDRS-FLP-S',1,1499,0.0,74.95),
('AMAZ-1064','WJNS-IND-28',3,1349,0.0,202.35)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1069','Delhivery - Sachin GIDC Surat'),
('SHOP-1071','Xpressbees - Pandesara'),
('FLIP-1059','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('SHOP-1036');
select pg_temp.ret_set('FLIP-1047', 'in_transit');
select pg_temp.ret_new('FLIP-1048', 'Item arrived damaged', 'webhook');
select pg_temp.ret_set('AMAZ-1045', 'pickup');
select pg_temp.ret_new('AMAZ-1046', 'Customer changed mind', 'webhook');
select pg_temp.rto_set('FLIP-1051', 'in_transit');
select pg_temp.rto_new('SHOP-1061', 'AWB31000146', 'Address incomplete');
select pg_temp.cod_collect(array['FLIP-1055']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-08MAY', array['SHOP-1055']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-08MAY', array['SHOP-1047']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-08MAY', array['SHOP-1052','SHOP-1057']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-08MAY', array['SHOP-1049','SHOP-1058','AMAZ-1049']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-05-11', 'ICIC000000881431', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-05-11', 'ICIC000000881466', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-05-11', 'ICIC000000881563', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-05-11', 'ICIC000000881616', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-05-11', 'ICIC000000881638', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-05-11', 'ICIC000000881712', 1);
select pg_temp.retime();

-- Sat 09 May 2026
select pg_temp.day('2026-05-09');
select pg_temp.grn_new('Weekly replenishment 27 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R033)', 'DC-TKF-0070', '[{"sku":"WTOP-PCH-S","q":4,"a":4,"r":0},{"sku":"WTOP-PCH-M","q":2,"a":2,"r":0},{"sku":"BTEE-BLU-45Y","q":2,"a":2,"r":0},{"sku":"BTEE-RED-45Y","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 04 May 2026 - Krishna Denim Works (ref R034)', 'KDW/26/0151', 1);
select pg_temp.bill_po('Weekly replenishment 04 May 2026 - Rajdhani Shirting Mills (ref R036)', 'RSM/26/0179', 1);
select pg_temp.bill_po('Weekly replenishment 04 May 2026 - Shree Ambika Textiles (ref R037)', 'SAT/26/0148', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1065','Amazon - Seller Central','2026-05-09 14:56+05:30','Manav Joshi','prepaid',329.0,0.0,16.45,345.45,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1066','Amazon - Seller Central','2026-05-09 10:49+05:30','Rahul Bhatt','prepaid',1298.0,0.0,64.9,1362.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1067','Amazon - Seller Central','2026-05-09 18:02+05:30','Sanjay Gajera','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1072','Shopify - Main Store','2026-05-09 21:14+05:30','Chirag Zaveri','prepaid',1856.0,92.8,88.17,1851.37,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1068','Amazon - Seller Central','2026-05-09 22:17+05:30','Chirag Zaveri','cod',1448.0,0.0,72.4,1520.4,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1069','Amazon - Seller Central','2026-05-09 10:09+05:30','Yash Vora','prepaid',2697.0,0.0,134.85,2831.85,'cancelled','refunded','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1065','BTEE-BLU-67Y',1,329,0.0,16.45),
('AMAZ-1066','MTRK-BLK-M',2,649,0.0,64.9),
('AMAZ-1067','WTOP-PCH-L',2,599,0.0,59.9),
('SHOP-1072','BTEE-BLU-89Y',1,329,16.45,15.63),
('SHOP-1072','WPAL-YLW-L',2,599,59.9,56.91),
('SHOP-1072','BTEE-RED-45Y',1,329,16.45,15.63),
('AMAZ-1068','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1068','WKRT-PNK-XL',1,849,0.0,42.45),
('AMAZ-1069','MSHC-RED-M',3,899,0.0,134.85)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1068','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('SHOP-1036', 'damaged', 'quarantined');
select pg_temp.ret_set('FLIP-1048', 'approved');
select pg_temp.ret_set('AMAZ-1046', 'approved');
select pg_temp.rto_new('SHOP-1064', 'AWB31000153', 'Address incomplete');
select pg_temp.retime();

-- Sun 10 May 2026
select pg_temp.day('2026-05-10');
select pg_temp.bill_po('Weekly replenishment 27 Apr 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R033)', 'TKF/26/0175', 1);
select pg_temp.grn_new('Weekly replenishment 04 May 2026 - Rajdhani Shirting Mills (ref R035)', 'DC-RSM-0067', '[{"sku":"MSHC-RED-XL","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1070','Amazon - Seller Central','2026-05-10 22:16+05:30','Mitul Dave','prepaid',599.0,29.95,28.45,597.5,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1073','Shopify - Main Store','2026-05-10 20:39+05:30','Mehul Shukla','prepaid',987.0,98.7,44.42,932.72,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1074','Shopify - Main Store','2026-05-10 18:01+05:30','Divya Nair','cod',949.0,0.0,47.45,996.45,'shipped','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1075','Shopify - Main Store','2026-05-10 13:04+05:30','Pratik Lad','cod',1898.0,0.0,94.9,1992.9,'delivered','pending','Delhi','Surat Main Warehouse'),
('SHOP-1076','Shopify - Main Store','2026-05-10 11:27+05:30','Pratik Lad','prepaid',2048.0,102.4,97.28,2042.88,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1070','BSHF-WHT-67Y',1,599,29.95,28.45),
('SHOP-1073','BTEE-BLU-67Y',1,329,32.9,14.81),
('SHOP-1073','BTEE-RED-89Y',2,329,65.8,29.61),
('SHOP-1074','BKUR-CRM-45Y',1,949,0.0,47.45),
('SHOP-1075','BKUR-MUS-89Y',2,949,0.0,94.9),
('SHOP-1076','MTRK-BLK-M',1,649,32.45,30.83),
('SHOP-1076','MJNS-IND-32',1,1399,69.95,66.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1075','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1040');
select pg_temp.ret_set('FLIP-1048', 'pickup');
select pg_temp.ret_set('AMAZ-1045', 'in_transit');
select pg_temp.ret_set('AMAZ-1046', 'pickup');
select pg_temp.rto_set('SHOP-1061', 'in_transit');
select pg_temp.rto_new('SHOP-1065', 'AWB31000174', 'Customer refused delivery');
select pg_temp.settle_pay('AMZ-STL-20260427', 0.0);
select pg_temp.retime();

-- Mon 11 May 2026
select pg_temp.day('2026-05-11');
select pg_temp.bill_po('Weekly replenishment 04 May 2026 - Rajdhani Shirting Mills (ref R035)', 'RSM/26/0167', 1);
select pg_temp.po_new('Weekly replenishment 11 May 2026 - Krishna Denim Works (ref R040)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MCHN-KHK-30","q":12},{"sku":"MCHN-OLV-32","q":8},{"sku":"WJNS-IND-32","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 11 May 2026 - Little Stitch Garments (ref R041)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"BKUR-MUS-89Y","q":8},{"sku":"GLHG-RED-45Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 11 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R042)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"WLEG-MAR-L","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 11 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R043)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MTRK-BLK-M","q":12},{"sku":"MTRK-BLK-L","q":10},{"sku":"WLEG-MAR-M","q":6},{"sku":"WLEG-MAR-L","q":6},{"sku":"WTOP-PCH-M","q":14},{"sku":"WTOP-PCH-L","q":14},{"sku":"BTEE-BLU-89Y","q":10},{"sku":"GLEG-BLK-67Y","q":8}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1071','Amazon - Seller Central','2026-05-11 11:23+05:30','Yash Vora','cod',3256.0,0.0,162.8,3418.8,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1061','Flipkart - Seller Hub','2026-05-11 19:52+05:30','Kiran Naik','prepaid',1248.0,0.0,62.4,1310.4,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1062','Flipkart - Seller Hub','2026-05-11 16:02+05:30','Dev Trivedi','prepaid',1098.0,0.0,54.9,1152.9,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1072','Amazon - Seller Central','2026-05-11 13:01+05:30','Divya Nair','prepaid',6544.0,327.2,310.85,6527.65,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1077','Shopify - Main Store','2026-05-11 12:43+05:30','Sonal Parekh','cod',1199.0,0.0,59.95,1258.95,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1073','Amazon - Seller Central','2026-05-11 15:44+05:30','Shreya Banerjee','prepaid',2897.0,289.7,130.38,2737.68,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1063','Flipkart - Seller Hub','2026-05-11 15:51+05:30','Sagar Rathod','prepaid',2197.0,219.7,98.88,2076.18,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1074','Amazon - Seller Central','2026-05-11 10:10+05:30','Neha Patel','prepaid',3796.0,379.6,170.83,3587.23,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1071','MPOL-NVY-XL',1,699,0.0,34.95),
('AMAZ-1071','GLHG-TEL-89Y',1,1999,0.0,99.95),
('AMAZ-1071','GLEG-PNK-67Y',1,279,0.0,13.95),
('AMAZ-1071','GLEG-BLK-89Y',1,279,0.0,13.95),
('FLIP-1061','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1061','MTRK-BLK-L',1,649,0.0,32.45),
('FLIP-1062','GTOP-WHT-89Y',1,349,0.0,17.45),
('FLIP-1062','GFRK-LIL-89Y',1,749,0.0,37.45),
('AMAZ-1072','WDRS-FLP-M',1,1499,74.95,71.2),
('AMAZ-1072','WKRT-TEL-L',1,849,42.45,40.33),
('AMAZ-1072','WTOP-PCH-L',2,599,59.9,56.91),
('AMAZ-1072','WDRS-FLR-S',2,1499,149.9,142.41),
('SHOP-1077','MCHN-OLV-30',1,1199,0.0,59.95),
('AMAZ-1073','WJNS-IND-28',1,1349,134.9,60.71),
('AMAZ-1073','MCHN-KHK-34',1,1199,119.9,53.96),
('AMAZ-1073','WLEG-BLK-L',1,349,34.9,15.71),
('FLIP-1063','MTRK-BLK-L',1,649,64.9,29.21),
('FLIP-1063','MTRK-BLK-M',1,649,64.9,29.21),
('FLIP-1063','MSHC-GRN-L',1,899,89.9,40.46),
('AMAZ-1074','BKUR-MUS-45Y',1,949,94.9,42.71),
('AMAZ-1074','BKUR-CRM-67Y',3,949,284.7,128.12)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1077','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1040', 'good', 'restocked');
select pg_temp.ret_refund_d2c('SHOP-1036', 'UPI-REFUND-SHOP-1036');
select pg_temp.ret_recv('FLIP-1047');
select pg_temp.ret_new('AMAZ-1042', 'Size did not fit', 'webhook');
select pg_temp.cod_collect(array['SHOP-1063']::text[]);
select pg_temp.rto_set('SHOP-1064', 'in_transit');
select pg_temp.cod_collect(array['FLIP-1056']::text[]);
select pg_temp.cod_collect(array['SHOP-1069']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260504', '2026-05-04', '2026-05-10', array['AMAZ-1042','AMAZ-1045','AMAZ-1048','AMAZ-1044','AMAZ-1047','AMAZ-1051','AMAZ-1050','AMAZ-1052','AMAZ-1053','AMAZ-1054','AMAZ-1055','AMAZ-1056','AMAZ-1057','AMAZ-1060','AMAZ-1058','AMAZ-1059']::text[], array[]::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260504', '2026-05-04', '2026-05-10', array['FLIP-1049','FLIP-1052','FLIP-1050','FLIP-1053','FLIP-1054']::text[], array['FLIP-1035','FLIP-1040']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260504', '2026-05-04', '2026-05-10', array['SHOP-1059','SHOP-1060','SHOP-1062']::text[], array[]::text[]);
select pg_temp.retime();

-- Tue 12 May 2026
select pg_temp.day('2026-05-12');
select pg_temp.grn_new('Weekly replenishment 04 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R038)', 'DC-TKF-0073', '[{"sku":"BTEE-RED-67Y","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1078','Shopify - Main Store','2026-05-12 16:41+05:30','Prachi Kulkarni','prepaid',3796.0,0.0,189.8,3985.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1075','Amazon - Seller Central','2026-05-12 14:17+05:30','Chirag Zaveri','prepaid',1797.0,0.0,89.85,1886.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1076','Amazon - Seller Central','2026-05-12 09:34+05:30','Nidhi Agarwal','prepaid',649.0,0.0,32.45,681.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1079','Shopify - Main Store','2026-05-12 09:05+05:30','Sanjay Gajera','prepaid',2396.0,0.0,119.8,2515.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1077','Amazon - Seller Central','2026-05-12 13:02+05:30','Bhavna Solanki','prepaid',2697.0,134.85,128.11,2690.26,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1078','Amazon - Seller Central','2026-05-12 13:10+05:30','Divya Nair','prepaid',2848.0,0.0,142.4,2990.4,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1078','BKUR-CRM-89Y',2,949,0.0,94.9),
('SHOP-1078','BKUR-MUS-89Y',1,949,0.0,47.45),
('SHOP-1078','BKUR-MUS-45Y',1,949,0.0,47.45),
('AMAZ-1075','WTOP-WHT-M',3,599,0.0,89.85),
('AMAZ-1076','MTRK-BLK-M',1,649,0.0,32.45),
('SHOP-1079','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1079','WLEG-NVY-M',1,349,0.0,17.45),
('SHOP-1079','WTOP-PCH-M',1,599,0.0,29.95),
('SHOP-1079','WKRT-TEL-XL',1,849,0.0,42.45),
('AMAZ-1077','MSHF-WHT-L',2,999,99.9,94.91),
('AMAZ-1077','MPOL-MRN-XL',1,699,34.95,33.2),
('AMAZ-1078','WJNS-IND-30',1,1349,0.0,67.45),
('AMAZ-1078','WDRS-FLP-M',1,1499,0.0,74.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_set('FLIP-1048', 'in_transit');
select pg_temp.ret_set('AMAZ-1042', 'approved');
select pg_temp.ret_set('AMAZ-1046', 'in_transit');
select pg_temp.rto_recv('FLIP-1051', 'good', 'restocked');
select pg_temp.rto_set('SHOP-1065', 'in_transit');
select pg_temp.rto_new('AMAZ-1064', 'AWB31000204', 'Customer unreachable');
select pg_temp.cod_collect(array['AMAZ-1068']::text[]);
select pg_temp.settle_pay('FLK-STL-20260427', 0.0);
select pg_temp.retime();

-- Wed 13 May 2026
select pg_temp.day('2026-05-13');
select pg_temp.bill_po('Weekly replenishment 04 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R038)', 'TKF/26/0179', 1);
select pg_temp.grn_new('Weekly replenishment 04 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R039)', 'DC-TKF-0076', '[{"sku":"MTRK-BLK-M","q":8,"a":8,"r":0},{"sku":"MTRK-BLK-L","q":8,"a":8,"r":0},{"sku":"WLEG-MAR-L","q":6,"a":5,"r":1},{"sku":"WTOP-PCH-M","q":10,"a":10,"r":0},{"sku":"WTOP-PCH-L","q":10,"a":10,"r":0},{"sku":"GLEG-BLK-45Y","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1080','Shopify - Main Store','2026-05-13 15:55+05:30','Divya Nair','prepaid',3247.0,0.0,162.35,3409.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1079','Amazon - Seller Central','2026-05-13 09:03+05:30','Mehul Shukla','cod',1499.0,0.0,74.95,1573.95,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1081','Shopify - Main Store','2026-05-13 12:51+05:30','Sejal Kapadia','cod',1798.0,89.9,85.41,1793.51,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1064','Flipkart - Seller Hub','2026-05-13 11:46+05:30','Pooja Jain','prepaid',558.0,0.0,27.9,585.9,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1065','Flipkart - Seller Hub','2026-05-13 16:01+05:30','Meghna Rao','prepaid',1777.0,88.85,84.41,1772.56,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1080','MJNS-BLK-32',1,1399,0.0,69.95),
('SHOP-1080','MTRK-BLK-L',1,649,0.0,32.45),
('SHOP-1080','MCHN-KHK-30',1,1199,0.0,59.95),
('AMAZ-1079','WDRS-FLP-S',1,1499,0.0,74.95),
('SHOP-1081','MSHC-GRN-L',2,899,89.9,85.41),
('FLIP-1064','GLEG-PNK-67Y',2,279,0.0,27.9),
('FLIP-1065','GLEG-PNK-67Y',1,279,13.95,13.25),
('FLIP-1065','GFRK-PNK-67Y',2,749,74.9,71.16)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1079','Ecom Express - Udhna Hub'),
('SHOP-1081','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1047', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1042', 'pickup');
select pg_temp.settle_pay('SHP-STL-20260504', 0.0);
select pg_temp.claim_new('AMAZ-1015', 'lost_shipment', 6557.25, '2026-06-12');
select pg_temp.retime();

-- Thu 14 May 2026
select pg_temp.day('2026-05-14');
select pg_temp.grn_new('Weekly replenishment 04 May 2026 - Rajdhani Shirting Mills (ref R035)', 'DC-RSM-0070', '[{"sku":"MSHC-RED-XL","q":2,"a":2,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 04 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R039)', 'TKF/26/0190', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1066','Flipkart - Seller Hub','2026-05-14 12:05+05:30','Heena Khan','prepaid',2297.0,0.0,114.85,2411.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1080','Amazon - Seller Central','2026-05-14 09:50+05:30','Kavya Menon','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1081','Amazon - Seller Central','2026-05-14 11:50+05:30','Karan Malhotra','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1082','Amazon - Seller Central','2026-05-14 12:18+05:30','Sejal Kapadia','prepaid',9646.0,482.3,1396.54,10560.24,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1083','Amazon - Seller Central','2026-05-14 10:28+05:30','Mehul Shukla','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1084','Amazon - Seller Central','2026-05-14 09:59+05:30','Aditi Joshi','prepaid',949.0,94.9,42.71,896.81,'delivered','paid','West Bengal','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1066','WKRT-PNK-S',2,849,0.0,84.9),
('FLIP-1066','WTOP-PCH-L',1,599,0.0,29.95),
('AMAZ-1080','WTOP-PCH-M',2,599,0.0,59.9),
('AMAZ-1081','WTOP-PCH-M',1,599,0.0,29.95),
('AMAZ-1082','MTRK-BLK-M',1,649,32.45,30.83),
('AMAZ-1082','MJNS-IND-34',1,1399,69.95,66.45),
('AMAZ-1082','MBLZ-NVY-40',2,3799,379.9,1299.26),
('AMAZ-1083','WKRT-PNK-M',1,849,0.0,42.45),
('AMAZ-1083','WLEG-BLK-L',1,349,0.0,17.45),
('AMAZ-1084','BKUR-MUS-67Y',1,949,94.9,42.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_recv('AMAZ-1045');
select pg_temp.cod_collect(array['SHOP-1071']::text[]);
select pg_temp.cod_collect(array['FLIP-1059']::text[]);
select pg_temp.rto_set('AMAZ-1064', 'in_transit');
select pg_temp.rto_new('AMAZ-1065', 'AWB31000229', 'Address incomplete');
select pg_temp.rto_new('SHOP-1074', 'AWB31000252', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['SHOP-1077']::text[]);
select pg_temp.retime();

-- Fri 15 May 2026
select pg_temp.day('2026-05-15');
select pg_temp.bill_po('Weekly replenishment 04 May 2026 - Rajdhani Shirting Mills (ref R035)', 'RSM/26/0173', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1085','Amazon - Seller Central','2026-05-15 18:20+05:30','Tanvi Rana','prepaid',2098.0,0.0,104.9,2202.9,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1067','Flipkart - Seller Hub','2026-05-15 12:19+05:30','Aditi Joshi','prepaid',3846.0,192.3,182.68,3836.38,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1086','Amazon - Seller Central','2026-05-15 22:17+05:30','Rahul Bhatt','prepaid',8156.0,407.8,1325.77,9073.97,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1082','Shopify - Main Store','2026-05-15 10:34+05:30','Dev Trivedi','cod',4846.0,0.0,242.3,5088.3,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1068','Flipkart - Seller Hub','2026-05-15 21:33+05:30','Kunal Desai','prepaid',2396.0,0.0,119.8,2515.8,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1083','Shopify - Main Store','2026-05-15 16:21+05:30','Chirag Zaveri','prepaid',699.0,0.0,34.95,733.95,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1085','MPOL-NVY-M',1,699,0.0,34.95),
('AMAZ-1085','MJNS-BLK-30',1,1399,0.0,69.95),
('FLIP-1067','MCHN-KHK-30',1,1199,59.95,56.95),
('FLIP-1067','MTRK-BLK-L',1,649,32.45,30.83),
('FLIP-1067','MKUR-WHT-XL',1,1099,54.95,52.2),
('FLIP-1067','MSHC-GRN-L',1,899,44.95,42.7),
('AMAZ-1086','GLEG-PNK-67Y',2,279,27.9,26.51),
('AMAZ-1086','MBLZ-NVY-38',2,3799,379.9,1299.26),
('SHOP-1082','WLEG-BLK-M',1,349,0.0,17.45),
('SHOP-1082','WDRS-FLP-S',2,1499,0.0,149.9),
('SHOP-1082','WDRS-FLP-M',1,1499,0.0,74.95),
('FLIP-1068','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1068','WTOP-PCH-S',2,599,0.0,59.9),
('FLIP-1068','WPAL-YLW-XL',1,599,0.0,29.95),
('SHOP-1083','MPOL-NVY-M',1,699,0.0,34.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1082','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1042', 'in_transit');
select pg_temp.ret_dispo('AMAZ-1045', 'damaged', 'quarantined');
select pg_temp.ret_recv('AMAZ-1046');
select pg_temp.rto_recv('SHOP-1061', 'good', 'restocked');
select pg_temp.rto_recv('SHOP-1064', 'good', 'restocked');
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-15MAY', array['SHOP-1069','AMAZ-1068']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-15MAY', array['FLIP-1056']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-15MAY', array['FLIP-1055']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-15MAY', array['SHOP-1063']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-05-18', 'ICIC000000881746', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-05-18', 'ICIC000000881822', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-05-18', 'ICIC000000881893', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-05-18', 'ICIC000000881965', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-05-18', 'ICIC000000881987', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-05-18', 'ICIC000000882061', 1);
select pg_temp.claim_new('AMAZ-1045', 'damaged_return', 339.64, '2026-06-14');
select pg_temp.retime();

-- Sat 16 May 2026
select pg_temp.day('2026-05-16');
select pg_temp.grn_new('Weekly replenishment 11 May 2026 - Krishna Denim Works (ref R040)', 'DC-KDW-0064', '[{"sku":"MCHN-KHK-30","q":8,"a":8,"r":0},{"sku":"MCHN-OLV-32","q":5,"a":5,"r":0},{"sku":"WJNS-IND-32","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 11 May 2026 - Little Stitch Garments (ref R041)', 'DC-LSG-0067', '[{"sku":"BKUR-MUS-89Y","q":5,"a":5,"r":0},{"sku":"GLHG-RED-45Y","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1069','Flipkart - Seller Hub','2026-05-16 10:53+05:30','Aarav Mehta','prepaid',3446.0,0.0,172.3,3618.3,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1070','Flipkart - Seller Hub','2026-05-16 22:42+05:30','Sanjay Gajera','cod',1797.0,89.85,85.35,1792.5,'cancelled','failed','Rajasthan','Surat Main Warehouse'),
('AMAZ-1087','Amazon - Seller Central','2026-05-16 13:12+05:30','Bhavna Solanki','prepaid',2547.0,0.0,127.35,2674.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1071','Flipkart - Seller Hub','2026-05-16 09:09+05:30','Vivek Singh','prepaid',4998.0,0.0,743.77,5741.77,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1084','Shopify - Main Store','2026-05-16 21:06+05:30','Sagar Rathod','cod',2947.0,0.0,147.35,3094.35,'delivered','pending','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1069','MCHN-KHK-30',1,1199,0.0,59.95),
('FLIP-1069','MTRK-BLK-M',1,649,0.0,32.45),
('FLIP-1069','MPOL-MRN-XL',1,699,0.0,34.95),
('FLIP-1069','MSHC-GRN-L',1,899,0.0,44.95),
('FLIP-1070','WTOP-WHT-L',1,599,29.95,28.45),
('FLIP-1070','WTOP-PCH-L',1,599,29.95,28.45),
('FLIP-1070','WTOP-WHT-M',1,599,29.95,28.45),
('AMAZ-1087','WKRT-PNK-S',3,849,0.0,127.35),
('FLIP-1071','MCHN-KHK-30',1,1199,0.0,59.95),
('FLIP-1071','MBLZ-NVY-40',1,3799,0.0,683.82),
('SHOP-1084','MJNS-BLK-34',1,1399,0.0,69.95),
('SHOP-1084','MSHC-GRN-M',1,899,0.0,44.95),
('SHOP-1084','MTRK-BLK-L',1,649,0.0,32.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1084','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1048');
select pg_temp.rto_set('AMAZ-1065', 'in_transit');
select pg_temp.rto_set('SHOP-1074', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1075']::text[]);
select pg_temp.rto_new('AMAZ-1071', 'AWB31000257', 'Address incomplete');
select pg_temp.claim_step('AMAZ-1015', 'lost_shipment', 'claimed', null);
select pg_temp.retime();

-- Sun 17 May 2026
select pg_temp.day('2026-05-17');
select pg_temp.bill_po('Weekly replenishment 11 May 2026 - Krishna Denim Works (ref R040)', 'KDW/26/0161', 1);
select pg_temp.bill_po('Weekly replenishment 11 May 2026 - Little Stitch Garments (ref R041)', 'LSG/26/0163', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1072','Flipkart - Seller Hub','2026-05-17 13:38+05:30','Manav Joshi','prepaid',1207.0,0.0,60.35,1267.35,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1088','Amazon - Seller Central','2026-05-17 12:07+05:30','Kavya Menon','prepaid',1648.0,82.4,78.28,1643.88,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1085','Shopify - Main Store','2026-05-17 20:33+05:30','Kiran Naik','prepaid',449.0,0.0,22.45,471.45,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1089','Amazon - Seller Central','2026-05-17 15:58+05:30','Aditi Joshi','prepaid',3497.0,174.85,166.11,3488.26,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1073','Flipkart - Seller Hub','2026-05-17 16:15+05:30','Heena Khan','prepaid',279.0,0.0,13.95,292.95,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('FLIP-1074','Flipkart - Seller Hub','2026-05-17 18:44+05:30','Karan Malhotra','prepaid',2998.0,299.8,134.91,2833.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1086','Shopify - Main Store','2026-05-17 13:06+05:30','Meghna Rao','cod',1399.0,0.0,69.95,1468.95,'delivered','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1072','GLEG-PNK-45Y',2,279,0.0,27.9),
('FLIP-1072','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1088','MTRK-BLK-L',1,649,32.45,30.83),
('AMAZ-1088','MSHF-WHT-XL',1,999,49.95,47.45),
('SHOP-1085','WDUP-SLV-FREE',1,449,0.0,22.45),
('AMAZ-1089','MJNS-IND-34',2,1399,139.9,132.91),
('AMAZ-1089','MPOL-NVY-M',1,699,34.95,33.2),
('FLIP-1073','GLEG-PNK-67Y',1,279,0.0,13.95),
('FLIP-1074','WDRS-FLP-L',2,1499,299.8,134.91),
('SHOP-1086','MJNS-IND-32',1,1399,0.0,69.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1086','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1046', 'good', 'restocked');
select pg_temp.cod_collect(array['SHOP-1081']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260504', 0.0);
select pg_temp.retime();

-- Mon 18 May 2026
select pg_temp.day('2026-05-18');
select pg_temp.po_new('Weekly replenishment 18 May 2026 - Krishna Denim Works (ref R044)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MJNS-IND-34","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 18 May 2026 - Little Stitch Garments (ref R045)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLP-S","q":14},{"sku":"WDRS-FLP-M","q":6},{"sku":"BKUR-MUS-45Y","q":8},{"sku":"GFRK-PNK-67Y","q":6},{"sku":"GFRK-LIL-89Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 18 May 2026 - Rajdhani Shirting Mills (ref R046)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MBLZ-NVY-38","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 18 May 2026 - Rajdhani Shirting Mills (ref R047)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-GRN-L","q":6},{"sku":"MBLZ-NVY-40","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 18 May 2026 - Shree Ambika Textiles (ref R048)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-S","q":10},{"sku":"WKRT-PNK-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 18 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R049)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MPOL-NVY-M","q":6},{"sku":"MPOL-MRN-XL","q":6},{"sku":"WLEG-MAR-L","q":8},{"sku":"GLEG-PNK-67Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 18 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R050)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"WLEG-BLK-L","q":8},{"sku":"WLEG-MAR-M","q":6},{"sku":"WTOP-PCH-L","q":12},{"sku":"BTEE-BLU-89Y","q":8},{"sku":"GLEG-BLK-67Y","q":8},{"sku":"GLEG-PNK-45Y","q":8},{"sku":"GLEG-PNK-67Y","q":6}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1090','Amazon - Seller Central','2026-05-18 14:33+05:30','Neha Patel','prepaid',1198.0,0.0,59.9,1257.9,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1091','Amazon - Seller Central','2026-05-18 22:33+05:30','Dev Trivedi','prepaid',2497.0,124.85,118.61,2490.76,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1075','Flipkart - Seller Hub','2026-05-18 19:52+05:30','Rohit Iyer','prepaid',5395.0,0.0,269.75,5664.75,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1092','Amazon - Seller Central','2026-05-18 13:56+05:30','Chirag Zaveri','prepaid',3697.0,0.0,184.85,3881.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1093','Amazon - Seller Central','2026-05-18 22:53+05:30','Yash Vora','prepaid',1199.0,0.0,59.95,1258.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1076','Flipkart - Seller Hub','2026-05-18 12:50+05:30','Kavya Menon','cod',1499.0,0.0,74.95,1573.95,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1077','Flipkart - Seller Hub','2026-05-18 19:16+05:30','Karan Malhotra','prepaid',1748.0,0.0,87.4,1835.4,'delivered','paid','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1090','WPAL-WHT-M',2,599,0.0,59.9),
('AMAZ-1091','BKUR-MUS-45Y',1,949,47.45,45.08),
('AMAZ-1091','BSHF-WHT-89Y',1,599,29.95,28.45),
('AMAZ-1091','BKUR-CRM-89Y',1,949,47.45,45.08),
('FLIP-1075','WTOP-PCH-L',2,599,0.0,59.9),
('FLIP-1075','WJNS-BLK-28',2,1349,0.0,134.9),
('FLIP-1075','WDRS-FLP-L',1,1499,0.0,74.95),
('AMAZ-1092','MSHC-RED-XL',1,899,0.0,44.95),
('AMAZ-1092','MJNS-IND-32',2,1399,0.0,139.9),
('AMAZ-1093','MCHN-KHK-30',1,1199,0.0,59.95),
('FLIP-1076','WDRS-FLR-L',1,1499,0.0,74.95),
('FLIP-1077','MTRK-BLK-M',1,649,0.0,32.45),
('FLIP-1077','MKUR-MUS-M',1,1099,0.0,54.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1076','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1048', 'damaged', 'quarantined');
select pg_temp.rto_recv('SHOP-1065', 'good', 'restocked');
select pg_temp.rto_set('AMAZ-1071', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1082']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260511', '2026-05-11', '2026-05-17', array['AMAZ-1061','AMAZ-1062','AMAZ-1063','AMAZ-1066','AMAZ-1072','AMAZ-1067','AMAZ-1070','AMAZ-1073','AMAZ-1074','AMAZ-1078','AMAZ-1077']::text[], array['AMAZ-1045','AMAZ-1046']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260511', '2026-05-11', '2026-05-17', array['FLIP-1057','FLIP-1058','FLIP-1060','FLIP-1063','FLIP-1061','FLIP-1062','FLIP-1064']::text[], array['FLIP-1047','FLIP-1048']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260511', '2026-05-11', '2026-05-17', array['SHOP-1066','SHOP-1067','SHOP-1068','SHOP-1072','SHOP-1076','SHOP-1073']::text[], array[]::text[]);
select pg_temp.claim_new('FLIP-1048', 'damaged_return', 717.01, '2026-06-17');
select pg_temp.claim_step('AMAZ-1045', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Tue 19 May 2026
select pg_temp.day('2026-05-19');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1094','Amazon - Seller Central','2026-05-19 10:40+05:30','Meghna Rao','prepaid',2897.0,0.0,144.85,3041.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1087','Shopify - Main Store','2026-05-19 14:02+05:30','Manav Joshi','prepaid',2535.0,0.0,126.75,2661.75,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1095','Amazon - Seller Central','2026-05-19 18:22+05:30','Mehul Shukla','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('SHOP-1088','Shopify - Main Store','2026-05-19 16:05+05:30','Neha Patel','cod',6244.0,0.0,312.2,6556.2,'delivered','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1096','Amazon - Seller Central','2026-05-19 18:14+05:30','Rohit Iyer','cod',4196.0,209.8,199.32,4185.52,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1097','Amazon - Seller Central','2026-05-19 22:25+05:30','Sanjay Gajera','cod',449.0,22.45,21.33,447.88,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1089','Shopify - Main Store','2026-05-19 13:48+05:30','Karan Malhotra','prepaid',977.0,0.0,48.85,1025.85,'delivered','paid','West Bengal','Surat Main Warehouse'),
('FLIP-1078','Flipkart - Seller Hub','2026-05-19 12:09+05:30','Pooja Jain','prepaid',4443.0,222.15,211.05,4431.9,'delivered','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1090','Shopify - Main Store','2026-05-19 12:54+05:30','Isha Gupta','prepaid',5346.0,534.6,240.58,5051.98,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1094','WSAR-BLU-FREE',1,2199,0.0,109.95),
('AMAZ-1094','WLEG-BLK-M',2,349,0.0,34.9),
('SHOP-1087','BKUR-CRM-89Y',1,949,0.0,47.45),
('SHOP-1087','BTEE-RED-89Y',1,329,0.0,16.45),
('SHOP-1087','BTEE-RED-45Y',2,329,0.0,32.9),
('SHOP-1087','BSHF-WHT-1011Y',1,599,0.0,29.95),
('AMAZ-1095','WPAL-WHT-M',1,599,0.0,29.95),
('SHOP-1088','MTRK-BLK-L',1,649,0.0,32.45),
('SHOP-1088','MCHN-OLV-30',1,1199,0.0,59.95),
('SHOP-1088','MSHF-SKY-M',2,999,0.0,99.9),
('SHOP-1088','MCHN-OLV-32',2,1199,0.0,119.9),
('AMAZ-1096','MCHN-OLV-34',2,1199,119.9,113.91),
('AMAZ-1096','MSHC-RED-XL',2,899,89.9,85.41),
('AMAZ-1097','WDUP-SLV-FREE',1,449,22.45,21.33),
('SHOP-1089','GTOP-WHT-67Y',2,349,0.0,34.9),
('SHOP-1089','GLEG-BLK-67Y',1,279,0.0,13.95),
('FLIP-1078','WTOP-PCH-S',2,599,59.9,56.91),
('FLIP-1078','WTOP-WHT-M',1,599,29.95,28.45),
('FLIP-1078','WPAL-YLW-XL',3,599,89.85,85.36),
('FLIP-1078','WKRT-PNK-XL',1,849,42.45,40.33),
('SHOP-1090','WTOP-PCH-S',1,599,59.9,26.96),
('SHOP-1090','WSAR-BLU-FREE',2,2199,439.8,197.91),
('SHOP-1090','WLEG-NVY-L',1,349,34.9,15.71)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1088','Delhivery - Sachin GIDC Surat'),
('AMAZ-1096','Bluedart - Surat City'),
('AMAZ-1097','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1042');
select pg_temp.rto_recv('SHOP-1074', 'good', 'restocked');
select pg_temp.cod_collect(array['AMAZ-1079']::text[]);
select pg_temp.settle_pay('FLK-STL-20260504', 0.0);
select pg_temp.retime();

-- Wed 20 May 2026
select pg_temp.day('2026-05-20');
select pg_temp.grn_new('Weekly replenishment 11 May 2026 - Krishna Denim Works (ref R040)', 'DC-KDW-0067', '[{"sku":"MCHN-KHK-30","q":4,"a":4,"r":0},{"sku":"MCHN-OLV-32","q":3,"a":3,"r":0},{"sku":"WJNS-IND-32","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 11 May 2026 - Little Stitch Garments (ref R041)', 'DC-LSG-0070', '[{"sku":"BKUR-MUS-89Y","q":3,"a":3,"r":0},{"sku":"GLHG-RED-45Y","q":2,"a":2,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1098','Amazon - Seller Central','2026-05-20 12:14+05:30','Prachi Kulkarni','prepaid',849.0,0.0,42.45,891.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1079','Flipkart - Seller Hub','2026-05-20 11:27+05:30','Manav Joshi','cod',949.0,94.9,42.71,896.81,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1091','Shopify - Main Store','2026-05-20 11:14+05:30','Nikhil Pandey','prepaid',1047.0,0.0,52.35,1099.35,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1092','Shopify - Main Store','2026-05-20 17:19+05:30','Karan Malhotra','cod',1897.0,0.0,94.85,1991.85,'delivered','pending','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1098','WKRT-TEL-XL',1,849,0.0,42.45),
('FLIP-1079','BKUR-MUS-45Y',1,949,94.9,42.71),
('SHOP-1091','WLEG-BLK-L',3,349,0.0,52.35),
('SHOP-1092','WDUP-SLV-FREE',1,449,0.0,22.45),
('SHOP-1092','WKRT-PNK-L',1,849,0.0,42.45),
('SHOP-1092','WTOP-WHT-L',1,599,0.0,29.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1079','Bluedart - Surat City'),
('SHOP-1092','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_recv('AMAZ-1065', 'good', 'restocked');
select pg_temp.ret_new('AMAZ-1076', 'Size did not fit', 'webhook');
select pg_temp.cod_collect(array['SHOP-1086']::text[]);
select pg_temp.settle_pay('SHP-STL-20260511', 0.0);
select pg_temp.retime();

-- Thu 21 May 2026
select pg_temp.day('2026-05-21');
select pg_temp.bill_po('Weekly replenishment 11 May 2026 - Krishna Denim Works (ref R040)', 'KDW/26/0169', 1);
select pg_temp.bill_po('Weekly replenishment 11 May 2026 - Little Stitch Garments (ref R041)', 'LSG/26/0175', 1);
select pg_temp.grn_new('Weekly replenishment 11 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R042)', 'DC-TKF-0079', '[{"sku":"WLEG-MAR-L","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 11 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R043)', 'DC-TKF-0082', '[{"sku":"MTRK-BLK-M","q":12,"a":12,"r":0},{"sku":"MTRK-BLK-L","q":10,"a":10,"r":0},{"sku":"WLEG-MAR-M","q":6,"a":6,"r":0},{"sku":"WLEG-MAR-L","q":6,"a":6,"r":0},{"sku":"WTOP-PCH-M","q":14,"a":14,"r":0},{"sku":"WTOP-PCH-L","q":14,"a":14,"r":0},{"sku":"BTEE-BLU-89Y","q":10,"a":10,"r":0},{"sku":"GLEG-BLK-67Y","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Shree Ambika Textiles (ref R048)', 'DC-SAT-0061', '[{"sku":"WKRT-PNK-S","q":10,"a":10,"r":0},{"sku":"WKRT-PNK-M","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1080','Flipkart - Seller Hub','2026-05-21 17:38+05:30','Divya Nair','prepaid',948.0,94.8,42.67,895.87,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1093','Shopify - Main Store','2026-05-21 20:33+05:30','Bhavna Solanki','prepaid',3946.0,197.3,187.44,3936.14,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1094','Shopify - Main Store','2026-05-21 14:06+05:30','Ritu Saxena','prepaid',2246.0,0.0,112.3,2358.3,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1099','Amazon - Seller Central','2026-05-21 21:36+05:30','Rahul Bhatt','prepaid',779.0,0.0,38.95,817.95,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1100','Amazon - Seller Central','2026-05-21 18:06+05:30','Mitul Dave','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1101','Amazon - Seller Central','2026-05-21 12:13+05:30','Dev Trivedi','prepaid',2497.0,0.0,124.85,2621.85,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1081','Flipkart - Seller Hub','2026-05-21 09:26+05:30','Sagar Rathod','prepaid',1798.0,0.0,89.9,1887.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1080','WTOP-PCH-L',1,599,59.9,26.96),
('FLIP-1080','WLEG-BLK-M',1,349,34.9,15.71),
('SHOP-1093','MCHN-OLV-32',2,1199,119.9,113.91),
('SHOP-1093','MTRK-BLK-M',1,649,32.45,30.83),
('SHOP-1093','MSHC-RED-M',1,899,44.95,42.7),
('SHOP-1094','BSHF-WHT-89Y',1,599,0.0,29.95),
('SHOP-1094','BKUR-MUS-45Y',1,949,0.0,47.45),
('SHOP-1094','BSHT-GRY-89Y',2,349,0.0,34.9),
('AMAZ-1099','GJNS-IND-45Y',1,779,0.0,38.95),
('AMAZ-1100','BKUR-MUS-67Y',1,949,0.0,47.45),
('AMAZ-1101','BSHF-WHT-89Y',1,599,0.0,29.95),
('AMAZ-1101','BKUR-MUS-67Y',2,949,0.0,94.9),
('FLIP-1081','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1081','MCHN-KHK-30',1,1199,0.0,59.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1042', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1076', 'approved');
select pg_temp.cod_collect(array['FLIP-1076']::text[]);
select pg_temp.claim_step('FLIP-1048', 'damaged_return', 'claimed', null);
select pg_temp.claim_new('AMAZ-1042', 'damaged_return', 1913.41, '2026-06-20');
select pg_temp.retime();

-- Fri 22 May 2026
select pg_temp.day('2026-05-22');
select pg_temp.bill_po('Weekly replenishment 11 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R042)', 'TKF/26/0197', 1);
select pg_temp.bill_po('Weekly replenishment 11 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R043)', 'TKF/26/0200', 1);
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Krishna Denim Works (ref R044)', 'DC-KDW-0070', '[{"sku":"MJNS-IND-34","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Little Stitch Garments (ref R045)', 'DC-LSG-0073', '[{"sku":"WDRS-FLP-S","q":14,"a":14,"r":0},{"sku":"WDRS-FLP-M","q":6,"a":6,"r":0},{"sku":"BKUR-MUS-45Y","q":8,"a":8,"r":0},{"sku":"GFRK-PNK-67Y","q":6,"a":6,"r":0},{"sku":"GFRK-LIL-89Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Shree Ambika Textiles (ref R048)', 'SAT/26/0155', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1095','Shopify - Main Store','2026-05-22 16:29+05:30','Prachi Kulkarni','cod',7094.0,709.4,319.24,6703.84,'shipped','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1096','Shopify - Main Store','2026-05-22 22:28+05:30','Vivek Singh','cod',599.0,59.9,26.96,566.06,'shipped','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1082','Flipkart - Seller Hub','2026-05-22 20:58+05:30','Nikhil Pandey','cod',5996.0,0.0,299.8,6295.8,'delivered','pending','Uttar Pradesh','Surat Main Warehouse'),
('FLIP-1083','Flipkart - Seller Hub','2026-05-22 18:26+05:30','Anjali Verma','cod',599.0,0.0,29.95,628.95,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1102','Amazon - Seller Central','2026-05-22 21:38+05:30','Kavya Menon','prepaid',1798.0,179.8,80.91,1699.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1084','Flipkart - Seller Hub','2026-05-22 12:49+05:30','Isha Gupta','prepaid',2847.0,0.0,142.35,2989.35,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1103','Amazon - Seller Central','2026-05-22 21:56+05:30','Nidhi Agarwal','prepaid',9646.0,0.0,1470.04,11116.04,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1095','MTRK-BLK-M',2,649,129.8,58.41),
('SHOP-1095','WTOP-WHT-L',1,599,59.9,26.96),
('SHOP-1095','WDRS-FLP-S',2,1499,299.8,134.91),
('SHOP-1095','WSAR-GRN-FREE',1,2199,219.9,98.96),
('SHOP-1096','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1082','WDRS-FLR-L',1,1499,0.0,74.95),
('FLIP-1082','WDRS-FLP-S',3,1499,0.0,224.85),
('FLIP-1083','WTOP-WHT-L',1,599,0.0,29.95),
('AMAZ-1102','MSHC-GRN-L',2,899,179.8,80.91),
('FLIP-1084','MCHN-KHK-30',2,1199,0.0,119.9),
('FLIP-1084','MTEE-BLK-XL',1,449,0.0,22.45),
('AMAZ-1103','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1103','MBLZ-NVY-40',2,3799,0.0,1367.64),
('AMAZ-1103','MJNS-IND-32',1,1399,0.0,69.95)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1082','Delhivery - Sachin GIDC Surat'),
('FLIP-1083','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1076', 'pickup');
select pg_temp.cod_collect(array['SHOP-1084']::text[]);
select pg_temp.rto_new('AMAZ-1088', 'AWB31000294', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['SHOP-1088']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-22MAY', array['SHOP-1086']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-22MAY', array['SHOP-1075','AMAZ-1079']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-22MAY', array['SHOP-1077']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-22MAY', array['SHOP-1071','FLIP-1059','SHOP-1081','SHOP-1082']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-05-25', 'ICIC000000882133', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-05-25', 'ICIC000000882221', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-05-25', 'ICIC000000882314', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-05-25', 'ICIC000000882376', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-05-25', 'ICIC000000882458', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-05-25', 'ICIC000000882540', 1);
select pg_temp.retime();

-- Sat 23 May 2026
select pg_temp.day('2026-05-23');
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Krishna Denim Works (ref R044)', 'KDW/26/0172', 1);
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Little Stitch Garments (ref R045)', 'LSG/26/0177', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1085','Flipkart - Seller Hub','2026-05-23 17:24+05:30','Meghna Rao','prepaid',3397.0,339.7,152.87,3210.17,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1097','Shopify - Main Store','2026-05-23 19:20+05:30','Harsh Modi','cod',4646.0,232.3,220.68,4634.38,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1086','Flipkart - Seller Hub','2026-05-23 14:07+05:30','Kavya Menon','prepaid',4346.0,0.0,217.3,4563.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1098','Shopify - Main Store','2026-05-23 09:14+05:30','Sonal Parekh','prepaid',3996.0,0.0,199.8,4195.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1099','Shopify - Main Store','2026-05-23 16:47+05:30','Karan Malhotra','cod',698.0,0.0,34.9,732.9,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1104','Amazon - Seller Central','2026-05-23 19:46+05:30','Tanvi Rana','prepaid',2226.0,0.0,111.3,2337.3,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1105','Amazon - Seller Central','2026-05-23 19:31+05:30','Divya Nair','prepaid',1198.0,119.8,53.91,1132.11,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1085','WTOP-PCH-S',1,599,59.9,26.96),
('FLIP-1085','MJNS-IND-34',2,1399,279.8,125.91),
('SHOP-1097','WJNS-IND-32',3,1349,202.35,192.23),
('SHOP-1097','WTOP-WHT-M',1,599,29.95,28.45),
('FLIP-1086','MJNS-BLK-32',2,1399,0.0,139.9),
('FLIP-1086','MSHC-RED-M',1,899,0.0,44.95),
('FLIP-1086','MTRK-BLK-M',1,649,0.0,32.45),
('SHOP-1098','WTOP-PCH-S',1,599,0.0,29.95),
('SHOP-1098','WPAL-WHT-XL',1,599,0.0,29.95),
('SHOP-1098','WSAR-RED-FREE',1,2199,0.0,109.95),
('SHOP-1098','WTOP-PCH-M',1,599,0.0,29.95),
('SHOP-1099','WLEG-MAR-M',2,349,0.0,34.9),
('AMAZ-1104','BKUR-MUS-89Y',1,949,0.0,47.45),
('AMAZ-1104','BTEE-RED-89Y',1,329,0.0,16.45),
('AMAZ-1104','BSHT-NVY-89Y',1,349,0.0,17.45),
('AMAZ-1104','BSHF-WHT-45Y',1,599,0.0,29.95),
('AMAZ-1105','WTOP-PCH-M',2,599,119.8,53.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1097','Xpressbees - Pandesara'),
('SHOP-1099','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.rto_recv('AMAZ-1071', 'good', 'restocked');
select pg_temp.cod_collect(array['AMAZ-1096']::text[]);
select pg_temp.retime();

-- Sun 24 May 2026
select pg_temp.day('2026-05-24');
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Rajdhani Shirting Mills (ref R046)', 'DC-RSM-0076', '[{"sku":"MBLZ-NVY-38","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 18 May 2026 - Rajdhani Shirting Mills (ref R047)', 'DC-RSM-0079', '[{"sku":"MSHC-GRN-L","q":4,"a":4,"r":0},{"sku":"MBLZ-NVY-40","q":4,"a":4,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1100','Shopify - Main Store','2026-05-24 09:02+05:30','Anjali Verma','prepaid',3344.0,334.4,150.49,3160.09,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1101','Shopify - Main Store','2026-05-24 20:57+05:30','Kunal Desai','prepaid',1507.0,75.35,71.59,1503.24,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1102','Shopify - Main Store','2026-05-24 10:52+05:30','Prachi Kulkarni','prepaid',628.0,0.0,31.4,659.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1103','Shopify - Main Store','2026-05-24 21:46+05:30','Kavya Menon','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1087','Flipkart - Seller Hub','2026-05-24 11:13+05:30','Neha Patel','cod',9047.0,0.0,1167.22,10214.22,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1088','Flipkart - Seller Hub','2026-05-24 15:05+05:30','Riya Shah','cod',3346.0,167.3,158.94,3337.64,'delivered','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1100','WTOP-WHT-L',1,599,59.9,26.96),
('SHOP-1100','WTOP-PCH-L',2,599,119.8,53.91),
('SHOP-1100','WTOP-PCH-M',2,599,119.8,53.91),
('SHOP-1100','WLEG-BLK-M',1,349,34.9,15.71),
('SHOP-1101','GLEG-BLK-67Y',2,279,27.9,26.51),
('SHOP-1101','BKUR-MUS-89Y',1,949,47.45,45.08),
('SHOP-1102','GTOP-YLW-45Y',1,349,0.0,17.45),
('SHOP-1102','GLEG-PNK-67Y',1,279,0.0,13.95),
('SHOP-1103','WTOP-WHT-M',1,599,0.0,29.95),
('FLIP-1087','WLHG-RED-L',1,5499,0.0,989.82),
('FLIP-1087','WSAR-RED-FREE',1,2199,0.0,109.95),
('FLIP-1087','WJNS-IND-28',1,1349,0.0,67.45),
('FLIP-1088','MSHC-GRN-XL',1,899,44.95,42.7),
('FLIP-1088','MSHC-RED-XL',2,899,89.9,85.41),
('FLIP-1088','MTRK-BLK-XL',1,649,32.45,30.83)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1087','Xpressbees - Pandesara'),
('FLIP-1088','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1076', 'in_transit');
select pg_temp.ret_new('FLIP-1066', 'Item arrived damaged', 'webhook');
select pg_temp.rto_set('AMAZ-1088', 'in_transit');
select pg_temp.settle_pay('AMZ-STL-20260511', 0.0);
select pg_temp.claim_step('AMAZ-1042', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Mon 25 May 2026
select pg_temp.day('2026-05-25');
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Rajdhani Shirting Mills (ref R046)', 'RSM/26/0190', 1);
select pg_temp.bill_po('Weekly replenishment 18 May 2026 - Rajdhani Shirting Mills (ref R047)', 'RSM/26/0194', 1);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Krishna Denim Works (ref R051)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MCHN-KHK-30","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Krishna Denim Works (ref R052)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MJNS-BLK-32","q":12},{"sku":"MCHN-OLV-32","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Little Stitch Garments (ref R053)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLP-L","q":6},{"sku":"BKUR-CRM-89Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Rajdhani Shirting Mills (ref R054)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"BSHF-WHT-89Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Rajdhani Shirting Mills (ref R055)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHC-RED-M","q":6},{"sku":"MBLZ-NVY-40","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Shree Ambika Textiles (ref R056)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WPAL-WHT-XL","q":6},{"sku":"WSAR-BLU-FREE","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Shree Ambika Textiles (ref R057)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WPAL-WHT-M","q":8},{"sku":"WPAL-YLW-XL","q":6},{"sku":"WSAR-BLU-FREE","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R058)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MPOL-NVY-M","q":6},{"sku":"MPOL-MRN-XL","q":6},{"sku":"WLEG-BLK-M","q":8},{"sku":"WTOP-PCH-M","q":8},{"sku":"GLEG-PNK-67Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 25 May 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R059)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"WLEG-BLK-M","q":6},{"sku":"WLEG-BLK-L","q":8},{"sku":"GLEG-BLK-67Y","q":8},{"sku":"GLEG-PNK-45Y","q":8},{"sku":"GLEG-PNK-67Y","q":8}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1089','Flipkart - Seller Hub','2026-05-25 17:10+05:30','Amit Sethi','prepaid',2206.0,0.0,110.3,2316.3,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1104','Shopify - Main Store','2026-05-25 19:36+05:30','Dev Trivedi','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1106','Amazon - Seller Central','2026-05-25 15:48+05:30','Karan Malhotra','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1107','Amazon - Seller Central','2026-05-25 20:32+05:30','Divya Nair','prepaid',1798.0,0.0,89.9,1887.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1108','Amazon - Seller Central','2026-05-25 18:54+05:30','Sejal Kapadia','prepaid',5896.0,294.8,280.06,5881.26,'delivered','paid','Madhya Pradesh','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1089','BKUR-MUS-45Y',1,949,0.0,47.45),
('FLIP-1089','BSHF-WHT-89Y',1,599,0.0,29.95),
('FLIP-1089','BTEE-BLU-89Y',1,329,0.0,16.45),
('FLIP-1089','BTEE-BLU-45Y',1,329,0.0,16.45),
('SHOP-1104','WPAL-WHT-M',1,599,0.0,29.95),
('AMAZ-1106','BTEE-RED-45Y',1,329,32.9,14.81),
('AMAZ-1107','MSHC-RED-XL',2,899,0.0,89.9),
('AMAZ-1108','WDRS-FLP-M',3,1499,224.85,213.61),
('AMAZ-1108','MJNS-BLK-32',1,1399,69.95,66.45)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_set('FLIP-1066', 'approved');
select pg_temp.cod_collect(array['AMAZ-1097']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260518', '2026-05-18', '2026-05-24', array['AMAZ-1075','AMAZ-1076','AMAZ-1082','AMAZ-1084','AMAZ-1081','AMAZ-1083','AMAZ-1080','AMAZ-1085','AMAZ-1086','AMAZ-1087','AMAZ-1091','AMAZ-1089','AMAZ-1092','AMAZ-1093','AMAZ-1094','AMAZ-1090','AMAZ-1095','AMAZ-1098']::text[], array['AMAZ-1042']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260518', '2026-05-18', '2026-05-24', array['FLIP-1065','FLIP-1066','FLIP-1067','FLIP-1068','FLIP-1069','FLIP-1071','FLIP-1074','FLIP-1077','FLIP-1072','FLIP-1075','FLIP-1078']::text[], array[]::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260518', '2026-05-18', '2026-05-24', array['SHOP-1078','SHOP-1079','SHOP-1080','SHOP-1083','SHOP-1085','SHOP-1089','SHOP-1090','SHOP-1091']::text[], array[]::text[]);
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
