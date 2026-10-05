-- 0074: Fixed asset register with monthly depreciation and disposal.
--
--   * Assets are bought through a purchase bill (choose the asset ledger on the bill line) or loaded as opening balances; the register holds the
--     detail the ledger does not (what, where, when, rate) and does NOT post the purchase a second time.
--   * Depreciation is posted once a month, one entry: Dr Depreciation Expense, Cr Accumulated Depreciation. A month already depreciated is skipped,
--     so running it twice is harmless. The 2nd of every month the scheduler does last month by itself.
--   * Disposal posts the sale: proceeds, the accumulated depreciation, the cost, and the gain or loss.
--   Default rates are straight-line rates from the Companies Act useful lives with 5% residual value. The income-tax block rates are different.
--   Your CA should confirm the rates (they are editable per category and per asset).

insert into account_groups (parent_group_id, name, nature, is_primary)
select (select account_group_id from account_groups where name = 'Assets'), 'Fixed Assets', 'asset', false
where not exists (select 1 from account_groups where name = 'Fixed Assets');

insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = v.grp), v.name, v.nature, 0, v.ob, false, false, 'active'
from (values
  ('Fixed Assets',       'Furniture & Fixtures',               'asset',   'debit'),
  ('Fixed Assets',       'Computers & IT Equipment',           'asset',   'debit'),
  ('Fixed Assets',       'Office Equipment',                   'asset',   'debit'),
  ('Fixed Assets',       'Plant & Machinery',                  'asset',   'debit'),
  ('Fixed Assets',       'Vehicles',                           'asset',   'debit'),
  ('Fixed Assets',       'Accumulated Depreciation',           'asset',   'credit'),
  ('Indirect Expenses',  'Depreciation Expense',               'expense', 'debit'),
  ('Indirect Expenses',  'Loss on Sale of Fixed Assets',       'expense', 'debit'),
  ('Indirect Income',    'Gain on Sale of Fixed Assets',       'income',  'credit')
) as v(grp, name, nature, ob)
where not exists (select 1 from ledgers l where l.name = v.name) and exists (select 1 from account_groups g where g.name = v.grp);

create table if not exists asset_categories (
  category_id     uuid primary key default gen_random_uuid(),
  name            text not null unique,
  asset_ledger_id uuid not null references ledgers(ledger_id),
  method          text not null default 'SLM' check (method in ('SLM', 'WDV')),
  rate_pct        numeric(6,3) not null check (rate_pct > 0 and rate_pct <= 100),
  salvage_pct     numeric(5,2) not null default 5 check (salvage_pct >= 0 and salvage_pct < 100)
);
insert into asset_categories (name, asset_ledger_id, method, rate_pct, salvage_pct)
select v.name, l.ledger_id, 'SLM', v.rate, 5
from (values ('Furniture & Fixtures', 9.50), ('Computers & IT Equipment', 31.67), ('Office Equipment', 19.00), ('Plant & Machinery', 6.33), ('Vehicles', 11.88)) as v(name, rate)
join ledgers l on l.name = v.name
on conflict (name) do nothing;

create sequence if not exists fixed_asset_seq;
create table if not exists fixed_assets (
  asset_id        uuid primary key default gen_random_uuid(),
  asset_no        text not null unique,
  name            text not null,
  category_id     uuid not null references asset_categories(category_id),
  location        text,
  purchase_date   date not null,
  put_to_use_date date not null,
  dep_from        date not null,                 -- first month to depreciate (1st of the month)
  cost            numeric(14,2) not null check (cost > 0),
  salvage_value   numeric(14,2) not null default 0 check (salvage_value >= 0),
  method          text not null check (method in ('SLM', 'WDV')),
  rate_pct        numeric(6,3) not null check (rate_pct > 0 and rate_pct <= 100),
  accumulated_dep numeric(14,2) not null default 0 check (accumulated_dep >= 0),
  status          text not null default 'active' check (status in ('active', 'disposed')),
  bill_id         uuid references purchase_bills(bill_id),
  notes           text,
  disposed_on     date,
  disposal_proceeds numeric(14,2),
  disposal_voucher_id uuid references vouchers(voucher_id),
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  check (salvage_value < cost),
  check (accumulated_dep <= cost - salvage_value)
);
create table if not exists asset_depreciation (
  asset_id   uuid not null references fixed_assets(asset_id) on delete cascade,
  month      date not null,
  amount     numeric(14,2) not null check (amount > 0),
  voucher_id uuid references vouchers(voucher_id),
  primary key (asset_id, month)
);
alter table asset_categories enable row level security;
alter table fixed_assets enable row level security;
alter table asset_depreciation enable row level security;
drop policy if exists "ac read" on asset_categories;   create policy "ac read" on asset_categories   for select to authenticated using (has_accounting_view());
drop policy if exists "fa read" on fixed_assets;       create policy "fa read" on fixed_assets       for select to authenticated using (has_accounting_view());
drop policy if exists "ad read" on asset_depreciation; create policy "ad read" on asset_depreciation for select to authenticated using (has_accounting_view());
grant select on asset_categories, fixed_assets, asset_depreciation to authenticated;

