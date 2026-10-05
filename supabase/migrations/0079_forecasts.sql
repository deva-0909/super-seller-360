-- 0079: Forecasts.
--
-- 1. DEMAND: for every product, what will it sell over the next weeks, when will stock run out and how much to order.
--    Method (deliberately simple, explainable and checked against the past): a recency-weighted average of the last 12 complete
--    weeks (newest week counts most) plus a damped trend (last 4 weeks against the 4 before, only when there are 8+ weeks of
--    history), times a festival / season uplift you set per calendar month. A product with under 3 weeks of sales is marked low
--    confidence. The method is back-tested on the last 4 weeks and the error (WAPE) is shown, so you know how far to trust it.
-- 2. CASH: a 13-week cash forecast from today's bank and cash balance: settlements and COD money on the way, orders delivered but
--    not yet in a settlement, expected receipts from forecast sales, supplier bills by due date, payroll and its statutory dues, and
--    anything you add yourself (GST payment, advance tax, loan EMI, rent, an expected receipt). Flags the weeks that dip below a
--    cash buffer you choose, and can show a "what if sales fall 20%" scenario.

create table if not exists forecast_settings (
  id                 int primary key default 1 check (id = 1),
  trend_damp         numeric(4,2) not null default 0.5 check (trend_damp between 0 and 1),
  demand_weeks       int not null default 8 check (demand_weeks between 2 and 26),
  min_cash_buffer    numeric(14,2) not null default 100000,
  payout_lag_days    int not null default 7 check (payout_lag_days between 0 and 60),    -- settlement period end to money in bank, when there is no history
  cod_lag_days       int not null default 7 check (cod_lag_days between 0 and 60),
  sale_to_cash_days  int not null default 14 check (sale_to_cash_days between 0 and 90),  -- a future sale to money in bank
  payout_ratio_default numeric(4,2) not null default 0.85 check (payout_ratio_default between 0.3 and 1),
  updated_by         uuid, updated_at timestamptz not null default now()
);
insert into forecast_settings (id) values (1) on conflict do nothing;

create table if not exists forecast_uplift (
  month   int primary key check (month between 1 and 12),
  pct     numeric(6,2) not null default 0 check (pct between -90 and 500),
  note    text
);
insert into forecast_uplift (month) select g from generate_series(1, 12) g on conflict do nothing;

create table if not exists cash_plan_items (
  item_id     uuid primary key default gen_random_uuid(),
  item_date   date not null,
  direction   text not null check (direction in ('in', 'out')),
  amount      numeric(14,2) not null check (amount > 0),
  label       text not null check (btrim(label) <> ''),
  repeat      text not null default 'none' check (repeat in ('none', 'weekly', 'monthly')),
  until       date,
  status      text not null default 'active' check (status in ('active', 'cancelled')),
  created_by  uuid default auth.uid(), created_at timestamptz not null default now()
);
alter table forecast_settings enable row level security; alter table forecast_uplift enable row level security; alter table cash_plan_items enable row level security;
drop policy if exists "fs read" on forecast_settings; create policy "fs read" on forecast_settings for select to authenticated using (has_po_view() or has_accounting_view());
drop policy if exists "fu read" on forecast_uplift; create policy "fu read" on forecast_uplift for select to authenticated using (has_po_view() or has_accounting_view());
drop policy if exists "cpi read" on cash_plan_items; create policy "cpi read" on cash_plan_items for select to authenticated using (has_accounting_view());
grant select on forecast_settings, forecast_uplift, cash_plan_items to authenticated;

create or replace function fc_can_edit() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Operations Manager', 'Finance Manager'), false)
$$;

