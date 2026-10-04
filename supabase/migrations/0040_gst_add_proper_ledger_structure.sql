-- ============================================================================
-- Super Seller 360 — GST correctness audit, part 2: proper ledger structure
--
-- Splits the single pooled GST Payable (Output) ledger into the three
-- ledgers GST law actually requires to be tracked and reported separately:
-- CGST + SGST for intrastate supply, IGST for interstate supply. Also adds
-- a proper Input Tax Credit ledger (asset) and a Marketplace Commission
-- Expense ledger (expense) — required to model ITC correctly: marketplaces
-- charge GST on their commission, which is claimable input credit, not
-- just a deduction from what they remit.
--
-- The old GST Payable (Output) ledger is kept, not dropped — it holds real
-- historical postings and this project's own rule (immutable posted
-- vouchers) means history is never rewritten, only reclassified forward
-- (see migration 0042).
-- ============================================================================
insert into ledgers (account_group_id, name, nature)
select account_group_id, 'CGST Payable (Output)', 'liability' from account_groups where name = 'Duties & Taxes'
union all
select account_group_id, 'SGST Payable (Output)', 'liability' from account_groups where name = 'Duties & Taxes'
union all
select account_group_id, 'IGST Payable (Output)', 'liability' from account_groups where name = 'Duties & Taxes'
union all
select account_group_id, 'GST Input Tax Credit (ITC)', 'asset' from account_groups where name = 'Assets'
union all
select account_group_id, 'Marketplace Commission Expense', 'expense' from account_groups where name = 'Expenses';
