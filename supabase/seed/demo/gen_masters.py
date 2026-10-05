#!/usr/bin/env python3
"""Writes supabase/demo/01_masters.sql: company, channels, warehouses, bank accounts and the garment catalogue (idempotent)."""
import os
from catalogue import products, STYLES, LISTED

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "demo")
def q(s): return "null" if s is None else "'" + str(s).replace("'", "''") + "'"

s = []
s.append("""-- 01_masters.sql - business masters the demo story needs. Safe to run on a database that already has them (nothing is duplicated).
-- Company, three sales channels, two warehouses, two bank accounts (with their ledgers), the garment catalogue and the channel listings.
""")
s.append("""insert into companies (name, state, gstin)
select 'Super Seller 360 - Default Company', 'Gujarat', '24AAAAA0000A1Z5' where not exists (select 1 from companies);

insert into channels (company_id, name, type, api_status, settlement_cycle)
select c.company_id, v.name, v.type, 'connected', v.cycle from companies c, (values
  ('Shopify - Main Store', 'd2c', 'Daily'), ('Amazon - Seller Central', 'marketplace', 'T+7'), ('Flipkart - Seller Hub', 'marketplace', 'Weekly')) v(name, type, cycle)
where not exists (select 1 from channels x where x.name = v.name);

insert into warehouses (company_id, name, type, address, status)
select c.company_id, v.name, v.type, v.addr, 'active' from companies c, (values
  ('Surat Main Warehouse', 'own', 'Plot 14, GIDC Sachin, Surat, Gujarat'), ('Mumbai Fulfilment Center', '3pl', 'Bhiwandi Logistics Park, Mumbai, Maharashtra')) v(name, type, addr)
where not exists (select 1 from warehouses x where x.name = v.name);

-- bank ledgers and accounts
insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, status)
select (select account_group_id from account_groups where name = 'Bank Accounts'), v.name, 'asset', 0, 'debit', 'active'
from (values ('Bank - ICICI Bank (7734)'), ('Bank - HDFC Bank (4821)')) v(name)
where not exists (select 1 from ledgers x where x.name = v.name);

insert into bank_accounts (company_id, bank_name, account_name, account_number_last4, status, ledger_id)
select (select company_id from companies limit 1), v.bank, v.acct, v.l4, 'active', (select ledger_id from ledgers where name = v.ledger)
from (values
  ('ICICI Bank - Udhna Branch, Surat', 'Super Seller 360 Collections Account', '7734', 'Bank - ICICI Bank (7734)'),
  ('HDFC Bank - Ring Road Branch, Surat', 'Super Seller 360 Current Account', '4821', 'Bank - HDFC Bank (4821)')) v(bank, acct, l4, ledger)
where not exists (select 1 from bank_accounts x where x.account_number_last4 = v.l4);
""")

LIST_ROWS = [f"({q(p['sku'])},{q(c)},{i * 13 + 1})" for i, p in enumerate(products) for c in sorted(LISTED[p['sku']])]
rows = []
for p in products:
    rows.append(f"({q(p['sku'])},{q(p['name'])},{q(p['variant'])},{q(p['barcode'])},{q(p['hsn'])},{p['rate']},{q(p['brand'])},{q(p['category'])},{p['cost']},{p['pack']},{q(p['status'])})")
s.append("""-- the garment catalogue (166 SKUs: men, women, boys, girls). GST: 5% up to Rs 2,500 per piece, 18% above.
insert into products (company_id, sku, name, variant, barcode, hsn, gst_rate, brand, category, cost_price, packaging_cost, status)
select (select company_id from companies limit 1), v.* from (values
""" + ",\n".join(rows) + """
) as v(sku, name, variant, barcode, hsn, gst_rate, brand, category, cost_price, packaging_cost, status)
where not exists (select 1 from products x where x.sku = v.sku);

-- channel listings: every SKU on Shopify, about 78% on Amazon and 62% on Flipkart. Inactive / discontinued SKUs are inactive on the marketplaces.
insert into channel_sku_map (product_id, channel_id, channel_sku, listing_id, status)
select p.product_id, c.channel_id,
  case v.ch when 'SHOP' then p.sku when 'AMAZ' then 'AMZ-' || p.sku else 'FK-' || p.sku end,
  case when v.ch = 'SHOP' then (7400000000000 + v.n)::text
       when v.ch = 'AMAZ' then 'B0' || upper(substr(md5(p.sku || 'amz'), 1, 8))
       else 'APR' || upper(substr(md5(p.sku || 'fk'), 1, 13)) end,
  case when v.ch <> 'SHOP' and p.status <> 'active' then 'inactive' else 'active' end
from (values
""" + ",\n".join(LIST_ROWS) + """
) as v(sku, ch, n)
join products p on p.sku = v.sku
join channels c on c.name = case v.ch when 'SHOP' then 'Shopify - Main Store' when 'AMAZ' then 'Amazon - Seller Central' else 'Flipkart - Seller Hub' end
where not exists (select 1 from channel_sku_map m where m.product_id = p.product_id and m.channel_id = c.channel_id);

update products set status = 'discontinued' where sku in ('BAG-CNV','BOTL-750','EARBUD-PRO','MUG-350','SLEEVE-14','TS-BLK-M','TS-WHT-M','YOGA-6MM');
""")
open(os.path.join(OUT, "01_masters.sql"), "w").write("\n".join(s))
print("ok", len(products))
