-- ============================================================================
-- Super Seller 360 — GST correctness audit, part 1: state/GSTIN fields
--
-- Finding: the system had exactly one pooled "GST Payable (Output)" ledger
-- with no CGST/SGST/IGST split at all, and no state data anywhere —
-- structurally incapable of determining interstate vs intrastate for any
-- transaction, which Indian GST law requires to be shown and reported
-- separately. This is the data needed to even make that determination:
-- the company's registered state (GSTIN-linked) and each order's ship-to
-- state (place of supply).
-- ============================================================================
alter table companies add column state text;
alter table companies add column gstin text;
update companies set state = 'Gujarat', gstin = '24AAAAA0000A1Z5' where state is null;
alter table companies alter column state set not null;

alter table orders add column ship_to_state text;
