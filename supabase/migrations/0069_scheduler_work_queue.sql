-- 0069: A scheduler for the timed jobs, a work queue of everything that needs a person, and in-app notifications.
--
--   * scheduled_jobs / job_runs: the jobs the app runs by itself (recurring journals, retry of failed dispatch and invoices, clean-up, daily digest),
--     with when each last ran and whether it worked. They are registered with pg_cron when it is available (Supabase has it; turn it on once under
--     Database > Extensions). "Run now" works either way.
--   * work_queue: ONE list of what a person still has to do (unreconciled bank lines, bills and claims waiting, returns not inspected, settlements
--     and COD not in, claims close to their deadline, failed postings, periods to close, returns to file, jobs that failed). Each role sees what its
--     rights allow. The number shows on the bell in the top bar.
--   * notifications: a daily digest for the owner, kept in the app.

-- ---------------------------------------------------------------- jobs
create table if not exists scheduled_jobs (
  job_key      text primary key,
  label        text not null,
  description  text not null,
  schedule     text not null,                  -- cron, in UTC
  enabled      boolean not null default true,
  last_run_at  timestamptz,
  last_status  text check (last_status in ('ok', 'error')),
  last_message text,
  last_ms      int
);
create table if not exists job_runs (
  run_id      uuid primary key default gen_random_uuid(),
  job_key     text not null references scheduled_jobs(job_key) on delete cascade,
  started_at  timestamptz not null default now(),
  status      text not null check (status in ('ok', 'error')),
  message     text,
  ms          int,
  by_user     uuid
);
create index if not exists job_runs_recent on job_runs (job_key, started_at desc);
alter table scheduled_jobs enable row level security;
alter table job_runs enable row level security;
drop policy if exists "jobs read" on scheduled_jobs;
create policy "jobs read" on scheduled_jobs for select to authenticated using (current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Auditor'));
drop policy if exists "job runs read" on job_runs;
create policy "job runs read" on job_runs for select to authenticated using (current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Auditor'));
grant select on scheduled_jobs, job_runs to authenticated;

insert into scheduled_jobs (job_key, label, description, schedule) values
  ('recurring_journals', 'Recurring journal entries', 'Posts recurring entries (rent, depreciation and so on) when they fall due.', '5 * * * *'),
  ('automation_retries', 'Retry failed dispatch and invoices', 'Tries again every stock-out or invoice that stopped, and catches orders the live trigger missed.', '*/30 * * * *'),
  ('cleanup_attachments', 'Clear unused proof photos', 'Removes photos that were taken but never attached to a saved record.', '30 21 * * *'),
  ('owner_digest', 'Daily owner digest', 'Writes the morning summary of what needs attention for the owner (8 am India time).', '30 2 * * *')
on conflict (job_key) do nothing;

-- notifications
create table if not exists notifications (
  notification_id uuid primary key default gen_random_uuid(),
  user_id     uuid not null references user_profiles(user_id) on delete cascade,
  title       text not null,
  body        text,
  href        text,
  dedupe_key  text,
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create unique index if not exists notifications_dedupe on notifications (user_id, dedupe_key) where dedupe_key is not null;
alter table notifications enable row level security;
drop policy if exists "own notifications" on notifications;
create policy "own notifications" on notifications for select to authenticated using (user_id = auth.uid());
grant select on notifications to authenticated;
create or replace function mark_notifications_read() returns void
language sql security definer set search_path = public, pg_temp as $$
  update notifications set read_at = now() where user_id = auth.uid() and read_at is null
$$;

-- ---------------------------------------------------------------- the work queue
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
from scheduled_jobs j where j.enabled and j.last_status = 'error';
grant select on work_queue to authenticated;

-- how many things need me (for the bell in the top bar)
create or replace function my_work_count() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object('high', count(*) filter (where severity = 'high'), 'total', count(*),
    'unread', (select count(*) from notifications where user_id = auth.uid() and read_at is null))
  from work_queue
$$;

-- ---------------------------------------------------------------- running a job
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

create or replace function run_job_now(p_key text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_role_name() not in ('Super Admin', 'Operations Manager', 'Finance Manager') then raise exception 'Only a Super Admin, Operations Manager or Finance Manager can run a job'; end if;
  return run_scheduled_job(p_key, auth.uid());
end $$;

create or replace function set_job_enabled(p_key text, p_enabled boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_role_name() <> 'Super Admin' then raise exception 'Only a Super Admin can switch a job on or off'; end if;
  update scheduled_jobs set enabled = p_enabled where job_key = p_key;
  if not found then raise exception 'Unknown job'; end if;
end $$;

-- ---------------------------------------------------------------- the daily digest (one per owner per day)
create or replace function run_owner_digest() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u record; v_high int; v_total int; v_body text; v_n int := 0; v_key text := 'digest:' || current_date;
begin
  select count(*) filter (where severity = 'high'), count(*) into v_high, v_total from work_queue;
  -- the queue is read with the caller's rights; run from the scheduler this sees everything the owner role may see
  select string_agg('• ' || title || ' (' || n || ')', E'\n' order by case severity when 'high' then 1 when 'medium' then 2 else 3 end, title) into v_body
    from (select title, severity, n from work_queue order by case severity when 'high' then 1 when 'medium' then 2 else 3 end limit 8) q;
  for u in select up.user_id from user_profiles up join roles r on r.role_id = up.role_id
            where up.status = 'active' and r.name in ('Super Admin', 'CEO/Owner') loop
    insert into notifications (user_id, title, body, href, dedupe_key)
    values (u.user_id, case when v_total = 0 then 'Nothing needs you today' else v_total || ' item(s) need attention (' || v_high || ' urgent)' end, coalesce(v_body, 'All clear.'), '/work-queue', v_key)
    on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('owners', v_n, 'items', v_total, 'urgent', v_high);
end $$;

-- ---------------------------------------------------------------- register the timers with pg_cron (when the database has it)
do $$
declare j record; v_ok boolean := false;
begin
  begin
    create extension if not exists pg_cron;
    v_ok := true;
  exception when others then
    raise notice 'pg_cron is not available (%). Turn it on under Database > Extensions, then run: select register_job_timers();', sqlerrm;
  end;
end $$;

create or replace function register_job_timers() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare j record; n int := 0;
begin
  if to_regnamespace('cron') is null then return jsonb_build_object('registered', 0, 'note', 'pg_cron is not enabled'); end if;
  for j in select * from scheduled_jobs loop
    if j.enabled then
      execute format('select cron.schedule(%L, %L, %L)', 'ss360_' || j.job_key, j.schedule, format('select public.run_scheduled_job(%L)', j.job_key));
      n := n + 1;
    else
      begin execute format('select cron.unschedule(%L)', 'ss360_' || j.job_key); exception when others then null; end;
    end if;
  end loop;
  return jsonb_build_object('registered', n);
end $$;
do $$ begin perform register_job_timers(); exception when others then raise notice 'timers not registered: %', sqlerrm; end $$;

-- the left menu: add the automation screen
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
    'automation_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager'), false),
    'uploads', import_can('products') or import_can('opening_stock') or import_can('listing_map') or import_can('ledger_opening') or import_can('orders')
  )
$$;

revoke execute on function run_scheduled_job(text, uuid), run_job_now(text), set_job_enabled(text, boolean), run_owner_digest(), register_job_timers(),
  my_work_count(), mark_notifications_read(), my_nav_access() from public, anon, authenticated;
grant execute on function run_job_now(text), set_job_enabled(text, boolean), my_work_count(), mark_notifications_read(), my_nav_access() to authenticated;
