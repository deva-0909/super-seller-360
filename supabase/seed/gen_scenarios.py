#!/usr/bin/env python3
"""Single source of truth for the returns & delivery scenario map.

Generates:
  docs/returns-delivery-scenario-map.md                  (the deep-dive reference, read by humans)
  supabase/migrations/0053_logistics_scenario_catalogue.sql  (feeds the in-app Scenario Map screen)

Run:  python3 supabase/seed/gen_scenarios.py
Support levels:  auto = the rule book posts the journal automatically      tracked = status tracked in the app, no journal needed
                 manual = possible today but a person must do/post it      gap = not in the app yet (recommendation given)
"""
import json, pathlib

G = {}   # group -> description
GROUPS = [
    ("A", "Forward delivery (warehouse to customer)", "Everything that can happen between dispatch and a happy customer."),
    ("B", "RTO - return to origin (undelivered)", "The parcel never reached the customer and comes back to us."),
    ("C", "Customer returns (reverse pickup)", "The customer received the parcel and sends it back."),
    ("D", "Exchanges and replacements", "Customer wants a different size/colour, or we owe a replacement."),
    ("E", "Cash on delivery (COD)", "Cash collected by the courier and remitted to us later."),
    ("F", "Marketplace settlements and fees", "Amazon / Flipkart / gateway payouts, fees and deductions."),
    ("G", "Claims and disputes", "Getting money back from couriers, marketplaces and suppliers."),
    ("H", "GST, valuation and period-end", "What the CA cares about when the books are closed."),
    ("I", "Warehouse and stock", "What physically happens to the goods that come back."),
]

S = []
def s(code, title, what, stock, acct, gst, claim, support, note, rules=()):
    S.append(dict(code=code, grp=code[0], title=title, what=what, stock=stock, acct=acct, gst=gst, claim=claim,
                  support=support, note=note, rules=list(rules)))

# ============================================================ A. Forward delivery
s("A01", "Delivered on first attempt - prepaid",
  "Courier delivers, customer has already paid online (UPI / card / wallet).",
  "Stock leaves the warehouse at dispatch.",
  "Invoice at dispatch: Dr Trade Receivables, Cr Sales, Cr GST. Money arrives later in the marketplace / gateway settlement (Dr Bank, Cr Trade Receivables).",
  "Output GST at the invoice; CGST+SGST within Gujarat, IGST outside.", "-", "auto", "Settlement receipt is rule-driven (STL-RECEIPT).", ["STL-RECEIPT"])
s("A02", "Delivered on first attempt - COD",
  "Courier hands over the parcel and collects cash.",
  "Stock leaves at dispatch.",
  "Invoice at dispatch (Dr Trade Receivables). When the courier collects: Dr COD Receivable from Couriers, Cr Trade Receivables. When the courier remits: Dr Bank, Cr COD Receivable.",
  "Same as A01.", "-", "auto", "", ["COD-COLLECTED", "COD-REMITTED"])
s("A03", "Delivery delayed beyond the promised date",
  "Weather, strikes, festival rush, hub congestion. Customer may cancel or the marketplace may penalise a late delivery.",
  "No change - goods are with the courier.",
  "No entry until there is an effect (cancellation -> A20, penalty -> bank/settlement deduction, compensation -> claim).",
  "-", "Possible: late-delivery penalty reversal on marketplaces.", "gap",
  "No promised-date / SLA tracking in the app. Recommend adding expected_delivery_date to orders and an 'overdue in transit' list.", ["BNK-PENALTY"])
s("A04", "Attempt failed - customer not available",
  "Door locked / phone not answered. Courier re-attempts (usually up to 3 times over 3-5 days).",
  "No change.", "No entry.", "-", "-", "tracked", "Order stays 'shipped'. Courier webhook can raise an RTO when attempts are exhausted.")
s("A05", "Attempt failed - address wrong or incomplete",
  "Missing landmark, wrong pincode, unreachable building. Courier raises an NDR (non-delivery report) and waits 48-72 h for the seller to fix it.",
  "No change.", "No entry. If not fixed in time the courier starts an RTO (see B01).",
  "-", "-", "gap", "No NDR queue in the app. Recommend an 'Action needed' list fed by the courier webhook so someone calls the customer before the parcel turns around.")
s("A06", "Customer asks to reschedule or change delivery slot",
  "Customer travelling / wants a weekend delivery.", "No change.", "No entry.", "-", "-", "tracked", "Courier-side action.")
s("A07", "Customer refuses at the door",
  "Changed mind, found it cheaper, did not order, parcel opened and rejected.",
  "Goods go back to the courier - RTO starts.", "See B01 / B03 - sale reversed when goods are received back.", "See B03.", "No.", "auto", "Treated as an RTO with reason 'Customer refused'.", ["RTO-REV-COD", "RTO-REV-PREPAID-D2C", "RTO-REV-OTHER"])
s("A08", "COD customer does not have the cash",
  "Customer is home but cannot pay.", "Becomes an RTO.", "See B11.", "See B03.", "No.", "auto", "Common on COD orders. Consider prepaid-only for risky pincodes.", ["RTO-REV-COD"])
s("A09", "Pincode not serviceable / out-of-delivery-area surcharge",
  "Courier accepted the booking but cannot deliver, or charges an ODA surcharge.",
  "Becomes an RTO if undeliverable.", "RTO as B01. ODA surcharge arrives as a freight bill (bank rule BNK-COURIER).", "Freight GST 18% as ITC.", "Maybe: surcharge dispute.", "auto", "", ["BNK-COURIER"])
s("A10", "Parcel stuck or misrouted at a hub",
  "No tracking movement for days; sorted to the wrong city.", "No change.", "No entry unless it becomes lost (A11).", "-", "Becomes a lost-shipment claim after the courier's no-movement limit (usually 15 days).", "tracked", "")
