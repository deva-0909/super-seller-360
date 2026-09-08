-- ============================================================================
-- Super Seller 360 — Phase 2A: lock down post_sales_voucher()
-- The security advisor flagged that post_sales_voucher, being SECURITY
-- DEFINER, was callable by the anon (unauthenticated) role via PostgREST.
-- The function already checks the caller's role internally, but an
-- unauthenticated request should never reach it in the first place.
-- ============================================================================
revoke execute on function post_sales_voucher(uuid) from anon;
revoke execute on function post_sales_voucher(uuid) from public;
grant execute on function post_sales_voucher(uuid) to authenticated;
