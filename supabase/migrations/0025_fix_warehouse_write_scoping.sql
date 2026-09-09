-- ============================================================================
-- Super Seller 360 — Fix: Warehouse Manager write-scoping gap on returns/rtos
--
-- Found during senior-QA-style testing: the returns/rtos INSERT and UPDATE
-- RLS policies only checked has_returns_write() (role), never warehouse
-- scope — unlike the SELECT policy, which correctly restricts a Warehouse
-- Manager to their assigned warehouse(s).
--
-- Confirmed live in two stages: an INSERT ... RETURNING happened to fail,
-- but for an unrelated reason (Postgres also checks the SELECT policy when
-- returning an inserted row — she couldn't see the row she'd just have
-- created, so the whole statement errored). That looked like protection
-- but wasn't the real mechanism, so it was re-tested with a plain INSERT
-- and no RETURNING — matching exactly how the app's real .insert() calls
-- work — and it succeeded silently: a Warehouse Manager scoped only to
-- Surat created a return against Mumbai's warehouse with zero error.
--
-- Fix: the same warehouse-scope check the SELECT policy already uses,
-- applied to INSERT and UPDATE too, for both returns and rtos. Re-verified
-- after the fix: the same attack is now blocked, writing to her own
-- warehouse still works, and Super Admin (unscoped) is unaffected.
-- ============================================================================

drop policy "returns write" on returns;
create policy "returns write" on returns for insert with check (
  has_returns_write() and (
    current_role_name() <> 'Warehouse Manager'
    or warehouse_id is null
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = returns.warehouse_id)
  )
);

drop policy "returns write update" on returns;
create policy "returns write update" on returns for update using (
  has_returns_write() and (
    current_role_name() <> 'Warehouse Manager'
    or warehouse_id is null
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = returns.warehouse_id)
  )
);

drop policy "rtos write" on rtos;
create policy "rtos write" on rtos for insert with check (
  has_returns_write() and (
    current_role_name() <> 'Warehouse Manager'
    or warehouse_id is null
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = rtos.warehouse_id)
  )
);

drop policy "rtos write update" on rtos;
create policy "rtos write update" on rtos for update using (
  has_returns_write() and (
    current_role_name() <> 'Warehouse Manager'
    or warehouse_id is null
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = rtos.warehouse_id)
  )
);