s("A11", "Parcel lost in transit",
  "Courier declares it lost. Customer gets a refund or replacement.",
  "Stock is gone - it will never be received back.",
  "Log as an RTO and mark it Claimed: sale reversed by credit note (RTO-REV-*). With the Inventory pack on, cost moves from COGS to Damaged & Lost Stock Loss. Raise a lost_shipment claim; recognise Dr Claims Receivable / Cr Claim Recoveries only when approved.",
  "Credit note reverses output GST. ITC on the lost goods is reversed under Sec 17(5)(h) if the loss is not recovered.",
  "Yes - lost_shipment claim against the courier (limit is usually declared value, capped).", "auto", "Add the claim from the Claims screen straight away so the deadline clock is tracked.", ["RTO-REV-COD", "RTO-REV-PREPAID-D2C", "RTO-REV-OTHER", "INV-WRITEOFF-RTO", "CLM-APPROVED", "CLM-RECOVERED"])
s("A12", "Parcel damaged in transit",
  "Torn bag, water damage, crushed box. Customer refuses it or accepts and returns it.",
  "Damaged goods come back (RTO) or are returned (C-group).",
  "Credit note as RTO / return. Inspect as 'damaged' -> Claimed. Claim against the courier.",
  "Credit note reverses GST.", "Yes - damaged_return claim.", "auto", "Photos at unboxing are what win these claims.", ["RTO-REV-COD", "RET-CN-D2C", "RET-CN-MKT", "INV-WRITEOFF-RTO", "INV-WRITEOFF-RETURN"])
s("A13", "Partial delivery - one box of a multi-box order missing",
  "Order shipped in two cartons, one arrives.", "Part of the stock is with the customer, part is missing.",
  "Needs a partial credit note for the missing part.", "Credit note for the missing value only.", "Yes - lost_shipment for the missing carton.", "gap",
  "The app reverses whole invoices only. Recommend line-level returns/credit notes (see C20).")
s("A14", "Order split across two warehouses",
  "Surat has some SKUs, the Mumbai 3PL has the rest.", "Each warehouse is reduced separately.", "One invoice, two stock movements.", "Place of supply is unchanged.", "-", "gap",
  "Orders ship from one warehouse today. Recommend per-line warehouse on order lines.")
s("A15", "Wrong item dispatched (our mistake)",
  "Picker sent the wrong size / colour / style.", "Wrong item comes back, right item goes out.",
  "Return with reason 'Wrong item received' (credit note + restock), then a fresh replacement order. No claim - this is our own cost.",
  "Credit note + new invoice.", "No (seller error).", "auto", "Track picking accuracy separately - it is a process leak, not a courier problem.", ["RET-CN-D2C", "RET-CN-MKT"])
s("A16", "Short quantity or missing accessory",
  "Combo set missing a piece, dupatta not in the packet.", "Customer keeps most of it.",
  "Partial refund -> manual credit note, or full return.", "Credit note for the difference.", "Sometimes (if packed correctly and courier tampered).", "manual", "Partial credit notes are manual today (C19).")
s("A17", "Customer says 'not received' but tracking shows delivered",
  "Fake claim, wrong-person delivery, neighbour/security accepted it.", "Goods are with the customer (or lost).",
  "If we are forced to refund: marketplace chargeback / A-to-Z deduction shows in settlement or bank (BNK-PENALTY, review) and is disputed with proof of delivery.",
  "No reversal of the invoice unless we accept the refund.", "Yes - dispute with POD / OTP / photo evidence.", "manual", "", ["BNK-PENALTY"])
s("A18", "Customer cancels before dispatch",
  "Order is paid but cancelled before an invoice exists.", "Reserved stock is released.",
  "No sales entry (no invoice yet). Prepaid refund goes back via the gateway; the gateway fee is not refunded - it stays an expense (BNK-GATEWAY).",
  "None.", "No.", "tracked", "The cancel hook only fires when an invoice exists, so cheap pre-dispatch cancellations do not create noise.", ["BNK-GATEWAY"])
s("A19", "Seller cancels (out of stock, price error, fraud suspicion)",
  "We cannot fulfil. Marketplaces charge a cancellation penalty to the seller.", "Reserved stock is released.",
  "No sales entry. Marketplace penalty: Dr Marketplace Penalties & Chargebacks (review).", "No GST on a penalty.", "Dispute if the cancellation was not ours.", "auto", "", ["BNK-PENALTY"])
s("A20", "Cancelled after dispatch (intercept)",
  "Customer or seller asks the courier to stop and return the parcel.", "Goods come back as an RTO.",
  "As B01-B03. Both-way freight is a cost (BNK-COURIER, BNK-RTO-CHARGES).", "Credit note on receipt.", "No.", "auto", "", ["RTO-REV-COD", "RTO-REV-PREPAID-D2C", "RTO-REV-OTHER", "BNK-RTO-CHARGES"])
s("A21", "Cancelled after invoicing, before the courier picks up",
  "Invoice exists but the goods never left.", "Stock returns to available.",
  "Order marked Cancelled -> credit note posts automatically (own store prepaid: Cr Customer Refunds Payable; otherwise Cr Trade Receivables).",
  "Credit note reverses GST.", "No.", "auto", "Order must have an invoice for the hook to fire.", ["ORD-CANCEL-D2C-PREPAID", "ORD-CANCEL-OTHER"])
s("A22", "Fake / prank / duplicate order",
  "Typical on COD: wrong phone number, someone else's address, same order placed twice.", "Becomes an RTO.",
  "As B11. The cost is the two-way freight plus packaging.", "Credit note on receipt.", "No.", "gap",
  "No risk scoring. Recommend a per-pincode and per-customer RTO rate on the Insights screen to push risky COD orders to prepaid.", ["RTO-REV-COD"])
s("A23", "Delivered to the wrong person",
  "Neighbour / watchman / wrong flat.", "Goods are with someone else.", "Treat like A17 and file a lost-shipment claim if the courier agrees it was mis-delivered.",
  "-", "Yes.", "manual", "")

# ============================================================ B. RTO
s("B01", "RTO initiated by the courier",
  "Three failed attempts, refusal, wrong address left unfixed, or seller instruction.", "Goods are travelling back (RTO in transit). Not in any warehouse yet.",
  "No entry yet - the sale is only reversed when the goods are physically received back.",
  "Output GST stays until the credit note.", "-", "tracked", "Courier webhook creates the RTO as 'initiated' / 'in transit'. Your CA may prefer reversing at initiation; the hook fires on receipt - change the event if policy differs.")
