-- 0073: Payment runs. Pay all the supplier bills that are due in one go.
--
--   Pick the bills due (MSME suppliers first, they have a legal payment limit) -> the app makes the bank's bulk-payment file (one line per supplier)
--   -> the bank pays it (the bank has its own approval step) -> enter the UTRs -> the app records one payment per supplier, split across their bills
--   -> a Finance Manager approves them all in one click (that is what posts the entries; the person who recorded them cannot approve them).
--   A supplier the bank did not pay is simply left out and its bills become payable again.

create sequence if not exists payment_run_seq;
create table if not exists payment_runs (
  run_id          uuid primary key default gen_random_uuid(),
  run_no          text not null unique,
  bank_account_id uuid not null references bank_accounts(bank_account_id),
  run_date        date not null,
  status          text not null default 'draft' check (status in ('draft', 'exported', 'completed', 'cancelled')),
  total           numeric(14,2) not null default 0,
  note            text,
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  exported_at     timestamptz,
  completed_at    timestamptz,
  completed_by    uuid
);
create table if not exists payment_run_items (
  item_id     uuid primary key default gen_random_uuid(),
  run_id      uuid not null references payment_runs(run_id) on delete cascade,
  supplier_id uuid not null references suppliers(supplier_id),
  bill_id     uuid not null references purchase_bills(bill_id),
  amount      numeric(14,2) not null check (amount > 0),
  status      text not null default 'pending' check (status in ('pending', 'paid', 'not_paid')),
  payment_id  uuid references supplier_payments(payment_id),
  unique (run_id, bill_id)
);
create index if not exists payment_run_items_bill on payment_run_items (bill_id);
alter table payment_runs enable row level security;
alter table payment_run_items enable row level security;
drop policy if exists "pr read" on payment_runs;      create policy "pr read"  on payment_runs      for select to authenticated using (has_accounting_view());
drop policy if exists "pri read" on payment_run_items; create policy "pri read" on payment_run_items for select to authenticated using (has_accounting_view());
grant select on payment_runs, payment_run_items to authenticated;

-- amount of a bill already promised to a run that is still open
create or replace function bill_in_open_runs(p_bill uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(i.amount), 0) from payment_run_items i join payment_runs r on r.run_id = i.run_id
   where i.bill_id = p_bill and i.status = 'pending' and r.status in ('draft', 'exported')
$$;

