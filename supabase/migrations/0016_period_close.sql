-- ============================================================================
-- Super Seller 360 — Period Close
--
-- Deliberate separation of duties per the Role Permission sheet: Period
-- Close is Full for Finance Manager, Configured for Accountant, and "—" for
-- EVERY other role — including Super Admin. This is intentional: the person
-- who administers the system isn't automatically trusted to close the
-- books. has_period_close() honors this literally.
-- ============================================================================

create or replace function has_period_close()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Finance Manager','Accountant'), false)
$$;
alter function has_period_close() set search_path = public, pg_temp;

-- Seed the Equity side of the books — didn't exist yet because nothing had
-- needed it until now. Retained Earnings is where each period's net profit
-- lands once closed.
insert into account_groups (name, nature, is_primary)
select 'Equity', 'equity', true
where not exists (select 1 from account_groups where name = 'Equity');

insert into ledgers (account_group_id, name, nature)
select account_group_id, 'Retained Earnings', 'equity'
from account_groups where name = 'Equity'
and not exists (select 1 from ledgers where name = 'Retained Earnings');

-- Block new vouchers from posting into a period that's no longer open —
-- post_sales_voucher already can't find a closed period (it only looks up
-- status = 'open'), but a manually-created voucher could otherwise
-- reference a closed accounting_period_id directly. This closes that gap.
create or replace function prevent_voucher_in_closed_period()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period_status text;
begin
  select status into v_period_status from accounting_periods where accounting_period_id = new.accounting_period_id;
  if v_period_status <> 'open' then
    raise exception 'Cannot post a voucher into a % accounting period', v_period_status;
  end if;
  return new;
end;
$$;

create trigger trg_prevent_voucher_in_closed_period
  before insert on vouchers
  for each row execute function prevent_voucher_in_closed_period();

-- ---------------------------------------------------------------------------
-- close_accounting_period — computes THIS PERIOD's income/expense activity
-- (not all-time), posts real closing entries zeroing each income/expense
-- ledger's period movement into Retained Earnings, then locks the period.
-- This is a genuine closing entry, not just a status flag — Retained
-- Earnings actually accumulates the transferred profit/loss.
-- ---------------------------------------------------------------------------
create or replace function close_accounting_period(p_period_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period accounting_periods%rowtype;
  v_voucher_type_id uuid;
  v_voucher_id uuid;
  v_retained_earnings_ledger uuid;
  v_line record;
  v_total_debit numeric := 0;
  v_total_credit numeric := 0;
  v_net_profit numeric := 0;
begin
  if not has_period_close() then
    raise exception 'Not authorized to close accounting periods';
  end if;

  select * into v_period from accounting_periods where accounting_period_id = p_period_id;
  if not found then
    raise exception 'Accounting period % not found', p_period_id;
  end if;
  if v_period.status <> 'open' then
    raise exception 'Period % is already %', v_period.period_name, v_period.status;
  end if;

  select ledger_id into v_retained_earnings_ledger from ledgers where name = 'Retained Earnings';
  select voucher_type_id into v_voucher_type_id from voucher_types where code = 'JOURNAL';

  -- Draft voucher first (see post_sales_voucher's comment for why: the
  -- immutability trigger only blocks a voucher that was ALREADY posted).
  insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, source_type, source_id, narration, total_debit, total_credit)
  values (v_voucher_type_id, 'CLOSE-' || v_period.period_name, v_period.end_date, p_period_id, 'draft', 'period_close', p_period_id, 'Period close: ' || v_period.period_name, 0, 0)
  returning voucher_id into v_voucher_id;

  -- Income ledgers: their period credit-debit balance gets debited out
  -- (zeroing this period's contribution) and credited to Retained Earnings.
  for v_line in
    select l.ledger_id, sum(je.credit) - sum(je.debit) as balance
    from ledgers l
    join journal_entries je on je.account_id = l.ledger_id
    where l.nature = 'income' and je.date between v_period.start_date and v_period.end_date
    group by l.ledger_id
    having sum(je.credit) - sum(je.debit) <> 0
  loop
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_line.ledger_id, v_line.balance, 0, 'period_close', p_period_id);
    v_total_debit := v_total_debit + v_line.balance;
    v_net_profit := v_net_profit + v_line.balance;
  end loop;

  -- Expense ledgers: their period debit-credit balance gets credited out,
  -- debited to Retained Earnings.
  for v_line in
    select l.ledger_id, sum(je.debit) - sum(je.credit) as balance
    from ledgers l
    join journal_entries je on je.account_id = l.ledger_id
    where l.nature = 'expense' and je.date between v_period.start_date and v_period.end_date
    group by l.ledger_id
    having sum(je.debit) - sum(je.credit) <> 0
  loop
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_line.ledger_id, 0, v_line.balance, 'period_close', p_period_id);
    v_total_credit := v_total_credit + v_line.balance;
    v_net_profit := v_net_profit - v_line.balance;
  end loop;

  if v_total_debit <> 0 or v_total_credit <> 0 then
    -- Net profit lands on Retained Earnings as whichever side balances the
    -- entry — credit if profitable, debit if a loss.
    if v_net_profit >= 0 then
      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_retained_earnings_ledger, 0, v_net_profit, 'period_close', p_period_id);
      v_total_credit := v_total_credit + v_net_profit;
    else
      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_retained_earnings_ledger, -v_net_profit, 0, 'period_close', p_period_id);
      v_total_debit := v_total_debit - v_net_profit;
    end if;

    update vouchers set total_debit = v_total_debit, total_credit = v_total_credit, status = 'posted'
      where voucher_id = v_voucher_id;
  else
    -- Nothing to close (no activity this period) — remove the empty draft
    -- rather than leaving a zero-value voucher behind.
    delete from vouchers where voucher_id = v_voucher_id;
    v_voucher_id := null;
  end if;

  update accounting_periods
    set status = 'closed', locked_at = now(), closed_by = auth.uid()
    where accounting_period_id = p_period_id;

  return v_voucher_id;
end;
$$;

revoke execute on function close_accounting_period(uuid) from anon, public;
grant execute on function close_accounting_period(uuid) to authenticated;