s("B02", "RTO in transit (4-10 days)",
  "Reverse leg of the journey; same delays and loss risks as the forward leg.", "In transit.", "No entry.", "-", "Lost on the way back -> B07.", "tracked", "")
s("B03", "RTO received - parcel intact, goods resaleable",
  "Seal intact, tags intact, quantities match.",
  "Restocked into the chosen warehouse. With the Inventory pack: Dr Inventory, Cr COGS.",
  "Credit note posts automatically: Dr Sales Returns & RTO Reversals, Dr CGST/SGST or IGST, Cr Trade Receivables (COD / marketplace) or Cr Customer Refunds Payable (own-store prepaid).",
  "Credit note mirrors the invoice's GST split. Appears in the GST summary credit notes.", "No.", "auto", "A second event (inspected, restocked) never double-posts.", ["RTO-REV-COD", "RTO-REV-PREPAID-D2C", "RTO-REV-OTHER", "INV-RTO-RESTOCK"])
s("B04", "RTO received - damaged by the courier",
  "Torn, crushed, wet, tampered.", "Quarantined; not available to sell.",
  "Credit note as B03. Inspection 'damaged' -> Claimed. With the Inventory pack: cost moves from COGS to Damaged & Lost Stock Loss. Claim approved -> Dr Claims Receivable, Cr Claim Recoveries.",
  "Credit note reverses GST. Claim recovery is not a supply (no GST).", "Yes - damaged_return against the courier.", "auto", "", ["RTO-REV-COD", "RTO-REV-PREPAID-D2C", "RTO-REV-OTHER", "INV-WRITEOFF-RTO", "CLM-APPROVED", "CLM-RECOVERED"])
s("B05", "RTO received - different item inside (swapped)",
  "Customer or someone en route swapped the garment for a cheap one.", "Wrong item quarantined.",
  "As B04, inspection 'wrong_item'. Evidence: unboxing video, weight at dispatch vs receipt.", "As B04.", "Yes - against the courier or (marketplaces) SAFE-T / SPF.", "auto", "", ["INV-WRITEOFF-RTO", "CLM-APPROVED"])
s("B06", "RTO received - used, washed, tag removed",
  "Worn once and refused.", "Quarantined -> may be resold as B-grade.",
  "Credit note as B03. Stock is held in quarantine (no write-off by default). If sold as B-grade at a discount, the difference is a loss.", "As B03.", "Sometimes.", "auto", "Quarantine is not written off automatically because it may be resold - change the rule condition if your policy differs.", ["RTO-REV-COD", "RTO-REV-OTHER"])
s("B07", "RTO never arrives (lost on the way back)",
  "Courier shows RTO delivered / lost but the warehouse never receives it.", "Stock is gone.",
  "Mark RTO Claimed -> credit note + write-off + lost_shipment claim, as A11.", "As A11.", "Yes - lost_shipment.", "auto", "", ["INV-WRITEOFF-RTO", "CLM-APPROVED"])
s("B08", "RTO received after the month (or year) was closed",
  "Parcel arrives weeks later.", "Restocked when it arrives.",
  "Credit note is dated the day it is processed, in the current OPEN period - closed periods are never reopened.",
  "Sec 34(2): credit notes must be issued by 30 November after the financial year-end or the annual return date, whichever is earlier, or the output-tax reduction is lost.", "-", "auto", "If the date falls in a closed period the event is logged as an error for the accountant, never silently dropped.")
s("B09", "RTO of a prepaid own-store order",
  "Customer paid on Shopify, parcel returned.", "As B03.",
  "Credit note creates Customer Refunds Payable. Pay the refund from the bank and record it (refund rule: Dr Customer Refunds Payable, Cr Bank).",
  "As B03.", "-", "partial", "There is no refund screen for RTOs (only for customer returns). Recommend adding a 'Mark refunded' action on the RTO page.", ["RTO-REV-PREPAID-D2C", "RET-REFUND-D2C"])
s("B10", "RTO of a prepaid marketplace order",
  "Marketplace refunds the customer and adjusts our payout.", "As B03.",
  "Credit note reduces Trade Receivables (what the marketplace owes us). No bank entry - the marketplace nets it in a settlement.", "As B03.", "-", "auto", "", ["RTO-REV-OTHER"])
s("B11", "RTO of a COD order",
  "No cash was ever collected.", "As B03.",
  "Credit note reduces Trade Receivables (nothing was collected from the customer). The real cost is freight both ways + the COD handling fee.", "As B03.", "No.", "auto", "", ["RTO-REV-COD", "BNK-RTO-CHARGES"])
s("B12", "RTO charges and COD fees",
  "Forward freight + reverse freight + COD fee are non-refundable. Marketplaces show an 'RTO fee' inside settlements.", "-",
  "Courier bills paid from the bank: Dr Reverse Logistics & RTO Charges, Dr ITC (18%), Cr Bank. Settlement deductions are currently booked as one commission expense.",
  "18% GST on courier services is input credit.", "Dispute wrong charges.", "partial",
  "Courier bills: automatic. Settlement fees are lumped together - recommend splitting by fee_type (commission / shipping / RTO / gateway) into separate expense ledgers.", ["BNK-RTO-CHARGES", "BNK-COURIER"])
s("B13", "Chronic RTO pincodes and customers",
  "30-40% RTO in some regions on COD.", "-", "-", "-", "-", "gap",
  "Recommend RTO rate by pincode / courier / SKU on the Business Insights screen.")
s("B14", "Courier re-attempts after RTO was initiated",
  "Customer calls and accepts delivery after all.", "Back to forward delivery.", "No entry (nothing was posted at initiation).", "-", "-", "gap",
  "An RTO cannot be cancelled in the app. Recommend a 'Cancel RTO / re-attempt' action.")

# ============================================================ C. Customer returns
s("C01", "Return policy and window",
  "7 / 10 / 15 / 30 day windows; non-returnable items (innerwear, altered or customised pieces, sarees with falls attached).", "-", "No entry.", "-", "-", "gap",
  "The app does not enforce a return window or category rules. Recommend a window per category and a warning on late return requests.")
