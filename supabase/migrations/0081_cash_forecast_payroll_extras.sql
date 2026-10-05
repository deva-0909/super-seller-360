-- Cash forecast: include approved-but-unpaid bonus and final settlements as money going out.
do $$ begin
  if exists (select 1 from pg_proc where proname = 'cash_forecast_items') and not exists (select 1 from pg_proc where proname = 'cash_forecast_items_base') then
    alter function cash_forecast_items(int, numeric) rename to cash_forecast_items_base;
  end if;
end $$;

create or replace function cash_forecast_items(p_weeks int default 13, p_sales_factor numeric default 1) returns table (item_date date, week_start date, kind text, label text, amount numeric)
language plpgsql security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_w0 date := date_trunc('week', (now() at time zone 'Asia/Kolkata'))::date; v_end date;
begin
  if not has_accounting_view() then return; end if;
  p_weeks := least(greatest(coalesce(p_weeks, 13), 4), 26); v_end := v_w0 + 7 * p_weeks;
  return query select b.item_date, b.week_start, b.kind, b.label, b.amount from cash_forecast_items_base(p_weeks, p_sales_factor) b;
  return query
    select d, date_trunc('week', d)::date, 'payroll'::text, 'Bonus ' || r.bonus_no || ' to pay', -r.net
      from (select br.bonus_no, greatest(current_date + 1, br.approved_at::date + 3) as d, (select sum(l.amount - l.tds) from bonus_lines l where l.bonus_id = br.bonus_id) as net
              from bonus_runs br where br.status = 'approved') r where r.net > 0 and r.d < v_end;
  return query
    select d, date_trunc('week', d)::date, 'payroll'::text, 'Final settlement ' || r.fnf_no || ' to pay', -r.net
      from (select f.fnf_no, greatest(current_date + 1, f.last_day + 2) as d, f.net from fnf_settlements f where f.status = 'approved') r where r.net > 0 and r.d < v_end;
end $$;

revoke execute on function cash_forecast_items(int, numeric), cash_forecast_items_base(int, numeric) from public, anon, authenticated;
grant execute on function cash_forecast_items(int, numeric) to authenticated;
