-- 0091: database fixes from the 5 October 2026 audit.
--   1. run_recurring_journals can no longer be pushed into the future by any signed-in user.
--   2. The anonymous (not signed in) role loses its default access to every table, view, sequence and function.
--   3. Bank, COD and cash data is readable only by the finance team and the Operations Manager (allow-list, not "everyone but the warehouse").
--   4. The bank-statement feed can only use secrets named BANKFEED_..., and cannot point at local or private addresses.
--   5. Users cannot delete their own channel / warehouse scope rows.
--   6. The stock time-out report counts purchase receipts (on the date goods were received), so stock is no longer all "overdue".
--   7. An order cannot be settled twice (guard), and the ten orders that were (first settlement of April, which covered orders not yet delivered) are corrected.

-- 1 ----------------------------------------------------------------------------------------------------------------------------------------
do $do$
declare d text;
begin
  d := pg_get_functiondef('run_recurring_journals(date)'::regprocedure);
  if d !~ 'least\(coalesce\(p_upto' then
    d := regexp_replace(d, 'begin\s+for r in select \* from recurring_journals', E'begin\n  p_upto := least(coalesce(p_upto, app_today()), app_today());\n  for r in select * from recurring_journals');
    execute d;
  end if;
end $do$;

-- 2 ----------------------------------------------------------------------------------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon;
do $do$ begin
  begin execute 'alter default privileges for role postgres in schema public revoke all on tables from anon'; exception when others then null; end;
  begin execute 'alter default privileges for role postgres in schema public revoke all on sequences from anon'; exception when others then null; end;
  begin execute 'alter default privileges for role postgres in schema public revoke all on functions from anon'; exception when others then null; end;
  begin execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from anon'; exception when others then null; end;
  begin execute 'alter default privileges for role supabase_admin in schema public revoke all on sequences from anon'; exception when others then null; end;
  begin execute 'alter default privileges for role supabase_admin in schema public revoke all on functions from anon'; exception when others then null; end;
end $do$;

-- 3 ----------------------------------------------------------------------------------------------------------------------------------------
create or replace function has_bankcod_view() returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Finance Manager', 'Accountant', 'Auditor', 'Operations Manager'), false)
$$;
alter function has_bankcod_view() set search_path = public, pg_temp;

-- 4 ----------------------------------------------------------------------------------------------------------------------------------------
do $do$
declare d text;
begin
  d := pg_get_functiondef('save_bank_feed(jsonb)'::regprocedure);
  if d !~ 'BANKFEED_' then
    d := replace(d, $x$'^[A-Z][A-Z0-9_]{2,60}$'$x$, $x$'^BANKFEED_[A-Z0-9_]{1,50}$'$x$);
    d := replace(d, $x$The secret name must be capital letters, digits and underscores, e.g. BANKFEED_HDFC_TOKEN$x$, $x$The secret name must start with BANKFEED_ (capital letters, digits and underscores), e.g. BANKFEED_HDFC_TOKEN$x$);
    d := regexp_replace(d, 'if p_feed \? ''secret_name''', $y$if v_url is not null and v_url ~* '^https://(localhost|127\.|10\.|0\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|\[|[^/]*@)' then
    raise exception 'The bank API address cannot be a local or private address';
  end if;
  if p_feed ? 'secret_name'$y$);
    execute d;
  end if;
end $do$;

-- 5 ----------------------------------------------------------------------------------------------------------------------------------------
do $do$
declare t text;
begin
  foreach t in array array['user_channel_scope', 'user_warehouse_scope'] loop
    execute format('drop policy if exists %I on %I', case t when 'user_channel_scope' then 'admin and self manage channel scope' else 'admin and self manage warehouse scope' end, t);
    execute format('drop policy if exists "scope read" on %I', t);
    execute format('drop policy if exists "scope admin" on %I', t);
    execute format($p$create policy "scope read" on %I for select to authenticated using (user_id = auth.uid() or current_role_name() in ('Super Admin', 'Operations Manager'))$p$, t);
    execute format($p$create policy "scope admin" on %I for all to authenticated using (current_role_name() in ('Super Admin', 'Operations Manager')) with check (current_role_name() in ('Super Admin', 'Operations Manager'))$p$, t);
  end loop;
end $do$;

