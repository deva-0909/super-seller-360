-- 0072: Settlement upload with fee checking, bank auto-match, and anomaly alerts.
--
--   * channel_fee_rules: the commission / shipping / gateway rate agreed with each marketplace. Every fee line on an uploaded settlement is
--     compared with it and anything above the rate (beyond a small tolerance) is flagged for a claim.
--   * imp_settlement: a settlement report uploaded through Excel Uploads becomes a settlement with its order-wise lines.
--   * settlement_bank_matches: a pending settlement with exactly ONE unmatched bank credit for the expected amount can be reconciled in one click.
--   * anomalies: things worth a second look (selling below cost, very large discounts, possible duplicate supplier payments).

create table if not exists channel_fee_rules (
  rule_id    uuid primary key default gen_random_uuid(),
  channel_id uuid not null references channels(channel_id) on delete cascade,
  fee_type   text not null check (fee_type in ('commission', 'shipping', 'gateway_fee')),
  percent    numeric(6,3) not null default 0 check (percent >= 0 and percent <= 100),
  fixed      numeric(12,2) not null default 0 check (fixed >= 0),
  tolerance  numeric(12,2) not null default 1 check (tolerance >= 0),
  updated_at timestamptz not null default now(),
  unique (channel_id, fee_type)
);
alter table channel_fee_rules enable row level security;
drop policy if exists "fee rules read" on channel_fee_rules;
create policy "fee rules read" on channel_fee_rules for select to authenticated using (has_settlements_view());
grant select on channel_fee_rules to authenticated;

create table if not exists settlement_fee_dismissals (
  settlement_line_id uuid primary key references settlement_lines(settlement_line_id) on delete cascade,
  note text, by_user uuid default auth.uid(), at timestamptz not null default now()
);
alter table settlement_fee_dismissals enable row level security;
drop policy if exists "fee dismiss read" on settlement_fee_dismissals;
create policy "fee dismiss read" on settlement_fee_dismissals for select to authenticated using (has_settlements_view());
grant select on settlement_fee_dismissals to authenticated;

create or replace function set_fee_rule(p_channel uuid, p_fee_type text, p_percent numeric, p_fixed numeric, p_tolerance numeric default 1) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_role_name() not in ('Super Admin', 'Finance Manager', 'Marketplace Manager') then raise exception 'Only a Super Admin, Finance Manager or Marketplace Manager can set fee rates'; end if;
  if not has_channel_scope(p_channel) then raise exception 'You are not assigned to this channel'; end if;
  if p_fee_type not in ('commission', 'shipping', 'gateway_fee') then raise exception 'Fee type must be commission, shipping or gateway_fee'; end if;
  if coalesce(p_percent, 0) < 0 or coalesce(p_percent, 0) > 100 or coalesce(p_fixed, 0) < 0 or coalesce(p_tolerance, 0) < 0 then raise exception 'Percent must be 0 to 100; fixed amount and tolerance cannot be negative'; end if;
  insert into channel_fee_rules (channel_id, fee_type, percent, fixed, tolerance) values (p_channel, p_fee_type, coalesce(p_percent, 0), coalesce(p_fixed, 0), coalesce(p_tolerance, 1))
    on conflict (channel_id, fee_type) do update set percent = excluded.percent, fixed = excluded.fixed, tolerance = excluded.tolerance, updated_at = now();
