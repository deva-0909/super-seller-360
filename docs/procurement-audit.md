# Procurement audit — Requisition → PO → GRN (scan) → Invoice matching → Payment

Scope: branch-store requisition, purchase orders, goods receipt (with barcode/QR scan), supplier invoice matching, accounting. Based on migrations 0059, 0065, 0071, 0104 and live data.
Status: FINDINGS ONLY — nothing below has been built yet.

## Summary
The PO → GRN → bill chain exists, but it is a "happy path" chain. Nothing stops the same goods being billed twice, a bill being paid without a matching receipt, or a user raising, approving and receiving their own order. There is no requisition step at all.

Severity: **C** = money/stock can be lost or misstated, **H** = control gap, **M** = missing capability.

## A. Requisition (branch store → purchase)
| # | Sev | Finding |
|---|---|---|
| A1 | M | No requisition / indent module. Branches cannot formally request stock; requests happen off-system. |
| A2 | H | Reorder suggestions (`reorder_suggestions`) sum stock across all warehouses, so a branch that is out of stock is hidden by a warehouse that has plenty. |
| A3 | M | No link requisition → PO, so no way to see "what was asked, what was ordered, what arrived" per branch. |
| A4 | M | No branch-to-branch / warehouse transfer, so a requisition cannot be fulfilled from internal stock first. |

## B. Purchase order
| # | Sev | Finding |
|---|---|---|
| B1 | H | Single approval limit (₹50,000). Approvers whose own PO is under the limit are auto-approved — raiser and approver can be the same person. |
| B2 | H | No amendment / versioning. Changing qty or price after approval is not possible, or silently done outside the system. |
| B3 | M | No PO print / PDF to send to the supplier. |
| B4 | M | No freight, packing, discount or other charges on the PO, so landed cost is unknown. |
| B5 | M | No expected delivery date tracking or overdue-PO alerts. |
| B6 | M | PO is not attachable (attachment entity types lack PO and GRN). |

## C. Goods receipt (GRN)
| # | Sev | Finding |
|---|---|---|
| C1 | C | Before Round 20, receiving was by typed quantity only; Round 20 adds scanning but is not yet live (0104 not applied). |
| C2 | H | GRN checks only against the PO (10% over-tolerance). No supplier challan / delivery note number or photo captured. |
| C3 | H | No reversal, return-to-vendor (RTV) or quarantine/rejection flow after posting. A wrong GRN cannot be undone cleanly. |
| C4 | H | GRN date can be backdated without restriction or reason. |
| C5 | H | Receiver can be the same person who raised/approved the PO (no segregation of duties). |
| C6 | M | Direct stock-in (Round 20) has no approval, valuation or "unbilled" queue — a bypass of the PO chain if misused. |

## D. Invoice matching (3-way)
| # | Sev | Finding |
|---|---|---|
| D1 | C | Bill lines are built from *received − billed*. The supplier's invoice quantity and total are never captured, so the system cannot detect that the supplier billed more than delivered. |
| D2 | C | Price differences are returned to the screen but not stored; no tolerance, no hold, no approval of variance. |
| D3 | C | Generic `create_purchase_bill` has no PO/GRN link. Goods can be billed with no PO, or billed again on top of a PO bill. Live example: a ₹30,000 no-PO inventory bill; inventory ledger ₹9,91,640 vs stock at cost ₹9,61,640 (₹30,000 gap). |
| D4 | H | Nothing blocks payment of an unmatched or on-hold bill. |
| D5 | H | Supplier credit notes have no stock effect and no link to a return. |
| D6 | M | GST on the supplier invoice is not reconciled against PO tax. |

## E. Accounting
| # | Sev | Finding |
|---|---|---|
| E1 | H | No GRNI (goods received not invoiced) accrual — received stock is not in the books until the bill is approved, so month-end stock and payables are understated. |
| E2 | M | Cost is standard (`products.cost_price`); no weighted-average or landed cost, so COGS drifts from real purchase prices. |
| E3 | M | No aged "received, not billed" or "billed, not received" report. |

