-- ============================================================================
-- Super Seller 360 — Phase 3: RLS for Returns, RTO, Inventory
-- Matches the Role Permission sheet: Returns/RTO and Inventory columns have
-- an identical access pattern — Full: Super Admin, Operations Manager,
-- Warehouse Manager, Marketplace Manager. View: CEO/Owner, Finance Manager,
-- Claims Manager, Auditor. None: Accountant, Tax Manager.
-- Warehouse Manager is additionally scoped to their assigned warehouse(s),
-- consistent with the Phase 1 pattern already used for the warehouses table.
-- ============================================================================

create or replace function has_returns_view()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in (
    'Super Admin','CEO/Owner','Operations Manager','Warehouse Manager',
    'Finance Manager','Claims Manager','Marketplace Manager','Auditor'
  ), false)
$$;
alter function has_returns_view() set search_path = public, pg_temp;

create or replace function has_returns_write()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in (
    'Super Admin','Operations Manager','Warehouse Manager','Marketplace Manager'
  ), false)
$$;
alter function has_returns_write() set search_path = public, pg_temp;

alter table returns                enable row level security;
alter table rtos                   enable row level security;
alter table inventory_transactions enable row level security;
alter table inventory_balances     enable row level security;

-- Returns/RTO: full visibility for company-wide roles; Warehouse Manager
-- sees only rows scoped to their assigned warehouse(s) (or unassigned rows
-- still awaiting a destination warehouse, so new returns aren't invisible
-- before triage).
create policy "returns visibility" on returns for select
  using (
    current_role_name() in ('Super Admin','CEO/Owner','Operations Manager','Finance Manager','Claims Manager','Marketplace Manager','Auditor')
    or (
      current_role_name() = 'Warehouse Manager'
      and (
        warehouse_id is null
        or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = returns.warehouse_id)
      )
    )
  );
create policy "returns write" on returns for insert with check (has_returns_write());
create policy "returns write update" on returns for update using (has_returns_write());

create policy "rtos visibility" on rtos for select
  using (
    current_role_name() in ('Super Admin','CEO/Owner','Operations Manager','Finance Manager','Claims Manager','Marketplace Manager','Auditor')
    or (
      current_role_name() = 'Warehouse Manager'
      and (
        warehouse_id is null
        or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = rtos.warehouse_id)
      )
    )
  );
create policy "rtos write" on rtos for insert with check (has_returns_write());
create policy "rtos write update" on rtos for update using (has_returns_write());

-- Inventory: same visibility pattern, always scoped by warehouse for
-- Warehouse Manager (no "unassigned" case here — every movement/balance
-- always has a concrete warehouse).
create policy "inventory_transactions visibility" on inventory_transactions for select
  using (
    current_role_name() in ('Super Admin','CEO/Owner','Operations Manager','Finance Manager','Claims Manager','Marketplace Manager','Auditor')
    or (
      current_role_name() = 'Warehouse Manager'
      and exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = inventory_transactions.warehouse_id)
    )
  );
-- No direct writes — only record_inventory_movement() (SECURITY DEFINER) writes here.

create policy "inventory_balances visibility" on inventory_balances for select
  using (
    current_role_name() in ('Super Admin','CEO/Owner','Operations Manager','Finance Manager','Claims Manager','Marketplace Manager','Auditor')
    or (
      current_role_name() = 'Warehouse Manager'
      and exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = inventory_balances.warehouse_id)
    )
  );
-- No direct writes — only record_inventory_movement() (SECURITY DEFINER) writes here.
