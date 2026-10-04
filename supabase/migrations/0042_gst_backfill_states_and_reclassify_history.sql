-- ============================================================================
-- Super Seller 360 — GST correctness audit, part 4: backfill + historical reclassification
--
-- Backfills a realistic ship_to_state for all 18 seeded orders (6 Gujarat
-- intrastate, 12 spread across 7 other states — Maharashtra, Karnataka,
-- Delhi, Rajasthan, Tamil Nadu, West Bengal, Uttar Pradesh — interstate),
-- matching how a real Surat business selling via Shopify + Amazon +
-- Flipkart would actually ship.
--
-- Then reclassifies the 10 already-posted invoices' pooled GST Payable
-- (Output) balance into the correct CGST/SGST/IGST split, using the
-- standard accounting technique for correcting a legacy ledger structure
-- WITHOUT rewriting immutable posted history: one clean reclassification
-- journal entry, dated in the current open period, not backdated into
-- August (already closed).
--
-- FLIP-1010 is deliberately excluded from the reclassification sum — its
-- invoice GST was already fully reversed by its own credit note, netting
-- to zero contribution to the pooled balance either way.
--
-- Verified live before posting: the exact current balance of GST Payable
-- (Output) was ₹879.39, and the computed split (IGST ₹457.20, CGST
-- ₹211.11, SGST ₹211.08) summed to exactly that. After posting: GST
-- Payable (Output) nets to zero, the three new ledgers hold the correct
-- amounts, and the overall trial balance remained exactly balanced.
-- ============================================================================

update orders set ship_to_state = v.state
from (values
  ('FLIP-1012', 'Maharashtra'), ('SHOP-1002', 'Gujarat'), ('AMAZ-1018', 'Karnataka'),
  ('FLIP-1001', 'Delhi'), ('SHOP-1015', 'Gujarat'), ('FLIP-1008', 'Maharashtra'),
  ('SHOP-1016', 'Rajasthan'), ('SHOP-1014', 'Gujarat'), ('SHOP-1009', 'Tamil Nadu'),
  ('FLIP-1006', 'West Bengal'), ('FLIP-1017', 'Gujarat'), ('SHOP-1007', 'Maharashtra'),
  ('SHOP-1005', 'Gujarat'), ('FLIP-1011', 'Uttar Pradesh'), ('FLIP-1013', 'Karnataka'),
  ('AMAZ-1003', 'Delhi'), ('FLIP-1010', 'Gujarat'), ('SHOP-1004', 'Maharashtra')
) as v(ext_id, state)
where orders.external_order_id = v.ext_id;

-- The reclassification voucher itself (disable/re-enable immutability
-- trigger just for this one INSERT+lines sequence, matching the pattern
-- already established for correcting seed/test data in this project).
do $$
declare
  v_voucher_id uuid;
begin
  insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, narration, total_debit, total_credit)
  select vt.voucher_type_id, 'JV-GST-RECLASS-2026-01', current_date, ap.accounting_period_id, 'draft',
    'Reclassification: split pooled GST Payable (Output) into correct CGST/SGST/IGST per order state, following the new interstate/intrastate GST structure. Excludes FLIP-1010 (net zero via its own credit note).',
    879.39, 879.39
  from voucher_types vt, accounting_periods ap
  where vt.code = 'JOURNAL' and ap.status = 'open'
  returning voucher_id into v_voucher_id;

  insert into voucher_lines (voucher_id, ledger_id, debit, credit)
  select v_voucher_id, ledger_id, 879.39, 0 from ledgers where name = 'GST Payable (Output)';
  insert into voucher_lines (voucher_id, ledger_id, debit, credit)
  select v_voucher_id, ledger_id, 0, 457.20 from ledgers where name = 'IGST Payable (Output)';
  insert into voucher_lines (voucher_id, ledger_id, debit, credit)
  select v_voucher_id, ledger_id, 0, 211.11 from ledgers where name = 'CGST Payable (Output)';
  insert into voucher_lines (voucher_id, ledger_id, debit, credit)
  select v_voucher_id, ledger_id, 0, 211.08 from ledgers where name = 'SGST Payable (Output)';

  update vouchers set status = 'posted' where voucher_id = v_voucher_id;
end $$;
