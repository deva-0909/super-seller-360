-- ============================================================================
-- Super Seller 360 — Lock down trigger-only functions
-- log_order_status_change() and prevent_voucher_in_closed_period() should
-- only ever fire via their triggers, never be called directly via RPC.
-- Confirmed safe: trigger invocation doesn't go through the same EXECUTE
-- permission check as a direct call (same pattern already proven with
-- sync_journal_entries in Phase 2A) — verified live by updating an order's
-- status after this revoke and confirming the history row still logged.
-- ============================================================================
revoke execute on function log_order_status_change() from anon, authenticated, public;
revoke execute on function prevent_voucher_in_closed_period() from anon, authenticated, public;
revoke execute on function close_accounting_period(uuid) from anon;
