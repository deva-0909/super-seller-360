-- Seed: channels

insert into channels (company_id, name, type, api_status, settlement_cycle)
select company_id, v.name, v.type, 'connected', v.cycle
from companies, (values
  ('Shopify - Main Store','d2c','Daily'),
  ('Amazon - Seller Central','marketplace','T+7'),
  ('Flipkart - Seller Hub','marketplace','Weekly')
) as v(name, type, cycle)
limit 3;

-- Seed: warehouses

insert into warehouses (company_id, name, type, address, status)
select company_id, v.name, v.type, v.address, 'active'
from companies, (values
  ('Surat Main Warehouse','own','Plot 14, GIDC Sachin, Surat, Gujarat'),
  ('Mumbai Fulfilment Center','3pl','Bhiwandi Logistics Park, Mumbai, Maharashtra')
) as v(name, type, address);

-- Seed: products

insert into products (company_id, sku, name, category, hsn, gst_rate, brand, packaging_cost, cost_price, status)
select company_id, v.sku, v.name, v.category, v.hsn, v.gst_rate, 'Super Seller House Brand', 15, v.cost, 'active'
from companies, (values
  ('TS-BLK-M', 'Classic Crew T-Shirt - Black', 'Apparel', '610910', 12, 180),
  ('TS-WHT-M', 'Classic Crew T-Shirt - White', 'Apparel', '610910', 12, 180),
  ('MUG-350', 'Ceramic Coffee Mug 350ml', 'Home', '691200', 12, 90),
  ('BAG-CNV', 'Canvas Tote Bag', 'Accessories', '420292', 12, 120),
  ('EARBUD-PRO', 'Wireless Earbuds Pro', 'Electronics', '851830', 18, 850),
  ('YOGA-6MM', 'Yoga Mat 6mm', 'Fitness', '950691', 12, 300),
  ('BOTL-750', 'Stainless Steel Water Bottle 750ml', 'Home', '732393', 18, 220),
  ('SLEEVE-14', 'Laptop Sleeve 14-inch', 'Accessories', '420292', 12, 260)
) as v(sku, name, category, hsn, gst_rate, cost);

-- Seed: channel_sku_map (Shopify + Amazon only, Flipkart intentionally left unmapped for realism)

insert into channel_sku_map (product_id, channel_id, channel_sku, listing_id, status)
select p.product_id, c.channel_id, p.sku, upper(left(c.name,4)) || '-' || p.sku, 'active'
from products p
cross join channels c
where c.name in ('Shopify - Main Store', 'Amazon - Seller Central');

-- Seed: orders

insert into orders (external_order_id, channel_id, order_date, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status)
select v.ext_id, c.channel_id, v.order_date, v.payment_type, v.gross, v.discount, v.tax, v.net, v.fulfilment, v.payment_status
from (values
  ('FLIP-1001', 'Flipkart - Seller Hub', now() - interval '24 days', 'prepaid', 350.45, 0.0, 42.05, 392.5, 'processing', 'paid'),('SHOP-1002', 'Shopify - Main Store', now() - interval '26 days', 'prepaid', 1814.25, 90.71, 243.19, 1966.73, 'processing', 'paid'),('AMAZ-1003', 'Amazon - Seller Central', now() - interval '4 days', 'prepaid', 2353.22, 235.32, 403.47, 2521.37, 'pending', 'paid'),('SHOP-1004', 'Shopify - Main Store', now() - interval '2 days', 'prepaid', 641.19, 0.0, 76.94, 718.13, 'processing', 'refunded'),('SHOP-1005', 'Shopify - Main Store', now() - interval '6 days', 'prepaid', 455.85, 22.79, 82.05, 515.11, 'delivered', 'paid'),('FLIP-1006', 'Flipkart - Seller Hub', now() - interval '9 days', 'prepaid', 170.82, 17.08, 20.5, 174.24, 'processing', 'paid'),('SHOP-1007', 'Shopify - Main Store', now() - interval '7 days', 'prepaid', 367.33, 0.0, 44.08, 411.41, 'delivered', 'paid'),('FLIP-1008', 'Flipkart - Seller Hub', now() - interval '19 days', 'cod', 759.85, 75.98, 91.18, 775.05, 'delivered', 'paid'),('SHOP-1009', 'Shopify - Main Store', now() - interval '13 days', 'cod', 1850.84, 185.08, 279.06, 1944.82, 'shipped', 'pending'),('FLIP-1010', 'Flipkart - Seller Hub', now() - interval '4 days', 'prepaid', 407.01, 20.35, 48.84, 435.5, 'delivered', 'paid'),('FLIP-1011', 'Flipkart - Seller Hub', now() - interval '5 days', 'prepaid', 2168.26, 0.0, 377.75, 2546.01, 'processing', 'paid'),('FLIP-1012', 'Flipkart - Seller Hub', now() - interval '27 days', 'prepaid', 1087.02, 54.35, 130.44, 1163.11, 'delivered', 'paid'),('FLIP-1013', 'Flipkart - Seller Hub', now() - interval '5 days', 'cod', 824.26, 0.0, 98.91, 923.17, 'pending', 'pending'),('SHOP-1014', 'Shopify - Main Store', now() - interval '15 days', 'cod', 1353.07, 67.65, 191.78, 1477.2, 'delivered', 'paid'),('SHOP-1015', 'Shopify - Main Store', now() - interval '19 days', 'prepaid', 645.9, 0.0, 77.51, 723.41, 'delivered', 'paid'),('SHOP-1016', 'Shopify - Main Store', now() - interval '17 days', 'prepaid', 416.84, 0.0, 50.02, 466.86, 'delivered', 'paid'),('FLIP-1017', 'Flipkart - Seller Hub', now() - interval '7 days', 'prepaid', 590.4, 59.04, 70.85, 602.21, 'delivered', 'paid'),('AMAZ-1018', 'Amazon - Seller Central', now() - interval '26 days', 'prepaid', 977.04, 48.85, 141.48, 1069.67, 'delivered', 'paid')
) as v(ext_id, channel_name, order_date, payment_type, gross, discount, tax, net, fulfilment, payment_status)
join channels c on c.name = v.channel_name;

