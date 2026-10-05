-- 0083: Profit and Loss for any date range.
--
-- trial_balance() includes period-close vouchers, which zero out income and expense in a closed period, so a closed year would show
-- a nil profit. This function leaves those closing vouchers out, so the P&L of any range (open or closed) shows true trading activity.
-- SECURITY INVOKER: the caller's row-level security still decides what they can see.
-- Amount sign: income = credit - debit, expense = debit - credit (both positive when normal).

create or replace function profit_and_loss(p_from date default null, p_to date default current_date)
returns table (ledger_id uuid, ledger_name text, group_name text, nature text, amount numeric)
language sql stable set search_path = public, pg_temp as $$
  select l.ledger_id, l.name, g.name, l.nature,
         case when l.nature = 'income' then sum(je.credit - je.debit) else sum(je.debit - je.credit) end as amount
    from journal_entries je
    join ledgers l on l.ledger_id = je.account_id
    join account_groups g on g.account_group_id = l.account_group_id
    left join vouchers v on v.voucher_id = je.voucher_id
   where je.status = 'posted'
     and l.nature in ('income', 'expense')
     and coalesce(v.source_type, '') <> 'period_close'
     and je.date >= coalesce(p_from, date '1900-01-01') and je.date <= coalesce(p_to, current_date)
   group by l.ledger_id, l.name, g.name, l.nature
  having sum(je.debit) <> 0 or sum(je.credit) <> 0
   order by l.nature desc, g.name, l.name
$$;

revoke execute on function profit_and_loss(date, date) from public, anon;
grant execute on function profit_and_loss(date, date) to authenticated;