s("C02", "Return requested -> approved -> pickup scheduled",
  "Customer raises it, support approves, courier pickup is booked.", "Goods still with the customer.", "No entry.", "-", "-", "tracked", "Statuses: Requested, Approved, Pickup, In transit.")
s("C03", "Pickup fails - customer not ready / not available",
  "Reverse pickup attempts fail up to 3 times; request auto-closes.", "No change.", "No entry. Reverse pickup fee may still be billed (BNK-RTO-CHARGES).", "-", "-", "tracked", "", ["BNK-RTO-CHARGES"])
s("C04", "Customer self-ships the return",
  "Remote area without pickup; customer sends it by post/courier and is reimbursed.", "Goods arrive at the warehouse.",
  "Reimbursement: Dr Reverse Logistics & RTO Charges, Cr Bank.", "GST only if the customer provides a valid invoice (rare).", "-", "manual", "", ["BNK-RTO-CHARGES"])
s("C05", "Reason: size / fit",
  "Top reason in garments (30-40% of returns). Wrong size ordered or the brand runs small/large.", "Restock if tags intact.",
  "Credit note (C13). Consider an exchange (D01) rather than a refund to keep the sale.", "As C13.", "No.", "auto", "Track fit-returns by SKU and size to fix the size chart.", ["RET-CN-D2C", "RET-CN-MKT"])
s("C06", "Reason: colour / look different from the photo",
  "Fabric shade differs on screen vs in hand.", "Restock if tags intact.", "Credit note (C13).", "As C13.", "No.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT"])
s("C07", "Reason: quality / stitching / fabric defect",
  "Seams open, colour bleeds, fabric thin - seller-side problem.", "Quarantine; not resold as new.",
  "Credit note (C13). Inspection 'damaged' -> Claimed with the Inventory pack: cost moves to Damaged & Lost Stock Loss. Supplier / karigar debit note is manual.",
  "As C13.", "Supplier recovery (not a courier claim).", "partial", "No supplier debit-note flow. Recommend a defect register by supplier / production lot.", ["RET-CN-D2C", "RET-CN-MKT", "INV-WRITEOFF-RETURN"])
s("C08", "Reason: damaged on arrival",
  "Transit damage reported on delivery.", "Quarantine.", "Credit note + write-off + damaged_return claim against the courier.", "As C13.", "Yes - courier.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT", "INV-WRITEOFF-RETURN", "CLM-APPROVED"])
s("C09", "Reason: wrong item received",
  "See A15 - our picking error.", "Restock the returned item.", "Credit note + replacement (D03).", "As C13.", "No.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT"])
s("C10", "Reason: changed mind / found cheaper / not needed",
  "No fault anywhere.", "Restock if unused.", "Credit note (C13). Some marketplaces charge the customer a fee instead.", "As C13.", "No.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT"])
s("C11", "Reason: delivered too late",
  "Event or festival has passed.", "Restock if unused.", "Credit note (C13).", "As C13.", "Maybe: late-delivery compensation from the courier.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT"])
s("C12", "Reason: missing piece in a set / combo",
  "Kurta set without the dupatta.", "Restock what comes back.", "Full return (C13) or partial credit note (C19).", "As C13.", "Maybe.", "partial", "", ["RET-CN-D2C"])
s("C13", "Return received - good condition",
  "Tags intact, unwashed, as sent.", "Restocked into the chosen warehouse. With the Inventory pack: Dr Inventory, Cr COGS at cost.",
  "Credit note posts automatically: Dr Sales Returns, Dr GST (same split as the invoice), Cr Customer Refunds Payable (own store) or Cr Trade Receivables (marketplace).",
  "Appears in the GST summary under credit notes; reduces output tax in the month it is issued.", "No.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT", "RET-CN-OTHER", "INV-RETURN-RESTOCK"])
s("C14", "Return received - worn, washed, stained, perfume smell, tags removed",
  "'Wardrobing' - worn once and returned.", "Quarantined; may be resold as B-grade.",
  "Options: reject the refund (C18) or accept with a deduction (C19). Default: credit note + quarantine.", "As C13.", "Sometimes.", "partial",
  "Deduction-based partial refunds are manual (C19).", ["RET-CN-D2C", "RET-CN-MKT"])
s("C15", "Return received - a different item sent back",
  "Customer sends back a cheaper garment, or a brick in the box.", "Wrong item quarantined.",
  "Refund should be withheld / reversed. Marketplace: SAFE-T / SPF claim. Inspection 'wrong_item' -> Claimed.", "Credit note only if the refund is finally granted.", "Yes - marketplace protection claim.", "partial", "", ["INV-WRITEOFF-RETURN", "CLM-APPROVED"])
s("C16", "Return received - empty box / missing items",
  "Parcel arrived light.", "Nothing to restock.", "As C15, inspection 'missing'.", "As C15.", "Yes - courier (tampering) or marketplace.", "partial", "", ["CLM-APPROVED"])
s("C17", "Return received - damaged",
  "Torn or soiled beyond normal use.", "Quarantined / written off.", "Credit note (if refund granted) + write-off with the Inventory pack. Claim if the damage happened in transit.", "As C13.", "Sometimes.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT", "INV-WRITEOFF-RETURN"])
s("C18", "Return rejected at inspection",
  "Does not meet the return policy (outside window, used, no tags).", "Returned to the customer (RTC).",
  "No credit note, no revenue reversal. Refund status Rejected. Outbound freight to send it back is an expense.", "None.", "No.", "tracked",
  "The credit-note hook only fires on received / inspected / restocked / quarantined / claimed. A 'rejected' return posts nothing.", ["BNK-COURIER"])
s("C19", "Partial refund (deduction for wear, missing tag, restocking fee)",
  "Customer is refunded less than the invoice.", "Restock or quarantine.", "Needs a credit note for the refunded value only.", "Credit note for the reduced value; GST recomputed on it.", "No.", "gap",
  "Credit notes are whole-invoice today. Recommend a partial credit-note amount on the return.")