create or replace function payment_run_candidates(p_due_by date default current_date) returns table (
  bill_id uuid, bill_no text, supplier_id uuid, supplier_name text, due_date date, outstanding numeric, is_msme boolean, msme_days_left int, has_bank boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_lim int;
begin
  if not has_accounting_view() then raise exception 'Not authorized'; end if;
  select msme_limit_days into v_lim from purchase_settings where id = 1;
  return query
  select b.bill_id, b.bill_no, b.supplier_id, s.name, b.due_date,
         bill_outstanding(b.bill_id, null, true) - bill_in_open_runs(b.bill_id) as outstanding,
         s.is_msme, case when s.is_msme then (b.supplier_invoice_date + coalesce(v_lim, 45) - current_date) end,
         (sb.account_number is not null and sb.ifsc is not null)
    from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id left join supplier_bank sb on sb.supplier_id = b.supplier_id
   where b.status = 'approved' and s.status <> 'blocked' and b.due_date <= p_due_by
     and bill_outstanding(b.bill_id, null, true) - bill_in_open_runs(b.bill_id) > 0
   order by (case when s.is_msme then (b.supplier_invoice_date + coalesce(v_lim, 45) - current_date) else 9999 end), b.due_date, b.bill_no;
end $$;

-- p_items: [{bill_id, amount}]
create or replace function payment_run_create(p_bank uuid, p_run_date date, p_items jsonb, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; it jsonb; b purchase_bills%rowtype; v_amt numeric; v_free numeric; v_total numeric := 0; v_no text;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can make a payment run'; end if;
  if not exists (select 1 from bank_accounts where bank_account_id = p_bank) then raise exception 'Choose the bank account the payment will go from'; end if;
  if p_run_date is null or p_run_date < current_date - 7 then raise exception 'Choose the payment date (today or soon)'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Choose at least one bill'; end if;
  v_no := 'PR-' || to_char(p_run_date, 'YYMM') || '-' || lpad(nextval('payment_run_seq')::text, 4, '0');
  insert into payment_runs (run_no, bank_account_id, run_date, note) values (v_no, p_bank, p_run_date, nullif(btrim(coalesce(p_note, '')), '')) returning run_id into v_id;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into b from purchase_bills where bill_id = (it ->> 'bill_id')::uuid;
    if not found or b.status <> 'approved' then raise exception 'A chosen bill is not an approved bill'; end if;
    if exists (select 1 from suppliers where supplier_id = b.supplier_id and status = 'blocked') then raise exception 'Bill % belongs to a blocked supplier', b.bill_no; end if;
    v_free := bill_outstanding(b.bill_id, null, true) - bill_in_open_runs(b.bill_id);
    v_amt := round(coalesce(nullif(it ->> 'amount', '')::numeric, v_free), 2);
    if v_amt <= 0 then continue; end if;
    if v_amt > v_free then raise exception 'Bill % has only % left to pay (after other open payment runs)', b.bill_no, v_free; end if;
    insert into payment_run_items (run_id, supplier_id, bill_id, amount) values (v_id, b.supplier_id, b.bill_id, v_amt);
    v_total := v_total + v_amt;
  end loop;
  if v_total <= 0 then raise exception 'Nothing to pay in this run'; end if;
  update payment_runs set total = v_total where run_id = v_id;
  return v_id;
end $$;

-- the rows for the bank's bulk-payment file, one line per supplier
create or replace function payment_run_export(p_run uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r payment_runs%rowtype; v_rows jsonb; v_missing text;
begin
  if not has_accounting_write() then raise exception 'Not authorized'; end if;
  select * into r from payment_runs where run_id = p_run for update;
  if not found then raise exception 'Payment run not found'; end if;
  if r.status not in ('draft', 'exported') then raise exception 'This run is %', r.status; end if;
  select string_agg(s.name, ', ') into v_missing from (
    select distinct su.name from payment_run_items i join suppliers su on su.supplier_id = i.supplier_id left join supplier_bank sb on sb.supplier_id = i.supplier_id
     where i.run_id = p_run and i.status = 'pending' and (sb.account_number is null or sb.ifsc is null)) s;
  if v_missing is not null then raise exception 'Bank details (account number and IFSC) are missing for: %. Add them under Suppliers first.', v_missing; end if;
  select jsonb_agg(jsonb_build_object('supplier_id', x.supplier_id, 'beneficiary', coalesce(x.holder, x.name), 'account_number', x.acc, 'ifsc', x.ifsc, 'bank', x.bank,
                                      'amount', x.amt, 'reference', r.run_no, 'bills', x.bills) order by x.name) into v_rows
    from (select su.supplier_id, su.name, sb.account_holder as holder, sb.account_number as acc, sb.ifsc, sb.bank_name as bank, sum(i.amount) as amt,
                 string_agg(b.bill_no, ' ' order by b.bill_no) as bills
            from payment_run_items i join suppliers su on su.supplier_id = i.supplier_id join supplier_bank sb on sb.supplier_id = i.supplier_id join purchase_bills b on b.bill_id = i.bill_id
           where i.run_id = p_run and i.status = 'pending' group by su.supplier_id, su.name, sb.account_holder, sb.account_number, sb.ifsc, sb.bank_name) x;
  update payment_runs set status = 'exported', exported_at = coalesce(exported_at, now()) where run_id = p_run;
  return coalesce(v_rows, '[]'::jsonb);
end $$;

-- p_results: [{supplier_id, utr}]  (a supplier left out, or with a blank UTR, was not paid)
create or replace function payment_run_complete(p_run uuid, p_results jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r payment_runs%rowtype; x jsonb; v_sup uuid; v_utr text; v_alloc jsonb; v_sum numeric; v_pay uuid; v_paid int := 0; v_not int := 0; v_date date;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can complete a payment run'; end if;
  select * into r from payment_runs where run_id = p_run for update;
  if not found then raise exception 'Payment run not found'; end if;
  if r.status <> 'exported' then raise exception 'Export the file for the bank first (this run is %)', r.status; end if;
  v_date := least(r.run_date, current_date);
  for v_sup in select distinct supplier_id from payment_run_items where run_id = p_run and status = 'pending' loop
    select nullif(btrim(coalesce(e ->> 'utr', '')), '') into v_utr from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) e where (e ->> 'supplier_id')::uuid = v_sup limit 1;
    if v_utr is null then
      update payment_run_items set status = 'not_paid' where run_id = p_run and supplier_id = v_sup; v_not := v_not + 1; continue;
    end if;
    select jsonb_agg(jsonb_build_object('bill_id', bill_id, 'amount', amount)), sum(amount) into v_alloc, v_sum from payment_run_items where run_id = p_run and supplier_id = v_sup and status = 'pending';
    -- the run's own reservation must not count against the bill while its payment is recorded
    update payment_run_items set status = 'paid' where run_id = p_run and supplier_id = v_sup;
    v_pay := create_supplier_payment(v_sup, v_date, 'bank', r.bank_account_id, v_sum, v_utr, 'Payment run ' || r.run_no, v_alloc);
    update payment_run_items set payment_id = v_pay where run_id = p_run and supplier_id = v_sup;
    v_paid := v_paid + 1;
  end loop;
  update payment_runs set status = 'completed', completed_at = now(), completed_by = auth.uid() where run_id = p_run;
  return jsonb_build_object('suppliers_paid', v_paid, 'suppliers_not_paid', v_not);
end $$;

create or replace function payment_run_approve_payments(p_run uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; v_done int := 0; v_fail jsonb := '[]'::jsonb;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve supplier payments'; end if;
  for p in select distinct sp.payment_id, sp.payment_no from payment_run_items i join supplier_payments sp on sp.payment_id = i.payment_id where i.run_id = p_run and sp.status = 'pending' loop
    begin
      perform approve_supplier_payment(p.payment_id); v_done := v_done + 1;
    exception when others then v_fail := v_fail || jsonb_build_object('payment', p.payment_no, 'reason', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('approved', v_done, 'failed', v_fail);
end $$;

create or replace function payment_run_cancel(p_run uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r payment_runs%rowtype;
begin
  if not has_accounting_write() then raise exception 'Not authorized'; end if;
  select * into r from payment_runs where run_id = p_run for update;
  if not found then raise exception 'Payment run not found'; end if;
  if r.status not in ('draft', 'exported') then raise exception 'Only a run that is not completed can be cancelled'; end if;
  update payment_runs set status = 'cancelled' where run_id = p_run;
  update payment_run_items set status = 'not_paid' where run_id = p_run and status = 'pending';
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
;

revoke execute on function bill_in_open_runs(uuid), payment_run_candidates(date), payment_run_create(uuid, date, jsonb, text), payment_run_export(uuid), payment_run_complete(uuid, jsonb),
  payment_run_approve_payments(uuid), payment_run_cancel(uuid) from public, anon, authenticated;
grant execute on function bill_in_open_runs(uuid), payment_run_candidates(date), payment_run_create(uuid, date, jsonb, text), payment_run_export(uuid), payment_run_complete(uuid, jsonb),
  payment_run_approve_payments(uuid), payment_run_cancel(uuid) to authenticated;
