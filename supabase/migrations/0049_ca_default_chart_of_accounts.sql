-- 0049: CA-grade default chart of accounts for a multi-channel garment e-commerce seller.
-- The app previously had 9 ledgers (no bank, no COGS, no returns, no logistics expenses). Everything the
-- rule engine (0050+) posts to needs a home, so the standard heads a 10-year practising CA would open are
-- added here. All of it is editable from Accounting > Rule Book > Ledgers; nothing is hard-wired by name
-- except the legacy sales-invoice / commission functions that already looked ledgers up by name.

-- 1. Account groups (sub-groups under the existing primary groups)
insert into account_groups (parent_group_id, name, nature, is_primary, status)
select (select account_group_id from account_groups where name = p.parent and is_primary), p.name, p.nature, false, 'active'
from (values
  ('Assets',      'Bank Accounts',        'asset'),
  ('Assets',      'Current Assets',       'asset'),
  ('Assets',      'Stock-in-Trade',       'asset'),
  ('Liabilities', 'Current Liabilities',  'liability'),
  ('Expenses',    'Direct Expenses',      'expense'),
  ('Expenses',    'Indirect Expenses',    'expense'),
  ('Income',      'Indirect Income',      'income')
) as p(parent, name, nature)
where not exists (select 1 from account_groups g where g.name = p.name);

-- 2. Ledgers
insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = v.grp), v.name, v.nature, 0,
       case when v.nature in ('asset','expense') then 'debit' else 'credit' end, v.gst, v.recon, 'active'
from (values
  -- Assets
  ('Sundry Debtors',      'COD Receivable from Couriers',                 'asset',     false, true),
  ('Current Assets',      'Claims Receivable - Courier & Marketplace',    'asset',     false, true),
  ('Current Assets',      'Settlement Short-Pay Receivable',              'asset',     false, true),
  ('Current Assets',      'Advance Tax & TDS Paid',                       'asset',     false, false),
  ('Current Assets',      'TDS Receivable (Sec 194-O)',                   'asset',     false, false),
  ('Current Assets',      'GST TCS Credit Receivable',                    'asset',     false, false),
  ('Current Assets',      'Suspense - To Be Classified',                  'asset',     false, true),
  ('Stock-in-Trade',      'Inventory - Stock-in-Trade',                   'asset',     false, false),
  -- Liabilities / equity
  ('Current Liabilities', 'Customer Refunds Payable',                     'liability', false, true),
  ('Current Liabilities', 'Settlement Excess Received',                   'liability', false, true),
  ('Equity',              'Opening Balance Equity',                       'equity',    false, false),
  -- Income
  ('Sales Accounts',      'Sales Returns & RTO Reversals',                'income',    true,  false),
  ('Indirect Income',     'Courier & Marketplace Claim Recoveries',       'income',    false, false),
  ('Indirect Income',     'Interest Income',                              'income',    false, false),
  -- Direct expenses
  ('Direct Expenses',     'Cost of Goods Sold',                           'expense',   false, false),
  ('Direct Expenses',     'Freight & Courier Charges - Outward',          'expense',   true,  false),
  ('Direct Expenses',     'Reverse Logistics & RTO Charges',              'expense',   true,  false),
  ('Direct Expenses',     'Packaging Materials Consumed',                 'expense',   true,  false),
  ('Direct Expenses',     'Payment Gateway Charges',                      'expense',   true,  false),
  ('Direct Expenses',     'Damaged & Lost Stock Loss',                    'expense',   false, false),
  ('Direct Expenses',     'Marketplace Penalties & Chargebacks',          'expense',   false, false),
  -- Indirect expenses
  ('Indirect Expenses',   'Bank Charges',                                 'expense',   true,  false),
  ('Indirect Expenses',   'Salaries & Wages',                             'expense',   false, false),
  ('Indirect Expenses',   'Rent',                                         'expense',   false, false),
  ('Indirect Expenses',   'Electricity & Utilities',                      'expense',   false, false),
  ('Indirect Expenses',   'Advertising & Promotion',                      'expense',   true,  false),
  ('Indirect Expenses',   'Software & Subscriptions',                     'expense',   true,  false),
  ('Indirect Expenses',   'Professional & Audit Fees',                    'expense',   true,  false),
  ('Indirect Expenses',   'Short-Pay & Bad Debts Written Off',            'expense',   false, false),
  ('Indirect Expenses',   'Miscellaneous Expenses',                       'expense',   false, false)
) as v(grp, name, nature, gst, recon)
where not exists (select 1 from ledgers l where l.name = v.name);

-- 3. One ledger per bank account, linked so rules can say "the bank this line came from"
alter table bank_accounts add column if not exists ledger_id uuid references ledgers(ledger_id);

insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = 'Bank Accounts'),
       'Bank - ' || split_part(b.bank_name, ' - ', 1) || ' (' || coalesce(b.account_number_last4, '----') || ')',
       'asset', 0, 'debit', false, true, 'active'
from bank_accounts b
where b.ledger_id is null
  and not exists (select 1 from ledgers l where l.name = 'Bank - ' || split_part(b.bank_name, ' - ', 1) || ' (' || coalesce(b.account_number_last4, '----') || ')');

update bank_accounts b set ledger_id = l.ledger_id
from ledgers l
where b.ledger_id is null
  and l.name = 'Bank - ' || split_part(b.bank_name, ' - ', 1) || ' (' || coalesce(b.account_number_last4, '----') || ')';

-- New bank accounts get their ledger automatically.
create or replace function bank_account_ensure_ledger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_name text; v_id uuid;
begin
  if new.ledger_id is not null then return new; end if;
  v_name := 'Bank - ' || split_part(new.bank_name, ' - ', 1) || ' (' || coalesce(new.account_number_last4, '----') || ')';
  select ledger_id into v_id from ledgers where name = v_name;
  if v_id is null then
    insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
    values ((select account_group_id from account_groups where name = 'Bank Accounts'), v_name, 'asset', 0, 'debit', false, true, 'active')
    returning ledger_id into v_id;
  end if;
  new.ledger_id := v_id;
  return new;
end $$;

drop trigger if exists trg_bank_account_ensure_ledger on bank_accounts;
create trigger trg_bank_account_ensure_ledger before insert on bank_accounts
  for each row execute function bank_account_ensure_ledger();
