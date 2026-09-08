-- ============================================================================
-- Super Seller 360 — Phase 2A: RLS + seed data
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helper role-group functions (reuse current_role_name() from Phase 1)
-- ---------------------------------------------------------------------------
-- IMPORTANT: every one of these coalesces to false explicitly. Without it,
-- a caller with no user_profiles row gets current_role_name() = NULL, and
-- "NULL in (...)" is NULL rather than false — which then makes
-- "if not (has_x_write())" in plpgsql silently skip the exception branch
-- instead of blocking. This was a real bug caught during Phase 2 testing
-- (an order posted successfully for a caller with no role at all) — the
-- coalesce below is the fix, already folded into this file for anyone
-- running migrations fresh.
create or replace function has_accounting_view()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in (
    'Super Admin','CEO/Owner','Operations Manager','Finance Manager',
    'Accountant','Claims Manager','Tax Manager','Auditor'
  ), false)
$$;
alter function has_accounting_view() set search_path = public, pg_temp;

create or replace function has_accounting_write()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin','Finance Manager','Accountant'), false)
$$;
alter function has_accounting_write() set search_path = public, pg_temp;

create or replace function has_orders_write()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin','Operations Manager','Marketplace Manager'), false)
$$;
alter function has_orders_write() set search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- RLS: accounting core — view per has_accounting_view(), write per has_accounting_write()
-- ---------------------------------------------------------------------------
alter table account_groups     enable row level security;
alter table cost_centres       enable row level security;
alter table cost_categories    enable row level security;
alter table ledgers            enable row level security;
alter table voucher_types      enable row level security;
alter table accounting_periods enable row level security;
alter table vouchers           enable row level security;
alter table voucher_lines      enable row level security;
alter table journal_entries    enable row level security;
alter table journal_rules      enable row level security;
alter table opening_balances   enable row level security;

create policy "accounting view" on account_groups for select using (has_accounting_view());
create policy "accounting write" on account_groups for all using (has_accounting_write()) with check (has_accounting_write());

create policy "accounting view" on cost_centres for select using (has_accounting_view());
create policy "accounting write" on cost_centres for all using (has_accounting_write()) with check (has_accounting_write());

create policy "accounting view" on cost_categories for select using (has_accounting_view());
create policy "accounting write" on cost_categories for all using (has_accounting_write()) with check (has_accounting_write());

create policy "accounting view" on ledgers for select using (has_accounting_view());
create policy "accounting write" on ledgers for all using (has_accounting_write()) with check (has_accounting_write());

create policy "accounting view" on voucher_types for select using (has_accounting_view());
create policy "accounting write" on voucher_types for all using (has_accounting_write()) with check (has_accounting_write());

create policy "accounting view" on accounting_periods for select using (has_accounting_view());
create policy "accounting write" on accounting_periods for all using (has_accounting_write()) with check (has_accounting_write());

-- Vouchers/voucher_lines: writable through post_sales_voucher() (SECURITY
-- DEFINER, bypasses RLS) for normal sales postings. Direct insert is still
-- allowed for Finance/Accountant/Super Admin for manual journal vouchers;
-- the immutability triggers protect posted rows regardless of who writes.
create policy "accounting view" on vouchers for select using (has_accounting_view());
create policy "accounting write" on vouchers for insert with check (has_accounting_write());
create policy "accounting write update" on vouchers for update using (has_accounting_write());

create policy "accounting view" on voucher_lines for select using (has_accounting_view());
create policy "accounting write" on voucher_lines for insert with check (has_accounting_write());
create policy "accounting write update" on voucher_lines for update using (has_accounting_write());

create policy "accounting view" on journal_entries for select using (has_accounting_view());
-- journal_entries is a derived table (see sync_journal_entries trigger) — no direct writes.

create policy "accounting view" on journal_rules for select using (has_accounting_view());
create policy "accounting write" on journal_rules for all using (has_accounting_write()) with check (has_accounting_write());

create policy "accounting view" on opening_balances for select using (has_accounting_view());
create policy "accounting write" on opening_balances for all using (has_accounting_write()) with check (has_accounting_write());

-- ---------------------------------------------------------------------------
-- RLS: orders — everyone with a role can view (every role has at least
-- "View" on Orders per the Role Permission sheet); write per has_orders_write()
-- ---------------------------------------------------------------------------
alter table orders       enable row level security;
alter table order_lines  enable row level security;
alter table invoices     enable row level security;
alter table credit_notes enable row level security;

create policy "orders readable by authenticated" on orders for select using (auth.uid() is not null);
create policy "orders write" on orders for insert with check (has_orders_write());
create policy "orders write update" on orders for update using (has_orders_write());

create policy "order_lines readable by authenticated" on order_lines for select using (auth.uid() is not null);
create policy "order_lines write" on order_lines for insert with check (has_orders_write());
create policy "order_lines write update" on order_lines for update using (has_orders_write());

create policy "invoices view" on invoices for select using (has_accounting_view());
create policy "invoices write" on invoices for all using (has_accounting_write()) with check (has_accounting_write());

create policy "credit_notes view" on credit_notes for select using (has_accounting_view());
create policy "credit_notes write" on credit_notes for all using (has_accounting_write()) with check (has_accounting_write());

-- ---------------------------------------------------------------------------
-- Seed data: minimal chart of accounts + voucher type + open period, so
-- post_sales_voucher() has something to post against out of the box.
-- ---------------------------------------------------------------------------
insert into account_groups (name, nature, is_primary) values
  ('Assets', 'asset', true),
  ('Liabilities', 'liability', true),
  ('Income', 'income', true),
  ('Expenses', 'expense', true);

insert into account_groups (parent_group_id, name, nature, is_primary)
select account_group_id, 'Sundry Debtors', 'asset', false from account_groups where name = 'Assets'
union all
select account_group_id, 'Duties & Taxes', 'liability', false from account_groups where name = 'Liabilities'
union all
select account_group_id, 'Sales Accounts', 'income', false from account_groups where name = 'Income';

insert into ledgers (account_group_id, name, nature, gst_applicable, reconciliation_required)
select account_group_id, 'Trade Receivables', 'asset', false, true from account_groups where name = 'Sundry Debtors'
union all
select account_group_id, 'GST Payable (Output)', 'liability', true, false from account_groups where name = 'Duties & Taxes'
union all
select account_group_id, 'Sales Revenue', 'income', true, false from account_groups where name = 'Sales Accounts';

insert into voucher_types (code, name, numbering_prefix, source_event_type) values
  ('SALES', 'Sales Invoice', 'INV', 'order.invoiced'),
  ('CREDIT_NOTE', 'Credit Note', 'CN', 'return.credited'),
  ('JOURNAL', 'Journal', 'JV', null),
  ('PAYMENT', 'Payment', 'PMT', null),
  ('RECEIPT', 'Receipt', 'RCT', null);

insert into accounting_periods (financial_year_id, period_name, start_date, end_date, status)
values (
  'FY' || extract(year from current_date)::text || '-' || right((extract(year from current_date) + 1)::text, 2),
  to_char(current_date, 'Mon YYYY'),
  date_trunc('month', current_date)::date,
  (date_trunc('month', current_date) + interval '1 month - 1 day')::date,
  'open'
);
