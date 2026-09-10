-- ============================================================================
-- Super Seller 360 — Fix: channel write-scoping gap on channel_sku_map and claims
--
-- Bugs found during senior-QA testing, same class as 0030 (orders), on two
-- more tables Marketplace Manager can write to but that reference a channel:
--
-- 1. channel_sku_map: "operations manages channel_sku_map" checked role
--    only. Confirmed live: Arjun (scoped to Amazon + Flipkart) created a
--    SKU mapping for SHOPIFY with zero error.
-- 2. claims: has_claims_create() checked role only, never the channel of
--    the order being claimed against. Confirmed live: Arjun created a
--    claim against a real SHOPIFY order with zero error.
--
-- Both cleaned up immediately after confirming, then fixed using the same
-- has_channel_scope() helper already added for orders in 0030 — for
-- claims, scoped via the order's channel_id since claims has no direct
-- channel_id column of its own.
--
-- Re-verified after the fix: both attacks are blocked, legitimate scoped
-- use (a claim against his own Amazon order) still works, and unscoped
-- roles (Operations Manager) are completely unaffected — confirmed by
-- successfully creating a claim against the same Shopify order as her.
-- Final counts confirmed clean: 16 channel_sku_map rows and 5 claims,
-- exactly matching the original seed data, and books still balanced.
-- ============================================================================

drop policy "operations manages channel_sku_map" on channel_sku_map;
create policy "operations manages channel_sku_map"
  on channel_sku_map for all
  using (
    current_role_name() in ('Super Admin','Operations Manager','Marketplace Manager')
    and has_channel_scope(channel_id)
  )
  with check (
    current_role_name() in ('Super Admin','Operations Manager','Marketplace Manager')
    and has_channel_scope(channel_id)
  );

drop policy "claims create" on claims;
create policy "claims create" on claims for insert with check (
  has_claims_create()
  and has_channel_scope((select o.channel_id from orders o where o.order_id = claims.order_id))
);