s("C20", "Partial return - 1 of 3 items sent back",
  "Multi-item order, only some pieces returned.", "Only the returned lines restock.", "Credit note for the returned lines only.", "GST on the returned lines.", "-", "gap",
  "disposition_return() restocks every line of the order, and the credit note covers the whole invoice. Recommend line-level returns (return_lines table). Highest-value next improvement for returns.")
s("C21", "Return lost in reverse transit",
  "Reverse pickup lost by the courier.", "Stock gone.", "Credit note + write-off + claim, as A11 / B07.", "As A11.", "Yes - lost_shipment.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT", "INV-WRITEOFF-RETURN", "CLM-APPROVED"])
s("C22", "Refund of a COD order",
  "Customer paid cash, wants money back.", "As C13.", "Credit note creates a refund liability; pay by NEFT/UPI and record the refund: Dr Customer Refunds Payable, Cr Bank. Wrong bank details = failed refund (loop).", "As C13.", "-", "auto", "", ["RET-CN-D2C", "RET-REFUND-D2C"])
s("C23", "Refund mode: original source, store credit, bank transfer",
  "Card/UPI refunds go back instantly via the gateway; store credit keeps the money with us.", "-",
  "Gateway/UPI/bank refund: Dr Customer Refunds Payable, Cr Bank. Store credit keeps the liability open until redeemed (leave Customer Refunds Payable, or add a Store Credit ledger).",
  "Store credit issued against a return is not a new supply; GST on the eventual redemption sale.", "-", "partial", "Store-credit liability has no ledger or screen yet.", ["RET-REFUND-D2C"])
s("C24", "Refund timing: instant on pickup vs after quality check",
  "Marketplaces refund the customer early to trusted buyers.", "-",
  "Our credit note posts when goods are physically received; the marketplace's early refund is netted in settlement.", "Credit note date = date we process it.", "-", "auto", "", ["RET-CN-MKT", "RET-REFUND-MKT"])
s("C25", "Refund fails or customer disputes with the bank",
  "Wrong account number, card closed, chargeback.", "-", "Chargeback fee / penalty: Dr Marketplace Penalties & Chargebacks. Refund liability stays open until paid.", "No GST on penalties.", "Dispute with evidence.", "manual", "", ["BNK-PENALTY"])
s("C26", "Marketplace-fulfilled returns (grading at the fulfilment centre)",
  "Amazon / Flipkart receive the return and grade it: sellable, unsellable, customer-damaged, carrier-damaged, defective.", "Marketplace stock, not ours until returned to us.",
  "Credit note as C13 when we confirm receipt/grade; carrier-damaged -> platform reimburses (claim).", "As C13.", "Yes - SAFE-T / SPF for carrier-damaged or not received.", "partial",
  "Grades map onto the app's four results (good / damaged / wrong_item / missing). Recommend a 'grade' field to keep the platform's wording.", ["RET-CN-MKT", "CLM-APPROVED"])
s("C27", "Return never reaches the seller but the customer was refunded",
  "Marketplace refunded early; parcel lost or returned to the wrong place.", "Stock gone.", "Claim reimbursement from the marketplace within its window.", "-", "Yes.", "manual", "", ["CLM-APPROVED"])
s("C28", "Return of a discounted / coupon order",
  "Customer paid less than list price.", "As C13.", "Credit note is for the amount actually paid (the invoice value), not the list price.", "GST on the paid value.", "No.", "auto", "Credit-note amounts come from the invoice, so discounts are respected.", ["RET-CN-D2C", "RET-CN-MKT"])
s("C29", "Serial returners / wardrobing",
  "A few customers account for a large share of returns.", "-", "-", "-", "-", "gap", "Recommend a repeat-returner list and a return-rate by customer.")

# ============================================================ D. Exchanges / replacements
s("D01", "Exchange - size or colour swap",
  "Customer sends back M and wants L.", "M comes back (restock); L goes out.",
  "Model it as a return (credit note, restock) plus a new order for the replacement. Price difference is collected / refunded on the new order.", "Credit note for the old invoice; fresh invoice for the new.", "No.", "partial",
  "No exchange object linking the two orders. Recommend an 'Exchange' return type that auto-creates the replacement order.", ["RET-CN-D2C", "RET-CN-MKT"])
s("D02", "Exchange not possible - replacement size out of stock",
  "Customer wanted L, only M was available.", "M returns.", "Converts to a normal refund (C13).", "As C13.", "No.", "auto", "", ["RET-CN-D2C", "RET-CN-MKT"])
s("D03", "Free replacement for a defective or wrong item",
  "We ship a new piece at no charge.", "New piece leaves stock; defective piece is written off or returned to supplier.",
  "Credit note for the original, zero-value (or no) invoice for the replacement; cost of the replacement is a loss (Damaged & Lost Stock Loss).", "Zero-value supply - confirm treatment with your CA.", "Supplier recovery.", "manual", "", ["INV-ADJ-LOSS"])

# ============================================================ E. COD
s("E01", "COD cash collected by the courier",
  "Courier collects at the door.", "-", "Dr COD Receivable from Couriers, Cr Trade Receivables. The money now sits with the courier.", "-", "-", "auto", "", ["COD-COLLECTED"])
s("E02", "COD remitted in full",
  "Courier pays out T+2 to T+7 / weekly.", "-", "Dr Bank, Cr COD Receivable from Couriers.", "-", "-", "auto", "", ["COD-REMITTED"])
s("E03", "COD remitted short",
  "Courier deducts a COD fee (about 1.5-2.5% or Rs25-40 per parcel), or amounts don't tally.", "-",
  "Remitted part posts normally; the balance stays visible in COD Receivable (status short_remit). Fee deductions: add a rule line (Dr Freight & Courier Charges + ITC) or book from the courier invoice.",
  "COD fee is a service (18% GST, ITC).", "Yes - incorrect_deduction.", "partial", "Fee-from-remittance is not split automatically.", ["COD-REMITTED", "CLM-APPROVED-DEDUCTION"])
s("E04", "COD collected amount differs from order value",
  "Customer negotiated, no change, or paid part.", "-", "Collected amount is what moves into COD Receivable; the difference remains in Trade Receivables to be written off or recovered.", "Discount after invoice -> credit note.", "-", "manual", "")
