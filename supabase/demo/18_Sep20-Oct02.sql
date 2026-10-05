-- 20 Sep to 02 Oct 2026: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.
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


-- Sun 20 Sep 2026
select pg_temp.day('2026-09-20');
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Krishna Denim Works (ref R175)', 'KDW/26/0365', 1);
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Krishna Denim Works (ref R176)', 'KDW/26/0369', 1);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Rajdhani Shirting Mills (ref R181)', 'DC-RSM-0154', '[{"sku":"MSHC-GRN-L","q":8,"a":8,"r":0},{"sku":"MKUR-MUS-XL","q":5,"a":5,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Shree Ambika Textiles (ref R182)', 'SAT/26/0354', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1437','Shopify - Main Store','2026-09-20 20:04+05:30','Sonal Parekh','prepaid',2547.0,0.0,127.35,2674.35,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1408','Flipkart - Seller Hub','2026-09-20 22:53+05:30','Isha Gupta','cod',6745.0,1011.75,286.67,6019.92,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1438','Shopify - Main Store','2026-09-20 13:14+05:30','Dev Trivedi','cod',3597.0,0.0,179.85,3776.85,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('FLIP-1409','Flipkart - Seller Hub','2026-09-20 12:52+05:30','Divya Nair','prepaid',1656.0,82.8,78.67,1651.87,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1439','Shopify - Main Store','2026-09-20 09:38+05:30','Shreya Banerjee','prepaid',1678.0,251.7,71.32,1497.62,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1440','Shopify - Main Store','2026-09-20 14:58+05:30','Pooja Jain','prepaid',279.0,27.9,12.56,263.66,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1441','Shopify - Main Store','2026-09-20 16:11+05:30','Aarav Mehta','prepaid',9494.0,949.4,427.24,8971.84,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1545','Amazon - Seller Central','2026-09-20 09:26+05:30','Heena Khan','prepaid',7296.0,0.0,1079.67,8375.67,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1442','Shopify - Main Store','2026-09-20 19:22+05:30','Vivek Singh','prepaid',3495.0,0.0,174.75,3669.75,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1443','Shopify - Main Store','2026-09-20 15:48+05:30','Meghna Rao','prepaid',699.0,34.95,33.2,697.25,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1444','Shopify - Main Store','2026-09-20 20:27+05:30','Rohit Iyer','prepaid',549.0,0.0,27.45,576.45,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1546','Amazon - Seller Central','2026-09-20 19:48+05:30','Amit Sethi','prepaid',8497.0,424.85,1341.96,9414.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1445','Shopify - Main Store','2026-09-20 17:11+05:30','Vivek Singh','prepaid',1299.0,194.85,55.21,1159.36,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1446','Shopify - Main Store','2026-09-20 10:30+05:30','Kavya Menon','cod',6098.0,304.9,968.78,6761.88,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1547','Amazon - Seller Central','2026-09-20 18:38+05:30','Vivek Singh','prepaid',3695.0,369.5,166.29,3491.79,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1548','Amazon - Seller Central','2026-09-20 16:58+05:30','Dev Trivedi','prepaid',1298.0,129.8,58.41,1226.61,'delivered','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1549','Amazon - Seller Central','2026-09-20 16:38+05:30','Sanjay Gajera','prepaid',698.0,0.0,34.9,732.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1437','WKRT-TEL-XL',3,849,0.0,127.35),
('FLIP-1408','WKRT-PNK-L',3,849,382.05,108.25),
('FLIP-1408','GLHG-TEL-67Y',1,1999,299.85,84.96),
('FLIP-1408','WSAR-BLU-FREE',1,2199,329.85,93.46),
('SHOP-1438','WDRS-FLP-S',2,1499,0.0,149.9),
('SHOP-1438','WTOP-WHT-L',1,599,0.0,29.95),
('FLIP-1409','GLEG-PNK-89Y',2,279,27.9,26.51),
('FLIP-1409','GNGT-PNK-45Y',2,549,54.9,52.16),
('SHOP-1439','GJNS-IND-1011Y',1,779,116.85,33.11),
('SHOP-1439','MSHC-GRN-M',1,899,134.85,38.21),
('SHOP-1440','GLEG-BLK-45Y',1,279,27.9,12.56),
('SHOP-1441','MSHC-RED-XL',1,899,89.9,40.46),
('SHOP-1441','MHOD-BLK-M',2,1299,259.8,116.91),
('SHOP-1441','GLHG-RED-89Y',3,1999,599.7,269.87),
('AMAZ-1545','WLHG-RED-M',1,5499,0.0,989.82),
('AMAZ-1545','WTOP-PCH-L',2,599,0.0,59.9),
('AMAZ-1545','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1442','WTOP-WHT-L',3,599,0.0,89.85),
('SHOP-1442','WJNS-BLK-30',1,1349,0.0,67.45),
('SHOP-1442','WLEG-NVY-M',1,349,0.0,17.45),
('SHOP-1443','MPOL-MRN-M',1,699,34.95,33.2),
('SHOP-1444','GNGT-PNK-67Y',1,549,0.0,27.45),
('AMAZ-1546','MSHC-RED-M',1,899,44.95,42.7),
('AMAZ-1546','MBLZ-NVY-42',2,3799,379.9,1299.26),
('SHOP-1445','MHOD-BLK-XL',1,1299,194.85,55.21),
('SHOP-1446','WLHG-RED-L',1,5499,274.95,940.33),
('SHOP-1446','WTOP-PCH-M',1,599,29.95,28.45),
('AMAZ-1547','GNGT-PNK-1011Y',3,549,164.7,74.12),
('AMAZ-1547','WDRS-FLR-S',1,1499,149.9,67.46),
('AMAZ-1547','GNGT-PNK-45Y',1,549,54.9,24.71),
('AMAZ-1548','MTRK-BLK-L',2,649,129.8,58.41),
('AMAZ-1549','WLEG-BLK-M',2,349,0.0,34.9)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1408','Xpressbees - Pandesara'),
('SHOP-1438','DTDC - Ring Road Surat'),
('SHOP-1446','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1445');
select pg_temp.ret_recv('SHOP-1363');
select pg_temp.ret_refund_d2c('SHOP-1364', 'UPI-REFUND-SHOP-1364');
select pg_temp.ret_recv('SHOP-1366');
select pg_temp.ret_set('AMAZ-1465', 'in_transit');
select pg_temp.ret_recv('SHOP-1374');
select pg_temp.ret_set('AMAZ-1491', 'pickup');
select pg_temp.cod_collect(array['SHOP-1415']::text[]);
select pg_temp.cod_collect(array['SHOP-1422']::text[]);
select pg_temp.settle_pay('AMZ-STL-20260907', 0.0);
select pg_temp.retime();

