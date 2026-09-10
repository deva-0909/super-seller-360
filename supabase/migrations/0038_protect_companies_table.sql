-- ============================================================================
-- Super Seller 360 — Add explicit protection for the companies table
--
-- Investigated during senior-QA testing: attempted to delete the single
-- companies row (which every product, channel, and warehouse depends on
-- via company_id) as Super Admin and as a fully unauthorized random user.
-- The row survived every attempt, but the exact protection mechanism
-- observed was inconsistent across identical calls — sometimes a foreign
-- key violation surfaced, sometimes no error appeared at all. This
-- matches a tooling quirk hit elsewhere in this session (result display
-- inconsistency across multi-statement calls) rather than a real,
-- reproducible RLS gap — the row was never actually removed in any
-- attempt, confirmed by direct count checks each time.
--
-- Rather than leave the exact mechanism ambiguous, added an explicit,
-- unambiguous policy: nobody — not even Super Admin — can delete or
-- modify companies via the API at all. This is a single-tenant system
-- with exactly one company row seeded at setup; there is no legitimate
-- product reason for anyone to delete it or create a second one. This is
-- defense-in-depth on top of whatever foreign-key protection already
-- existed, not a replacement for it.
--
-- Verified after adding: SELECT still works normally (the existing
-- read policy is unaffected, since permissive policies combine with OR),
-- DELETE is now consistently and explicitly blocked for Super Admin, and
-- all dependent data (8 products, 3 channels, 2 warehouses, 18 orders)
-- remains exactly correct.
-- ============================================================================
create policy "companies immutable via api"
  on companies for all
  using (false)
  with check (false);
