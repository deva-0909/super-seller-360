-- ============================================================================
-- Super Seller 360 — Fix: Marketplace Manager channel write-scoping gap
--
-- Bug found during senior-QA testing: the exact same class of gap as the
-- Warehouse Manager write-scoping bug (0025), on the direct analog case.
-- The orders INSERT/UPDATE policies only checked has_orders_write() (role),
-- never channel scope — despite Marketplace Manager's channel *visibility*
-- already being correctly scoped via user_channel_scope.
--
-- Confirmed live: Arjun (Marketplace Manager, scoped to Amazon + Flipkart
-- only) successfully cancelled a real SHOPIFY order (SHOP-1002) with zero
-- error. Reverted the change immediately, then fixed the root cause.
--
-- Re-verified after the fix: the same attack is blocked (status stayed
-- unchanged), writing to his own scoped channels (Amazon) still works, and
-- unscoped roles (Super Admin, Operations Manager) are unaffected.
-- ============================================================================

create or replace function has_channel_scope(p_channel_id uuid)
returns boolean language sql stable as $$
  select coalesce(
    current_role_name() <> 'Marketplace Manager'
    or exists (select 1 from user_channel_scope ucs where ucs.user_id = auth.uid() and ucs.channel_id = p_channel_id),
    false
  )
$$;
alter function has_channel_scope(uuid) set search_path = public, pg_temp;

drop policy "orders write" on orders;
create policy "orders write" on orders for insert with check (has_orders_write() and has_channel_scope(channel_id));

drop policy "orders write update" on orders;
create policy "orders write update" on orders for update using (has_orders_write() and has_channel_scope(channel_id));