s("E05", "COD order returned after cash was collected",
  "Customer paid, then returns the item.", "As C13.", "Credit note creates a refund liability; refund paid from the bank.", "As C13.", "-", "auto", "", ["RET-CN-D2C", "RET-REFUND-D2C"])
s("E06", "Courier delays remittance",
  "Cash sits with the courier beyond the agreed cycle.", "-", "Outstanding in COD Receivable from Couriers - age it and chase.", "-", "Escalate / interest.", "tracked", "COD screen lists pending remittances.")
s("E07", "Unidentified COD credit in the bank",
  "Lump-sum NEFT from a courier with no order breakdown.", "-", "Left unmatched on purpose (BNK-IGNORE-SETTLEMENT) so the COD screen reconciles it; does not hit the books twice.", "-", "-", "auto", "", ["BNK-IGNORE-SETTLEMENT"])
s("E08", "Courier default / write-off",
  "Courier shuts down owing cash.", "-", "Dr Short-Pay & Bad Debts Written Off, Cr COD Receivable from Couriers (manual journal).", "Bad-debt GST treatment: CA to confirm.", "Legal recovery.", "manual", "")

# ============================================================ F. Marketplace settlements
s("F01", "Settlement received in full",
  "Payout equals gross sales minus fees.", "-", "Fees and ITC are booked on reconciliation. The receipt: Dr Bank, Cr Trade Receivables.", "ITC on the 18% GST in fees.", "-", "auto", "", ["STL-RECEIPT"])
s("F02", "Settlement short-paid",
  "Bank received less than the statement says.", "-", "Dr Bank (actual), Dr Settlement Short-Pay Receivable (shortfall), Cr Trade Receivables (expected). Raise an incorrect_deduction claim.", "-", "Yes.", "auto", "", ["STL-RECEIPT", "CLM-APPROVED-DEDUCTION"])
s("F03", "Settlement paid in excess",
  "Payout is more than expected (reversal of an earlier deduction, error).", "-", "Cr Settlement Excess Received - a liability until explained or returned.", "-", "-", "auto", "", ["STL-RECEIPT"])
s("F04", "Commission, closing fee, shipping fee, collection fee",
  "Marketplace deductions with 18% GST.", "-", "Booked on reconciliation as Marketplace Commission Expense + GST Input Tax Credit.", "ITC claim on the marketplace's tax invoice.", "Dispute wrong rates.", "partial",
  "All deductions land in one expense ledger. Recommend fee-type ledgers (commission, shipping, closing, collection, RTO).")
s("F05", "Commission refunded on returns",
  "Marketplaces return part of the commission when an item is returned, but keep fixed fees and shipping.", "-", "Appears as a credit in the next settlement.", "ITC reversal on the refunded part.", "Check the calculation.", "gap",
  "Settlement lines model deductions only, not refund-type credits.")
s("F06", "GST TCS and income-tax TDS on payouts",
  "Marketplace collects GST TCS (0.5% as of 2025; confirm current rate) and TDS under Sec 194-O (0.1% as of 2025; confirm) before paying you.", "-",
  "Dr GST TCS Credit Receivable and Dr TDS Receivable, reducing the cash received. Claimed in GSTR-2B / Form 26AS.", "TCS credit is set off in GSTR-3B; TDS against income tax.", "-", "gap",
  "Ledgers exist but settlements do not capture TCS/TDS yet. Recommend two extra settlement fields and lines in STL-RECEIPT.")
s("F07", "Payout withheld as a reserve / hold",
  "Marketplace holds funds for the return window or a pending dispute.", "-", "Stays in Trade Receivables until released.", "-", "-", "tracked", "")
s("F08", "Penalties (late dispatch, cancellations, high RTO / return rate)",
  "Deducted from the payout.", "-", "Dr Marketplace Penalties & Chargebacks.", "No GST on penalties.", "Dispute where not our fault.", "partial", "In settlements these are lumped into deductions; paid by bank they use BNK-PENALTY.", ["BNK-PENALTY"])
s("F09", "Advertising and promotion fees inside the settlement",
  "Sponsored-product charges netted from the payout.", "-", "Should be Advertising & Promotion expense with ITC.", "18% GST.", "-", "gap", "Needs fee-type split (F04).", ["BNK-ADS"])
s("F10", "Marketplace reimburses lost / damaged inventory",
  "Credit appears in a settlement for goods lost at the fulfilment centre.", "-", "Dr Bank, Cr Claims Receivable (or Claim Recoveries if not pre-booked).", "No GST.", "Yes.", "partial", "", ["CLM-RECOVERED"])

# ============================================================ G. Claims
s("G01", "Lost-shipment claim against the courier",
  "Compensation is usually the declared value up to a cap; strict filing deadlines.", "Stock already written off.", "Booked only on approval: Dr Claims Receivable, Cr Claim Recoveries. Recovery: Dr Bank, Cr Claims Receivable.", "Compensation is not a supply.", "-", "auto", "Contingent assets are not booked until recovery is virtually certain.", ["CLM-APPROVED", "CLM-RECOVERED"])
s("G02", "Damaged-in-transit claim",
  "Needs unboxing photos / video and the damage report.", "Goods quarantined or written off.", "As G01.", "As G01.", "-", "auto", "", ["CLM-APPROVED", "CLM-RECOVERED"])
s("G03", "Weight discrepancy / volumetric weight overcharge",
  "Courier bills more weight than shipped.", "-", "Approved recovery should reduce the freight expense, not be income. Default deduction rule credits Marketplace Commission Expense - add a rule for courier claims if you want Freight.", "ITC adjustment.", "Yes - excess_deduction.", "partial", "", ["CLM-APPROVED-DEDUCTION"])
s("G04", "Wrongly deducted marketplace fee",
  "Wrong commission slab, duplicate fee.", "-", "Approved: Dr Claims Receivable, Cr Marketplace Commission Expense.", "ITC adjustment.", "Yes - incorrect_deduction.", "auto", "", ["CLM-APPROVED-DEDUCTION"])