create or replace view asset_register with (security_invoker = true) as
select a.*, c.name as category_name, a.cost - a.accumulated_dep as book_value, greatest(a.cost - a.salvage_value - a.accumulated_dep, 0) as depreciable_left
from fixed_assets a join asset_categories c on c.category_id = a.category_id;
grant select on asset_register to authenticated;

create or replace function asset_set_category(p_category uuid, p_method text, p_rate numeric, p_salvage_pct numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can change depreciation rates'; end if;
  if p_method not in ('SLM', 'WDV') then raise exception 'Method must be SLM (straight line) or WDV (written down value)'; end if;
  if p_rate is null or p_rate <= 0 or p_rate > 100 then raise exception 'Rate must be above 0 and at most 100'; end if;
  if p_salvage_pct is null or p_salvage_pct < 0 or p_salvage_pct >= 100 then raise exception 'Residual value percent must be 0 to under 100'; end if;
  update asset_categories set method = p_method, rate_pct = p_rate, salvage_pct = p_salvage_pct where category_id = p_category;
end $$;

create or replace function asset_create(p_name text, p_category uuid, p_purchase date, p_put_to_use date, p_cost numeric, p_location text default null,
                                        p_bill uuid default null, p_opening_accum numeric default 0, p_dep_from date default null, p_notes text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare c asset_categories%rowtype; v_id uuid; v_salv numeric; v_from date;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can add an asset'; end if;
  select * into c from asset_categories where category_id = p_category;
  if not found then raise exception 'Choose a category'; end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then raise exception 'Describe the asset'; end if;
  if p_cost is null or p_cost <= 0 then raise exception 'Enter the cost'; end if;
  if p_purchase is null or p_purchase > current_date then raise exception 'The purchase date cannot be empty or in the future'; end if;
  if p_put_to_use is null or p_put_to_use < p_purchase or p_put_to_use > current_date then raise exception 'The date put to use must be on or after the purchase date and not in the future'; end if;
  v_salv := round(p_cost * c.salvage_pct / 100, 2);
  if coalesce(p_opening_accum, 0) < 0 or coalesce(p_opening_accum, 0) > p_cost - v_salv then raise exception 'Depreciation already taken cannot be more than cost less the residual value (%)', p_cost - v_salv; end if;
  v_from := date_trunc('month', coalesce(p_dep_from, p_put_to_use))::date;
  if v_from < date_trunc('month', p_put_to_use)::date then raise exception 'Depreciation cannot start before the month the asset was put to use'; end if;
  insert into fixed_assets (asset_no, name, category_id, location, purchase_date, put_to_use_date, dep_from, cost, salvage_value, method, rate_pct, accumulated_dep, bill_id, notes)
  values ('FA-' || lpad(nextval('fixed_asset_seq')::text, 5, '0'), btrim(p_name), p_category, nullif(btrim(coalesce(p_location, '')), ''), p_purchase, p_put_to_use, v_from, round(p_cost, 2), v_salv,
          c.method, c.rate_pct, round(coalesce(p_opening_accum, 0), 2), p_bill, nullif(btrim(coalesce(p_notes, '')), ''))
  returning asset_id into v_id;
  return v_id;
end $$;

-- the monthly calculation and posting. p_month is any date in the month.
create or replace function asset_depreciate_month(p_month date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare m date := date_trunc('month', p_month)::date; a record; v_amt numeric; v_total numeric := 0; v_n int := 0; v_ids uuid[] := '{}'; v_amts numeric[] := '{}';
  l_exp uuid; l_acc uuid; v_res jsonb; i int;
begin
  if m > date_trunc('month', current_date)::date then raise exception 'Depreciation cannot be posted for a future month'; end if;
  select ledger_id into l_exp from ledgers where name = 'Depreciation Expense';
  select ledger_id into l_acc from ledgers where name = 'Accumulated Depreciation';
  if l_exp is null or l_acc is null then raise exception 'The Depreciation Expense or Accumulated Depreciation ledger is missing'; end if;
  for a in select * from fixed_assets where status = 'active' and dep_from <= m and put_to_use_date < (m + interval '1 month')::date
           and not exists (select 1 from asset_depreciation d where d.asset_id = fixed_assets.asset_id and d.month = m) order by asset_no loop
    v_amt := case when a.method = 'SLM' then round((a.cost - a.salvage_value) * a.rate_pct / 100 / 12, 2) else round((a.cost - a.accumulated_dep) * a.rate_pct / 100 / 12, 2) end;
    v_amt := least(v_amt, a.cost - a.salvage_value - a.accumulated_dep);
    if v_amt <= 0 then continue; end if;
    v_ids := v_ids || a.asset_id; v_amts := v_amts || v_amt; v_total := v_total + v_amt; v_n := v_n + 1;
  end loop;
  if v_n = 0 then return jsonb_build_object('month', m, 'assets', 0, 'amount', 0, 'note', 'Nothing to depreciate'); end if;
  v_res := acc_post_journal((m + interval '1 month - 1 day')::date, 'Depreciation for ' || to_char(m, 'Mon YYYY') || ' (' || v_n || ' assets)',
            jsonb_build_array(jsonb_build_object('ledger_id', l_exp, 'debit', v_total, 'credit', 0, 'narration', 'Depreciation ' || to_char(m, 'Mon YYYY')),
                              jsonb_build_object('ledger_id', l_acc, 'debit', 0, 'credit', v_total, 'narration', 'Depreciation ' || to_char(m, 'Mon YYYY'))),
            'asset_depreciation', null, 'posted', auth.uid());
  for i in 1 .. v_n loop
    insert into asset_depreciation (asset_id, month, amount, voucher_id) values (v_ids[i], m, v_amts[i], (v_res ->> 'voucher_id')::uuid);
    update fixed_assets set accumulated_dep = accumulated_dep + v_amts[i] where asset_id = v_ids[i];
  end loop;
  return jsonb_build_object('month', m, 'assets', v_n, 'amount', v_total, 'voucher_no', v_res ->> 'voucher_no');
end $$;

create or replace function run_depreciation(p_month date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can post depreciation'; end if;
  return asset_depreciate_month(p_month);
end $$;

create or replace function asset_dispose(p_asset uuid, p_date date, p_proceeds numeric, p_receipt_ledger uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare a fixed_assets%rowtype; c asset_categories%rowtype; v_lines jsonb := '[]'::jsonb; v_gain numeric; l_acc uuid; l_gain uuid; l_loss uuid; v_res jsonb; v_proc numeric := round(coalesce(p_proceeds, 0), 2);
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can dispose of an asset'; end if;
  select * into a from fixed_assets where asset_id = p_asset for update;
  if not found then raise exception 'Asset not found'; end if;
  if a.status <> 'active' then raise exception 'This asset is already disposed'; end if;
  if p_date is null or p_date > current_date or p_date < a.put_to_use_date then raise exception 'The disposal date must be after the asset was put to use and not in the future'; end if;
  if v_proc < 0 then raise exception 'Sale proceeds cannot be negative'; end if;
  if v_proc > 0 and p_receipt_ledger is null then raise exception 'Choose where the sale money went (bank or cash ledger)'; end if;
  select * into c from asset_categories where category_id = a.category_id;
  select ledger_id into l_acc from ledgers where name = 'Accumulated Depreciation';
  select ledger_id into l_gain from ledgers where name = 'Gain on Sale of Fixed Assets';
  select ledger_id into l_loss from ledgers where name = 'Loss on Sale of Fixed Assets';
  v_gain := v_proc - (a.cost - a.accumulated_dep);
  if v_proc > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', p_receipt_ledger, 'debit', v_proc, 'credit', 0, 'narration', 'Sale proceeds ' || a.asset_no); end if;
  if a.accumulated_dep > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_acc, 'debit', a.accumulated_dep, 'credit', 0, 'narration', 'Depreciation written off ' || a.asset_no); end if;
  if v_gain < 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_loss, 'debit', -v_gain, 'credit', 0, 'narration', 'Loss on sale ' || a.asset_no); end if;
  v_lines := v_lines || jsonb_build_object('ledger_id', c.asset_ledger_id, 'debit', 0, 'credit', a.cost, 'narration', 'Cost removed ' || a.asset_no);
  if v_gain > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_gain, 'debit', 0, 'credit', v_gain, 'narration', 'Gain on sale ' || a.asset_no); end if;
  v_res := acc_post_journal(p_date, 'Disposal of ' || a.asset_no || ' ' || a.name || coalesce(' - ' || nullif(btrim(coalesce(p_note, '')), ''), ''), v_lines, 'asset_disposal', a.asset_id, 'posted', auth.uid());
  update fixed_assets set status = 'disposed', disposed_on = p_date, disposal_proceeds = v_proc, disposal_voucher_id = (v_res ->> 'voucher_id')::uuid where asset_id = p_asset;
  return jsonb_build_object('voucher_no', v_res ->> 'voucher_no', 'book_value', a.cost - a.accumulated_dep, 'gain_or_loss', v_gain);
end $$;

insert into scheduled_jobs (job_key, label, description, schedule) values
  ('asset_depreciation', 'Monthly depreciation', 'Posts last month''s depreciation for all fixed assets on the 2nd of each month (8:30 am India time).', '0 3 2 * *')
on conflict (job_key) do nothing;

create or replace function run_scheduled_job(p_key text, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t0 timestamptz := clock_timestamp(); v_res jsonb; v_ms int; v_msg text;
begin
  if not exists (select 1 from scheduled_jobs where job_key = p_key) then raise exception 'Unknown job'; end if;
  begin
    v_res := case p_key
      when 'recurring_journals'  then run_recurring_journals()
      when 'automation_retries'  then run_automation_retries()
      when 'cleanup_attachments' then jsonb_build_object('removed', cleanup_pending_attachments())
      when 'owner_digest'        then run_owner_digest()
      when 'asset_depreciation'  then asset_depreciate_month((date_trunc('month', current_date) - interval '1 month')::date)
      else null end;
    if v_res is null then raise exception 'Job % has nothing to run', p_key; end if;
    v_ms := (extract(epoch from clock_timestamp() - t0) * 1000)::int; v_msg := left(v_res::text, 300);
    update scheduled_jobs set last_run_at = now(), last_status = 'ok', last_message = v_msg, last_ms = v_ms where job_key = p_key;
    insert into job_runs (job_key, status, message, ms, by_user) values (p_key, 'ok', v_msg, v_ms, p_by);
    return jsonb_build_object('ok', true, 'result', v_res);
  exception when others then
    v_ms := (extract(epoch from clock_timestamp() - t0) * 1000)::int; v_msg := left(sqlerrm, 300);
    update scheduled_jobs set last_run_at = now(), last_status = 'error', last_message = v_msg, last_ms = v_ms where job_key = p_key;
    insert into job_runs (job_key, status, message, ms, by_user) values (p_key, 'error', v_msg, v_ms, p_by);
    return jsonb_build_object('ok', false, 'error', v_msg);
  end;
end $$;

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
union all
select 'payrun-open', 'Purchases', 'medium', 'Payment runs sent to the bank, UTRs not entered',
       count(*) || ' payment run(s) were exported to the bank. Enter the UTRs once the bank has paid.',
       '/purchases/payment-runs', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(exported_at)
from payment_runs where status = 'exported' having count(*) > 0 and has_accounting_write()
union all
select 'payrun-approve', 'Purchases', 'high', 'Supplier payments waiting for approval from a payment run',
       count(distinct r.run_id) || ' run(s) have payments waiting for your approval.',
       '/purchases/payment-runs', array['Finance Manager']::text[], null, null, count(distinct r.run_id)::int, min(r.completed_at)
from payment_runs r join payment_run_items i on i.run_id = r.run_id join supplier_payments p on p.payment_id = i.payment_id
where r.status = 'completed' and p.status = 'pending' having count(*) > 0 and has_purchase_approve()
union all
select 'depr-due', 'Accounting', 'medium', 'Depreciation not posted for last month',
       count(*) || ' asset(s) have no depreciation for ' || to_char(date_trunc('month', current_date) - interval '1 month', 'Mon YYYY') || '. It is posted on the 2nd of each month, or post it now.',
       '/accounting/assets', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, now()
from asset_register a where a.status = 'active' and a.depreciable_left > 0 and a.dep_from <= (date_trunc('month', current_date) - interval '1 month')::date
  and a.put_to_use_date < date_trunc('month', current_date)
  and not exists (select 1 from asset_depreciation d where d.asset_id = a.asset_id and d.month = (date_trunc('month', current_date) - interval '1 month')::date)
having count(*) > 0 and has_accounting_write()
;

revoke execute on function asset_set_category(uuid, text, numeric, numeric), asset_create(text, uuid, date, date, numeric, text, uuid, numeric, date, text), asset_depreciate_month(date),
  run_depreciation(date), asset_dispose(uuid, date, numeric, uuid, text), run_scheduled_job(text, uuid) from public, anon, authenticated;
grant execute on function asset_set_category(uuid, text, numeric, numeric), asset_create(text, uuid, date, date, numeric, text, uuid, numeric, date, text),
  run_depreciation(date), asset_dispose(uuid, date, numeric, uuid, text) to authenticated;