## F. Controls
| # | Sev | Finding |
|---|---|---|
| F1 | H | Segregation of duties is not enforced anywhere in the chain (seeded data shows one user raising, deciding and receiving). |
| F2 | H | Supplier master changes (bank details, GST) are not under maker-checker after activation. |
| F3 | M | Audit trail exists for stock (immutable transactions) but not for PO edits/approvals beyond status. |

## Proposed target flow ("full proof")
1. **Requisition** by branch (items, qty, needed-by) → branch manager approval → purchase consolidates into POs, or fulfils by transfer.
2. **PO** with charges, expected date, versions/amendments, tiered approval limits, PDF; raiser ≠ approver.
3. **Scan GRN** (Round 20 base): scan every unit, challan no. + photo, good/damaged/short/extra with reasons, quarantine, RTV; receiver ≠ PO approver; no backdating without approver.
4. **Supplier invoice capture** *after* GRN: invoice no., date, per-line qty/price/GST, total — compared with PO price and GRN received qty.
5. **3-way match** with configurable tolerances (qty, price, total). Within tolerance → auto-pass; outside → "On hold" with reason and approver; bills without PO/GRN only through an exception path.
6. **Payment block** on held/unmatched bills.
7. **GRNI accrual** posted at GRN, reversed on bill; landed cost / weighted-average cost option; direct stock-in goes to a review queue.
8. **Reports**: received-not-billed, billed-not-received, variance, overdue POs, requisition fulfilment per branch.

## Proposed build order
1. Safety net first: close D3/D4 (link bills to GRN, block double billing, payment block), apply 0104.
2. Invoice capture + 3-way match with tolerances and hold queue (D1, D2, D6).
3. GRN hardening: challan, reversal/RTV, quarantine, SoD, backdating (C2–C5).
4. PO upgrades: amendments, charges, PDF, tiered limits (B1–B6).
5. Requisition module + branch-aware reorder + transfers (A1–A4).
6. GRNI accrual and landed cost (E1–E3).

## Decisions (14 Oct 2026)
- Approval limits: **two tiers**. Up to the limit (₹50,000, `purchase_settings.po_approval_limit`) a Finance Manager or Super Admin approves; above it only the Owner (Super Admin / CEO-Owner).
- Match tolerance: **zero**. Any difference in price, quantity or total puts the bill on hold; only the Owner can release it (with a written reason, and not the person who entered it). Only a ₹1.00 round-off on the invoice total is ignored (`purchase_settings.match_round_off`).

## Round 21 (migration 0105) — built
- A PO is no longer auto-approved for its own raiser (unless "allow self approval" is on); `approval_level` records manager/owner.
- Supplier invoice capture: invoice no., date, per-line quantity and price, grand total, entered as printed.
- Three-way match (order price, goods received not yet billed, invoice total) → `matched` or `held`; held bills cannot be approved, so cannot be paid.
- Stock bills with no PO are held automatically (closes finding D3).
- Owner "Release hold" with a note.
Closes: B1 (partly), D1, D2, D3, D4. Still open: C2–C5, B2–B6, A1–A4, E1–E3, F2–F3.

## Round 22 (migration 0106) — receiving controls, built
- Challan number required; challan photo required on the scan screen and stored as proof on the receipt.
- Receipts can be dated at most 2 days back (`purchase_settings.grn_backdate_days`); only the Owner can record older ones.
- Whoever raised or approved a PO cannot receive its goods (unless "allow self approval" is on).
- Damaged/rejected quantity needs a written reason.
- Return to vendor (RTV): stock goes out, reason and gate-pass/debit-note reference recorded, billable quantity drops; warns when a supplier credit note is needed.
Closes: C2, C3, C4, C5. Still open: B2–B6, A1–A4, E1–E3, F2–F3, C6.
