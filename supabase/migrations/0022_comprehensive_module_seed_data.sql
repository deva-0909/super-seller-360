-- ============================================================================
-- Super Seller 360 — Comprehensive seed data for previously-empty modules
--
-- Audit finding: Phases 3, 4, and 5 (Returns, RTO, Inventory, Settlements,
-- Bank, COD, Claims, Tax) had zero permanent seed data — every test during
-- development was created and cleaned up immediately after, so despite the
-- features being built and tested, there was nothing to click through and
-- see. This seeds real, permanent examples across every state each module
-- supports, using real existing orders, posted through the actual workflow
-- functions (not fabricated final states) so the accounting stays correct.
--
-- Grounded in Surat: both bank branches, the destination warehouse for every
-- return/RTO, and the couriers used are all Surat-based.
--
-- NOTE: this file documents what was seeded via direct execution against
-- the live database (using the same role-simulation technique as all
-- testing in this project) — reproducing it exactly requires calling
-- disposition_return/disposition_rto/advance_claim/reconcile_settlement as
-- the correct role for each step, not a single flat SQL script. See README
-- "Comprehensive seed data" section for the full breakdown of what exists
-- and why each state was chosen.
-- ============================================================================

-- Bank accounts (Surat branches)
insert into bank_accounts (company_id, bank_name, account_name, account_number_last4)
select company_id, v.bank_name, v.account_name, v.last4
from companies, (values
  ('HDFC Bank - Ring Road Branch, Surat', 'Super Seller 360 Current Account', '4821'),
  ('ICICI Bank - Udhna Branch, Surat', 'Super Seller 360 Collections Account', '7734')
) as v(bank_name, account_name, last4)
on conflict do nothing;

-- Settlements: reconciled, short_pay, and pending — one of each state
insert into settlements (channel_id, external_settlement_id, period_start, period_end, gross, deductions, expected_amount, actual_amount, status)
select c.channel_id, v.ext_id, v.p_start::date, v.p_end::date, v.gross, v.deductions, v.expected, v.actual, v.status
from channels c, (values
  ('Amazon - Seller Central', 'AMZ-SETTLE-2026-08-A', '2026-08-01', '2026-08-15', 6200, 930, 5270, 5270, 'reconciled'),
  ('Flipkart - Seller Hub', 'FK-SETTLE-2026-08-A', '2026-08-01', '2026-08-15', 4100, 615, 3485, 3180, 'short_pay'),
  ('Flipkart - Seller Hub', 'FK-SETTLE-2026-09-A', '2026-09-01', '2026-09-07', 2850, 427.50, 2422.50, null, 'pending')
) as v(channel_name, ext_id, p_start, p_end, gross, deductions, expected, actual, status)
where c.name = v.channel_name
on conflict (channel_id, external_settlement_id) do nothing;

-- Bank transactions: 2 matched to the settlements above, 2 genuinely unmatched
insert into bank_transactions (bank_account_id, txn_date, reference, amount, type, matched_entity, matched_reference_id, match_status)
select ba.bank_account_id, '2026-08-17'::date, 'NEFT-AMZN-IN-88213', 5270, 'credit', 'settlement', s.settlement_id, 'matched'
from bank_accounts ba, settlements s
where ba.bank_name like 'HDFC%' and s.external_settlement_id = 'AMZ-SETTLE-2026-08-A';

insert into bank_transactions (bank_account_id, txn_date, reference, amount, type, matched_entity, matched_reference_id, match_status)
select ba.bank_account_id, '2026-08-18'::date, 'NEFT-FKRT-IN-55102', 3180, 'credit', 'settlement', s.settlement_id, 'matched'
from bank_accounts ba, settlements s
where ba.bank_name like 'HDFC%' and s.external_settlement_id = 'FK-SETTLE-2026-08-A';

insert into bank_transactions (bank_account_id, txn_date, reference, amount, type)
select bank_account_id, '2026-09-05'::date, 'UPI-CR-7734209981', 1250, 'credit'
from bank_accounts where bank_name like 'ICICI%';

insert into bank_transactions (bank_account_id, txn_date, reference, amount, type)
select bank_account_id, '2026-09-03'::date, 'BANK-CHARGES-AUG26', 118, 'debit'
from bank_accounts where bank_name like 'HDFC%';

-- COD collections (Surat-area couriers): remitted, remitted, short_remit, pending-with-ageing
insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, collected_date, remitted_date)
select order_id, 'Delhivery - Sachin GIDC Surat', net_amount, net_amount, net_amount, 'remitted', current_date - 12, current_date - 8
from orders where external_order_id = 'FLIP-1008';

insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, collected_date, remitted_date)
select order_id, 'Ecom Express - Udhna Hub', net_amount, net_amount, net_amount, 'remitted', current_date - 10, current_date - 6
from orders where external_order_id = 'SHOP-1014';

insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, collected_date, remitted_date)
select order_id, 'DTDC - Ring Road Surat', net_amount, net_amount, 900, 'short_remit', current_date - 9, current_date - 4
from orders where external_order_id = 'SHOP-1009';

insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, collected_date)
select order_id, 'Bluedart - Surat City', net_amount, net_amount, 0, 'collected', current_date - 3
from orders where external_order_id = 'FLIP-1013';

-- Tax transactions: one of each matched_status
insert into tax_transactions (tax_type, period, source, document_ref, taxable_value, tax_amount, matched_status)
values
  ('GST', 'Aug 2026', 'Amazon settlement statement', 'GSTR1-AUG26-A', 4200, 756, 'matched'),
  ('GST', 'Sep 2026', 'Flipkart settlement statement', 'GSTR1-SEP26-A', 2100, 252, 'unmatched'),
  ('TDS', 'Aug 2026', 'Amazon 194-O deduction', '26AS-AUG26', 6200, 62, 'matched'),
  ('TCS', 'Aug 2026', 'Flipkart TCS collection', 'GSTR8-AUG26', 4100, 41, 'disputed');

-- Returns, RTOs, Claims, and the Credit Note + reversing voucher were created
-- by calling the actual workflow functions (disposition_return,
-- disposition_rto, advance_claim) as the correct role for each step, plus
-- one manually-posted CREDIT_NOTE voucher — see README for the full list of
-- which order became which state and why. Not reproduced here as flat SQL
-- because the whole point is that they went through the real, tested
-- functions rather than being inserted as fait-accompli final rows.