end $$;
create or replace function delete_fee_rule(p_rule uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_role_name() not in ('Super Admin', 'Finance Manager', 'Marketplace Manager') then raise exception 'Not authorized'; end if;
  delete from channel_fee_rules where rule_id = p_rule;
end $$;

-- ---------------------------------------------------------------- the settlement upload
-- one row per settlement line: settlement_id, order_id (our marketplace order number), fee_type, amount, tax_amount
-- order_value rows are what the marketplace collected; fee rows (commission, shipping, gateway_fee, tax, refund, other) are what it kept.
create or replace function imp_settlement(p_rows jsonb, p_apply boolean, p_opt jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; i int; rn int; v_out jsonb := '[]'; v_err text; v_warn text; v_act text;
  v_cid uuid := nullif(p_opt ->> 'channel_id', '')::uuid; v_cname text;
  v_sid text; v_oid text; v_ft text; v_amt numeric; v_tax numeric; v_ps date; v_pe date; v_ord uuid;
  v_keys text[] := '{}'; v_errk text[] := '{}'; k text; v_ex settlements%rowtype; v_new uuid; g record;
  v_gross numeric; v_ded numeric; v_n int;
  a_rn int[] := '{}'; a_key text[] := '{}'; a_ord uuid[] := '{}'; a_ft text[] := '{}'; a_amt numeric[] := '{}'; a_tax numeric[] := '{}'; a_ps date[] := '{}'; a_pe date[] := '{}';
  a_err text[] := '{}'; a_warn text[] := '{}'; j int;
begin
  if v_cid is null then raise exception 'Choose the channel this settlement belongs to'; end if;
  select name into v_cname from channels where channel_id = v_cid;
  if v_cname is null then raise exception 'Channel not found'; end if;
  if not has_channel_scope(v_cid) then raise exception 'You are not assigned to channel %', v_cname; end if;

  for i in 0 .. jsonb_array_length(p_rows) - 1 loop
    r := p_rows -> i; rn := coalesce(nullif(r ->> '_row', '')::int, i + 2);
    v_err := null; v_warn := null; v_ord := null; v_amt := null; v_tax := 0; v_ps := null; v_pe := null;
    v_sid := imp_txt(r, 'settlement_id'); v_oid := imp_txt(r, 'order_id'); v_ft := lower(coalesce(imp_txt(r, 'fee_type'), ''));
    v_ft := replace(replace(v_ft, ' ', '_'), '-', '_');
    if v_sid is null then v_err := 'Settlement id is required';
    elsif v_sid ~* '^[0-9.]+e\+?[0-9]+$' then v_err := 'Settlement id ' || v_sid || ' was turned into a short number by Excel. Format the column as Text and download the report again';
    elsif v_ft not in ('order_value', 'commission', 'shipping', 'gateway_fee', 'tax', 'refund', 'other') then v_err := 'Fee type "' || v_ft || '" must be one of order_value, commission, shipping, gateway_fee, tax, refund, other';
    else
      v_amt := imp_num(imp_txt(r, 'amount'));
      if imp_txt(r, 'tax_amount') is not null then v_tax := imp_num(imp_txt(r, 'tax_amount')); end if;
      if v_amt is null or v_tax is null or v_amt < 0 or v_tax < 0 then v_err := 'Amount and tax amount must be numbers, zero or more. Show fees as positive amounts';
      elsif v_ft = 'order_value' and v_oid is null then v_err := 'An order_value row needs the order id';
      end if;
    end if;
    if v_err is null and imp_txt(r, 'period_start') is not null then begin v_ps := imp_txt(r, 'period_start')::date; exception when others then v_err := 'Period start is not a date (use YYYY-MM-DD)'; end; end if;
    if v_err is null and imp_txt(r, 'period_end') is not null then begin v_pe := imp_txt(r, 'period_end')::date; exception when others then v_err := 'Period end is not a date (use YYYY-MM-DD)'; end; end if;
    if v_err is null and v_oid is not null then
      select order_id into v_ord from orders where channel_id = v_cid and external_order_id = v_oid;
      if v_ord is null then v_warn := 'Order ' || v_oid || ' is not in the app, so its fees cannot be checked against the order'; end if;
    end if;
    a_rn := a_rn || rn; a_key := a_key || coalesce(v_sid, ''); a_ord := a_ord || v_ord; a_ft := a_ft || coalesce(v_ft, ''); a_amt := a_amt || coalesce(v_amt, 0); a_tax := a_tax || coalesce(v_tax, 0);
    a_ps := a_ps || v_ps; a_pe := a_pe || v_pe; a_err := a_err || v_err; a_warn := a_warn || v_warn;
    if v_err is not null and v_sid is not null then v_errk := v_errk || v_sid; end if;
  end loop;

  -- per settlement: all or nothing
  for k in select distinct a_key[x] from generate_subscripts(a_key, 1) x where a_key[x] <> '' loop
    select * into v_ex from settlements where channel_id = v_cid and external_settlement_id = k;
    select count(*) into v_n from generate_subscripts(a_key, 1) x where a_key[x] = k;
    v_gross := 0; v_ded := 0; v_ps := null; v_pe := null;
    for j in 1 .. coalesce(array_length(a_key, 1), 0) loop
      if a_key[j] = k then
        if a_ft[j] = 'order_value' then v_gross := v_gross + a_amt[j]; else v_ded := v_ded + a_amt[j] + a_tax[j]; end if;
        v_ps := coalesce(v_ps, a_ps[j]); v_pe := coalesce(v_pe, a_pe[j]);
      end if;
    end loop;
    v_act := null;
    if k = any (v_errk) then v_act := null;
    elsif v_ex.settlement_id is not null and exists (select 1 from settlement_lines where settlement_id = v_ex.settlement_id) then v_act := 'unchanged';
    elsif v_ex.settlement_id is not null and v_ex.status <> 'pending' then v_act := 'blocked';
    elsif v_ex.settlement_id is not null then v_act := 'update';
    else v_act := 'add';
    end if;
    if v_act = 'blocked' then
      for j in 1 .. array_length(a_key, 1) loop if a_key[j] = k and a_err[j] is null then a_err[j] := 'Settlement ' || k || ' is already ' || v_ex.status || ' and has no lines. It cannot be rewritten'; end if; end loop;
    elsif v_act in ('add', 'update') then
      if v_gross = 0 then
        for j in 1 .. array_length(a_key, 1) loop if a_key[j] = k and a_err[j] is null then a_err[j] := 'Settlement ' || k || ' has no order_value rows, so nothing was collected to pay out'; end if; end loop;
        v_act := null;
      elsif v_ded > v_gross then
        for j in 1 .. array_length(a_key, 1) loop if a_key[j] = k and a_err[j] is null then a_err[j] := 'Settlement ' || k || ': deductions (' || v_ded || ') are more than the order value (' || v_gross || '). Check the sign of refunds'; end if; end loop;
        v_act := null;
      elsif p_apply then
        if v_act = 'add' then
          insert into settlements (channel_id, external_settlement_id, period_start, period_end, gross, deductions, expected_amount) values (v_cid, k, v_ps, v_pe, v_gross, v_ded, v_gross - v_ded) returning settlement_id into v_new;
        else
          update settlements set period_start = coalesce(v_ps, period_start), period_end = coalesce(v_pe, period_end), gross = v_gross, deductions = v_ded, expected_amount = v_gross - v_ded where settlement_id = v_ex.settlement_id;
          v_new := v_ex.settlement_id;
        end if;
        for j in 1 .. array_length(a_key, 1) loop
          if a_key[j] = k then insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (v_new, a_ord[j], a_ft[j], a_amt[j], a_tax[j]); end if;
        end loop;
      end if;
    end if;
    -- remember the action per row
    for j in 1 .. array_length(a_key, 1) loop
      if a_key[j] = k and a_err[j] is null then a_warn[j] := coalesce(a_warn[j], case when v_act = 'update' then 'This settlement was entered by hand; its totals are replaced by the file''s' end); end if;
    end loop;
    v_errk := v_errk;
    -- store the chosen action in the key array suffix
    for j in 1 .. array_length(a_key, 1) loop if a_key[j] = k then a_key[j] := k || '|' || coalesce(v_act, ''); end if; end loop;
  end loop;

  for j in 1 .. coalesce(array_length(a_rn, 1), 0) loop
    v_out := v_out || imp_res(a_rn[j], case when a_err[j] is null and a_key[j] like '%|' and a_key[j] <> '|' then 'Held back because another row of this settlement has an error' else a_err[j] end, a_warn[j], nullif(split_part(a_key[j], '|', 2), ''));
  end loop;
  return jsonb_build_object('rows', v_out);
end $$;

create or replace function import_can(p_kind text) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select coalesce(case p_kind
    when 'products'       then current_role_name() in ('Super Admin', 'Operations Manager')
    when 'opening_stock'  then current_role_name() in ('Super Admin', 'Operations Manager', 'Warehouse Manager')
    when 'stock_count'    then current_role_name() in ('Super Admin', 'Operations Manager', 'Warehouse Manager')
    when 'listing_map'    then current_role_name() in ('Super Admin', 'Operations Manager', 'Marketplace Manager')
    when 'ledger_opening' then has_accounting_write()
    when 'orders'         then has_orders_write()
    when 'settlement'     then current_role_name() in ('Super Admin', 'Finance Manager', 'Accountant')
    else false end, false)
$$;

create or replace function import_run(p_kind text, p_rows jsonb, p_apply boolean default false, p_options jsonb default '{}'::jsonb,
                                      p_file_name text default null, p_file_path text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_run uuid; v_res jsonb; v_rows jsonb; v_ferr text; v_opt jsonb := coalesce(p_options, '{}'::jsonb);
  v_add int; v_upd int; v_same int; v_warn int; v_rej int; v_total int;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not import_can(p_kind) then raise exception 'Your role cannot upload this kind of file'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'No rows received'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'A file can have up to 5000 rows. Split it and upload in parts'; end if;
  if p_file_path is not null and p_file_path not like auth.uid()::text || '/%' then raise exception 'File path is not in your folder'; end if;

  if p_apply then
    insert into import_runs (kind, file_name, file_path, options) values (p_kind, left(p_file_name, 200), p_file_path, v_opt) returning run_id into v_run;
    v_opt := v_opt || jsonb_build_object('run_id', v_run);
  end if;

  v_res := case p_kind
    when 'products'       then imp_products(p_rows, p_apply, v_opt)
    when 'opening_stock'  then imp_stock(p_rows, p_apply, v_opt, 'opening')
    when 'stock_count'    then imp_stock(p_rows, p_apply, v_opt, 'count')
    when 'listing_map'    then imp_listing_map(p_rows, p_apply, v_opt)
    when 'ledger_opening' then imp_ledger_opening(p_rows, p_apply, v_opt)
    when 'orders'         then imp_orders(p_rows, p_apply, v_opt)
    when 'settlement'     then imp_settlement(p_rows, p_apply, v_opt)
    else null end;
  if v_res is null then raise exception 'Unknown upload type'; end if;
  v_rows := v_res -> 'rows'; v_ferr := v_res ->> 'file_error';

  select count(*) filter (where e ->> 'action' = 'add'), count(*) filter (where e ->> 'action' = 'update'), count(*) filter (where e ->> 'action' = 'unchanged'),
         count(*) filter (where e ->> 'status' = 'warning' and (e ->> 'row')::int > 0), count(*) filter (where e ->> 'status' = 'error' and (e ->> 'row')::int > 0), count(*) filter (where (e ->> 'row')::int > 0)
    into v_add, v_upd, v_same, v_warn, v_rej, v_total from jsonb_array_elements(v_rows) e;

  if p_apply then
    -- a file-level problem (for example opening balances that do not balance) means nothing was saved
    if v_ferr is not null then v_add := 0; v_upd := 0; v_same := 0; end if;
    update import_runs set total_rows = v_total, added = v_add, updated = v_upd, unchanged = v_same, warnings = v_warn,
           rejected = case when v_ferr is not null then v_total else v_rej end where run_id = v_run;
    insert into import_run_rows (run_id, row_no, status, action, message)
    select v_run, (e ->> 'row')::int, e ->> 'status', e ->> 'action', e ->> 'message' from jsonb_array_elements(v_rows) e
     where e ->> 'status' <> 'ok' or e ->> 'action' is not null on conflict do nothing;
  end if;
  return jsonb_build_object('run_id', v_run, 'applied', p_apply and v_ferr is null, 'file_error', v_ferr, 'rows', v_rows,
    'summary', jsonb_build_object('total', v_total, 'added', v_add, 'updated', v_upd, 'unchanged', v_same, 'warnings', v_warn, 'errors', v_rej));
end $$;

-- ---------------------------------------------------------------- fee check
create or replace view settlement_fee_check with (security_invoker = true) as
select l.settlement_line_id, l.settlement_id, s.external_settlement_id, s.channel_id, c.name as channel_name, l.order_id, o.external_order_id, l.fee_type,
       l.amount as charged,
       round(coalesce((select sum(v.amount) from settlement_lines v where v.settlement_id = l.settlement_id and v.order_id = l.order_id and v.fee_type = 'order_value'), o.net_amount) * r.percent / 100 + r.fixed, 2) as expected,
       l.amount - round(coalesce((select sum(v.amount) from settlement_lines v where v.settlement_id = l.settlement_id and v.order_id = l.order_id and v.fee_type = 'order_value'), o.net_amount) * r.percent / 100 + r.fixed, 2) as variance,
       r.tolerance, s.created_at,
       (l.amount - round(coalesce((select sum(v.amount) from settlement_lines v where v.settlement_id = l.settlement_id and v.order_id = l.order_id and v.fee_type = 'order_value'), o.net_amount) * r.percent / 100 + r.fixed, 2)) > r.tolerance as flagged,
       exists (select 1 from settlement_fee_dismissals d where d.settlement_line_id = l.settlement_line_id) as dismissed
from settlement_lines l
join settlements s on s.settlement_id = l.settlement_id
join channels c on c.channel_id = s.channel_id
join orders o on o.order_id = l.order_id
join channel_fee_rules r on r.channel_id = s.channel_id and r.fee_type = l.fee_type
where l.fee_type in ('commission', 'shipping', 'gateway_fee');
grant select on settlement_fee_check to authenticated;

create or replace function dismiss_fee_flag(p_line uuid, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not (has_settlements_write() or current_role_name() = 'Accountant') then raise exception 'Not authorized'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Say why this is acceptable (for example promotional rate)'; end if;
  insert into settlement_fee_dismissals (settlement_line_id, note) values (p_line, btrim(p_note)) on conflict do nothing;
end $$;

-- ---------------------------------------------------------------- bank auto-match
create or replace view settlement_bank_matches with (security_invoker = true) as
select s.settlement_id, s.external_settlement_id, s.expected_amount, (array_agg(b.bank_txn_id))[1] as bank_txn_id, (array_agg(b.txn_date))[1] as txn_date
from settlements s
join bank_transactions b on b.type = 'credit' and b.match_status = 'unmatched' and abs(b.amount - s.expected_amount) < 0.005
                        and b.txn_date >= coalesce(s.period_end, s.created_at::date)
where s.status = 'pending' and s.actual_amount is null
group by s.settlement_id, s.external_settlement_id, s.expected_amount
having count(*) = 1
   and not exists (select 1 from settlements s2 where s2.status = 'pending' and s2.settlement_id <> s.settlement_id and abs(s2.expected_amount - s.expected_amount) < 0.005);
grant select on settlement_bank_matches to authenticated;

create or replace function settlement_auto_match(p_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare m record; v_done int := 0; v_fail jsonb := '[]'::jsonb;
begin
  if not has_settlements_reconcile() then raise exception 'Not authorized to reconcile settlements'; end if;
  for m in select * from settlement_bank_matches where p_id is null or settlement_id = p_id loop
    begin
      perform reconcile_settlement(m.settlement_id, m.expected_amount, m.bank_txn_id);
      v_done := v_done + 1;
    exception when others then
      v_fail := v_fail || jsonb_build_object('settlement', m.external_settlement_id, 'reason', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('reconciled', v_done, 'failed', v_fail);
end $$;

-- ---------------------------------------------------------------- anomalies
create or replace view anomalies with (security_invoker = true) as
select 'below-cost'::text as kind, 'Orders sold below cost'::text as title,
       count(*) || ' order line(s) in the last 30 days were sold for less than the product cost price.' as detail, count(*)::int as n, min(o.order_date) as since
from order_lines ol join orders o on o.order_id = ol.order_id join products p on p.product_id = ol.product_id
where o.order_date >= now() - interval '30 days' and o.fulfilment_status not in ('cancelled') and p.cost_price is not null and p.cost_price > 0
  and ol.unit_price > 0 and ol.unit_price < p.cost_price
having count(*) > 0
union all
select 'discount', 'Unusually large discounts', count(*) || ' order(s) in the last 30 days had a discount above 40% of the order value.', count(*)::int, min(order_date)
from orders where order_date >= now() - interval '30 days' and gross_amount > 0 and discount > gross_amount * 0.40 and fulfilment_status <> 'cancelled'
having count(*) > 0
union all
select 'dup-pay', 'Possible duplicate supplier payments', count(*) || ' pair(s) of payments to the same supplier for the same amount within 7 days.', count(*)::int, min(a.created_at)
from supplier_payments a join supplier_payments b on b.supplier_id = a.supplier_id and b.amount = a.amount and b.payment_id > a.payment_id
 and abs(b.payment_date - a.payment_date) <= 7 and a.status in ('pending', 'approved') and b.status in ('pending', 'approved')
where a.payment_date >= current_date - 60
having count(*) > 0;
grant select on anomalies to authenticated;

create or replace view work_queue with (security_invoker = true) as
-- failed automatic steps (stock-out, invoice, cancelled after dispatch)
select 'issue:' || i.issue_id as item_key, 'Automation' as category, case when i.kind = 'cancelled_after_dispatch' then 'medium' else 'high' end as severity,
       case i.kind when 'dispatch_failed' then 'Stock could not be taken out' when 'invoice_failed' then 'Invoice could not be posted' when 'cancelled_after_dispatch' then 'Cancelled after dispatch' else i.kind end as title,
       i.message as detail, '/orders/' || i.entity_id as href, array['Operations Manager', 'Accountant']::text[] as for_roles,
       i.kind as action_kind, i.issue_id as action_id, 1 as n, i.created_at as since
from automation_issues i where i.status = 'open'
union all
select 'rule-errors', 'Accounting', 'high', 'Entries that did not post automatically', count(*) || ' event(s) failed to create their journal entry in the last 30 days. Open the rule activity to see why.',
       '/accounting/rule-book/activity', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from journal_rule_log where status = 'error' and created_at > now() - interval '30 days' having count(*) > 0
union all
select 'bank-unreconciled', 'Bank', case when min(txn_date) < current_date - 7 then 'high' else 'medium' end, 'Bank lines not reconciled', count(*) || ' bank line(s) are waiting to be matched. Oldest: ' || min(txn_date) || '.',
       '/bank/reconcile', array['Accountant']::text[], null, null, count(*)::int, min(txn_date)::timestamptz
from bank_transactions where recon_status in ('unreconciled', 'suggested') and txn_date < current_date - 1 having count(*) > 0
union all
select 'bills-pending', 'Purchases', 'medium', 'Supplier bills waiting for approval', count(*) || ' bill(s) pending. Oldest raised ' || min(created_at)::date || '.',
       '/purchases/bills', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from purchase_bills where status = 'pending' having count(*) > 0 and has_purchase_approve()
union all
select 'bills-overdue', 'Purchases', 'high', 'Supplier bills past their due date', count(*) || ' approved bill(s) are overdue. Oldest due ' || min(due_date) || '.',
       '/purchases/ageing', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(due_date)::timestamptz
from purchase_bills where status = 'approved' and due_date < current_date and net_payable > 0
  and net_payable > coalesce((select sum(a.amount) from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id where a.bill_id = purchase_bills.bill_id and p.status = 'approved'), 0)
having count(*) > 0 and has_accounting_write()
union all
select 'claims-expense', 'Expenses', 'medium', 'Expense claims waiting for a decision', count(*) || ' claim(s) are waiting. Oldest submitted ' || min(submitted_at)::date || '.',
       '/expenses', array['Operations Manager', 'Finance Manager']::text[], null, null, count(*)::int, min(submitted_at)
from expense_claims where status in ('submitted', 'manager_approved') having count(*) > 0 and (has_expense_review() or has_accounting_write())
union all
select 'returns-inspect', 'Returns', case when min(received_date) < current_date - 4 then 'high' else 'medium' end, 'Returns received but not inspected', count(*) || ' return(s) are sitting in the warehouse. Oldest received ' || min(received_date) || '.',
       '/returns', array['Warehouse Manager']::text[], null, null, count(*)::int, min(received_date)::timestamptz
from returns where status = 'received' and has_returns_view() having count(*) > 0
union all
select 'rto-inspect', 'RTO', case when min(received_date) < current_date - 4 then 'high' else 'medium' end, 'RTO parcels received but not inspected', count(*) || ' RTO parcel(s) are waiting. Oldest received ' || min(received_date) || '.',
       '/rto', array['Warehouse Manager']::text[], null, null, count(*)::int, min(received_date)::timestamptz
from rtos where status = 'received' and has_returns_view() having count(*) > 0
union all
select 'settlements-late', 'Settlements', 'high', 'Settlements not received or reconciled', count(*) || ' settlement(s) are still pending a week after their period ended.',
       '/settlements', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, min(period_end)::timestamptz
from settlements where status = 'pending' and period_end < current_date - 7 and has_settlements_view() having count(*) > 0
union all
select 'settlements-short', 'Settlements', 'high', 'Settlements paid short or in excess', count(*) || ' settlement(s) did not match what was expected.',
       '/settlements', array['Finance Manager', 'Claims Manager']::text[], null, null, count(*)::int, min(created_at)
from settlements where status in ('short_pay', 'excess') and has_settlements_view() having count(*) > 0
union all
select 'cod-late', 'COD', 'high', 'COD cash not remitted by the courier', count(*) || ' COD collection(s) are over 7 days without a remittance.',
       '/cod', array['Accountant']::text[], null, null, count(*)::int, min(collected_date)::timestamptz
from cod_collections where status in ('collected', 'short_remit') and collected_date < current_date - 7 and has_bankcod_view() having count(*) > 0
union all
select 'claims-deadline', 'Claims', case when min(deadline) < current_date then 'high' else 'medium' end, 'Claims close to their deadline', count(*) || ' claim(s) are due within 7 days or already past the deadline.',
       '/claims', array['Claims Manager']::text[], null, null, count(*)::int, min(deadline)::timestamptz
from claims where status in ('potential', 'claimed') and deadline is not null and deadline <= current_date + 7 and has_claims_view() having count(*) > 0
union all
select 'period-close', 'Accounting', 'medium', 'Accounting periods ready to close', count(*) || ' period(s) ended more than 5 days ago and are still open (' || string_agg(period_name, ', ' order by start_date) || ').',
       '/accounting/periods', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(end_date)::timestamptz
from accounting_periods where status = 'open' and end_date < current_date - 5 having count(*) > 0 and has_accounting_view()
union all
select 'recurring-error', 'Accounting', 'high', 'Recurring entries that could not post', count(*) || ' recurring journal(s) are waiting because of an error (for example a closed period).',
       '/accounting/journal', array['Accountant']::text[], null, null, count(*)::int, min(next_run_date)::timestamptz
from recurring_journals where status = 'active' and last_error is not null having count(*) > 0 and has_accounting_view()
union all
select 'gstr1-due', 'GST', case when extract(day from current_date) > 11 then 'high' else 'medium' end, 'GSTR-1 not recorded as filed', 'GSTR-1 for ' || to_char(date_trunc('month', current_date) - interval '1 month', 'Mon YYYY') || ' has no filing record yet (due about the 11th; confirm with your CA).',
       '/gst/gstr1', array['Tax Manager', 'Accountant']::text[], null, null, 1, date_trunc('month', current_date)
where extract(day from current_date) >= 5 and has_gst_view()
  and not gst_period_filed(to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM'), 'GSTR1')
union all
select 'gstr3b-due', 'GST', case when extract(day from current_date) > 20 then 'high' else 'medium' end, 'GSTR-3B not recorded as filed', 'GSTR-3B for ' || to_char(date_trunc('month', current_date) - interval '1 month', 'Mon YYYY') || ' has no filing record yet (due about the 20th; confirm with your CA).',
       '/gst', array['Tax Manager', 'Accountant']::text[], null, null, 1, date_trunc('month', current_date)
where extract(day from current_date) >= 12 and has_gst_view()
  and not gst_period_filed(to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM'), 'GSTR3B')
union all
select 'stock-timeout', 'Inventory', 'medium', 'SKUs past their stock time-out', count(*) || ' SKU(s) have stock older than their time-out.',
       '/insights', array['Operations Manager']::text[], null, null, count(*)::int, now()
from sku_stock_aging where timeout_state = 'overdue' having count(*) > 0
union all
select 'job-failed:' || j.job_key, 'System', 'high', 'Scheduled job failed: ' || j.label, coalesce(j.last_message, 'The last run failed.'),
       '/admin/automation', array['Super Admin']::text[], null, null, 1, j.last_run_at
from scheduled_jobs j where j.enabled and j.last_status = 'error'
union all
select 'po-pending', 'Purchases', 'medium', 'Purchase orders waiting for approval', count(*) || ' purchase order(s) need approval.',
       '/purchases/orders', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from purchase_orders where status = 'pending' having count(*) > 0 and has_purchase_approve()
union all
select 'po-late', 'Purchases', 'medium', 'Purchase orders past their expected date', count(*) || ' order(s) not fully received. Oldest was due ' || min(expected_date) || '.',
       '/purchases/orders', array['Operations Manager', 'Warehouse Manager']::text[], null, null, count(*)::int, min(expected_date)::timestamptz
from purchase_orders where status in ('approved', 'part_received') and expected_date < current_date
having count(*) > 0 and (has_po_write() or has_grn_write())
union all
select 'grn-unbilled', 'Purchases', 'medium', 'Goods received but no supplier bill entered', count(*) || ' receipt(s) have no bill yet. Oldest ' || min(received_on) || '.',
       '/purchases/orders', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(received_on)::timestamptz
from po_unbilled where unbilled_qty > 0 having count(*) > 0 and has_accounting_write()
union all
select 'reorder-low', 'Inventory', 'medium', 'Products below their reorder level', count(*) || ' product(s) need re-ordering.',
       '/purchases/reorder', array['Operations Manager']::text[], null, null, count(*)::int, now()
from reorder_suggestions where needs_reorder having count(*) > 0 and has_po_write()
union all
select 'fee-overcharged', 'Settlements', 'high', 'Marketplace fees higher than the agreed rate',
       count(*) || ' fee line(s) are above the agreed rate, about Rs ' || round(sum(variance), 2) || ' in total. Raise a claim with the marketplace.',
       '/settlements/fees', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, min(created_at)
from settlement_fee_check where flagged and variance > 0 and not coalesce(dismissed, false) having count(*) > 0 and has_settlements_view() and has_accounting_view()
union all
select 'settle-match-ready', 'Settlements', 'medium', 'Settlements with an exact bank match waiting',
       count(*) || ' settlement(s) have one bank credit for exactly the expected amount. One click reconciles them.',
       '/settlements', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, now()
from settlement_bank_matches having count(*) > 0 and has_settlements_reconcile()
union all
select 'anom-' || kind, 'Check these', 'medium', title, detail, '/work-queue/anomalies', array['Operations Manager', 'Finance Manager']::text[], null, null, n, since
from anomalies where has_orders_write() or has_accounting_view()
;

create or replace function my_nav_access() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'all', true,
    'accounting_view', has_accounting_view(),
    'accounting_write', has_accounting_write(),
    'bankcod_view', has_bankcod_view(),
    'settlements_view', has_settlements_view(),
    'returns_view', has_returns_view(),
    'claims_view', has_claims_view(),
    'tax_view', has_tax_view(),
    'gst_view', has_gst_view(),
    'inventory_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Claims Manager',
                                                          'Marketplace Manager', 'Auditor', 'Warehouse Manager'), false),
    'users_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner'), false),
    'roles_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Auditor'), false),
    'audit_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Auditor'), false),
    'integrations_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager'), false),
    'channels_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Marketplace Manager', 'Auditor'), false),
    'warehouses_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Warehouse Manager', 'Auditor'), false),
    'connectors_manage', coalesce(current_role_name() = 'Super Admin', false),
    'purchasing_view', has_po_view(),
    'automation_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager'), false),
    'uploads', import_can('products') or import_can('opening_stock') or import_can('listing_map') or import_can('ledger_opening') or import_can('orders') or import_can('settlement')
  )
$$;

revoke execute on function set_fee_rule(uuid, text, numeric, numeric, numeric), delete_fee_rule(uuid), dismiss_fee_flag(uuid, text), settlement_auto_match(uuid),
  imp_settlement(jsonb, boolean, jsonb), import_can(text), import_run(text, jsonb, boolean, jsonb, text, text), my_nav_access() from public, anon, authenticated;
grant execute on function set_fee_rule(uuid, text, numeric, numeric, numeric), delete_fee_rule(uuid), dismiss_fee_flag(uuid, text), settlement_auto_match(uuid),
  import_can(text), import_run(text, jsonb, boolean, jsonb, text, text), my_nav_access() to authenticated;
