-- 0103: Product x Platform comparison.
--
-- One row per product per platform for any date range: orders, units, revenue (ex-GST, after line discount), cancelled / RTO / returned
-- orders, and (only for roles allowed to see cost) cost and gross margin. SECURITY INVOKER: the caller's row-level security still applies.
-- Order date is read in Indian time. Cancelled and RTO orders are kept out of sales and counted on their own.

create or replace function product_platform_performance(p_from date, p_to date)
returns table (product_id uuid, sku text, product_name text, category text, brand text,
               channel_id uuid, channel_name text,
               orders bigint, units numeric, revenue numeric,
               rto_orders bigint, cancelled_orders bigint, return_orders bigint,
               cost numeric)
language sql stable set search_path = public, pg_temp as $$
  with ol as (
    select ol.product_id, o.channel_id, o.order_id, o.fulfilment_status,
           ol.quantity, (ol.quantity * ol.unit_price - coalesce(ol.discount, 0)) as rev
      from orders o
      join order_lines ol on ol.order_id = o.order_id
     where ol.product_id is not null
       and (o.order_date at time zone 'Asia/Kolkata')::date between p_from and p_to
  ), ret as (
    select distinct r.order_id from returns r where r.status <> 'rejected'
  ), agg as (
    select ol.product_id, ol.channel_id,
           count(distinct ol.order_id) filter (where ol.fulfilment_status not in ('cancelled', 'rto'))            as orders,
           coalesce(sum(ol.quantity) filter (where ol.fulfilment_status not in ('cancelled', 'rto')), 0)          as units,
           coalesce(sum(ol.rev)      filter (where ol.fulfilment_status not in ('cancelled', 'rto')), 0)          as revenue,
           count(distinct ol.order_id) filter (where ol.fulfilment_status = 'rto')                                 as rto_orders,
           count(distinct ol.order_id) filter (where ol.fulfilment_status = 'cancelled')                           as cancelled_orders,
           count(distinct ol.order_id) filter (where ol.fulfilment_status not in ('cancelled', 'rto')
                                                 and ol.order_id in (select order_id from ret))                     as return_orders
      from ol
     group by ol.product_id, ol.channel_id
  )
  select p.product_id, p.sku, p.name, p.category, p.brand, c.channel_id, c.name,
         a.orders, a.units, a.revenue, a.rto_orders, a.cancelled_orders, a.return_orders,
         case when has_cost_view() then a.units * (coalesce(p.cost_price, 0) + coalesce(p.packaging_cost, 0)) end
    from agg a
    join products p on p.product_id = a.product_id
    join channels c on c.channel_id = a.channel_id
   order by p.name, p.product_id, c.name
$$;

revoke execute on function product_platform_performance(date, date) from public, anon;
grant execute on function product_platform_performance(date, date) to authenticated;