-- 6 ----------------------------------------------------------------------------------------------------------------------------------------
create or replace view sku_stock_aging with (security_invoker = true) as
with inbound as (
  select t.product_id, max(coalesce(g.received_on::timestamptz, t.created_at)) last_inbound_at
  from inventory_transactions t
  left join goods_receipts g on t.movement_type = 'purchase_receipt' and t.reference_type = 'goods_receipt' and g.grn_id = t.reference_id
  where t.movement_type in ('initial_stock', 'purchase_receipt') or (t.movement_type = 'adjustment' and t.quantity > 0)
  group by t.product_id
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
grant select on sku_stock_aging to authenticated;

-- 7 ----------------------------------------------------------------------------------------------------------------------------------------
-- a correction for orders that were settled twice: the earlier settlement is taken off them, the cash it brought in is held as an excess received,
-- the fees and tax credits booked on it are reversed
do $do$
declare
  r record; v_user uuid; v_ov numeric; v_ded numeric; v_tcs numeric; v_tds numeric; v_fee numeric; v_base numeric; v_gst numeric; v_excess numeric;
  v_type text; v_comm uuid; v_lines jsonb; v_mth date;
  l_rec uuid; l_itc uuid; l_tcs uuid; l_tds uuid; l_exc uuid;
begin
  select ledger_id into l_rec from ledgers where name = 'Trade Receivables';
  select ledger_id into l_itc from ledgers where name = 'GST Input Tax Credit (ITC)';
  select ledger_id into l_tcs from ledgers where name = 'GST TCS Credit Receivable';
  select ledger_id into l_tds from ledgers where name = 'TDS Receivable (Sec 194-O)';
  select ledger_id into l_exc from ledgers where name = 'Settlement Excess Received';
  select u.user_id into v_user from user_profiles u join roles ro on ro.role_id = u.role_id where ro.name = 'Super Admin' order by u.created_at limit 1;
  if l_rec is null or l_exc is null or v_user is null then return; end if;

  for r in
    select s.settlement_id, s.channel_id, s.period_end
      from settlements s
     where exists (select 1 from settlement_lines a join settlement_lines b on b.order_id = a.order_id and b.fee_type = 'order_value' and b.settlement_id <> a.settlement_id
                     join settlements s2 on s2.settlement_id = b.settlement_id
                    where a.settlement_id = s.settlement_id and a.fee_type = 'order_value' and s2.period_start > s.period_start)
     order by s.period_start
  loop
    -- the lines of this settlement whose order is settled again later
    create temp table if not exists _dup_lines (line_id uuid) on commit drop;
    truncate _dup_lines;
    insert into _dup_lines
      select l.settlement_line_id from settlement_lines l
       where l.settlement_id = r.settlement_id and l.fee_type in ('order_value', 'commission', 'shipping', 'gateway_fee', 'tcs', 'tds_194o')
         and l.order_id in (select a.order_id from settlement_lines a join settlement_lines b on b.order_id = a.order_id and b.fee_type = 'order_value' and b.settlement_id <> a.settlement_id
                              join settlements s2 on s2.settlement_id = b.settlement_id
                             where a.settlement_id = r.settlement_id and a.fee_type = 'order_value'
                               and s2.period_start > (select period_start from settlements where settlement_id = r.settlement_id));

    select coalesce(sum(l.amount) filter (where l.fee_type = 'order_value'), 0),
           coalesce(sum(l.amount) filter (where l.fee_type <> 'order_value'), 0),
           coalesce(sum(l.amount) filter (where l.fee_type = 'tcs'), 0),
           coalesce(sum(l.amount) filter (where l.fee_type = 'tds_194o'), 0)
      into v_ov, v_ded, v_tcs, v_tds
      from settlement_lines l where l.settlement_line_id in (select line_id from _dup_lines);
    if v_ov <= 0 then continue; end if;

    select type into v_type from channels where channel_id = r.channel_id;
    select ledger_id into v_comm from ledgers where name = case when v_type = 'd2c' then 'Payment Gateway Charges' else 'Marketplace Commission Expense' end;
    v_fee := v_ded - v_tcs - v_tds; v_base := round(v_fee / 1.18, 2); v_gst := v_fee - v_base;
    v_excess := v_ov - v_ded;
    v_lines := jsonb_build_array(jsonb_build_object('ledger_id', l_rec, 'debit', v_ov, 'credit', 0, 'narration', 'Orders settled twice: second credit taken off Trade Receivables'));
    if v_base > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', v_comm, 'debit', 0, 'credit', v_base, 'narration', 'Duplicate marketplace fees reversed'); end if;
    if v_gst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_itc, 'debit', 0, 'credit', v_gst, 'narration', 'GST input credit on duplicate fees reversed'); end if;
    if v_tcs > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tcs, 'debit', 0, 'credit', v_tcs, 'narration', 'GST TCS on duplicate settlement reversed'); end if;
    if v_tds > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tds, 'debit', 0, 'credit', v_tds, 'narration', 'TDS 194-O on duplicate settlement reversed'); end if;
    if v_excess > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_exc, 'debit', 0, 'credit', v_excess, 'narration', 'Cash received twice for the same orders, held until returned or set off'); end if;

    perform acc_post_journal(r.period_end, 'Correction: orders in this settlement were settled again in a later one (' || (select external_settlement_id from settlements where settlement_id = r.settlement_id) || ')', v_lines, 'manual', null, 'posted', v_user);

    delete from settlement_lines where settlement_line_id in (select line_id from _dup_lines);
    -- what is left on the statement can be refund deductions only: the expected amount is held at nil rather than below it
    update settlements set gross = gross - v_ov, deductions = deductions - v_ded, expected_amount = greatest(expected_amount - (v_ov - v_ded), 0),
           status = case when actual_amount > greatest(expected_amount - (v_ov - v_ded), 0) then 'excess' else status end
     where settlement_id = r.settlement_id;

    -- the marketplace tax credits recorded for that month were taken from the same lines
    v_mth := date_trunc('month', r.period_end)::date;
    begin
      update marketplace_credit_entries set amount = greatest(amount - v_tcs, 0) where channel_id = r.channel_id and month = v_mth and kind = 'gst_tcs' and v_tcs > 0;
      update marketplace_credit_entries set amount = greatest(amount - v_tds, 0) where channel_id = r.channel_id and month = v_mth and kind = 'tds_194o' and v_tds > 0;
    exception when others then null;
    end;
  end loop;
end $do$;

-- the guard: an order's value is settled once
create or replace function settlement_line_once() returns trigger language plpgsql set search_path = public, pg_temp as $$
declare v_other text;
begin
  if new.fee_type = 'order_value' and new.order_id is not null then
    select s.external_settlement_id into v_other from settlement_lines l join settlements s on s.settlement_id = l.settlement_id
     where l.order_id = new.order_id and l.fee_type = 'order_value' and l.settlement_id <> new.settlement_id limit 1;
    if v_other is not null then
      raise exception 'This order is already in settlement %. An order is settled once; a refund or a fee correction goes on its own line.', v_other;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_settlement_line_once on settlement_lines;
create trigger trg_settlement_line_once before insert or update of order_id, fee_type on settlement_lines for each row execute function settlement_line_once();
