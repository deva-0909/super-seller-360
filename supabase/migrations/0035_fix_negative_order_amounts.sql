-- ============================================================================
-- Super Seller 360 — Fix: negative order amounts could corrupt the books
--
-- Bug found during senior-QA testing: orders had no non-negative
-- constraint on any amount column. Confirmed live: created an order with
-- gross/tax/net all negative, then successfully invoiced it via
-- post_sales_voucher() — the resulting voucher posted real NEGATIVE
-- entries into the books (Trade Receivables debited -₹1,180, Sales
-- Revenue credited -₹1,180), silently reversing revenue and receivables
-- with no audit trail and completely bypassing the credit-note/return
-- workflow that's supposed to be the only legitimate way to reverse a
-- sale. The entry still "balanced" (both sides equal -1180), so none of
-- the existing checks caught it — balance alone doesn't guarantee
-- correctness. Cleaned up all resulting journal entries, the voucher,
-- invoice, and the order itself immediately after confirming.
--
-- Fixed at the source with CHECK constraints on the order's amount
-- columns, closing this for post_sales_voucher and any future feature
-- that trusts these values (CSV import, manual entry, a future
-- portal-webhook path) in one place rather than patching each consumer.
--
-- Re-verified: the same insert is now rejected outright, and since this
-- migration applies the constraint against existing data, all 18
-- pre-existing legitimate orders already satisfy it with zero migration
-- needed (Postgres validates existing rows when adding a CHECK
-- constraint, and this one applied cleanly).
-- ============================================================================
alter table orders add constraint orders_amounts_non_negative check (
  gross_amount >= 0 and discount >= 0 and tax_amount >= 0 and net_amount >= 0
);
