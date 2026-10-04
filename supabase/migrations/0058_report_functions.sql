-- 0058: Accounting report functions (trial balance and ledger statement).
--
-- Both are SECURITY INVOKER, so the caller's row-level security on ledgers / journal_entries still decides what they can see.
-- They do the arithmetic in the database, so a report is never cut short by the 1,000-row limit of the API, and they include each
-- ledger's opening balance (the ledger screens used to ignore it).
-- Sign convention everywhere: debit positive, credit negative. A ledger without an opening balance type takes the normal side of its nature.

create or replace function trial_balance(p_from date default null, p_to date default current_date)
returns table (ledger_id uuid, ledger_name text, group_name text, nature text,
               opening numeric, period_debit numeric, period_credit numeric, closing numeric)
language sql stable set search_path = public, pg_temp as $$
  with je as (
    select account_id,
           sum(case when date <  coalesce(p_from, date '1900-01-01') then debit - credit else 0 end) as pre,
           sum(case when date >= coalesce(p_from, date '1900-01-01') then debit  else 0 end)          as d,
           sum(case when date >= coalesce(p_from, date '1900-01-01') then credit else 0 end)          as c
      from journal_entries
     where status = 'posted' and date <= coalesce(p_to, current_date)
     group by account_id
  ), base as (
    select l.ledger_id, l.name as ledger_name, g.name as group_name, l.nature, l.status,
           (case when coalesce(l.opening_balance_type, case when l.nature in ('asset', 'expense') then 'debit' else 'credit' end) = 'debit'
                 then l.opening_balance else -l.opening_balance end) + coalesce(je.pre, 0) as opening,
           coalesce(je.d, 0) as period_debit, coalesce(je.c, 0) as period_credit
      from ledgers l
      join account_groups g on g.account_group_id = l.account_group_id
      left join je on je.account_id = l.ledger_id
  )
  select b.ledger_id, b.ledger_name, b.group_name, b.nature, b.opening, b.period_debit, b.period_credit,
         b.opening + b.period_debit - b.period_credit as closing
    from base b
   where b.status = 'active' or b.opening <> 0 or b.period_debit <> 0 or b.period_credit <> 0
   order by b.nature, b.group_name, b.ledger_name
$$;

create or replace function ledger_statement(p_ledger uuid, p_from date default null, p_to date default current_date)
returns table (seq bigint, entry_date date, voucher_id uuid, voucher_no text, narration text,
               debit numeric, credit numeric, balance numeric, is_opening boolean)
language sql stable set search_path = public, pg_temp as $$
  with opening as (
    select (select (case when coalesce(l.opening_balance_type, case when l.nature in ('asset', 'expense') then 'debit' else 'credit' end) = 'debit'
                         then l.opening_balance else -l.opening_balance end)
              from ledgers l where l.ledger_id = p_ledger)
           + coalesce((select sum(je.debit - je.credit) from journal_entries je
                        where je.account_id = p_ledger and je.status = 'posted' and je.date < coalesce(p_from, date '1900-01-01')), 0) as amt
  ), lines as (
    select je.date, je.voucher_id, v.voucher_no, v.narration, je.debit, je.credit,
           row_number() over (order by je.date, je.created_at, je.journal_id) as rn
      from journal_entries je
      left join vouchers v on v.voucher_id = je.voucher_id
     where je.account_id = p_ledger and je.status = 'posted'
       and je.date >= coalesce(p_from, date '1900-01-01') and je.date <= coalesce(p_to, current_date)
  ), allrows as (
    select 0::bigint as seq, p_from as entry_date, null::uuid as voucher_id, null::text as voucher_no, 'Opening balance'::text as narration,
           0::numeric as debit, 0::numeric as credit, (select amt from opening) as delta, true as is_opening
    union all
    select rn, date, voucher_id, voucher_no, narration, debit, credit, debit - credit, false from lines
  )
  select a.seq, a.entry_date, a.voucher_id, a.voucher_no, a.narration, a.debit, a.credit,
         sum(a.delta) over (order by a.seq) as balance, a.is_opening
    from allrows a
   order by a.seq
$$;

revoke execute on function trial_balance(date, date), ledger_statement(uuid, date, date) from public, anon;
grant execute on function trial_balance(date, date), ledger_statement(uuid, date, date) to authenticated;