-- Mon 21 Sep 2026
select pg_temp.day('2026-09-21');
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Rajdhani Shirting Mills (ref R181)', 'RSM/26/0372', 1);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Krishna Denim Works (ref R185)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"WJNS-IND-32","q":10},{"sku":"GJNS-IND-1011Y","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Little Stitch Garments (ref R186)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"BKUR-MUS-45Y","q":10},{"sku":"GFRK-LIL-45Y","q":6},{"sku":"GLHG-TEL-67Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Little Stitch Garments (ref R187)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"BKUR-MUS-67Y","q":18},{"sku":"BKUR-MUS-89Y","q":16},{"sku":"GLHG-RED-45Y","q":6},{"sku":"GLHG-RED-89Y","q":8},{"sku":"GNGT-PNK-45Y","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Ludhiana Winter Wear Co (ref R188)', 'Ludhiana Winter Wear Co', 'Mumbai Fulfilment Center', '[{"sku":"MHOD-BLK-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Ludhiana Winter Wear Co (ref R189)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"MHOD-BLK-M","q":14}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Rajdhani Shirting Mills (ref R190)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHC-GRN-M","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Rajdhani Shirting Mills (ref R191)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MSHF-WHT-L","q":8},{"sku":"MBLZ-NVY-42","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Shree Ambika Textiles (ref R192)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WKRT-PNK-L","q":10},{"sku":"WKRT-TEL-M","q":6},{"sku":"WPAL-YLW-L","q":6},{"sku":"WSAR-RED-FREE","q":6},{"sku":"WSAR-GRN-FREE","q":14},{"sku":"WSAR-BLU-FREE","q":6},{"sku":"WLHG-RED-L","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Shree Ambika Textiles (ref R193)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WKRT-PNK-XL","q":8},{"sku":"WPAL-WHT-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R194)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTRK-BLK-L","q":12},{"sku":"WTOP-WHT-L","q":14},{"sku":"WTOP-PCH-L","q":32},{"sku":"BTEE-RED-89Y","q":14},{"sku":"GLEG-PNK-89Y","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 21 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R195)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MPOL-NVY-M","q":6},{"sku":"MTRK-BLK-L","q":8},{"sku":"WLEG-BLK-M","q":10},{"sku":"WLEG-NVY-M","q":8},{"sku":"WTOP-WHT-M","q":40},{"sku":"BTEE-BLU-89Y","q":10},{"sku":"GLEG-BLK-67Y","q":28},{"sku":"GLEG-BLK-89Y","q":14},{"sku":"GLEG-PNK-89Y","q":16}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1447','Shopify - Main Store','2026-09-21 22:41+05:30','Ritu Saxena','cod',10998.0,1649.7,1682.69,11030.99,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1550','Amazon - Seller Central','2026-09-21 15:55+05:30','Prachi Kulkarni','prepaid',899.0,44.95,42.7,896.75,'shipped','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1551','Amazon - Seller Central','2026-09-21 10:57+05:30','Divya Nair','prepaid',1898.0,0.0,94.9,1992.9,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1552','Amazon - Seller Central','2026-09-21 11:34+05:30','Anjali Verma','prepaid',1698.0,0.0,84.9,1782.9,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1553','Amazon - Seller Central','2026-09-21 19:05+05:30','Meghna Rao','prepaid',949.0,47.45,45.08,946.63,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1554','Amazon - Seller Central','2026-09-21 17:08+05:30','Nidhi Agarwal','prepaid',558.0,55.8,25.11,527.31,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1555','Amazon - Seller Central','2026-09-21 16:15+05:30','Amit Sethi','prepaid',329.0,0.0,16.45,345.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1448','Shopify - Main Store','2026-09-21 17:23+05:30','Bhavna Solanki','prepaid',449.0,44.9,20.21,424.31,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1556','Amazon - Seller Central','2026-09-21 12:09+05:30','Karan Malhotra','prepaid',1558.0,233.7,66.22,1390.52,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1447','WLHG-MAG-L',2,5499,1649.7,1682.69),
('AMAZ-1550','MSHC-RED-XL',1,899,44.95,42.7),
('AMAZ-1551','BKUR-MUS-67Y',2,949,0.0,94.9),
('AMAZ-1552','WKRT-TEL-L',2,849,0.0,84.9),
('AMAZ-1553','BKUR-MUS-45Y',1,949,47.45,45.08),
('AMAZ-1554','GLEG-BLK-67Y',2,279,55.8,25.11),
('AMAZ-1555','BTEE-BLU-67Y',1,329,0.0,16.45),
('SHOP-1448','MTEE-BLK-XL',1,449,44.9,20.21),
('AMAZ-1556','GJNS-IND-89Y',2,779,233.7,66.22)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1447','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('AMAZ-1445', 'good', 'restocked');
select pg_temp.ret_set('SHOP-1354', 'in_transit');
select pg_temp.ret_recv('FLIP-1340');
select pg_temp.ret_dispo('SHOP-1374', 'good', 'restocked');
select pg_temp.ret_recv('FLIP-1354');
select pg_temp.ret_new('FLIP-1386', 'Item arrived damaged', 'webhook');
select pg_temp.rto_new('FLIP-1400', 'AWB31001177', 'Customer unreachable');
select pg_temp.cod_collect(array['SHOP-1423']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260914', '2026-09-14', '2026-09-20', array['AMAZ-1469','AMAZ-1475','AMAZ-1482','AMAZ-1483','AMAZ-1484','AMAZ-1471','AMAZ-1472','AMAZ-1477','AMAZ-1486','AMAZ-1491','AMAZ-1493','AMAZ-1494','AMAZ-1495','AMAZ-1498','AMAZ-1501','AMAZ-1476','AMAZ-1481','AMAZ-1497','AMAZ-1502','AMAZ-1506','AMAZ-1513','AMAZ-1485','AMAZ-1511','AMAZ-1490','AMAZ-1492','AMAZ-1496','AMAZ-1499','AMAZ-1500','AMAZ-1503','AMAZ-1505','AMAZ-1507','AMAZ-1512','AMAZ-1518','AMAZ-1520','AMAZ-1504','AMAZ-1508','AMAZ-1510','AMAZ-1516','AMAZ-1524','AMAZ-1514','AMAZ-1515','AMAZ-1517','AMAZ-1525']::text[], array['AMAZ-1442','AMAZ-1435','AMAZ-1445']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260914', '2026-09-14', '2026-09-20', array['FLIP-1361','FLIP-1370','FLIP-1365','FLIP-1368','FLIP-1377','FLIP-1371','FLIP-1378','FLIP-1385','FLIP-1387','FLIP-1375','FLIP-1376','FLIP-1379','FLIP-1389','FLIP-1390','FLIP-1391','FLIP-1395','FLIP-1396','FLIP-1380','FLIP-1381','FLIP-1382','FLIP-1383','FLIP-1384','FLIP-1386','FLIP-1398']::text[], array[]::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260914', '2026-09-14', '2026-09-20', array['SHOP-1385','SHOP-1392','SHOP-1393','SHOP-1394','SHOP-1395','SHOP-1398','SHOP-1391','SHOP-1399','SHOP-1387','SHOP-1396','SHOP-1403','SHOP-1404','SHOP-1397','SHOP-1401','SHOP-1407','SHOP-1408','SHOP-1409','SHOP-1411','SHOP-1416','SHOP-1412','SHOP-1413','SHOP-1417','SHOP-1414']::text[], array[]::text[]);
select pg_temp.claim_step('FLIP-1289', 'lost_shipment', 'claimed', null);
select pg_temp.claim_step('AMAZ-1442', 'lost_shipment', 'claimed', null);
select pg_temp.retime();

-- Tue 22 Sep 2026
select pg_temp.day('2026-09-22');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1449','Shopify - Main Store','2026-09-22 13:23+05:30','Kunal Desai','prepaid',1547.0,77.35,73.48,1543.13,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1410','Flipkart - Seller Hub','2026-09-22 22:15+05:30','Isha Gupta','prepaid',2047.0,204.7,92.12,1934.42,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1450','Shopify - Main Store','2026-09-22 21:56+05:30','Bhavna Solanki','cod',1299.0,64.95,61.7,1295.75,'shipped','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1411','Flipkart - Seller Hub','2026-09-22 21:48+05:30','Jigar Chauhan','cod',949.0,47.45,45.08,946.63,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1557','Amazon - Seller Central','2026-09-22 18:39+05:30','Kiran Naik','prepaid',3624.0,0.0,181.2,3805.2,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1558','Amazon - Seller Central','2026-09-22 11:04+05:30','Kunal Desai','prepaid',349.0,17.45,16.58,348.13,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1559','Amazon - Seller Central','2026-09-22 19:48+05:30','Prachi Kulkarni','prepaid',5895.0,294.75,280.01,5880.26,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1451','Shopify - Main Store','2026-09-22 16:43+05:30','Prachi Kulkarni','prepaid',2847.0,142.35,135.24,2839.89,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1452','Shopify - Main Store','2026-09-22 19:32+05:30','Pooja Jain','prepaid',649.0,32.45,30.83,647.38,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1453','Shopify - Main Store','2026-09-22 21:02+05:30','Sonal Parekh','prepaid',2176.0,108.8,103.36,2170.56,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1454','Shopify - Main Store','2026-09-22 11:50+05:30','Pratik Lad','cod',5499.0,549.9,890.84,5839.94,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1412','Flipkart - Seller Hub','2026-09-22 11:31+05:30','Anjali Verma','prepaid',3597.0,359.7,161.87,3399.17,'shipped','paid','Karnataka','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1449','WTOP-PCH-S',1,599,29.95,28.45),
('SHOP-1449','WTOP-WHT-L',1,599,29.95,28.45),
('SHOP-1449','WLEG-MAR-L',1,349,17.45,16.58),
('FLIP-1410','WTOP-WHT-M',2,599,119.8,53.91),
('FLIP-1410','WKRT-TEL-M',1,849,84.9,38.21),
('SHOP-1450','MHOD-GRY-L',1,1299,64.95,61.7),
('FLIP-1411','BKUR-MUS-45Y',1,949,47.45,45.08),
('AMAZ-1557','MTRK-BLK-M',3,649,0.0,97.35),
('AMAZ-1557','MTRK-BLK-L',1,649,0.0,32.45),
('AMAZ-1557','MPOL-NVY-M',1,699,0.0,34.95),
('AMAZ-1557','BTEE-RED-45Y',1,329,0.0,16.45),
('AMAZ-1558','WLEG-BLK-L',1,349,17.45,16.58),
('AMAZ-1559','MCHN-KHK-30',1,1199,59.95,56.95),
('AMAZ-1559','MPOL-NVY-M',1,699,34.95,33.2),
('AMAZ-1559','MHOD-GRY-M',2,1299,129.9,123.41),
('AMAZ-1559','MJNS-BLK-32',1,1399,69.95,66.45),
('SHOP-1451','BKUR-MUS-67Y',1,949,47.45,45.08),
('SHOP-1451','BKUR-MUS-45Y',2,949,94.9,90.16),
('SHOP-1452','MTRK-BLK-XL',1,649,32.45,30.83),
('SHOP-1453','GLEG-PNK-67Y',1,279,13.95,13.25),
('SHOP-1453','MTEE-BLK-M',1,449,22.45,21.33),
('SHOP-1453','MSHF-SKY-XL',1,999,49.95,47.45),
('SHOP-1453','MTEE-BLK-XL',1,449,22.45,21.33),
('SHOP-1454','WLHG-MAG-L',1,5499,549.9,890.84),
('FLIP-1412','WTOP-PCH-S',1,599,59.9,26.96),
('FLIP-1412','WDRS-FLP-S',2,1499,299.8,134.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1454','Delhivery - Sachin GIDC Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('FLIP-1340', 'good', 'restocked');
select pg_temp.ret_dispo('SHOP-1363', 'good', 'restocked');
select pg_temp.ret_dispo('SHOP-1366', 'good', 'restocked');
select pg_temp.ret_refund_d2c('SHOP-1374', 'UPI-REFUND-SHOP-1374');
select pg_temp.ret_recv('AMAZ-1466');
select pg_temp.ret_dispo('FLIP-1354', 'good', 'restocked');
select pg_temp.ret_new('AMAZ-1477', 'Size did not fit', 'webhook');
select pg_temp.ret_set('AMAZ-1491', 'in_transit');
select pg_temp.rto_recv('AMAZ-1509', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1386', 'approved');
select pg_temp.ret_new('FLIP-1389', 'Fabric quality not as expected', 'webhook');
select pg_temp.cod_collect(array['SHOP-1421']::text[]);
select pg_temp.cod_collect(array['AMAZ-1536']::text[]);
select pg_temp.cod_collect(array['AMAZ-1543']::text[]);
select pg_temp.cancel_order('AMAZ-1550');
select pg_temp.settle_pay('FLK-STL-20260907', 0.0);
select pg_temp.retime();

-- Wed 23 Sep 2026
select pg_temp.day('2026-09-23');
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Krishna Denim Works (ref R176)', 'DC-KDW-0157', '[{"sku":"MJNS-BLK-30","q":3,"a":3,"r":0},{"sku":"MJNS-BLK-32","q":7,"a":7,"r":0},{"sku":"MCHN-OLV-32","q":4,"a":4,"r":0},{"sku":"WJNS-IND-28","q":6,"a":6,"r":0},{"sku":"WJNS-BLK-32","q":4,"a":4,"r":0},{"sku":"GJNS-IND-89Y","q":4,"a":4,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Ludhiana Winter Wear Co (ref R179)', 'DC-LWW-0079', '[{"sku":"MHOD-BLK-M","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R183)', 'DC-TKF-0208', '[{"sku":"WLEG-NVY-L","q":6,"a":6,"r":0},{"sku":"WTOP-PCH-L","q":26,"a":26,"r":0},{"sku":"BTEE-RED-89Y","q":8,"a":8,"r":0},{"sku":"GLEG-PNK-89Y","q":8,"a":8,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1413','Flipkart - Seller Hub','2026-09-23 12:22+05:30','Ritu Saxena','prepaid',4774.0,238.7,226.78,4762.08,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1414','Flipkart - Seller Hub','2026-09-23 12:04+05:30','Aarav Mehta','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1415','Flipkart - Seller Hub','2026-09-23 14:19+05:30','Heena Khan','prepaid',2297.0,229.7,103.37,2170.67,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1560','Amazon - Seller Central','2026-09-23 11:13+05:30','Kiran Naik','prepaid',1497.0,0.0,74.85,1571.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1416','Flipkart - Seller Hub','2026-09-23 16:31+05:30','Kunal Desai','prepaid',349.0,17.45,16.58,348.13,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1455','Shopify - Main Store','2026-09-23 10:03+05:30','Kavya Menon','cod',2098.0,314.7,89.17,1872.47,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1417','Flipkart - Seller Hub','2026-09-23 17:34+05:30','Vipul Gandhi','prepaid',1199.0,179.85,50.96,1070.11,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1456','Shopify - Main Store','2026-09-23 18:03+05:30','Nidhi Agarwal','prepaid',649.0,97.35,27.58,579.23,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1457','Shopify - Main Store','2026-09-23 12:11+05:30','Rahul Bhatt','prepaid',6597.0,659.7,741.35,6678.65,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1413','BJNS-IND-45Y',2,799,79.9,75.91),
('FLIP-1413','BKUR-MUS-45Y',2,949,94.9,90.16),
('FLIP-1413','BTEE-BLU-67Y',1,329,16.45,15.63),
('FLIP-1413','BKUR-MUS-67Y',1,949,47.45,45.08),
('FLIP-1414','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1415','MJNS-BLK-32',1,1399,139.9,62.96),
('FLIP-1415','MTEE-BLK-M',2,449,89.8,40.41),
('AMAZ-1560','WDUP-GLD-FREE',2,449,0.0,44.9),
('AMAZ-1560','WTOP-WHT-M',1,599,0.0,29.95),
('FLIP-1416','WLEG-BLK-M',1,349,17.45,16.58),
('SHOP-1455','MCHN-OLV-34',1,1199,179.85,50.96),
('SHOP-1455','MSHC-RED-XL',1,899,134.85,38.21),
('FLIP-1417','MCHN-OLV-32',1,1199,179.85,50.96),
('SHOP-1456','MTRK-BLK-M',1,649,97.35,27.58),
('SHOP-1457','MBLZ-NVY-40',1,3799,379.9,615.44),
('SHOP-1457','MJNS-BLK-34',2,1399,279.8,125.91)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1455','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_refund_d2c('SHOP-1363', 'UPI-REFUND-SHOP-1363');
select pg_temp.ret_recv('AMAZ-1465');
select pg_temp.ret_dispo('AMAZ-1466', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1477', 'approved');
select pg_temp.rto_recv('FLIP-1373', 'good', 'restocked');
select pg_temp.ret_set('FLIP-1386', 'pickup');
select pg_temp.ret_set('FLIP-1389', 'approved');
select pg_temp.ret_new('SHOP-1412', 'Size did not fit', 'webhook');
select pg_temp.rto_set('FLIP-1400', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1425']::text[]);
select pg_temp.cod_collect(array['SHOP-1426']::text[]);
select pg_temp.rto_new('SHOP-1430', 'AWB31001198', 'Customer refused delivery');
select pg_temp.rto_new('FLIP-1405', 'AWB31001223', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['SHOP-1432']::text[]);
select pg_temp.cod_collect(array['FLIP-1406']::text[]);
select pg_temp.settle_pay('SHP-STL-20260914', 0.0);
select pg_temp.retime();

-- Thu 24 Sep 2026
select pg_temp.day('2026-09-24');
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Krishna Denim Works (ref R176)', 'KDW/26/0376', 1);
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Ludhiana Winter Wear Co (ref R179)', 'LWW/26/0196', 1);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Rajdhani Shirting Mills (ref R181)', 'DC-RSM-0157', '[{"sku":"MSHC-GRN-L","q":4,"a":4,"r":0},{"sku":"MKUR-MUS-XL","q":3,"a":3,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R183)', 'TKF/26/0494', 1);
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R184)', 'DC-TKF-0211', '[{"sku":"MTEE-BLK-L","q":6,"a":6,"r":0},{"sku":"WLEG-NVY-M","q":8,"a":8,"r":0},{"sku":"WTOP-WHT-L","q":26,"a":25,"r":1},{"sku":"WTOP-PCH-M","q":28,"a":27,"r":1},{"sku":"GTOP-WHT-89Y","q":6,"a":6,"r":0},{"sku":"GLEG-BLK-67Y","q":22,"a":22,"r":0},{"sku":"GLEG-PNK-89Y","q":12,"a":12,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1561','Amazon - Seller Central','2026-09-24 14:23+05:30','Shreya Banerjee','prepaid',10496.0,1574.4,1053.73,9975.33,'shipped','paid','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1562','Amazon - Seller Central','2026-09-24 13:50+05:30','Sanjay Gajera','prepaid',2398.0,479.6,95.92,2014.32,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1458','Shopify - Main Store','2026-09-24 13:22+05:30','Tanvi Rana','cod',1448.0,72.4,68.78,1444.38,'cancelled','failed','Delhi','Surat Main Warehouse'),
('AMAZ-1563','Amazon - Seller Central','2026-09-24 12:35+05:30','Shreya Banerjee','prepaid',3394.0,509.1,144.25,3029.15,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1459','Shopify - Main Store','2026-09-24 16:04+05:30','Bhavna Solanki','prepaid',949.0,47.45,45.08,946.63,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1460','Shopify - Main Store','2026-09-24 15:03+05:30','Jigar Chauhan','prepaid',4193.0,0.0,209.65,4402.65,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1564','Amazon - Seller Central','2026-09-24 16:39+05:30','Prachi Kulkarni','prepaid',2556.0,511.2,102.24,2147.04,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('SHOP-1461','Shopify - Main Store','2026-09-24 12:14+05:30','Mitul Dave','cod',2199.0,219.9,98.96,2078.06,'delivered','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1418','Flipkart - Seller Hub','2026-09-24 11:28+05:30','Heena Khan','cod',1395.0,279.0,55.8,1171.8,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1565','Amazon - Seller Central','2026-09-24 18:18+05:30','Riya Shah','prepaid',1698.0,169.8,76.41,1604.61,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1566','Amazon - Seller Central','2026-09-24 12:53+05:30','Kavya Menon','prepaid',3597.0,539.55,152.88,3210.33,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1462','Shopify - Main Store','2026-09-24 10:11+05:30','Anjali Verma','cod',7494.0,374.7,355.97,7475.27,'shipped','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1567','Amazon - Seller Central','2026-09-24 22:52+05:30','Meghna Rao','prepaid',3484.0,348.4,156.79,3292.39,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1419','Flipkart - Seller Hub','2026-09-24 17:43+05:30','Karan Malhotra','prepaid',1298.0,259.6,51.92,1090.32,'shipped','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1420','Flipkart - Seller Hub','2026-09-24 13:41+05:30','Kiran Naik','prepaid',11442.0,2288.4,1299.77,10453.37,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1421','Flipkart - Seller Hub','2026-09-24 19:08+05:30','Kavya Menon','prepaid',2747.0,274.7,123.63,2595.93,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1568','Amazon - Seller Central','2026-09-24 19:40+05:30','Shreya Banerjee','prepaid',2199.0,329.85,93.46,1962.61,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1561','WTOP-WHT-M',1,599,89.85,25.46),
('AMAZ-1561','WLHG-RED-M',1,5499,824.85,841.35),
('AMAZ-1561','WSAR-BLU-FREE',2,2199,659.7,186.92),
('AMAZ-1562','MCHN-KHK-30',2,1199,479.6,95.92),
('SHOP-1458','WKRT-TEL-XL',1,849,42.45,40.33),
('SHOP-1458','WTOP-WHT-L',1,599,29.95,28.45),
('AMAZ-1563','GLHG-TEL-89Y',1,1999,299.85,84.96),
('AMAZ-1563','GLEG-PNK-89Y',3,279,125.55,35.57),
('AMAZ-1563','GLEG-PNK-67Y',1,279,41.85,11.86),
('AMAZ-1563','GLEG-BLK-89Y',1,279,41.85,11.86),
('SHOP-1459','BKUR-CRM-89Y',1,949,47.45,45.08),
('SHOP-1460','WTOP-PCH-M',3,599,0.0,89.85),
('SHOP-1460','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1460','WPAL-WHT-XL',2,599,0.0,59.9),
('SHOP-1460','WTOP-PCH-S',1,599,0.0,29.95),
('AMAZ-1564','BTEE-RED-45Y',1,329,65.8,13.16),
('AMAZ-1564','BKUR-MUS-89Y',2,949,379.6,75.92),
('AMAZ-1564','BTEE-RED-89Y',1,329,65.8,13.16),
('SHOP-1461','WSAR-RED-FREE',1,2199,219.9,98.96),
('FLIP-1418','GLEG-BLK-45Y',1,279,55.8,11.16),
('FLIP-1418','GLEG-BLK-89Y',3,279,167.4,33.48),
('FLIP-1418','GLEG-BLK-67Y',1,279,55.8,11.16),
('AMAZ-1565','WKRT-PNK-XL',2,849,169.8,76.41),
('AMAZ-1566','MSHF-WHT-L',1,999,149.85,42.46),
('AMAZ-1566','MHOD-BLK-XL',1,1299,194.85,55.21),
('AMAZ-1566','MHOD-BLK-M',1,1299,194.85,55.21),
('SHOP-1462','MJNS-BLK-30',1,1399,69.95,66.45),
('SHOP-1462','MKUR-WHT-L',3,1099,164.85,156.61),
('SHOP-1462','MJNS-IND-30',2,1399,139.9,132.91),
('AMAZ-1567','GLEG-BLK-45Y',1,279,27.9,12.56),
('AMAZ-1567','GNGT-PNK-1011Y',3,549,164.7,74.12),
('AMAZ-1567','GJNS-IND-45Y',2,779,155.8,70.11),
('FLIP-1419','MTRK-BLK-L',2,649,259.6,51.92),
('FLIP-1420','MSHC-GRN-L',2,899,359.6,71.92),
('FLIP-1420','WTOP-WHT-M',2,599,239.6,47.92),
('FLIP-1420','WJKT-BLK-L',3,2699,1619.4,1165.97),
('FLIP-1420','GTOP-WHT-67Y',1,349,69.8,13.96),
('FLIP-1421','MKUR-MUS-L',1,1099,109.9,49.46),
('FLIP-1421','MTEE-BLK-XL',1,449,44.9,20.21),
('FLIP-1421','MCHN-OLV-32',1,1199,119.9,53.96),
('AMAZ-1568','WSAR-BLU-FREE',1,2199,329.85,93.46)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1461','Bluedart - Surat City'),
('FLIP-1418','Ecom Express - Udhna Hub'),
('SHOP-1462','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('SHOP-1354');
select pg_temp.ret_refund_d2c('SHOP-1366', 'UPI-REFUND-SHOP-1366');
select pg_temp.ret_dispo('AMAZ-1465', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1477', 'pickup');
select pg_temp.rto_recv('AMAZ-1488', 'damaged', 'quarantined');
select pg_temp.ret_recv('AMAZ-1491');
select pg_temp.ret_new('FLIP-1382', 'Size did not fit', 'webhook');
select pg_temp.ret_set('FLIP-1389', 'pickup');
select pg_temp.ret_set('SHOP-1412', 'approved');
select pg_temp.cod_collect(array['SHOP-1427']::text[]);
select pg_temp.cod_collect(array['SHOP-1434']::text[]);
select pg_temp.cod_collect(array['SHOP-1435']::text[]);
select pg_temp.cod_collect(array['SHOP-1436']::text[]);
select pg_temp.cod_collect(array['FLIP-1408']::text[]);
select pg_temp.retime();

-- Fri 25 Sep 2026
select pg_temp.day('2026-09-25');
select pg_temp.grn_new('Weekly replenishment 14 Sep 2026 - Ludhiana Winter Wear Co (ref R180)', 'DC-LWW-0082', '[{"sku":"MHOD-BLK-M","q":10,"a":10,"r":0},{"sku":"MHOD-BLK-L","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Rajdhani Shirting Mills (ref R181)', 'RSM/26/0377', 1);
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R184)', 'TKF/26/0499', 1);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Little Stitch Garments (ref R187)', 'DC-LSG-0154', '[{"sku":"BKUR-MUS-67Y","q":18,"a":18,"r":0},{"sku":"BKUR-MUS-89Y","q":16,"a":16,"r":0},{"sku":"GLHG-RED-45Y","q":6,"a":6,"r":0},{"sku":"GLHG-RED-89Y","q":8,"a":8,"r":0},{"sku":"GNGT-PNK-45Y","q":12,"a":12,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1422','Flipkart - Seller Hub','2026-09-25 14:19+05:30','Karan Malhotra','prepaid',1349.0,202.35,57.33,1203.98,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1423','Flipkart - Seller Hub','2026-09-25 15:20+05:30','Riya Shah','prepaid',16497.0,0.0,2969.46,19466.46,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('SHOP-1463','Shopify - Main Store','2026-09-25 10:32+05:30','Divya Nair','prepaid',3497.0,0.0,174.85,3671.85,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1424','Flipkart - Seller Hub','2026-09-25 14:48+05:30','Meghna Rao','prepaid',558.0,111.6,22.32,468.72,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1425','Flipkart - Seller Hub','2026-09-25 17:01+05:30','Pooja Jain','prepaid',2848.0,427.2,121.04,2541.84,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1569','Amazon - Seller Central','2026-09-25 12:37+05:30','Harsh Modi','prepaid',1228.0,122.8,55.27,1160.47,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1464','Shopify - Main Store','2026-09-25 11:47+05:30','Bhavna Solanki','prepaid',1547.0,232.05,65.74,1380.69,'shipped','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1465','Shopify - Main Store','2026-09-25 10:38+05:30','Bhavna Solanki','cod',599.0,0.0,29.95,628.95,'delivered','pending','West Bengal','Surat Main Warehouse'),
('FLIP-1426','Flipkart - Seller Hub','2026-09-25 21:08+05:30','Dev Trivedi','prepaid',2598.0,0.0,129.9,2727.9,'shipped','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1427','Flipkart - Seller Hub','2026-09-25 11:54+05:30','Vipul Gandhi','prepaid',1956.0,0.0,97.8,2053.8,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1570','Amazon - Seller Central','2026-09-25 20:25+05:30','Riya Shah','prepaid',2597.0,519.4,103.88,2181.48,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('SHOP-1466','Shopify - Main Store','2026-09-25 14:10+05:30','Aditi Joshi','prepaid',1299.0,194.85,55.21,1159.36,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1571','Amazon - Seller Central','2026-09-25 21:25+05:30','Pratik Lad','prepaid',949.0,142.35,40.33,846.98,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1572','Amazon - Seller Central','2026-09-25 13:58+05:30','Karan Malhotra','prepaid',2596.0,519.2,103.84,2180.64,'delivered','paid','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1422','WJNS-IND-28',1,1349,202.35,57.33),
('FLIP-1423','WLHG-RED-M',1,5499,0.0,989.82),
('FLIP-1423','WLHG-RED-L',2,5499,0.0,1979.64),
('SHOP-1463','MHOD-GRY-M',2,1299,0.0,129.9),
('SHOP-1463','MSHC-GRN-L',1,899,0.0,44.95),
('FLIP-1424','GLEG-PNK-45Y',2,279,111.6,22.32),
('FLIP-1425','WJNS-IND-32',1,1349,202.35,57.33),
('FLIP-1425','WDRS-FLR-L',1,1499,224.85,63.71),
('AMAZ-1569','BKUR-MUS-89Y',1,949,94.9,42.71),
('AMAZ-1569','GLEG-PNK-89Y',1,279,27.9,12.56),
('SHOP-1464','WKRT-PNK-L',1,849,127.35,36.08),
('SHOP-1464','WLEG-MAR-M',1,349,52.35,14.83),
('SHOP-1464','WLEG-BLK-L',1,349,52.35,14.83),
('SHOP-1465','WTOP-PCH-M',1,599,0.0,29.95),
('FLIP-1426','MHOD-BLK-XL',2,1299,0.0,129.9),
('FLIP-1427','BTEE-BLU-89Y',1,329,0.0,16.45),
('FLIP-1427','BKUR-MUS-67Y',1,949,0.0,47.45),
('FLIP-1427','BTEE-BLU-67Y',1,329,0.0,16.45),
('FLIP-1427','BSHT-GRY-89Y',1,349,0.0,17.45),
('AMAZ-1570','MHOD-BLK-XL',1,1299,259.8,51.96),
('AMAZ-1570','MTRK-BLK-M',2,649,259.6,51.92),
('SHOP-1466','MHOD-BLK-XL',1,1299,194.85,55.21),
('AMAZ-1571','BKUR-MUS-67Y',1,949,142.35,40.33),
('AMAZ-1572','BKUR-MUS-89Y',1,949,189.8,37.96),
('AMAZ-1572','BKUR-MUS-45Y',1,949,189.8,37.96),
('AMAZ-1572','BSHT-NVY-45Y',2,349,139.6,27.92)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1465','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('FLIP-1382', 'approved');
select pg_temp.ret_set('FLIP-1386', 'in_transit');
select pg_temp.ret_set('SHOP-1412', 'pickup');
select pg_temp.rto_set('SHOP-1430', 'in_transit');
select pg_temp.rto_set('FLIP-1405', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1438']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-25SEP', array['FLIP-1372','FLIP-1388','SHOP-1410','FLIP-1392','SHOP-1432']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-25SEP', array['FLIP-1393','SHOP-1415','SHOP-1422']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-25SEP', array['FLIP-1397','SHOP-1425','FLIP-1406']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-25SEP', array['SHOP-1405','SHOP-1406','FLIP-1394','SHOP-1421','SHOP-1423','AMAZ-1543']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-25SEP', array['SHOP-1426','AMAZ-1536']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-09-28', 'ICIC000000888110', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-09-28', 'ICIC000000888146', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-09-28', 'ICIC000000888212', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-09-28', 'ICIC000000888284', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-09-28', 'ICIC000000888339', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-09-28', 'ICIC000000888370', 1);
select pg_temp.claim_step('AMAZ-1379', 'lost_shipment', 'approved', null);
select pg_temp.retime();

-- Sat 26 Sep 2026
select pg_temp.day('2026-09-26');
select pg_temp.bill_po('Weekly replenishment 14 Sep 2026 - Ludhiana Winter Wear Co (ref R180)', 'LWW/26/0203', 1);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Little Stitch Garments (ref R186)', 'DC-LSG-0148', '[{"sku":"BKUR-MUS-45Y","q":6,"a":6,"r":0},{"sku":"GFRK-LIL-45Y","q":4,"a":4,"r":0},{"sku":"GLHG-TEL-67Y","q":5,"a":5,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Little Stitch Garments (ref R187)', 'LSG/26/0367', 1);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Rajdhani Shirting Mills (ref R191)', 'DC-RSM-0163', '[{"sku":"MSHF-WHT-L","q":8,"a":8,"r":0},{"sku":"MBLZ-NVY-42","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Shree Ambika Textiles (ref R192)', 'DC-SAT-0151', '[{"sku":"WKRT-PNK-L","q":10,"a":10,"r":0},{"sku":"WKRT-TEL-M","q":6,"a":6,"r":0},{"sku":"WPAL-YLW-L","q":6,"a":6,"r":0},{"sku":"WSAR-RED-FREE","q":6,"a":6,"r":0},{"sku":"WSAR-GRN-FREE","q":14,"a":14,"r":0},{"sku":"WSAR-BLU-FREE","q":6,"a":6,"r":0},{"sku":"WLHG-RED-L","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Shree Ambika Textiles (ref R193)', 'DC-SAT-0154', '[{"sku":"WKRT-PNK-XL","q":8,"a":8,"r":0},{"sku":"WPAL-WHT-L","q":6,"a":6,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('FLIP-1428','Flipkart - Seller Hub','2026-09-26 22:03+05:30','Nidhi Agarwal','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1467','Shopify - Main Store','2026-09-26 15:26+05:30','Tanvi Rana','prepaid',2747.0,137.35,130.48,2740.13,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1429','Flipkart - Seller Hub','2026-09-26 13:38+05:30','Dev Trivedi','cod',3799.0,379.9,615.44,4034.54,'delivered','pending','Rajasthan','Surat Main Warehouse'),
('AMAZ-1573','Amazon - Seller Central','2026-09-26 12:53+05:30','Prachi Kulkarni','prepaid',2848.0,0.0,142.4,2990.4,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1574','Amazon - Seller Central','2026-09-26 12:36+05:30','Sanjay Gajera','prepaid',599.0,119.8,23.96,503.16,'cancelled','refunded','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1430','Flipkart - Seller Hub','2026-09-26 15:07+05:30','Heena Khan','prepaid',7746.0,774.6,991.96,7963.36,'shipped','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1468','Shopify - Main Store','2026-09-26 11:39+05:30','Rohit Iyer','prepaid',999.0,0.0,49.95,1048.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1431','Flipkart - Seller Hub','2026-09-26 16:32+05:30','Sejal Kapadia','prepaid',3295.0,0.0,164.75,3459.75,'shipped','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1469','Shopify - Main Store','2026-09-26 13:17+05:30','Dev Trivedi','cod',349.0,0.0,17.45,366.45,'delivered','pending','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1575','Amazon - Seller Central','2026-09-26 09:55+05:30','Mehul Shukla','prepaid',1348.0,134.8,60.67,1273.87,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1432','Flipkart - Seller Hub','2026-09-26 14:54+05:30','Harsh Modi','prepaid',5647.0,1129.4,620.98,5138.58,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1576','Amazon - Seller Central','2026-09-26 17:16+05:30','Kunal Desai','prepaid',349.0,87.25,13.09,274.84,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1577','Amazon - Seller Central','2026-09-26 19:07+05:30','Jigar Chauhan','prepaid',599.0,119.8,23.96,503.16,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1433','Flipkart - Seller Hub','2026-09-26 14:44+05:30','Aditi Joshi','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1578','Amazon - Seller Central','2026-09-26 19:38+05:30','Jigar Chauhan','prepaid',329.0,32.9,14.81,310.91,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1434','Flipkart - Seller Hub','2026-09-26 18:59+05:30','Meghna Rao','prepaid',2047.0,511.75,76.77,1612.02,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1579','Amazon - Seller Central','2026-09-26 16:05+05:30','Sejal Kapadia','prepaid',1348.0,134.8,60.67,1273.87,'shipped','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1580','Amazon - Seller Central','2026-09-26 18:38+05:30','Vipul Gandhi','prepaid',449.0,89.8,17.96,377.16,'delivered','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('FLIP-1428','WTOP-PCH-L',1,599,0.0,29.95),
('SHOP-1467','BKUR-MUS-89Y',1,949,47.45,45.08),
('SHOP-1467','BTRK-BLK-45Y',1,999,49.95,47.45),
('SHOP-1467','BJNS-IND-89Y',1,799,39.95,37.95),
('FLIP-1429','MBLZ-NVY-40',1,3799,379.9,615.44),
('AMAZ-1573','WDRS-FLP-M',1,1499,0.0,74.95),
('AMAZ-1573','WJNS-IND-30',1,1349,0.0,67.45),
('AMAZ-1574','WTOP-PCH-L',1,599,119.8,23.96),
('FLIP-1430','WLHG-RED-M',1,5499,549.9,890.84),
('FLIP-1430','BKUR-MUS-67Y',2,949,189.8,85.41),
('FLIP-1430','WLEG-MAR-L',1,349,34.9,15.71),
('SHOP-1468','BTRK-BLK-45Y',1,999,0.0,49.95),
('FLIP-1431','MSHC-GRN-L',1,899,0.0,44.95),
('FLIP-1431','WPAL-YLW-XL',1,599,0.0,29.95),
('FLIP-1431','WTOP-PCH-L',3,599,0.0,89.85),
('SHOP-1469','BSHT-GRY-67Y',1,349,0.0,17.45),
('AMAZ-1575','MSHC-GRN-L',1,899,89.9,40.46),
('AMAZ-1575','MTEE-WHT-M',1,449,44.9,20.21),
('FLIP-1432','MCHN-KHK-30',1,1199,239.8,47.96),
('FLIP-1432','MTRK-BLK-M',1,649,129.8,25.96),
('FLIP-1432','MBLZ-NVY-40',1,3799,759.8,547.06),
('AMAZ-1576','WLEG-BLK-M',1,349,87.25,13.09),
('AMAZ-1577','WPAL-WHT-M',1,599,119.8,23.96),
('FLIP-1433','MCHN-KHK-30',1,1199,119.9,53.96),
('AMAZ-1578','BTEE-BLU-67Y',1,329,32.9,14.81),
('FLIP-1434','WTOP-PCH-L',2,599,299.5,44.93),
('FLIP-1434','WKRT-PNK-M',1,849,212.25,31.84),
('AMAZ-1579','MSHC-GRN-L',1,899,89.9,40.46),
('AMAZ-1579','WDUP-GLD-FREE',1,449,44.9,20.21),
('AMAZ-1580','WDUP-SLV-FREE',1,449,89.8,17.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1429','Xpressbees - Pandesara'),
('SHOP-1469','Xpressbees - Pandesara')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_dispo('SHOP-1354', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1477', 'in_transit');
select pg_temp.ret_dispo('AMAZ-1491', 'good', 'restocked');
select pg_temp.ret_new('AMAZ-1504', 'Wrong item delivered', 'webhook');
select pg_temp.ret_set('FLIP-1382', 'pickup');
select pg_temp.ret_set('FLIP-1389', 'in_transit');
select pg_temp.ret_new('SHOP-1420', 'Customer changed mind', 'webhook');
select pg_temp.rto_recv('FLIP-1400', 'good', 'restocked');
select pg_temp.ret_new('SHOP-1424', 'Wrong item delivered', 'manual');
select pg_temp.ret_new('FLIP-1403', 'Customer changed mind', 'webhook');
select pg_temp.cod_collect(array['SHOP-1446']::text[]);
select pg_temp.cod_collect(array['SHOP-1447']::text[]);
select pg_temp.ret_new('AMAZ-1551', 'Wrong item delivered', 'webhook');
select pg_temp.rto_new('SHOP-1450', 'AWB31001226', 'Customer refused delivery');
select pg_temp.cod_collect(array['SHOP-1454']::text[]);
select pg_temp.cod_collect(array['SHOP-1455']::text[]);
select pg_temp.retime();

-- Sun 27 Sep 2026
select pg_temp.day('2026-09-27');
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Krishna Denim Works (ref R185)', 'DC-KDW-0160', '[{"sku":"WJNS-IND-32","q":10,"a":10,"r":0},{"sku":"GJNS-IND-1011Y","q":12,"a":12,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Little Stitch Garments (ref R186)', 'LSG/26/0354', 1);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Rajdhani Shirting Mills (ref R190)', 'DC-RSM-0160', '[{"sku":"MSHC-GRN-M","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Rajdhani Shirting Mills (ref R191)', 'RSM/26/0390', 1);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Shree Ambika Textiles (ref R192)', 'SAT/26/0363', 1);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Shree Ambika Textiles (ref R193)', 'SAT/26/0370', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1470','Shopify - Main Store','2026-09-27 19:32+05:30','Sejal Kapadia','prepaid',349.0,34.9,15.71,329.81,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1581','Amazon - Seller Central','2026-09-27 20:13+05:30','Nidhi Agarwal','prepaid',1797.0,359.4,71.88,1509.48,'shipped','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1435','Flipkart - Seller Hub','2026-09-27 20:05+05:30','Yash Vora','prepaid',3997.0,399.7,179.87,3777.17,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1582','Amazon - Seller Central','2026-09-27 14:55+05:30','Aditi Joshi','cod',1048.0,157.2,44.54,935.34,'delivered','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1436','Flipkart - Seller Hub','2026-09-27 12:07+05:30','Harsh Modi','prepaid',2698.0,404.7,114.67,2407.97,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1437','Flipkart - Seller Hub','2026-09-27 10:14+05:30','Isha Gupta','prepaid',279.0,41.85,11.86,249.01,'shipped','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1438','Flipkart - Seller Hub','2026-09-27 17:43+05:30','Sagar Rathod','prepaid',2406.0,360.9,102.26,2147.36,'shipped','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1471','Shopify - Main Store','2026-09-27 09:04+05:30','Isha Gupta','cod',2597.0,0.0,129.85,2726.85,'shipped','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1583','Amazon - Seller Central','2026-09-27 11:22+05:30','Rohit Iyer','prepaid',2476.0,371.4,105.23,2209.83,'shipped','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1584','Amazon - Seller Central','2026-09-27 14:41+05:30','Mitul Dave','prepaid',3697.0,739.4,147.88,3105.48,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1585','Amazon - Seller Central','2026-09-27 18:40+05:30','Riya Shah','prepaid',599.0,0.0,29.95,628.95,'shipped','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1472','Shopify - Main Store','2026-09-27 16:43+05:30','Pooja Jain','prepaid',2398.0,239.8,107.91,2266.11,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1439','Flipkart - Seller Hub','2026-09-27 16:42+05:30','Isha Gupta','prepaid',349.0,52.35,14.83,311.48,'delivered','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1440','Flipkart - Seller Hub','2026-09-27 12:12+05:30','Sonal Parekh','cod',1897.0,474.25,71.14,1493.89,'delivered','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1586','Amazon - Seller Central','2026-09-27 21:53+05:30','Vivek Singh','prepaid',599.0,119.8,23.96,503.16,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1473','Shopify - Main Store','2026-09-27 18:09+05:30','Nikhil Pandey','cod',1257.0,62.85,59.71,1253.86,'delivered','pending','Madhya Pradesh','Surat Main Warehouse'),
('AMAZ-1587','Amazon - Seller Central','2026-09-27 13:13+05:30','Divya Nair','prepaid',279.0,41.85,11.86,249.01,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1441','Flipkart - Seller Hub','2026-09-27 12:57+05:30','Rahul Bhatt','prepaid',699.0,174.75,26.21,550.46,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1588','Amazon - Seller Central','2026-09-27 13:18+05:30','Rohit Iyer','prepaid',949.0,142.35,40.33,846.98,'shipped','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1470','BSHT-NVY-67Y',1,349,34.9,15.71),
('AMAZ-1581','WLEG-BLK-L',2,349,139.6,27.92),
('AMAZ-1581','MKUR-WHT-L',1,1099,219.8,43.96),
('FLIP-1435','BTRK-BLK-89Y',1,999,99.9,44.96),
('FLIP-1435','WDRS-FLP-S',2,1499,299.8,134.91),
('AMAZ-1582','WDUP-GLD-FREE',1,449,67.35,19.08),
('AMAZ-1582','WTOP-PCH-M',1,599,89.85,25.46),
('FLIP-1436','MJNS-IND-34',1,1399,209.85,59.46),
('FLIP-1436','MHOD-BLK-M',1,1299,194.85,55.21),
('FLIP-1437','GLEG-PNK-45Y',1,279,41.85,11.86),
('FLIP-1438','BTEE-BLU-67Y',2,329,98.7,27.97),
('FLIP-1438','BJNS-IND-1011Y',1,799,119.85,33.96),
('FLIP-1438','BKUR-MUS-67Y',1,949,142.35,40.33),
('SHOP-1471','MCHN-OLV-30',1,1199,0.0,59.95),
('SHOP-1471','MPOL-MRN-L',2,699,0.0,69.9),
('AMAZ-1583','BKUR-CRM-89Y',1,949,142.35,40.33),
('AMAZ-1583','BTEE-BLU-67Y',1,329,49.35,13.98),
('AMAZ-1583','WTOP-PCH-L',2,599,179.7,50.92),
('AMAZ-1584','MCHN-KHK-34',2,1199,479.6,95.92),
('AMAZ-1584','MHOD-GRY-M',1,1299,259.8,51.96),
('AMAZ-1585','WTOP-WHT-M',1,599,0.0,29.95),
('SHOP-1472','MCHN-OLV-30',2,1199,239.8,107.91),
('FLIP-1439','WLEG-MAR-L',1,349,52.35,14.83),
('FLIP-1440','BSHF-WHT-1011Y',2,599,299.5,44.93),
('FLIP-1440','MPOL-MRN-XL',1,699,174.75,26.21),
('AMAZ-1586','WTOP-PCH-L',1,599,119.8,23.96),
('SHOP-1473','BTEE-BLU-89Y',2,329,32.9,31.26),
('SHOP-1473','BSHF-WHT-1011Y',1,599,29.95,28.45),
('AMAZ-1587','GLEG-BLK-89Y',1,279,41.85,11.86),
('FLIP-1441','MPOL-MRN-M',1,699,174.75,26.21),
('AMAZ-1588','BKUR-MUS-45Y',1,949,142.35,40.33)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('AMAZ-1582','DTDC - Ring Road Surat'),
('SHOP-1471','Bluedart - Surat City'),
('FLIP-1440','Delhivery - Sachin GIDC Surat'),
('SHOP-1473','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1504', 'approved');
select pg_temp.ret_recv('FLIP-1386');
select pg_temp.ret_set('SHOP-1412', 'in_transit');
select pg_temp.ret_set('SHOP-1420', 'approved');
select pg_temp.ret_set('SHOP-1424', 'approved');
select pg_temp.ret_set('FLIP-1403', 'approved');
select pg_temp.ret_set('AMAZ-1551', 'approved');
select pg_temp.rto_new('FLIP-1412', 'AWB31001284', 'Delivery attempts exhausted');
select pg_temp.settle_pay('AMZ-STL-20260914', 0.0);
select pg_temp.retime();

-- Mon 28 Sep 2026
select pg_temp.day('2026-09-28');
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Krishna Denim Works (ref R185)', 'KDW/26/0384', 1);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Rajdhani Shirting Mills (ref R190)', 'RSM/26/0384', 1);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Krishna Denim Works (ref R196)', 'Krishna Denim Works', 'Mumbai Fulfilment Center', '[{"sku":"MJNS-BLK-34","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Krishna Denim Works (ref R197)', 'Krishna Denim Works', 'Surat Main Warehouse', '[{"sku":"MCHN-KHK-30","q":18},{"sku":"MCHN-OLV-30","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Little Stitch Garments (ref R198)', 'Little Stitch Garments', 'Mumbai Fulfilment Center', '[{"sku":"BSHT-GRY-89Y","q":6},{"sku":"BKUR-MUS-45Y","q":12},{"sku":"GNGT-PNK-1011Y","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Little Stitch Garments (ref R199)', 'Little Stitch Garments', 'Surat Main Warehouse', '[{"sku":"WDRS-FLR-L","q":8},{"sku":"BKUR-MUS-45Y","q":14}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Ludhiana Winter Wear Co (ref R200)', 'Ludhiana Winter Wear Co', 'Surat Main Warehouse', '[{"sku":"MHOD-GRY-M","q":8},{"sku":"WJKT-BLK-L","q":6},{"sku":"BTRK-BLK-45Y","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Rajdhani Shirting Mills (ref R201)', 'Rajdhani Shirting Mills', 'Mumbai Fulfilment Center', '[{"sku":"MSHF-WHT-L","q":6}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Rajdhani Shirting Mills (ref R202)', 'Rajdhani Shirting Mills', 'Surat Main Warehouse', '[{"sku":"MKUR-WHT-L","q":12}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Shree Ambika Textiles (ref R203)', 'Shree Ambika Textiles', 'Mumbai Fulfilment Center', '[{"sku":"WKRT-TEL-L","q":8}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Shree Ambika Textiles (ref R204)', 'Shree Ambika Textiles', 'Surat Main Warehouse', '[{"sku":"WSAR-BLU-FREE","q":10},{"sku":"WDUP-GLD-FREE","q":10}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R205)', 'Tiruppur Knit Fashions Pvt Ltd', 'Mumbai Fulfilment Center', '[{"sku":"MTRK-BLK-M","q":10},{"sku":"MTRK-BLK-L","q":14}]'::jsonb);
select pg_temp.po_new('Weekly replenishment 28 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R206)', 'Tiruppur Knit Fashions Pvt Ltd', 'Surat Main Warehouse', '[{"sku":"MPOL-NVY-M","q":8},{"sku":"MTRK-BLK-L","q":12},{"sku":"WLEG-BLK-M","q":14},{"sku":"WLEG-MAR-L","q":6},{"sku":"WTOP-WHT-M","q":48},{"sku":"BTEE-BLU-89Y","q":16},{"sku":"GLEG-BLK-89Y","q":18},{"sku":"GLEG-PNK-89Y","q":14}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1474','Shopify - Main Store','2026-09-28 15:58+05:30','Divya Nair','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1589','Amazon - Seller Central','2026-09-28 20:20+05:30','Rahul Bhatt','prepaid',349.0,69.8,13.96,293.16,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1442','Flipkart - Seller Hub','2026-09-28 22:55+05:30','Tanvi Rana','prepaid',3396.0,0.0,169.8,3565.8,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1475','Shopify - Main Store','2026-09-28 22:05+05:30','Aditi Joshi','cod',4146.0,0.0,207.3,4353.3,'delivered','pending','Gujarat','Surat Main Warehouse'),
('SHOP-1476','Shopify - Main Store','2026-09-28 16:43+05:30','Yash Vora','cod',1499.0,74.95,71.2,1495.25,'shipped','pending','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1443','Flipkart - Seller Hub','2026-09-28 16:15+05:30','Karan Malhotra','prepaid',3226.0,322.6,145.18,3048.58,'shipped','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1590','Amazon - Seller Central','2026-09-28 15:02+05:30','Chirag Zaveri','prepaid',7996.0,1199.4,339.83,7136.43,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1591','Amazon - Seller Central','2026-09-28 09:15+05:30','Mehul Shukla','prepaid',1498.0,374.5,56.17,1179.67,'shipped','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1477','Shopify - Main Store','2026-09-28 18:51+05:30','Manav Joshi','cod',3796.0,379.6,170.83,3587.23,'shipped','pending','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1592','Amazon - Seller Central','2026-09-28 09:03+05:30','Riya Shah','prepaid',279.0,0.0,13.95,292.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1593','Amazon - Seller Central','2026-09-28 20:02+05:30','Manav Joshi','prepaid',1148.0,287.0,43.05,904.05,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1594','Amazon - Seller Central','2026-09-28 21:59+05:30','Chirag Zaveri','prepaid',1848.0,0.0,92.4,1940.4,'delivered','paid','Rajasthan','Surat Main Warehouse'),
('SHOP-1478','Shopify - Main Store','2026-09-28 11:37+05:30','Kavya Menon','cod',2497.0,124.85,118.61,2490.76,'delivered','pending','Gujarat','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1474','MCHN-OLV-32',1,1199,119.9,53.96),
('AMAZ-1589','WLEG-BLK-L',1,349,69.8,13.96),
('FLIP-1442','WKRT-TEL-M',2,849,0.0,84.9),
('FLIP-1442','WKRT-PNK-XL',2,849,0.0,84.9),
('SHOP-1475','WKRT-TEL-L',1,849,0.0,42.45),
('SHOP-1475','WPAL-WHT-XL',1,599,0.0,29.95),
('SHOP-1475','WJNS-BLK-28',2,1349,0.0,134.9),
('SHOP-1476','WDRS-FLP-S',1,1499,74.95,71.2),
('FLIP-1443','BKUR-CRM-89Y',2,949,189.8,85.41),
('FLIP-1443','BTEE-BLU-89Y',1,329,32.9,14.81),
('FLIP-1443','BTRK-BLK-89Y',1,999,99.9,44.96),
('AMAZ-1590','GLHG-RED-45Y',1,1999,299.85,84.96),
('AMAZ-1590','GLHG-TEL-45Y',3,1999,899.55,254.87),
('AMAZ-1591','MPOL-MRN-M',1,699,174.75,26.21),
('AMAZ-1591','BJNS-IND-67Y',1,799,199.75,29.96),
('SHOP-1477','WDRS-FLR-S',1,1499,149.9,67.46),
('SHOP-1477','WTOP-PCH-L',1,599,59.9,26.96),
('SHOP-1477','WKRT-TEL-XL',2,849,169.8,76.41),
('AMAZ-1592','GLEG-PNK-67Y',1,279,0.0,13.95),
('AMAZ-1593','GNGT-PNK-45Y',1,549,137.25,20.59),
('AMAZ-1593','WTOP-WHT-M',1,599,149.75,22.46),
('AMAZ-1594','MTEE-BLK-L',1,449,0.0,22.45),
('AMAZ-1594','MJNS-BLK-30',1,1399,0.0,69.95),
('SHOP-1478','MCHN-OLV-30',1,1199,59.95,56.95),
('SHOP-1478','MTRK-BLK-M',2,649,64.9,61.66)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('SHOP-1475','DTDC - Ring Road Surat'),
('SHOP-1476','Bluedart - Surat City'),
('SHOP-1477','Ecom Express - Udhna Hub'),
('SHOP-1478','DTDC - Ring Road Surat')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_set('AMAZ-1504', 'pickup');
select pg_temp.ret_set('FLIP-1382', 'in_transit');
select pg_temp.ret_dispo('FLIP-1386', 'damaged', 'quarantined');
select pg_temp.ret_recv('FLIP-1389');
select pg_temp.ret_set('SHOP-1420', 'pickup');
select pg_temp.ret_new('AMAZ-1527', 'Customer changed mind', 'webhook');
select pg_temp.ret_set('SHOP-1424', 'pickup');
select pg_temp.ret_set('FLIP-1403', 'pickup');
select pg_temp.rto_recv('FLIP-1405', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1551', 'pickup');
select pg_temp.rto_set('SHOP-1450', 'in_transit');
select pg_temp.rto_new('FLIP-1411', 'AWB31001262', 'Address incomplete');
select pg_temp.cod_collect(array['FLIP-1418']::text[]);
select pg_temp.cod_collect(array['SHOP-1465']::text[]);
select pg_temp.settle_new('Amazon - Seller Central', 'AMZ-STL-20260921', '2026-09-21', '2026-09-27', array['AMAZ-1519','AMAZ-1522','AMAZ-1533','AMAZ-1534','AMAZ-1521','AMAZ-1523','AMAZ-1529','AMAZ-1531','AMAZ-1542','AMAZ-1526','AMAZ-1527','AMAZ-1528','AMAZ-1532','AMAZ-1537','AMAZ-1539','AMAZ-1545','AMAZ-1547','AMAZ-1548','AMAZ-1530','AMAZ-1535','AMAZ-1538','AMAZ-1540','AMAZ-1541','AMAZ-1544','AMAZ-1549','AMAZ-1551','AMAZ-1552','AMAZ-1546','AMAZ-1554','AMAZ-1553','AMAZ-1555','AMAZ-1556','AMAZ-1557','AMAZ-1558','AMAZ-1559','AMAZ-1567']::text[], array['AMAZ-1466','AMAZ-1465','AMAZ-1491']::text[]);
select pg_temp.settle_new('Flipkart - Seller Hub', 'FLK-STL-20260921', '2026-09-21', '2026-09-27', array['FLIP-1399','FLIP-1401','FLIP-1402','FLIP-1403','FLIP-1404','FLIP-1407','FLIP-1409','FLIP-1410','FLIP-1417','FLIP-1420']::text[], array['FLIP-1340','FLIP-1354','FLIP-1386']::text[]);
select pg_temp.settle_new('Shopify - Main Store', 'SHP-STL-20260921', '2026-09-21', '2026-09-27', array['SHOP-1418','SHOP-1428','SHOP-1420','SHOP-1424','SHOP-1431','SHOP-1439','SHOP-1440','SHOP-1429','SHOP-1441','SHOP-1442','SHOP-1433','SHOP-1437','SHOP-1443','SHOP-1444','SHOP-1445','SHOP-1448','SHOP-1449','SHOP-1451','SHOP-1452','SHOP-1453','SHOP-1459']::text[], array[]::text[]);
select pg_temp.claim_recover('FLIP-1273', 'excess_deduction', 'CLAIM-CR-FLIP-1273');
select pg_temp.claim_step('AMAZ-1407', 'damaged_return', 'approved', null);
select pg_temp.claim_new('FLIP-1386', 'damaged_return', 2077.11, '2026-10-28');
select pg_temp.retime();

-- Tue 29 Sep 2026
select pg_temp.day('2026-09-29');
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1595','Amazon - Seller Central','2026-09-29 15:46+05:30','Yash Vora','prepaid',678.0,101.7,28.81,605.11,'delivered','paid','Delhi','Surat Main Warehouse'),
('SHOP-1479','Shopify - Main Store','2026-09-29 10:32+05:30','Manav Joshi','cod',8046.0,804.6,1005.46,8246.86,'cancelled','failed','Gujarat','Surat Main Warehouse'),
('AMAZ-1596','Amazon - Seller Central','2026-09-29 19:35+05:30','Aditi Joshi','prepaid',949.0,0.0,47.45,996.45,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1444','Flipkart - Seller Hub','2026-09-29 17:55+05:30','Meghna Rao','prepaid',3956.0,395.6,493.81,4054.21,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1445','Flipkart - Seller Hub','2026-09-29 20:51+05:30','Mehul Shukla','prepaid',5198.0,779.7,640.71,5059.01,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1446','Flipkart - Seller Hub','2026-09-29 17:55+05:30','Anjali Verma','prepaid',7794.0,1558.8,311.76,6546.96,'delivered','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1597','Amazon - Seller Central','2026-09-29 11:39+05:30','Aditi Joshi','prepaid',1797.0,179.7,80.87,1698.17,'shipped','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('FLIP-1447','Flipkart - Seller Hub','2026-09-29 10:35+05:30','Shreya Banerjee','prepaid',599.0,0.0,29.95,628.95,'delivered','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1448','Flipkart - Seller Hub','2026-09-29 10:26+05:30','Prachi Kulkarni','prepaid',987.0,197.4,39.48,829.08,'delivered','paid','Maharashtra','Mumbai Fulfilment Center'),
('FLIP-1449','Flipkart - Seller Hub','2026-09-29 16:14+05:30','Manav Joshi','prepaid',5145.0,771.75,218.67,4591.92,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1450','Flipkart - Seller Hub','2026-09-29 21:12+05:30','Yash Vora','prepaid',1698.0,339.6,67.92,1426.32,'shipped','paid','West Bengal','Surat Main Warehouse'),
('AMAZ-1598','Amazon - Seller Central','2026-09-29 20:24+05:30','Vipul Gandhi','prepaid',1199.0,119.9,53.96,1133.06,'shipped','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1480','Shopify - Main Store','2026-09-29 22:22+05:30','Chirag Zaveri','prepaid',949.0,142.35,40.33,846.98,'delivered','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1481','Shopify - Main Store','2026-09-29 13:57+05:30','Riya Shah','prepaid',1199.0,119.9,53.96,1133.06,'delivered','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1599','Amazon - Seller Central','2026-09-29 17:09+05:30','Chirag Zaveri','prepaid',1978.0,296.7,84.07,1765.37,'delivered','paid','Delhi','Surat Main Warehouse'),
('FLIP-1451','Flipkart - Seller Hub','2026-09-29 10:25+05:30','Shreya Banerjee','prepaid',2148.0,214.8,96.67,2029.87,'delivered','paid','Delhi','Surat Main Warehouse')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1595','BSHT-NVY-67Y',1,349,52.35,14.83),
('AMAZ-1595','BTEE-BLU-45Y',1,329,49.35,13.98),
('SHOP-1479','WTOP-WHT-L',2,599,119.8,53.91),
('SHOP-1479','WJNS-IND-28',1,1349,134.9,60.71),
('SHOP-1479','WLHG-RED-M',1,5499,549.9,890.84),
('AMAZ-1596','BKUR-CRM-89Y',1,949,0.0,47.45),
('FLIP-1444','WJKT-BLK-L',1,2699,269.9,437.24),
('FLIP-1444','BTEE-RED-89Y',2,329,65.8,29.61),
('FLIP-1444','WTOP-PCH-S',1,599,59.9,26.96),
('FLIP-1445','MJNS-BLK-34',1,1399,209.85,59.46),
('FLIP-1445','MBLZ-NVY-40',1,3799,569.85,581.25),
('FLIP-1446','MJNS-BLK-34',2,1399,559.6,111.92),
('FLIP-1446','MCHN-OLV-32',2,1199,479.6,95.92),
('FLIP-1446','MHOD-BLK-XL',2,1299,519.6,103.92),
('AMAZ-1597','WTOP-PCH-M',2,599,119.8,53.91),
('AMAZ-1597','WPAL-YLW-XL',1,599,59.9,26.96),
('FLIP-1447','WTOP-PCH-L',1,599,0.0,29.95),
('FLIP-1448','BTEE-BLU-89Y',3,329,197.4,39.48),
('FLIP-1449','MTRK-BLK-L',1,649,97.35,27.58),
('FLIP-1449','MJNS-BLK-32',1,1399,209.85,59.46),
('FLIP-1449','MSHC-RED-XL',1,899,134.85,38.21),
('FLIP-1449','MKUR-WHT-XL',2,1099,329.7,93.42),
('FLIP-1450','WKRT-TEL-M',2,849,339.6,67.92),
('AMAZ-1598','MCHN-OLV-32',1,1199,119.9,53.96),
('SHOP-1480','BKUR-MUS-67Y',1,949,142.35,40.33),
('SHOP-1481','MCHN-KHK-30',1,1199,119.9,53.96),
('AMAZ-1599','MCHN-KHK-30',1,1199,179.85,50.96),
('AMAZ-1599','GJNS-IND-45Y',1,779,116.85,33.11),
('FLIP-1451','MHOD-GRY-M',1,1299,129.9,58.46),
('FLIP-1451','WKRT-PNK-M',1,849,84.9,38.21)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_refund_d2c('SHOP-1354', 'UPI-REFUND-SHOP-1354');
select pg_temp.ret_recv('AMAZ-1477');
select pg_temp.ret_dispo('FLIP-1389', 'damaged', 'quarantined');
select pg_temp.ret_set('AMAZ-1527', 'approved');
select pg_temp.rto_set('FLIP-1412', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1469']::text[]);
select pg_temp.settle_pay('FLK-STL-20260914', 0.0);
select pg_temp.claim_recover('AMAZ-1383', 'damaged_return', 'CLAIM-CR-AMAZ-1383');
select pg_temp.claim_new('FLIP-1389', 'damaged_return', 1479.24, '2026-10-29');
select pg_temp.retime();

-- Wed 30 Sep 2026
select pg_temp.day('2026-09-30');
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Little Stitch Garments (ref R186)', 'DC-LSG-0151', '[{"sku":"BKUR-MUS-45Y","q":4,"a":4,"r":0},{"sku":"GFRK-LIL-45Y","q":2,"a":2,"r":0},{"sku":"GLHG-TEL-67Y","q":3,"a":3,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Ludhiana Winter Wear Co (ref R189)', 'DC-LWW-0088', '[{"sku":"MHOD-BLK-M","q":14,"a":13,"r":1}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R194)', 'DC-TKF-0214', '[{"sku":"MTRK-BLK-L","q":8,"a":8,"r":0},{"sku":"WTOP-WHT-L","q":9,"a":9,"r":0},{"sku":"WTOP-PCH-L","q":21,"a":21,"r":0},{"sku":"BTEE-RED-89Y","q":9,"a":9,"r":0},{"sku":"GLEG-PNK-89Y","q":8,"a":7,"r":1}]'::jsonb);
select pg_temp.adjust('MKUR-MUS-XL', 'Surat Main Warehouse', -1);
select pg_temp.adjust('MJNS-IND-32', 'Surat Main Warehouse', -2);
select pg_temp.adjust('MCHN-OLV-30', 'Mumbai Fulfilment Center', 1);
select pg_temp.adjust('WJNS-IND-28', 'Surat Main Warehouse', -1);
select pg_temp.adjust('MCHN-KHK-30', 'Mumbai Fulfilment Center', -2);
select pg_temp.adjust('MTEE-BLK-L', 'Surat Main Warehouse', -1);
select pg_temp.adjust('MTEE-BLK-M', 'Surat Main Warehouse', -2);
select pg_temp.adjust('GNGT-PNK-89Y', 'Surat Main Warehouse', -1);
select pg_temp.adjust('GTOP-YLW-67Y', 'Surat Main Warehouse', 1);
select pg_temp.adjust('BTEE-BLU-45Y', 'Surat Main Warehouse', -2);
select pg_temp.adjust('MKUR-MUS-M', 'Mumbai Fulfilment Center', -1);
select pg_temp.adjust('WPAL-YLW-XL', 'Mumbai Fulfilment Center', -1);
select pg_temp.adjust('BSHF-WHT-67Y', 'Surat Main Warehouse', -1);
select pg_temp.adjust('MJNS-IND-32', 'Mumbai Fulfilment Center', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('AMAZ-1600','Amazon - Seller Central','2026-09-30 17:18+05:30','Sagar Rathod','prepaid',3998.0,599.7,169.92,3568.22,'delivered','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1601','Amazon - Seller Central','2026-09-30 15:03+05:30','Foram Thakkar','prepaid',4696.0,469.6,211.33,4437.73,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1602','Amazon - Seller Central','2026-09-30 19:33+05:30','Jigar Chauhan','prepaid',749.0,149.8,29.96,629.16,'shipped','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1452','Flipkart - Seller Hub','2026-09-30 20:01+05:30','Sagar Rathod','prepaid',1199.0,299.75,44.96,944.21,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('SHOP-1482','Shopify - Main Store','2026-09-30 09:52+05:30','Sagar Rathod','prepaid',658.0,98.7,27.97,587.27,'shipped','paid','Gujarat','Surat Main Warehouse'),
('SHOP-1483','Shopify - Main Store','2026-09-30 13:05+05:30','Neha Patel','prepaid',2698.0,134.9,128.16,2691.26,'delivered','paid','Tamil Nadu','Mumbai Fulfilment Center'),
('AMAZ-1603','Amazon - Seller Central','2026-09-30 10:27+05:30','Nidhi Agarwal','prepaid',1297.0,129.7,58.37,1225.67,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1604','Amazon - Seller Central','2026-09-30 13:17+05:30','Sejal Kapadia','prepaid',2047.0,511.75,76.77,1612.02,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('FLIP-1453','Flipkart - Seller Hub','2026-09-30 11:26+05:30','Pooja Jain','prepaid',4096.0,1024.0,153.6,3225.6,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1605','Amazon - Seller Central','2026-09-30 16:29+05:30','Mitul Dave','prepaid',779.0,155.8,31.16,654.36,'processing','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1606','Amazon - Seller Central','2026-09-30 18:09+05:30','Riya Shah','prepaid',1198.0,239.6,47.92,1006.32,'shipped','paid','Tamil Nadu','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('AMAZ-1600','GLHG-TEL-89Y',1,1999,299.85,84.96),
('AMAZ-1600','GLHG-RED-67Y',1,1999,299.85,84.96),
('AMAZ-1601','MCHN-KHK-30',2,1199,239.8,107.91),
('AMAZ-1601','MCHN-OLV-34',1,1199,119.9,53.96),
('AMAZ-1601','MKUR-MUS-XL',1,1099,109.9,49.46),
('AMAZ-1602','GFRK-LIL-45Y',1,749,149.8,29.96),
('FLIP-1452','MCHN-KHK-30',1,1199,299.75,44.96),
('SHOP-1482','BTEE-BLU-67Y',2,329,98.7,27.97),
('SHOP-1483','WJNS-BLK-32',2,1349,134.9,128.16),
('AMAZ-1603','GTOP-YLW-89Y',2,349,69.8,31.41),
('AMAZ-1603','WPAL-WHT-XL',1,599,59.9,26.96),
('AMAZ-1604','WTOP-PCH-L',2,599,299.5,44.93),
('AMAZ-1604','WKRT-PNK-XL',1,849,212.25,31.84),
('FLIP-1453','WKRT-PNK-L',2,849,424.5,63.68),
('FLIP-1453','MCHN-OLV-34',1,1199,299.75,44.96),
('FLIP-1453','MCHN-KHK-30',1,1199,299.75,44.96),
('AMAZ-1605','GJNS-IND-1011Y',1,779,155.8,31.16),
('AMAZ-1606','WLEG-BLK-M',1,349,69.8,13.96),
('AMAZ-1606','WKRT-PNK-M',1,849,169.8,33.96)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
select pg_temp.ret_dispo('AMAZ-1477', 'good', 'restocked');
select pg_temp.ret_set('AMAZ-1504', 'in_transit');
select pg_temp.ret_recv('SHOP-1412');
select pg_temp.ret_set('SHOP-1420', 'in_transit');
select pg_temp.ret_set('AMAZ-1527', 'pickup');
select pg_temp.ret_set('SHOP-1424', 'in_transit');
select pg_temp.ret_set('FLIP-1403', 'in_transit');
select pg_temp.ret_set('AMAZ-1551', 'in_transit');
select pg_temp.rto_set('FLIP-1411', 'in_transit');
select pg_temp.cod_collect(array['SHOP-1461']::text[]);
select pg_temp.cod_collect(array['FLIP-1429']::text[]);
select pg_temp.rto_new('AMAZ-1576', 'AWB31001323', 'Customer refused delivery');
select pg_temp.rto_new('AMAZ-1579', 'AWB31001326', 'Delivery attempts exhausted');
select pg_temp.cod_collect(array['AMAZ-1582']::text[]);
select pg_temp.cod_collect(array['FLIP-1440']::text[]);
select pg_temp.settle_pay('SHP-STL-20260921', 0.0);
select pg_temp.retime();

-- Thu 01 Oct 2026
select pg_temp.day('2026-10-01');
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Little Stitch Garments (ref R186)', 'LSG/26/0361', 1);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Ludhiana Winter Wear Co (ref R188)', 'DC-LWW-0085', '[{"sku":"MHOD-BLK-M","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Ludhiana Winter Wear Co (ref R189)', 'LWW/26/0214', 1);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R194)', 'TKF/26/0510', 1);
select pg_temp.grn_new('Weekly replenishment 21 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R195)', 'DC-TKF-0220', '[{"sku":"MPOL-NVY-M","q":6,"a":6,"r":0},{"sku":"MTRK-BLK-L","q":8,"a":8,"r":0},{"sku":"WLEG-BLK-M","q":10,"a":10,"r":0},{"sku":"WLEG-NVY-M","q":8,"a":7,"r":1},{"sku":"WTOP-WHT-M","q":40,"a":40,"r":0},{"sku":"BTEE-BLU-89Y","q":10,"a":10,"r":0},{"sku":"GLEG-BLK-67Y","q":28,"a":28,"r":0},{"sku":"GLEG-BLK-89Y","q":14,"a":14,"r":0},{"sku":"GLEG-PNK-89Y","q":16,"a":16,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 28 Sep 2026 - Little Stitch Garments (ref R198)', 'DC-LSG-0157', '[{"sku":"BSHT-GRY-89Y","q":6,"a":6,"r":0},{"sku":"BKUR-MUS-45Y","q":12,"a":12,"r":0},{"sku":"GNGT-PNK-1011Y","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 28 Sep 2026 - Shree Ambika Textiles (ref R204)', 'DC-SAT-0160', '[{"sku":"WSAR-BLU-FREE","q":10,"a":10,"r":0},{"sku":"WDUP-GLD-FREE","q":10,"a":10,"r":0}]'::jsonb);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1484','Shopify - Main Store','2026-10-01 21:14+05:30','Pooja Jain','prepaid',2214.0,0.0,110.7,2324.7,'processing','paid','Uttar Pradesh','Surat Main Warehouse'),
('AMAZ-1607','Amazon - Seller Central','2026-10-01 09:26+05:30','Vipul Gandhi','prepaid',2116.0,423.2,84.64,1777.44,'cancelled','refunded','Gujarat','Surat Main Warehouse'),
('FLIP-1454','Flipkart - Seller Hub','2026-10-01 19:26+05:30','Divya Nair','prepaid',799.0,79.9,35.96,755.06,'shipped','paid','Rajasthan','Surat Main Warehouse'),
('FLIP-1455','Flipkart - Seller Hub','2026-10-01 22:56+05:30','Rahul Bhatt','prepaid',5446.0,1361.5,204.23,4288.73,'shipped','paid','Delhi','Surat Main Warehouse'),
('AMAZ-1608','Amazon - Seller Central','2026-10-01 21:34+05:30','Mehul Shukla','prepaid',599.0,89.85,25.46,534.61,'cancelled','refunded','Rajasthan','Surat Main Warehouse'),
('FLIP-1456','Flipkart - Seller Hub','2026-10-01 18:15+05:30','Riya Shah','prepaid',3197.0,479.55,135.88,2853.33,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1609','Amazon - Seller Central','2026-10-01 10:08+05:30','Pratik Lad','prepaid',1198.0,299.5,44.93,943.43,'processing','paid','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1457','Flipkart - Seller Hub','2026-10-01 18:53+05:30','Amit Sethi','cod',628.0,0.0,31.4,659.4,'shipped','pending','Delhi','Surat Main Warehouse'),
('AMAZ-1610','Amazon - Seller Central','2026-10-01 13:30+05:30','Vipul Gandhi','prepaid',2598.0,259.8,116.91,2455.11,'shipped','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1458','Flipkart - Seller Hub','2026-10-01 18:14+05:30','Nikhil Pandey','cod',749.0,187.25,28.09,589.84,'shipped','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1611','Amazon - Seller Central','2026-10-01 22:13+05:30','Isha Gupta','prepaid',2556.0,383.4,108.64,2281.24,'shipped','paid','Maharashtra','Mumbai Fulfilment Center'),
('AMAZ-1612','Amazon - Seller Central','2026-10-01 12:22+05:30','Ritu Saxena','prepaid',2997.0,749.25,112.39,2360.14,'shipped','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1613','Amazon - Seller Central','2026-10-01 17:41+05:30','Aditi Joshi','prepaid',658.0,98.7,27.97,587.27,'shipped','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1614','Amazon - Seller Central','2026-10-01 14:26+05:30','Aditi Joshi','prepaid',329.0,32.9,14.81,310.91,'cancelled','refunded','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1459','Flipkart - Seller Hub','2026-10-01 16:36+05:30','Mitul Dave','cod',2398.0,239.8,107.91,2266.11,'shipped','pending','Delhi','Surat Main Warehouse'),
('SHOP-1485','Shopify - Main Store','2026-10-01 14:50+05:30','Shreya Banerjee','prepaid',5499.0,0.0,989.82,6488.82,'shipped','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1460','Flipkart - Seller Hub','2026-10-01 20:49+05:30','Sanjay Gajera','prepaid',1198.0,119.8,53.92,1132.12,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1615','Amazon - Seller Central','2026-10-01 11:57+05:30','Kiran Naik','prepaid',4896.0,1224.0,183.6,3855.6,'shipped','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1616','Amazon - Seller Central','2026-10-01 18:36+05:30','Yash Vora','cod',948.0,0.0,47.4,995.4,'shipped','pending','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1617','Amazon - Seller Central','2026-10-01 19:07+05:30','Vivek Singh','prepaid',1506.0,225.9,64.01,1344.11,'cancelled','refunded','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1484','GLEG-BLK-67Y',3,279,0.0,41.85),
('SHOP-1484','GNGT-PNK-1011Y',2,549,0.0,54.9),
('SHOP-1484','GLEG-BLK-89Y',1,279,0.0,13.95),
('AMAZ-1607','GJNS-IND-45Y',2,779,311.6,62.32),
('AMAZ-1607','GLEG-BLK-67Y',2,279,111.6,22.32),
('FLIP-1454','BJNS-IND-45Y',1,799,79.9,35.96),
('FLIP-1455','MHOD-BLK-XL',2,1299,649.5,97.43),
('FLIP-1455','WDRS-FLR-S',1,1499,374.75,56.21),
('FLIP-1455','WJNS-IND-32',1,1349,337.25,50.59),
('AMAZ-1608','WTOP-WHT-M',1,599,89.85,25.46),
('FLIP-1456','GLHG-RED-89Y',1,1999,299.85,84.96),
('FLIP-1456','WTOP-WHT-L',2,599,179.7,50.92),
('AMAZ-1609','BSHF-WHT-89Y',2,599,299.5,44.93),
('FLIP-1457','GTOP-YLW-89Y',1,349,0.0,17.45),
('FLIP-1457','GLEG-PNK-67Y',1,279,0.0,13.95),
('AMAZ-1610','MHOD-GRY-M',2,1299,259.8,116.91),
('FLIP-1458','GFRK-LIL-67Y',1,749,187.25,28.09),
('AMAZ-1611','BKUR-MUS-45Y',2,949,284.7,80.67),
('AMAZ-1611','BTEE-BLU-89Y',2,329,98.7,27.97),
('AMAZ-1612','MKUR-WHT-L',1,1099,274.75,41.21),
('AMAZ-1612','BKUR-MUS-45Y',2,949,474.5,71.18),
('AMAZ-1613','BTEE-RED-89Y',2,329,98.7,27.97),
('AMAZ-1614','BTEE-BLU-67Y',1,329,32.9,14.81),
('FLIP-1459','MCHN-OLV-34',2,1199,239.8,107.91),
('SHOP-1485','WLHG-RED-L',1,5499,0.0,989.82),
('FLIP-1460','WTOP-WHT-L',1,599,59.9,26.96),
('FLIP-1460','WTOP-WHT-M',1,599,59.9,26.96),
('AMAZ-1615','MHOD-BLK-M',1,1299,324.75,48.71),
('AMAZ-1615','MCHN-OLV-32',3,1199,899.25,134.89),
('AMAZ-1616','WLEG-BLK-L',1,349,0.0,17.45),
('AMAZ-1616','WPAL-WHT-M',1,599,0.0,29.95),
('AMAZ-1617','WLEG-MAR-M',1,349,52.35,14.83),
('AMAZ-1617','GLEG-PNK-67Y',2,279,83.7,23.72),
('AMAZ-1617','WPAL-WHT-XL',1,599,89.85,25.46)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1457','Xpressbees - Pandesara'),
('FLIP-1458','Xpressbees - Pandesara'),
('FLIP-1459','Ecom Express - Udhna Hub'),
('AMAZ-1616','Bluedart - Surat City')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('FLIP-1382');
select pg_temp.rto_recv('SHOP-1430', 'damaged', 'quarantined');
select pg_temp.ret_new('SHOP-1453', 'Fabric quality not as expected', 'manual');
select pg_temp.cod_collect(array['SHOP-1473']::text[]);
select pg_temp.rto_new('AMAZ-1588', 'AWB31001381', 'Delivery attempts exhausted');
select pg_temp.claim_step('FLIP-1386', 'damaged_return', 'claimed', null);
select pg_temp.retime();

-- Fri 02 Oct 2026
select pg_temp.day('2026-10-02');
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Ludhiana Winter Wear Co (ref R188)', 'LWW/26/0207', 1);
select pg_temp.bill_po('Weekly replenishment 21 Sep 2026 - Tiruppur Knit Fashions Pvt Ltd (ref R195)', 'TKF/26/0522', 1);
select pg_temp.grn_new('Weekly replenishment 28 Sep 2026 - Krishna Denim Works (ref R196)', 'DC-KDW-0163', '[{"sku":"MJNS-BLK-34","q":6,"a":6,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 28 Sep 2026 - Krishna Denim Works (ref R197)', 'DC-KDW-0166', '[{"sku":"MCHN-KHK-30","q":18,"a":18,"r":0},{"sku":"MCHN-OLV-30","q":8,"a":8,"r":0}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 28 Sep 2026 - Little Stitch Garments (ref R198)', 'LSG/26/0376', 1);
select pg_temp.grn_new('Weekly replenishment 28 Sep 2026 - Little Stitch Garments (ref R199)', 'DC-LSG-0160', '[{"sku":"WDRS-FLR-L","q":8,"a":8,"r":0},{"sku":"BKUR-MUS-45Y","q":14,"a":14,"r":0}]'::jsonb);
select pg_temp.grn_new('Weekly replenishment 28 Sep 2026 - Shree Ambika Textiles (ref R203)', 'DC-SAT-0157', '[{"sku":"WKRT-TEL-L","q":8,"a":7,"r":1}]'::jsonb);
select pg_temp.bill_po('Weekly replenishment 28 Sep 2026 - Shree Ambika Textiles (ref R204)', 'SAT/26/0382', 1);
set constraints all deferred;
insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)
select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values
('SHOP-1486','Shopify - Main Store','2026-10-02 21:40+05:30','Riya Shah','prepaid',8275.0,827.5,372.39,7819.89,'shipped','paid','Madhya Pradesh','Surat Main Warehouse'),
('FLIP-1461','Flipkart - Seller Hub','2026-10-02 13:39+05:30','Vipul Gandhi','cod',4245.0,636.75,180.42,3788.67,'shipped','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1618','Amazon - Seller Central','2026-10-02 18:39+05:30','Prachi Kulkarni','prepaid',7055.0,1763.75,264.56,5555.81,'shipped','paid','Rajasthan','Surat Main Warehouse'),
('AMAZ-1619','Amazon - Seller Central','2026-10-02 17:56+05:30','Heena Khan','cod',2098.0,419.6,83.92,1762.32,'shipped','pending','Karnataka','Mumbai Fulfilment Center'),
('FLIP-1462','Flipkart - Seller Hub','2026-10-02 22:17+05:30','Sonal Parekh','prepaid',9996.0,1999.2,971.74,8968.54,'shipped','paid','Karnataka','Mumbai Fulfilment Center'),
('AMAZ-1620','Amazon - Seller Central','2026-10-02 13:42+05:30','Sonal Parekh','prepaid',749.0,74.9,33.71,707.81,'shipped','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1463','Flipkart - Seller Hub','2026-10-02 22:24+05:30','Meghna Rao','prepaid',1299.0,194.85,55.21,1159.36,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1621','Amazon - Seller Central','2026-10-02 10:28+05:30','Kunal Desai','prepaid',1898.0,474.5,71.17,1494.67,'processing','paid','Delhi','Surat Main Warehouse'),
('SHOP-1487','Shopify - Main Store','2026-10-02 15:29+05:30','Kavya Menon','cod',599.0,0.0,29.95,628.95,'shipped','pending','Gujarat','Surat Main Warehouse'),
('FLIP-1464','Flipkart - Seller Hub','2026-10-02 11:52+05:30','Karan Malhotra','prepaid',878.0,219.5,32.92,691.42,'shipped','paid','Karnataka','Mumbai Fulfilment Center'),
('SHOP-1488','Shopify - Main Store','2026-10-02 14:15+05:30','Mehul Shukla','prepaid',349.0,34.9,15.71,329.81,'processing','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1622','Amazon - Seller Central','2026-10-02 11:18+05:30','Neha Patel','prepaid',1898.0,284.7,80.66,1693.96,'shipped','paid','Gujarat','Surat Main Warehouse'),
('AMAZ-1623','Amazon - Seller Central','2026-10-02 14:31+05:30','Pratik Lad','prepaid',349.0,69.8,13.96,293.16,'shipped','paid','West Bengal','Surat Main Warehouse'),
('SHOP-1489','Shopify - Main Store','2026-10-02 19:47+05:30','Shreya Banerjee','prepaid',329.0,32.9,14.81,310.91,'shipped','paid','Gujarat','Surat Main Warehouse'),
('FLIP-1465','Flipkart - Seller Hub','2026-10-02 14:16+05:30','Heena Khan','cod',1399.0,349.75,52.46,1101.71,'shipped','pending','Gujarat','Surat Main Warehouse'),
('AMAZ-1624','Amazon - Seller Central','2026-10-02 20:54+05:30','Sanjay Gajera','prepaid',928.0,139.2,39.44,828.24,'shipped','paid','Maharashtra','Mumbai Fulfilment Center')
) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;
insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
select o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values
('SHOP-1486','GLEG-PNK-45Y',1,279,27.9,12.56),
('SHOP-1486','GLHG-TEL-89Y',3,1999,599.7,269.87),
('SHOP-1486','GLHG-RED-67Y',1,1999,199.9,89.96),
('FLIP-1461','WTOP-WHT-M',1,599,89.85,25.46),
('FLIP-1461','WTOP-PCH-S',2,599,179.7,50.92),
('FLIP-1461','WDRS-FLR-S',1,1499,224.85,63.71),
('FLIP-1461','BKUR-CRM-89Y',1,949,142.35,40.33),
('AMAZ-1618','GLHG-RED-45Y',3,1999,1499.25,224.89),
('AMAZ-1618','GJNS-IND-1011Y',1,779,194.75,29.21),
('AMAZ-1618','GLEG-BLK-89Y',1,279,69.75,10.46),
('AMAZ-1619','WJNS-BLK-30',1,1349,269.8,53.96),
('AMAZ-1619','GFRK-LIL-45Y',1,749,149.8,29.96),
('FLIP-1462','WDRS-FLP-L',3,1499,899.4,179.88),
('FLIP-1462','WLHG-RED-L',1,5499,1099.8,791.86),
('AMAZ-1620','GFRK-LIL-89Y',1,749,74.9,33.71),
('FLIP-1463','MHOD-BLK-XL',1,1299,194.85,55.21),
('AMAZ-1621','WTOP-WHT-M',1,599,149.75,22.46),
('AMAZ-1621','MHOD-BLK-M',1,1299,324.75,48.71),
('SHOP-1487','WTOP-WHT-M',1,599,0.0,29.95),
('FLIP-1464','WTOP-WHT-L',1,599,149.75,22.46),
('FLIP-1464','GLEG-PNK-45Y',1,279,69.75,10.46),
('SHOP-1488','BSHT-GRY-45Y',1,349,34.9,15.71),
('AMAZ-1622','BKUR-CRM-45Y',1,949,142.35,40.33),
('AMAZ-1622','BKUR-MUS-45Y',1,949,142.35,40.33),
('AMAZ-1623','BSHT-NVY-89Y',1,349,69.8,13.96),
('SHOP-1489','BTEE-RED-67Y',1,329,32.9,14.81),
('FLIP-1465','MJNS-BLK-32',1,1399,349.75,52.46),
('AMAZ-1624','WTOP-PCH-L',1,599,89.85,25.46),
('AMAZ-1624','BTEE-BLU-67Y',1,329,49.35,13.98)
) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;
set constraints all immediate;
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)
select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values
('FLIP-1461','DTDC - Ring Road Surat'),
('AMAZ-1619','Xpressbees - Pandesara'),
('SHOP-1487','DTDC - Ring Road Surat'),
('FLIP-1465','Ecom Express - Udhna Hub')
) v(ext, cr) join orders o on o.external_order_id = v.ext;
select pg_temp.ret_recv('AMAZ-1504');
select pg_temp.ret_dispo('SHOP-1412', 'missing', 'claimed');
select pg_temp.ret_set('AMAZ-1527', 'in_transit');
select pg_temp.ret_set('SHOP-1453', 'approved');
select pg_temp.ret_new('FLIP-1413', 'Item arrived damaged', 'webhook');
select pg_temp.rto_set('AMAZ-1576', 'in_transit');
select pg_temp.rto_set('AMAZ-1579', 'in_transit');
select pg_temp.rto_new('FLIP-1441', 'AWB31001360', 'Customer refused delivery');
select pg_temp.cod_collect(array['SHOP-1475']::text[]);
select pg_temp.cod_collect(array['SHOP-1478']::text[]);
select pg_temp.cod_remit('Delhivery - Sachin GIDC Surat', 'COD-DELHIVERY-02OCT', array['SHOP-1446','SHOP-1454','FLIP-1440']::text[], 0.0);
select pg_temp.cod_remit('Ecom Express - Udhna Hub', 'COD-ECOM-02OCT', array['SHOP-1434','SHOP-1447','FLIP-1418']::text[], 0.0);
select pg_temp.cod_remit('DTDC - Ring Road Surat', 'COD-DTDC-02OCT', array['SHOP-1435','SHOP-1438','AMAZ-1582']::text[], 0.0);
select pg_temp.cod_remit('Bluedart - Surat City', 'COD-BLUEDART-02OCT', array['SHOP-1427','SHOP-1436','SHOP-1455','SHOP-1461']::text[], 0.0);
select pg_temp.cod_remit('Xpressbees - Pandesara', 'COD-XPRESSBEES-02OCT', array['FLIP-1408','SHOP-1465','FLIP-1429','SHOP-1469']::text[], 0.0);
select pg_temp.pay_due('Shree Ambika Textiles', '2026-10-05', 'ICIC000000888383', 1);
select pg_temp.pay_due('Tiruppur Knit Fashions Pvt Ltd', '2026-10-05', 'ICIC000000888406', 1);
select pg_temp.pay_due('Ludhiana Winter Wear Co', '2026-10-05', 'ICIC000000888418', 1);
select pg_temp.pay_due('Krishna Denim Works', '2026-10-05', 'ICIC000000888485', 1);
select pg_temp.pay_due('Rajdhani Shirting Mills', '2026-10-05', 'ICIC000000888531', 1);
select pg_temp.pay_due('Little Stitch Garments', '2026-10-05', 'ICIC000000888599', 1);
select pg_temp.claim_step('FLIP-1289', 'lost_shipment', 'rejected', null);
select pg_temp.claim_step('AMAZ-1442', 'lost_shipment', 'approved', null);
select pg_temp.claim_step('FLIP-1389', 'damaged_return', 'claimed', null);
select pg_temp.claim_new('SHOP-1412', 'lost_shipment', 1992.9, '2026-11-01');
select pg_temp.retime();
update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
