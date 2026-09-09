-- ============================================================================
-- Super Seller 360 — Phase 4: RLS for Settlements, Bank/COD
-- Settlements: Full = Super Admin, Finance Manager. Reconcile = + Accountant.
-- View = everyone else except Warehouse Manager (which has no access at all).
-- Bank/COD: Full = Super Admin, Finance Manager, Accountant.
-- View = everyone else except Warehouse Manager.
-- ============================================================================

create or replace function has_settlements_view()
returns boolean language sql stable as $$
  select coalesce(current_role_name() <> 'Warehouse Manager', false)
$$;
alter function has_settlements_view() set search_path = public, pg_temp;

create or replace function has_settlements_write()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin','Finance Manager'), false)
$$;
alter function has_settlements_write() set search_path = public, pg_temp;

create or replace function has_settlements_reconcile()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin','Finance Manager','Accountant'), false)
$$;
alter function has_settlements_reconcile() set search_path = public, pg_temp;

create or replace function has_bankcod_view()
returns boolean language sql stable as $$
  select coalesce(current_role_name() <> 'Warehouse Manager', false)
$$;
alter function has_bankcod_view() set search_path = public, pg_temp;

create or replace function has_bankcod_write()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin','Finance Manager','Accountant'), false)
$$;
alter function has_bankcod_write() set search_path = public, pg_temp;

alter table bank_accounts     enable row level security;
alter table settlements       enable row level security;
alter table settlement_lines  enable row level security;
alter table bank_transactions enable row level security;
alter table cod_collections   enable row level security;

create policy "bank_accounts view" on bank_accounts for select using (has_bankcod_view());
create policy "bank_accounts write" on bank_accounts for all
  using (has_bankcod_write()) with check (has_bankcod_write());

create policy "settlements view" on settlements for select using (has_settlements_view());
create policy "settlements write" on settlements for insert with check (has_settlements_write());
create policy "settlements write update" on settlements for update using (has_settlements_write() or has_settlements_reconcile());

create policy "settlement_lines view" on settlement_lines for select using (has_settlements_view());
create policy "settlement_lines write" on settlement_lines for all
  using (has_settlements_write()) with check (has_settlements_write());

create policy "bank_transactions view" on bank_transactions for select using (has_bankcod_view());
create policy "bank_transactions write" on bank_transactions for all
  using (has_bankcod_write()) with check (has_bankcod_write());

create policy "cod_collections view" on cod_collections for select using (has_bankcod_view());
create policy "cod_collections write" on cod_collections for all
  using (has_bankcod_write()) with check (has_bankcod_write());
