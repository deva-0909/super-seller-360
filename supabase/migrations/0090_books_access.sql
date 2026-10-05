-- 0090: who may open the books.
-- Until now every role that could see "accounting" (including Operations, Claims and Tax Managers) could read every journal entry, so they could work out
-- profit, bank balances and salaries. The books are now limited to the finance team; Tax Manager keeps read access to GST, TDS and TCS entries only.
-- Also adds a cost-price permission so warehouse, marketplace and claims staff do not see what stock costs.

create or replace function has_books_view() returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Finance Manager', 'Accountant', 'Auditor'), false)
$$;
alter function has_books_view() set search_path = public, pg_temp;

-- the Claims Manager has no business with supplier bills, payments or ledgers either
create or replace function has_accounting_view() returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Accountant', 'Tax Manager', 'Auditor'), false)
$$;
alter function has_accounting_view() set search_path = public, pg_temp;

create or replace function has_cost_view() returns boolean language sql stable as $$
  select coalesce(current_role_name() not in ('Warehouse Manager', 'Marketplace Manager', 'Claims Manager'), false)
$$;
alter function has_cost_view() set search_path = public, pg_temp;
grant execute on function has_books_view(), has_cost_view() to authenticated;

do $do$
declare t text; p text;
begin
  foreach t in array array['journal_entries', 'vouchers', 'voucher_lines', 'opening_balances', 'fixed_assets', 'asset_depreciation', 'recurring_journals', 'recurring_journal_runs'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t and cmd = 'SELECT' and qual like '%has_accounting_view()%' loop
      execute format('drop policy %I on %I', p, t);
    end loop;
    execute format('drop policy if exists "books view" on %I', t);
    execute format('create policy "books view" on %I for select to authenticated using (has_books_view())', t);
  end loop;
end $do$;

-- the Tax Manager (and anyone else who works on returns) reads only the tax ledgers
drop policy if exists "tax ledgers view" on journal_entries;
create policy "tax ledgers view" on journal_entries for select to authenticated
  using (has_gst_view() and account_id in (select ledger_id from ledgers where name ~* 'gst|tds|tcs'));

create or replace function my_nav_access() returns jsonb
language sql stable set search_path = public, pg_temp as $f$
  select jsonb_build_object(
    'all', true,
    'accounting_view', has_accounting_view(),
    'accounting_write', has_accounting_write(),
    'books_view', has_books_view(),
    'cost_view', has_cost_view(),
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
    'payroll_view', has_payroll_view(),
    'journal_review', has_journal_review(),
    'automation_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager'), false),
    'uploads', import_can('products') or import_can('opening_stock') or import_can('listing_map') or import_can('ledger_opening') or import_can('orders') or import_can('settlement')
  )
$f$;