create or replace function forecast_settings_save(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not fc_can_edit() then raise exception 'Only a Super Admin, Operations Manager or Finance Manager can change forecast settings'; end if;
  update forecast_settings set
    trend_damp = coalesce(nullif(p ->> 'trend_damp', '')::numeric, trend_damp), demand_weeks = coalesce(nullif(p ->> 'demand_weeks', '')::int, demand_weeks),
    min_cash_buffer = coalesce(nullif(p ->> 'min_cash_buffer', '')::numeric, min_cash_buffer), payout_lag_days = coalesce(nullif(p ->> 'payout_lag_days', '')::int, payout_lag_days),
    cod_lag_days = coalesce(nullif(p ->> 'cod_lag_days', '')::int, cod_lag_days), sale_to_cash_days = coalesce(nullif(p ->> 'sale_to_cash_days', '')::int, sale_to_cash_days),
    payout_ratio_default = coalesce(nullif(p ->> 'payout_ratio_default', '')::numeric, payout_ratio_default), updated_by = auth.uid(), updated_at = now() where id = 1;
exception when check_violation then raise exception 'One of the values is outside its allowed range';
end $$;

create or replace function forecast_uplift_set(p_month int, p_pct numeric, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not fc_can_edit() then raise exception 'Only a Super Admin, Operations Manager or Finance Manager can change the season uplift'; end if;
  if p_month not between 1 and 12 then raise exception 'Month must be 1 to 12'; end if;
  if p_pct is null or p_pct < -90 or p_pct > 500 then raise exception 'Uplift must be between -90%% and 500%%'; end if;
  update forecast_uplift set pct = p_pct, note = nullif(btrim(coalesce(p_note, '')), '') where month = p_month;
end $$;

create or replace function cash_plan_add(p_date date, p_direction text, p_amount numeric, p_label text, p_repeat text default 'none', p_until date default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can add a planned item'; end if;
  if p_date is null or p_date < current_date - 7 then raise exception 'Choose a date from this week onwards'; end if;
  if p_direction not in ('in', 'out') then raise exception 'Choose money in or money out'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount'; end if;
  if btrim(coalesce(p_label, '')) = '' then raise exception 'Say what it is for'; end if;
  if p_repeat not in ('none', 'weekly', 'monthly') then raise exception 'Repeat must be none, weekly or monthly'; end if;
  if p_until is not null and p_until < p_date then raise exception 'The end date is before the start date'; end if;
  insert into cash_plan_items (item_date, direction, amount, label, repeat, until) values (p_date, p_direction, round(p_amount, 2), btrim(p_label), p_repeat, p_until) returning item_id into v;
  return v;
end $$;
create or replace function cash_plan_cancel(p_item uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can remove a planned item'; end if;
  update cash_plan_items set status = 'cancelled' where item_id = p_item;
end $$;

-- ---------------------------------------------------------------- the forecasting method on one product's weekly series
-- xs holds weekly units, oldest first, already trimmed to the weeks since the first sale (at most 12). Returns the level, the damped
-- weekly trend and the back-test error (WAPE) over the last 4 weeks.
create or replace function fc_calc(xs numeric[], p_damp numeric) returns table (level numeric, trend numeric, wape numeric)
language plpgsql immutable as $$
declare n int := coalesce(array_length(xs, 1), 0); i int; t int; num numeric := 0; den numeric := 0; a4 numeric := 0; p4 numeric := 0; err numeric := 0; act numeric := 0; lv numeric; wsum numeric; wden numeric;
begin
  if n = 0 then return query select 0::numeric, 0::numeric, null::numeric; return; end if;
  for i in 1 .. n loop num := num + i * xs[i]; den := den + i; end loop;
  level := num / den; trend := 0; wape := null;
  if n >= 8 then
    for i in n - 3 .. n loop a4 := a4 + xs[i]; end loop;
    for i in n - 7 .. n - 4 loop p4 := p4 + xs[i]; end loop;
    trend := p_damp * ((a4 - p4) / 4.0) / 4.0;
    for t in n - 3 .. n loop
      wsum := 0; wden := 0;
      for i in 1 .. t - 1 loop wsum := wsum + i * xs[i]; wden := wden + i; end loop;
      lv := wsum / wden; err := err + abs(xs[t] - lv); act := act + xs[t];
    end loop;
    if act > 0 then wape := round(err * 100 / act, 1); end if;
  end if;
  return query select level, trend, wape;
end $$;

create or replace function fc_uplift_on(p_date date) returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select pct from forecast_uplift where month = extract(month from p_date)::int), 0)
$$;

-- weekly forecast for one product, from a level and trend
create or replace function fc_week_units(p_level numeric, p_trend numeric, p_k int, p_week date) returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select round(greatest(0, p_level + greatest(least(p_trend * p_k, p_level * 0.5), -p_level * 0.5)) * (1 + fc_uplift_on(p_week) / 100.0), 2)
$$;

-- ---------------------------------------------------------------- demand forecast, one row per product
create or replace function demand_forecast() returns table (
  product_id uuid, sku text, name text, preferred_supplier_id uuid, cost_price numeric, lead_time_days int, weeks_of_history int, last4_avg numeric, level numeric, trend numeric,
  next_weeks_units numeric, lead_cover_units numeric, on_hand numeric, reserved numeric, on_order numeric, available numeric, daily_rate numeric, days_cover numeric, stockout_date date,
  suggested_qty numeric, wape numeric, confidence text, series numeric[])
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare cfg forecast_settings%rowtype; v_week0 date := date_trunc('week', (now() at time zone 'Asia/Kolkata'))::date; r record; xs numeric[]; n int; k int; f record; v_next numeric; v_lead numeric; v_horizon int; v_cover int;
        v_daily numeric; v_avail numeric; v_conf text; w date; v_first date; v_lead_days int;
begin
  if not has_po_view() then return; end if;
  select * into cfg from forecast_settings where id = 1;
  select reorder_cover_days into v_cover from purchase_settings where id = 1; v_cover := coalesce(v_cover, 15);
  for r in
    with weeks as (select generate_series(v_week0 - 84, v_week0 - 7, interval '7 days')::date as w),
    sold as (select ol.product_id, date_trunc('week', (o.order_date at time zone 'Asia/Kolkata'))::date as w, sum(ol.quantity) as u
               from order_lines ol join orders o on o.order_id = ol.order_id
              where o.order_date >= (v_week0 - 84)::timestamp and o.fulfilment_status not in ('cancelled', 'rto') and ol.product_id is not null group by 1, 2),
    first_sale as (select ol.product_id, min(date_trunc('week', (o.order_date at time zone 'Asia/Kolkata'))::date) as fw
                     from order_lines ol join orders o on o.order_id = ol.order_id where o.fulfilment_status not in ('cancelled', 'rto') and ol.product_id is not null group by 1),
    stock as (select b.product_id, sum(b.quantity) as q from inventory_balances b group by 1),
    res as (select i.product_id, sum(i.reserved) as q from inventory_reserved i group by 1),
    onord as (select s.product_id, sum(greatest(s.quantity - s.received_qty - s.rejected_qty, 0)) as q from po_line_status s join purchase_orders po on po.po_id = s.po_id where po.status in ('approved', 'part_received') group by 1)
    select p.product_id, p.sku, p.name, p.preferred_supplier_id, p.cost_price, p.lead_time_days, fs.fw,
           (select array_agg(coalesce(s.u, 0) order by wk.w) from weeks wk left join sold s on s.product_id = p.product_id and s.w = wk.w where fs.fw is not null and wk.w >= fs.fw) as xs,
           coalesce(st.q, 0) as oh, coalesce(rs.q, 0) as rv, coalesce(oo.q, 0) as oo
      from products p left join first_sale fs on fs.product_id = p.product_id left join stock st on st.product_id = p.product_id left join res rs on rs.product_id = p.product_id left join onord oo on oo.product_id = p.product_id
     where p.status = 'active'
  loop
    xs := coalesce(r.xs, '{}'); n := coalesce(array_length(xs, 1), 0);
    if n > 12 then xs := xs[n - 11 : n]; n := 12; end if;
    select * into f from fc_calc(xs, cfg.trend_damp);
    v_next := 0;
    for k in 1 .. cfg.demand_weeks loop v_next := v_next + fc_week_units(f.level, f.trend, k, v_week0 + 7 * (k - 1) + 7 * 1); end loop;
    v_lead_days := coalesce(r.lead_time_days, 7); v_horizon := v_lead_days + v_cover;
    v_lead := 0;
    for k in 1 .. ceil(v_horizon / 7.0)::int loop
      v_lead := v_lead + fc_week_units(f.level, f.trend, k, v_week0 + 7 * k) * least(7, v_horizon - 7 * (k - 1)) / 7.0;
    end loop;
    v_daily := (select sum(fc_week_units(f.level, f.trend, k, v_week0 + 7 * k)) / 28.0 from generate_series(1, 4) k);
    v_avail := r.oh - r.rv;
    v_conf := case when n < 3 then 'low' when n >= 8 and coalesce(f.wape, 0) <= 35 then 'high' when n >= 5 and coalesce(f.wape, 0) <= 60 then 'medium' else 'low' end;
    return query select r.product_id, r.sku, r.name, r.preferred_supplier_id, r.cost_price, r.lead_time_days, n,
      case when n >= 4 then round((select sum(x) from unnest(xs[n - 3 : n]) x) / 4.0, 1) else case when n > 0 then round((select sum(x) from unnest(xs) x) / n, 1) else 0 end end,
      round(f.level, 2), round(f.trend, 3), round(v_next, 0), ceil(v_lead), r.oh, r.rv, r.oo, v_avail, round(v_daily, 2),
      case when v_daily > 0 then round(v_avail / v_daily, 1) end,
      case when v_daily > 0 and v_avail >= 0 then current_date + floor(v_avail / v_daily)::int when v_daily > 0 then current_date end,
      greatest(ceil(v_lead - (v_avail + r.oo)), 0), f.wape, v_conf, xs;
  end loop;
end $$;

-- weekly numbers for one product: the last 12 weeks actual and the coming weeks forecast, for the chart
create or replace function demand_forecast_weeks(p_product uuid) returns table (week_start date, actual numeric, forecast numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare cfg forecast_settings%rowtype; v_week0 date := date_trunc('week', (now() at time zone 'Asia/Kolkata'))::date; xs numeric[]; n int; f record; k int; v_fw date; i int;
begin
  if not has_po_view() then return; end if;
  select * into cfg from forecast_settings where id = 1;
  select min(date_trunc('week', (o.order_date at time zone 'Asia/Kolkata'))::date) into v_fw from order_lines ol join orders o on o.order_id = ol.order_id where ol.product_id = p_product and o.fulfilment_status not in ('cancelled', 'rto');
  if v_fw is null then return; end if;
  select array_agg(coalesce((select sum(ol.quantity) from order_lines ol join orders o on o.order_id = ol.order_id
           where ol.product_id = p_product and o.fulfilment_status not in ('cancelled', 'rto') and date_trunc('week', (o.order_date at time zone 'Asia/Kolkata'))::date = g::date), 0) order by g)
    into xs from generate_series(greatest(v_fw, v_week0 - 84), v_week0 - 7, interval '7 days') g;
  n := coalesce(array_length(xs, 1), 0);
  select * into f from fc_calc(xs, cfg.trend_damp);
  for i in 1 .. n loop return query select (greatest(v_fw, v_week0 - 84) + 7 * (i - 1))::date, xs[i], null::numeric; end loop;
  for k in 1 .. cfg.demand_weeks loop return query select v_week0 + 7 * k, null::numeric, fc_week_units(f.level, f.trend, k, v_week0 + 7 * k); end loop;
end $$;

-- ---------------------------------------------------------------- cash forecast
create or replace function cash_opening_balance() returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(case when l.opening_balance_type = 'credit' then -l.opening_balance else l.opening_balance end
         + coalesce((select sum(vl.debit - vl.credit) from voucher_lines vl join vouchers v on v.voucher_id = vl.voucher_id where vl.ledger_id = l.ledger_id and v.status = 'posted'), 0)), 0)
    from ledgers l join account_groups g on g.account_group_id = l.account_group_id where g.name in ('Bank Accounts', 'Cash-in-Hand') and l.status = 'active'
$$;

create or replace function cash_forecast_items(p_weeks int default 13, p_sales_factor numeric default 1) returns table (item_date date, week_start date, kind text, label text, amount numeric)
language plpgsql security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare cfg forecast_settings%rowtype; v_w0 date := date_trunc('week', (now() at time zone 'Asia/Kolkata'))::date; v_end date; v_ratio numeric; r record; d date; lm date; v_net numeric; k int; m date; f record; v_price numeric;
begin
  if not has_accounting_view() then return; end if;
  select * into cfg from forecast_settings where id = 1;
  p_weeks := least(greatest(coalesce(p_weeks, 13), 4), 26); p_sales_factor := least(greatest(coalesce(p_sales_factor, 1), 0), 3);
  v_end := v_w0 + 7 * p_weeks;
  create temp table if not exists _cf (item_date date, kind text, label text, amount numeric) on commit drop;
  delete from _cf;
  select least(1, greatest(0.3, coalesce(sum(expected_amount) / nullif(sum(gross), 0), cfg.payout_ratio_default))) into v_ratio from settlements where created_at > now() - interval '180 days' and gross > 0;
  v_ratio := coalesce(v_ratio, cfg.payout_ratio_default);

  -- settlements already reported but not yet paid
  for r in select s.settlement_id, s.external_settlement_id, s.expected_amount, s.period_end, c.name as cname,
                  coalesce((select avg(bt.txn_date - s2.period_end) from settlements s2 join bank_transactions bt on bt.matched_entity = 'settlement' and bt.matched_reference_id = s2.settlement_id
                             where s2.channel_id = s.channel_id and bt.txn_date > current_date - 180 and s2.period_end is not null), cfg.payout_lag_days) as lag_days
             from settlements s join channels c on c.channel_id = s.channel_id
            where s.status = 'pending' and s.actual_amount is null and s.expected_amount > 0 and coalesce(s.period_end, s.created_at::date) >= current_date - 60 loop
    d := greatest(current_date + 1, coalesce(r.period_end, current_date) + round(r.lag_days)::int);
    insert into _cf values (d, 'settlement', r.cname || ' settlement ' || r.external_settlement_id, r.expected_amount);
  end loop;
  -- COD collected by the courier but not yet remitted
  for r in select cc.cod_id, cc.collected_amount - cc.remitted_amount as amt, coalesce(cc.collected_date, current_date) as cd, o.external_order_id
             from cod_collections cc join orders o on o.order_id = cc.order_id where cc.status in ('collected', 'short_remit') and cc.collected_amount - cc.remitted_amount > 0 loop
    insert into _cf values (greatest(current_date + 1, r.cd + cfg.cod_lag_days), 'cod', 'COD ' || r.external_order_id, r.amt);
  end loop;
  -- prepaid marketplace orders shipped or delivered in the last 45 days that are not in any settlement yet
  for r in select o.order_date::date as od, sum(o.net_amount) as amt, count(*) as n from orders o join channels c on c.channel_id = o.channel_id and c.type = 'marketplace'
            where o.payment_type = 'prepaid' and o.fulfilment_status in ('shipped', 'delivered') and o.order_date >= now() - interval '45 days'
              and not exists (select 1 from settlement_lines l where l.order_id = o.order_id) group by o.order_date::date loop
    insert into _cf values (greatest(current_date + 1, r.od + cfg.payout_lag_days + 7), 'unsettled', r.n || ' marketplace order(s) of ' || r.od || ' not yet in a settlement', round(r.amt * v_ratio, 2));
  end loop;
  -- expected receipts from forecast sales (weeks after this one)
  for f in select * from demand_forecast() loop
    select coalesce(sum(ol.quantity * ol.unit_price) / nullif(sum(ol.quantity), 0), 0) into v_price from order_lines ol join orders o on o.order_id = ol.order_id
     where ol.product_id = f.product_id and o.order_date >= now() - interval '60 days' and o.fulfilment_status not in ('cancelled', 'rto');
    continue when v_price <= 0 or f.level <= 0;
    for k in 1 .. p_weeks loop
      d := v_w0 + 7 * k + 6 + cfg.sale_to_cash_days;
      exit when d >= v_end;
      insert into _cf values (d, 'new_sales', 'Forecast sales, week of ' || (v_w0 + 7 * k), round(fc_week_units(f.level, f.trend, k, v_w0 + 7 * k) * v_price * v_ratio * p_sales_factor, 2));
    end loop;
  end loop;
  -- supplier bills still to pay
  for r in select b.bill_no, b.status, b.due_date, s.name as sname, b.net_payable - coalesce((select sum(a.amount) from payment_allocations a join supplier_payments sp on sp.payment_id = a.payment_id where a.bill_id = b.bill_id and sp.status = 'approved'), 0) as due
             from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id where b.status in ('approved', 'pending') and b.net_payable > 0 loop
    continue when r.due <= 0.005;
    insert into _cf values (greatest(r.due_date, current_date), 'bill', r.sname || ' bill ' || r.bill_no || case when r.status = 'pending' then ' (awaiting approval)' else '' end, -round(r.due, 2));
  end loop;
  -- payroll: approved runs not yet paid, statutory dues, and the same again for months with no run yet
  select coalesce(sum(l.net_pay), 0) into v_net from payroll_runs pr join payroll_lines l on l.run_id = pr.run_id where pr.status = 'approved';
  if v_net > 0 then insert into _cf values (current_date + 1, 'payroll', 'Salary of approved payroll run(s)', -v_net); end if;
  for r in select d2.month, d2.head, d2.balance, d2.due_date from payroll_dues d2 where d2.balance > 0 loop
    insert into _cf values (greatest(r.due_date, current_date), 'statutory', upper(r.head) || ' for ' || to_char(r.month, 'Mon YYYY'), -r.balance);
  end loop;
  select max(month) into lm from payroll_runs where status in ('approved', 'paid');
  if lm is not null then
    select coalesce(sum(l.net_pay), 0) into v_net from payroll_runs pr join payroll_lines l on l.run_id = pr.run_id where pr.month = lm and pr.status in ('approved', 'paid');
    m := (lm + interval '1 month')::date;
    while m < v_end loop
      d := (m + interval '1 month' - interval '1 day')::date;
      if d >= current_date and d < v_end and v_net > 0 and not exists (select 1 from payroll_runs where month = m and status <> 'cancelled') then insert into _cf values (d, 'payroll', 'Expected salary for ' || to_char(m, 'Mon YYYY'), -v_net); end if;
      if not exists (select 1 from payroll_runs where month = m and status <> 'cancelled') then
        for r in select head, accrued from payroll_dues where month = lm and head in ('pf', 'esi', 'pt', 'tds') loop
          d := case r.head when 'tds' then case when extract(month from m) = 3 then make_date(extract(year from m)::int, 4, 30) else (m + interval '1 month' + interval '6 days')::date end else (m + interval '1 month' + interval '14 days')::date end;
          if d >= current_date and d < v_end then insert into _cf values (d, 'statutory', 'Expected ' || upper(r.head) || ' for ' || to_char(m, 'Mon YYYY'), -r.accrued); end if;
        end loop;
      end if;
      m := (m + interval '1 month')::date;
    end loop;
  end if;
  -- the user's own planned items, repeated as asked
  for r in select * from cash_plan_items where status = 'active' loop
    d := r.item_date;
    while d < v_end and (r.until is null or d <= r.until) loop
      if d >= v_w0 then insert into _cf values (greatest(d, current_date), 'plan_' || r.direction, r.label, case when r.direction = 'in' then r.amount else -r.amount end); end if;
      exit when r.repeat = 'none';
      d := case r.repeat when 'weekly' then d + 7 else (d + interval '1 month')::date end;
    end loop;
  end loop;
  return query select c.item_date, (date_trunc('week', c.item_date::timestamp))::date, c.kind, c.label, c.amount from _cf c where c.item_date < v_end order by c.item_date, c.kind;
end $$;

create or replace function cash_forecast(p_weeks int default 13, p_sales_factor numeric default 1) returns table (
  week_start date, opening numeric, collections numeric, new_sales numeric, other_in numeric, suppliers numeric, payroll numeric, statutory numeric, other_out numeric, closing numeric, low boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare cfg forecast_settings%rowtype; v_w0 date := date_trunc('week', (now() at time zone 'Asia/Kolkata'))::date; v_open numeric; v_close numeric; i int; r record;
begin
  if not has_accounting_view() then return; end if;
  select * into cfg from forecast_settings where id = 1;
  p_weeks := least(greatest(coalesce(p_weeks, 13), 4), 26);
  v_open := cash_opening_balance();
  create temp table if not exists _cfi (item_date date, week_start date, kind text, label text, amount numeric) on commit drop;
  delete from _cfi; insert into _cfi select * from cash_forecast_items(p_weeks, p_sales_factor);
  for i in 0 .. p_weeks - 1 loop
    select coalesce(sum(x.amount) filter (where x.kind in ('settlement', 'cod', 'unsettled')), 0) as collections, coalesce(sum(x.amount) filter (where x.kind = 'new_sales'), 0) as new_sales, coalesce(sum(x.amount) filter (where x.kind = 'plan_in'), 0) as other_in,
           coalesce(sum(x.amount) filter (where x.kind = 'bill'), 0) as suppliers, coalesce(sum(x.amount) filter (where x.kind = 'payroll'), 0) as payroll, coalesce(sum(x.amount) filter (where x.kind = 'statutory'), 0) as statutory, coalesce(sum(x.amount) filter (where x.kind = 'plan_out'), 0) as other_out
      into r from _cfi x where x.week_start = v_w0 + 7 * i;
    v_close := v_open + coalesce(r.collections, 0) + coalesce(r.new_sales, 0) + coalesce(r.other_in, 0) + coalesce(r.suppliers, 0) + coalesce(r.payroll, 0) + coalesce(r.statutory, 0) + coalesce(r.other_out, 0);
    return query select v_w0 + 7 * i, v_open, round(coalesce(r.collections, 0), 2), round(coalesce(r.new_sales, 0), 2), round(coalesce(r.other_in, 0), 2), round(coalesce(r.suppliers, 0), 2), round(coalesce(r.payroll, 0), 2), round(coalesce(r.statutory, 0), 2), round(coalesce(r.other_out, 0), 2), round(v_close, 2), v_close < cfg.min_cash_buffer;
    v_open := v_close;
  end loop;
end $$;

revoke execute on function fc_can_edit(), forecast_settings_save(jsonb), forecast_uplift_set(int, numeric, text), cash_plan_add(date, text, numeric, text, text, date), cash_plan_cancel(uuid),
  fc_calc(numeric[], numeric), fc_uplift_on(date), fc_week_units(numeric, numeric, int, date), demand_forecast(), demand_forecast_weeks(uuid), cash_opening_balance(),
  cash_forecast_items(int, numeric), cash_forecast(int, numeric) from public, anon, authenticated;
grant execute on function fc_can_edit(), forecast_settings_save(jsonb), forecast_uplift_set(int, numeric, text), cash_plan_add(date, text, numeric, text, text, date), cash_plan_cancel(uuid),
  demand_forecast(), demand_forecast_weeks(uuid), cash_opening_balance(), cash_forecast_items(int, numeric), cash_forecast(int, numeric) to authenticated;