s("G05", "Claim filed after the deadline",
  "Window missed.", "-", "Nothing was booked, so nothing to reverse. The loss stays in expenses.", "-", "Lost.", "tracked", "Deadline is stored per claim.")
s("G06", "Claim partially approved",
  "Approved amount is lower than claimed.", "-", "Booked at the approved amount.", "-", "Yes.", "auto", "", ["CLM-APPROVED"])
s("G07", "Claim rejected",
  "Evidence insufficient or policy excludes it.", "-", "No entry by default (nothing was recognised on filing).", "-", "Appeal.", "auto", "A claim.rejected event exists so you can attach a rule if your CA wants a write-off.")
s("G08", "Claim recovered in instalments or via a settlement credit",
  "Money arrives in pieces.", "-", "Each recovery posts its own entry (Dr Bank, Cr Claims Receivable) for the amount received that time.", "-", "-", "auto", "", ["CLM-RECOVERED"])
s("G09", "Supplier claim for defective goods",
  "Quality defect traced to a supplier or karigar.", "Defective stock returned to the supplier.", "Debit note to the supplier; Dr Supplier Payable, Cr Purchases / Inventory.", "Debit note adjusts input tax.", "Yes.", "gap", "No suppliers or purchases module yet.")

# ============================================================ H. GST, valuation, period end
s("H01", "Credit-note time limit (Sec 34(2))",
  "Output tax can be reduced only if the credit note is issued by 30 November following the financial year, or the annual return date, whichever is earlier.", "-", "Credit notes are dated when processed.", "Hard statutory limit.", "-", "tracked", "Process year-end returns before the cut-off.")
s("H02", "Credit note mirrors the original GST split",
  "Intrastate sale reversed with CGST+SGST; interstate with IGST.", "-", "Handled automatically from the invoice.", "Required.", "-", "auto", "", ["RET-CN-D2C", "RET-CN-MKT", "RTO-REV-COD"])
s("H03", "ITC reversal on goods lost, stolen or destroyed",
  "Sec 17(5)(h): ITC on stock lost or written off must be reversed.", "-", "Add a line to the write-off rules: Dr Damaged & Lost Stock Loss, Cr GST Input Tax Credit.", "ITC reversal.", "If the loss is recovered from the courier, ask your CA whether the reversal still applies.", "partial", "Documented on the rule; not on by default.", ["INV-ADJ-LOSS"])
s("H04", "Inventory write-down to net realisable value",
  "B-grade and aged seasonal stock sells below cost.", "Quantity unchanged, value lower.", "Dr Damaged & Lost Stock Loss (or Inventory write-down), Cr Inventory. Manual journal at period end.", "-", "-", "manual", "The stock time-out feature flags the SKUs that need this.")
s("H05", "Provision for expected returns at month-end",
  "Sales made in the last days of a month will be returned next month; many CAs book a provision based on the historical return rate.", "-", "Dr Sales Returns, Cr Provision for Returns; reversed next month. A period-end batch job - not automated.", "None until the credit notes are issued.", "-", "gap", "Recommend a period-end 'returns provision' helper using the last 90 days' return rate.")
s("H06", "Cut-off: RTO and returns in transit at month-end",
  "Goods on their way back when the period closes.", "Not in the warehouse.", "Revenue is reversed only on receipt, so it stays in the old month. Disclose / provide.", "-", "-", "tracked", "")
s("H07", "Round-off differences",
  "Paise differences between invoice, refund and gateway.", "-", "Small differences: add a Round Off line using the remainder balancing figure.", "-", "-", "manual", "Rules support a balancing-figure line.")

# ============================================================ I. Warehouse / stock
s("I01", "Goods received note for returns",
  "Quantity received vs expected; photos at the dock.", "Count checked.", "No entry.", "-", "-", "tracked", "Received date is stored; inspection result records the outcome.")
s("I02", "Quality grading - A, B, C, D",
  "A: resell as new. B: minor defect, discount. C: repair / re-pack. D: scrap or donate.", "A restocks; B/C quarantined; D written off.", "A: Dr Inventory, Cr COGS. D: Dr Damaged & Lost Stock Loss.", "-", "-", "partial", "The app has good / damaged / wrong_item / missing + restocked / quarantined / claimed. Recommend a grade field.", ["INV-RETURN-RESTOCK", "INV-WRITEOFF-RETURN"])
s("I03", "Restock into which warehouse",
  "Own warehouse vs the nearest 3PL.", "Goes to the selected warehouse.", "No entry (same company).", "Stock transfer between GSTINs would need a delivery challan.", "-", "tracked", "Warehouse is chosen when dispositioning.")
s("I04", "Quarantine bin",
  "Held for inspection, repair or claim evidence.", "Not counted as available stock.", "No entry unless it is written off.", "-", "-", "tracked", "Only restocked goods enter the sellable balance.")
s("I05", "Cycle-count differences",
  "Count differs from the system.", "Adjusted up or down.", "Shortage: Dr Damaged & Lost Stock Loss, Cr Inventory. Excess: reverse.", "ITC reversal on shortage (H03).", "-", "auto", "Inventory pack.", ["INV-ADJ-LOSS", "INV-ADJ-GAIN"])
s("I06", "Return with an unmapped SKU",
  "Product on the order line has no SKU mapping.", "Not restocked - the app warns.", "No inventory movement, so no COGS entry.", "-", "-", "tracked", "Map the SKU, then restock manually.")
s("I07", "Aged returned stock (seasonal garments)",
  "Returned winterwear in March loses value.", "Sits in stock.", "Write-down (H04).", "-", "-", "tracked", "Per-SKU stock time-out highlights these on the Inventory screen.")

# ------------------------------------------------------------------ emit
SUP = {"auto": "Automatic", "tracked": "Tracked", "manual": "Manual", "gap": "Not yet in app", "partial": "Partly automatic"}
by_sup = {}
for x in S: by_sup[x["support"]] = by_sup.get(x["support"], 0) + 1

