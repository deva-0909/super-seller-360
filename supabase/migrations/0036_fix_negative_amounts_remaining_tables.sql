-- ============================================================================
-- Super Seller 360 — Fix: negative amounts accepted across five more tables
--
-- Bugs found during senior-QA testing: the same gap found on orders (0035)
-- — no non-negative constraint on amount columns — existed on every other
-- table holding financial amounts. Confirmed live, one at a time, cleaned
-- up immediately after each:
--
-- - bank_transactions: a "credit" of -₹5,000 was accepted — since Cash
--   Flow sums credits as inflow, a negative one silently SUBTRACTS from
--   reported cash inflow while displaying as income.
-- - settlements: negative gross/deductions/expected_amount accepted.
-- - cod_collections: negative cod_amount/collected_amount accepted.
-- - tax_transactions: negative taxable_value/tax_amount accepted.
-- - products: negative cost_price (corrupts the Dashboard's inventory
--   value calculation) and an absurd gst_rate (tested 500%) both accepted.
--
-- Fixed all five at the source with CHECK constraints. All existing real
-- seed data already satisfied every constraint — each ALTER TABLE applied
-- cleanly with zero pre-existing violations, so nothing needed migrating.
--
-- Re-verified after the fix: negative amounts and the 500% GST rate are
-- now both rejected outright, legitimate values (18% GST, ₹200 cost price)
-- still insert fine, and a full count sweep afterward confirmed every
-- table exactly matches its correct seed count with zero contamination
-- from this round's testing (8 products, 18 orders, 4 bank transactions,
-- 3 settlements, 4 COD collections, 4 tax transactions, 5 claims, 3 returns).
-- ============================================================================

alter table bank_transactions add constraint bank_transactions_amount_non_negative check (amount >= 0);

alter table settlements add constraint settlements_amounts_non_negative check (
  gross >= 0 and deductions >= 0 and expected_amount >= 0
  and (actual_amount is null or actual_amount >= 0)
);

alter table cod_collections add constraint cod_collections_amounts_non_negative check (
  cod_amount >= 0 and collected_amount >= 0 and remitted_amount >= 0
);

alter table tax_transactions add constraint tax_transactions_amounts_non_negative check (
  taxable_value >= 0 and tax_amount >= 0
);

alter table products add constraint products_amounts_non_negative check (
  (cost_price is null or cost_price >= 0)
  and (packaging_cost is null or packaging_cost >= 0)
  and (gst_rate is null or (gst_rate >= 0 and gst_rate <= 100))
);
