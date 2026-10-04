-- Stock time-out: registered per SKU at registration. Clock starts at the last stock receipt (opening stock / positive adjustment);
-- return/RTO restocks do not reset it. Alert window = 15 days before time-out.
alter table products add column if not exists stock_timeout_days integer;
alter table products drop constraint if exists products_stock_timeout_positive;
alter table products add constraint products_stock_timeout_positive check (stock_timeout_days is null or (stock_timeout_days between 1 and 1095));

update products set stock_timeout_days = case
  when category like '%Winterwear' then 45
  when category in ('Women - Occasion') then 30
  when category in ('Women - Dresses','Girls - Dresses') then 40
  when category like '%Ethnic' or category = 'Women - Sarees' then 90
  when category like 'Boys%' or category like 'Girls%' then 120
  else 180 end
where sku ~ '^[A-Z]{4}-' and stock_timeout_days is null;
update products set stock_timeout_days = 30 where status = 'discontinued' and sku ~ '^[A-Z]{4}-';

create or replace view sku_stock_aging with (security_invoker = true) as
with inbound as (
  select product_id, max(created_at) last_inbound_at
  from inventory_transactions
  where movement_type = 'initial_stock' or (movement_type = 'adjustment' and quantity > 0)
  group by product_id
), stock as (
  select product_id, sum(quantity) on_hand from inventory_balances group by product_id
)
select p.product_id, p.sku, p.name, p.category, p.status, p.cost_price, p.stock_timeout_days,
  coalesce(s.on_hand, 0) as on_hand, i.last_inbound_at,
  (i.last_inbound_at::date + p.stock_timeout_days) as timeout_date,
  ((i.last_inbound_at::date + p.stock_timeout_days) - current_date) as days_left,
  coalesce(s.on_hand, 0) * coalesce(p.cost_price, 0) as stock_cost_value,
  case when coalesce(s.on_hand,0) <= 0 then 'no_stock'
       when p.stock_timeout_days is null or i.last_inbound_at is null then 'no_limit'
       when ((i.last_inbound_at::date + p.stock_timeout_days) - current_date) < 0 then 'overdue'
       when ((i.last_inbound_at::date + p.stock_timeout_days) - current_date) <= 15 then 'nearing'
       else 'ok' end as timeout_state
from products p left join stock s using (product_id) left join inbound i using (product_id);

create or replace view sku_channel_sales with (security_invoker = true) as
select ol.product_id, o.channel_id, o.order_id, o.order_date, ol.quantity,
  (ol.quantity * ol.unit_price - coalesce(ol.discount, 0)) as revenue, o.fulfilment_status
from order_lines ol join orders o using (order_id)
where o.fulfilment_status not in ('cancelled', 'rto') and ol.product_id is not null;

grant select on sku_stock_aging, sku_channel_sales to authenticated;