-- Seed: order_lines

insert into order_lines (order_id, product_id, quantity, unit_price, tax)
select o.order_id, p.product_id, v.qty, v.price, v.tax
from (values
  ('FLIP-1001', 'TS-BLK-M', 1, 350.45, 42.05),('SHOP-1002', 'BOTL-750', 1, 424.86, 76.47),('SHOP-1002', 'TS-BLK-M', 1, 384.61, 46.15),('SHOP-1002', 'SLEEVE-14', 2, 502.39, 120.57),('AMAZ-1003', 'EARBUD-PRO', 1, 2018.18, 363.27),('AMAZ-1003', 'TS-WHT-M', 1, 335.04, 40.2),('SHOP-1004', 'TS-WHT-M', 1, 383.62, 46.03),('SHOP-1004', 'BAG-CNV', 1, 257.57, 30.91),('SHOP-1005', 'BOTL-750', 1, 455.85, 82.05),('FLIP-1006', 'MUG-350', 1, 170.82, 20.5),('SHOP-1007', 'TS-BLK-M', 1, 367.33, 44.08),('FLIP-1008', 'MUG-350', 1, 175.32, 21.04),('FLIP-1008', 'SLEEVE-14', 1, 584.53, 70.14),('SHOP-1009', 'SLEEVE-14', 1, 491.84, 59.02),('SHOP-1009', 'TS-BLK-M', 1, 409.54, 49.14),('SHOP-1009', 'BOTL-750', 2, 474.73, 170.9),('FLIP-1010', 'TS-WHT-M', 1, 407.01, 48.84),('FLIP-1011', 'MUG-350', 1, 209.01, 25.08),('FLIP-1011', 'EARBUD-PRO', 1, 1959.25, 352.67),('FLIP-1012', 'YOGA-6MM', 2, 543.51, 130.44),('FLIP-1013', 'TS-WHT-M', 2, 412.13, 98.91),('SHOP-1014', 'BOTL-750', 1, 490.11, 88.22),('SHOP-1014', 'TS-WHT-M', 2, 431.48, 103.56),('SHOP-1015', 'YOGA-6MM', 1, 645.9, 77.51),('SHOP-1016', 'TS-WHT-M', 1, 416.84, 50.02),('FLIP-1017', 'SLEEVE-14', 1, 590.4, 70.85),('AMAZ-1018', 'SLEEVE-14', 1, 573.04, 68.76),('AMAZ-1018', 'BOTL-750', 1, 404.0, 72.72)
) as v(ext_id, sku, qty, price, tax)
join orders o on o.external_order_id = v.ext_id
join products p on p.sku = v.sku;

-- Second accounting period so seed orders spanning into last month can be posted
insert into accounting_periods (financial_year_id, period_name, start_date, end_date, status)
values (
  'FY' || extract(year from current_date - interval '1 month')::text || '-' || right((extract(year from current_date - interval '1 month') + 1)::text, 2),
  to_char(current_date - interval '1 month', 'Mon YYYY'),
  date_trunc('month', current_date - interval '1 month')::date,
  (date_trunc('month', current_date - interval '1 month') + interval '1 month - 1 day')::date,
  'open'
)
on conflict (financial_year_id, period_name) do nothing;

-- Post the delivered-and-paid orders through the real accounting engine —
-- this is what actually populates ledgers/journal_entries/invoices with
-- real, balanced data, not just static rows. Run as Super Admin (the caller
-- applying this migration needs an active authenticated session for the
-- has_orders_write()/has_accounting_write() checks inside post_sales_voucher
-- to pass — see README for how to run this against a fresh environment).
-- NOTE: when applying via the Supabase dashboard/MCP tooling as done here,
-- this step needs request.jwt.claims set to a Super Admin user_id first;
-- see the "Seed data" section in README for the exact command.