root = pathlib.Path(__file__).resolve().parent.parent.parent
md = []
w = md.append
w("# Returns and delivery - the full scenario map")
w("")
w("A reference for every way a parcel can go right or wrong between your warehouse and the customer's door and back, what happens to the **stock**, what the **journal entry** should be, and whether the app already does it.")
w("")
w("*Written from the point of view of a multi-channel garment seller (Shopify own store + Amazon + Flipkart, couriers, COD) based in Gujarat. GST figures reflect rules as understood in 2026 - have your CA confirm current rates and limits before relying on them.*")
w("")
w("**%d scenarios.** Support: " % len(S) + ", ".join("%s: %d" % (SUP[k], v) for k, v in sorted(by_sup.items(), key=lambda kv: -kv[1])) + ".")
w("")
w("## How the books treat a return (the one-page version)")
w("")
w("| Question | Default treatment | Why |")
w("|---|---|---|")
w("| When is a customer return / RTO recorded in the books? | When the goods are physically **received back** (not when requested or in transit) | The sale is only undone when the goods are back. Revenue stays until then. |")
w("| What is posted? | A **credit note**: Dr Sales Returns & RTO Reversals, Dr CGST/SGST or IGST (same split as the invoice), Cr the account that settles it | Keeps gross sales, returns and tax visible separately - what a CA wants to see. |")
w("| Where does the credit go? | Own store prepaid / returned: **Customer Refunds Payable**. COD, marketplace: **Trade Receivables** | On our store we owe the customer money back; on a marketplace the platform refunds and nets it in the next settlement. |")
w("| When is the refund paid? | Separate entry: Dr Customer Refunds Payable, Cr Bank | Clears the liability. Marketplace refunds post nothing (netted in settlement). |")
w("| Damaged / lost goods | Not written off by default. With the **Inventory & COGS** pack on, cost moves from COGS to Damaged & Lost Stock Loss | Quarantined goods may still be resold as B-grade. |")
w("| Claims against couriers | Booked only when **approved** (Dr Claims Receivable, Cr Claim Recoveries); cash receipt clears the receivable | A filed claim is a contingent asset - not recognised until recovery is virtually certain. |")
w("| COD cash | Collected: Dr COD Receivable from Couriers, Cr Trade Receivables. Remitted: Dr Bank, Cr COD Receivable | Shows exactly how much cash the couriers are holding for you. |")
w("")
for gid, gtitle, gdesc in GROUPS:
    w("## %s. %s" % (gid, gtitle))
    w("")
    w("*%s*" % gdesc)
    w("")
    for x in [y for y in S if y["grp"] == gid]:
        w("### %s - %s" % (x["code"], x["title"]))
        w("")
        w("- **What happens:** %s" % x["what"])
        w("- **Stock:** %s" % x["stock"])
        w("- **Journal entry:** %s" % x["acct"])
        w("- **GST:** %s" % x["gst"])
        w("- **Claim / recovery:** %s" % x["claim"])
        w("- **In the app:** %s%s" % (SUP[x["support"]], (" - " + x["note"]) if x["note"] else ""))
        if x["rules"]:
            w("- **Rules involved:** " + ", ".join("`%s`" % r for r in x["rules"]))
        w("")
w("## What to build next (from the gaps above)")
w("")
gaps = [x for x in S if x["support"] == "gap"]
w("The scenarios marked *Not yet in app*, in rough order of value:")
w("")
order = ["C20", "C19", "D01", "F06", "B09", "A05", "B13", "H05", "F04", "A03", "C01", "G09"]
for code in order:
    x = next((y for y in S if y["code"] == code), None)
    if x: w("- **%s %s** - %s" % (x["code"], x["title"], x["note"] or x["what"]))
(root / "docs").mkdir(exist_ok=True)
(root / "docs" / "returns-delivery-scenario-map.md").write_text("\n".join(md) + "\n")

doc = {"groups": [dict(id=a, title=b, desc=c) for a, b, c in GROUPS],
       "scenarios": [dict(code=x["code"], grp=x["grp"], title=x["title"], what=x["what"], stock=x["stock"], acct=x["acct"], gst=x["gst"],
                          claim=x["claim"], support=x["support"], note=x["note"], rules=x["rules"], ord=i) for i, x in enumerate(S)]}
payload = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
assert "$j$" not in payload
sql = """-- 0053: the returns / delivery scenario catalogue (generated by supabase/seed/gen_scenarios.py).
-- Reference data behind Accounting > Scenario Map. Read-only for everyone who can sign in.
create table if not exists logistics_scenarios (
  scenario_code text primary key,
  group_code    text not null,
  group_title   text not null,
  sort_order    int  not null,
  title         text not null,
  what_happens  text,
  stock_effect  text,
  accounting    text,
  gst_note      text,
  claim_note    text,
  app_support   text not null check (app_support in ('auto','partial','tracked','manual','gap')),
  app_note      text,
  rule_codes    text[] not null default '{}'
);
alter table logistics_scenarios enable row level security;
drop policy if exists "scenarios readable" on logistics_scenarios;
create policy "scenarios readable" on logistics_scenarios for select to authenticated using (true);
revoke all on logistics_scenarios from anon;
revoke insert, update, delete on logistics_scenarios from authenticated;

do $seed$
declare d jsonb := $j$@@PAYLOAD@@$j$::jsonb; g jsonb; x jsonb;
begin
  delete from logistics_scenarios;
  for x in select * from jsonb_array_elements(d -> 'scenarios') loop
    select y into g from jsonb_array_elements(d -> 'groups') y where y ->> 'id' = x ->> 'grp';
    insert into logistics_scenarios (scenario_code, group_code, group_title, sort_order, title, what_happens, stock_effect, accounting, gst_note, claim_note, app_support, app_note, rule_codes)
    values (x ->> 'code', x ->> 'grp', g ->> 'title', (x ->> 'ord')::int, x ->> 'title', x ->> 'what', x ->> 'stock', x ->> 'acct', x ->> 'gst', x ->> 'claim',
            x ->> 'support', nullif(x ->> 'note', ''), coalesce(array(select jsonb_array_elements_text(x -> 'rules')), '{}'));
  end loop;
end
$seed$;
""".replace("@@PAYLOAD@@", payload)
(root / "supabase" / "migrations" / "0053_logistics_scenario_catalogue.sql").write_text(sql)
print("scenarios:", len(S), by_sup, "sql bytes:", len(sql))
