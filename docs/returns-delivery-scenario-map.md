# Returns and delivery - the full scenario map

A reference for every way a parcel can go right or wrong between your warehouse and the customer's door and back, what happens to the **stock**, what the **journal entry** should be, and whether the app already does it.

*Written from the point of view of a multi-channel garment seller (Shopify own store + Amazon + Flipkart, couriers, COD) based in Gujarat. GST figures reflect rules as understood in 2026 - have your CA confirm current rates and limits before relying on them.*

**110 scenarios.** Support: Automatic: 47, Tracked: 19, Partly automatic: 17, Not yet in app: 16, Manual: 11.

## How the books treat a return (the one-page version)

| Question | Default treatment | Why |
|---|---|---|
| When is a customer return / RTO recorded in the books? | When the goods are physically **received back** (not when requested or in transit) | The sale is only undone when the goods are back. Revenue stays until then. |
| What is posted? | A **credit note**: Dr Sales Returns & RTO Reversals, Dr CGST/SGST or IGST (same split as the invoice), Cr the account that settles it | Keeps gross sales, returns and tax visible separately - what a CA wants to see. |
| Where does the credit go? | Own store prepaid / returned: **Customer Refunds Payable**. COD, marketplace: **Trade Receivables** | On our store we owe the customer money back; on a marketplace the platform refunds and nets it in the next settlement. |
| When is the refund paid? | Separate entry: Dr Customer Refunds Payable, Cr Bank | Clears the liability. Marketplace refunds post nothing (netted in settlement). |
| Damaged / lost goods | Not written off by default. With the **Inventory & COGS** pack on, cost moves from COGS to Damaged & Lost Stock Loss | Quarantined goods may still be resold as B-grade. |
| Claims against couriers | Booked only when **approved** (Dr Claims Receivable, Cr Claim Recoveries); cash receipt clears the receivable | A filed claim is a contingent asset - not recognised until recovery is virtually certain. |
| COD cash | Collected: Dr COD Receivable from Couriers, Cr Trade Receivables. Remitted: Dr Bank, Cr COD Receivable | Shows exactly how much cash the couriers are holding for you. |

## A. Forward delivery (warehouse to customer)

*Everything that can happen between dispatch and a happy customer.*

### A01 - Delivered on first attempt - prepaid

- **What happens:** Courier delivers, customer has already paid online (UPI / card / wallet).
- **Stock:** Stock leaves the warehouse at dispatch.
- **Journal entry:** Invoice at dispatch: Dr Trade Receivables, Cr Sales, Cr GST. Money arrives later in the marketplace / gateway settlement (Dr Bank, Cr Trade Receivables).
- **GST:** Output GST at the invoice; CGST+SGST within Gujarat, IGST outside.
- **Claim / recovery:** -
- **In the app:** Automatic - Settlement receipt is rule-driven (STL-RECEIPT).
- **Rules involved:** `STL-RECEIPT`

### A02 - Delivered on first attempt - COD

- **What happens:** Courier hands over the parcel and collects cash.
- **Stock:** Stock leaves at dispatch.
- **Journal entry:** Invoice at dispatch (Dr Trade Receivables). When the courier collects: Dr COD Receivable from Couriers, Cr Trade Receivables. When the courier remits: Dr Bank, Cr COD Receivable.
- **GST:** Same as A01.
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `COD-COLLECTED`, `COD-REMITTED`

### A03 - Delivery delayed beyond the promised date

- **What happens:** Weather, strikes, festival rush, hub congestion. Customer may cancel or the marketplace may penalise a late delivery.
- **Stock:** No change - goods are with the courier.
- **Journal entry:** No entry until there is an effect (cancellation -> A20, penalty -> bank/settlement deduction, compensation -> claim).
- **GST:** -
- **Claim / recovery:** Possible: late-delivery penalty reversal on marketplaces.
- **In the app:** Not yet in app - No promised-date / SLA tracking in the app. Recommend adding expected_delivery_date to orders and an 'overdue in transit' list.
- **Rules involved:** `BNK-PENALTY`

### A04 - Attempt failed - customer not available

- **What happens:** Door locked / phone not answered. Courier re-attempts (usually up to 3 times over 3-5 days).
- **Stock:** No change.
- **Journal entry:** No entry.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked - Order stays 'shipped'. Courier webhook can raise an RTO when attempts are exhausted.

### A05 - Attempt failed - address wrong or incomplete

- **What happens:** Missing landmark, wrong pincode, unreachable building. Courier raises an NDR (non-delivery report) and waits 48-72 h for the seller to fix it.
- **Stock:** No change.
- **Journal entry:** No entry. If not fixed in time the courier starts an RTO (see B01).
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Not yet in app - No NDR queue in the app. Recommend an 'Action needed' list fed by the courier webhook so someone calls the customer before the parcel turns around.

### A06 - Customer asks to reschedule or change delivery slot

- **What happens:** Customer travelling / wants a weekend delivery.
- **Stock:** No change.
- **Journal entry:** No entry.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked - Courier-side action.

### A07 - Customer refuses at the door

- **What happens:** Changed mind, found it cheaper, did not order, parcel opened and rejected.
- **Stock:** Goods go back to the courier - RTO starts.
- **Journal entry:** See B01 / B03 - sale reversed when goods are received back.
- **GST:** See B03.
- **Claim / recovery:** No.
- **In the app:** Automatic - Treated as an RTO with reason 'Customer refused'.
- **Rules involved:** `RTO-REV-COD`, `RTO-REV-PREPAID-D2C`, `RTO-REV-OTHER`

### A08 - COD customer does not have the cash

- **What happens:** Customer is home but cannot pay.
- **Stock:** Becomes an RTO.
- **Journal entry:** See B11.
- **GST:** See B03.
- **Claim / recovery:** No.
- **In the app:** Automatic - Common on COD orders. Consider prepaid-only for risky pincodes.
- **Rules involved:** `RTO-REV-COD`

### A09 - Pincode not serviceable / out-of-delivery-area surcharge

- **What happens:** Courier accepted the booking but cannot deliver, or charges an ODA surcharge.
- **Stock:** Becomes an RTO if undeliverable.
- **Journal entry:** RTO as B01. ODA surcharge arrives as a freight bill (bank rule BNK-COURIER).
- **GST:** Freight GST 18% as ITC.
- **Claim / recovery:** Maybe: surcharge dispute.
- **In the app:** Automatic
- **Rules involved:** `BNK-COURIER`

### A10 - Parcel stuck or misrouted at a hub

- **What happens:** No tracking movement for days; sorted to the wrong city.
- **Stock:** No change.
- **Journal entry:** No entry unless it becomes lost (A11).
- **GST:** -
- **Claim / recovery:** Becomes a lost-shipment claim after the courier's no-movement limit (usually 15 days).
- **In the app:** Tracked

### A11 - Parcel lost in transit

- **What happens:** Courier declares it lost. Customer gets a refund or replacement.
- **Stock:** Stock is gone - it will never be received back.
- **Journal entry:** Log as an RTO and mark it Claimed: sale reversed by credit note (RTO-REV-*). With the Inventory pack on, cost moves from COGS to Damaged & Lost Stock Loss. Raise a lost_shipment claim; recognise Dr Claims Receivable / Cr Claim Recoveries only when approved.
- **GST:** Credit note reverses output GST. ITC on the lost goods is reversed under Sec 17(5)(h) if the loss is not recovered.
- **Claim / recovery:** Yes - lost_shipment claim against the courier (limit is usually declared value, capped).
- **In the app:** Automatic - Add the claim from the Claims screen straight away so the deadline clock is tracked.
- **Rules involved:** `RTO-REV-COD`, `RTO-REV-PREPAID-D2C`, `RTO-REV-OTHER`, `INV-WRITEOFF-RTO`, `CLM-APPROVED`, `CLM-RECOVERED`

### A12 - Parcel damaged in transit

- **What happens:** Torn bag, water damage, crushed box. Customer refuses it or accepts and returns it.
- **Stock:** Damaged goods come back (RTO) or are returned (C-group).
- **Journal entry:** Credit note as RTO / return. Inspect as 'damaged' -> Claimed. Claim against the courier.
- **GST:** Credit note reverses GST.
- **Claim / recovery:** Yes - damaged_return claim.
- **In the app:** Automatic - Photos at unboxing are what win these claims.
- **Rules involved:** `RTO-REV-COD`, `RET-CN-D2C`, `RET-CN-MKT`, `INV-WRITEOFF-RTO`, `INV-WRITEOFF-RETURN`

### A13 - Partial delivery - one box of a multi-box order missing

- **What happens:** Order shipped in two cartons, one arrives.
- **Stock:** Part of the stock is with the customer, part is missing.
- **Journal entry:** Needs a partial credit note for the missing part.
- **GST:** Credit note for the missing value only.
- **Claim / recovery:** Yes - lost_shipment for the missing carton.
- **In the app:** Not yet in app - The app reverses whole invoices only. Recommend line-level returns/credit notes (see C20).

### A14 - Order split across two warehouses

- **What happens:** Surat has some SKUs, the Mumbai 3PL has the rest.
- **Stock:** Each warehouse is reduced separately.
- **Journal entry:** One invoice, two stock movements.
- **GST:** Place of supply is unchanged.
- **Claim / recovery:** -
- **In the app:** Not yet in app - Orders ship from one warehouse today. Recommend per-line warehouse on order lines.

### A15 - Wrong item dispatched (our mistake)

- **What happens:** Picker sent the wrong size / colour / style.
- **Stock:** Wrong item comes back, right item goes out.
- **Journal entry:** Return with reason 'Wrong item received' (credit note + restock), then a fresh replacement order. No claim - this is our own cost.
- **GST:** Credit note + new invoice.
- **Claim / recovery:** No (seller error).
- **In the app:** Automatic - Track picking accuracy separately - it is a process leak, not a courier problem.
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### A16 - Short quantity or missing accessory

- **What happens:** Combo set missing a piece, dupatta not in the packet.
- **Stock:** Customer keeps most of it.
- **Journal entry:** Partial refund -> manual credit note, or full return.
- **GST:** Credit note for the difference.
- **Claim / recovery:** Sometimes (if packed correctly and courier tampered).
- **In the app:** Manual - Partial credit notes are manual today (C19).

### A17 - Customer says 'not received' but tracking shows delivered

- **What happens:** Fake claim, wrong-person delivery, neighbour/security accepted it.
- **Stock:** Goods are with the customer (or lost).
- **Journal entry:** If we are forced to refund: marketplace chargeback / A-to-Z deduction shows in settlement or bank (BNK-PENALTY, review) and is disputed with proof of delivery.
- **GST:** No reversal of the invoice unless we accept the refund.
- **Claim / recovery:** Yes - dispute with POD / OTP / photo evidence.
- **In the app:** Manual
- **Rules involved:** `BNK-PENALTY`

### A18 - Customer cancels before dispatch

- **What happens:** Order is paid but cancelled before an invoice exists.
- **Stock:** Reserved stock is released.
- **Journal entry:** No sales entry (no invoice yet). Prepaid refund goes back via the gateway; the gateway fee is not refunded - it stays an expense (BNK-GATEWAY).
- **GST:** None.
- **Claim / recovery:** No.
- **In the app:** Tracked - The cancel hook only fires when an invoice exists, so cheap pre-dispatch cancellations do not create noise.
- **Rules involved:** `BNK-GATEWAY`

### A19 - Seller cancels (out of stock, price error, fraud suspicion)

- **What happens:** We cannot fulfil. Marketplaces charge a cancellation penalty to the seller.
- **Stock:** Reserved stock is released.
- **Journal entry:** No sales entry. Marketplace penalty: Dr Marketplace Penalties & Chargebacks (review).
- **GST:** No GST on a penalty.
- **Claim / recovery:** Dispute if the cancellation was not ours.
- **In the app:** Automatic
- **Rules involved:** `BNK-PENALTY`

### A20 - Cancelled after dispatch (intercept)

- **What happens:** Customer or seller asks the courier to stop and return the parcel.
- **Stock:** Goods come back as an RTO.
- **Journal entry:** As B01-B03. Both-way freight is a cost (BNK-COURIER, BNK-RTO-CHARGES).
- **GST:** Credit note on receipt.
- **Claim / recovery:** No.
- **In the app:** Automatic
- **Rules involved:** `RTO-REV-COD`, `RTO-REV-PREPAID-D2C`, `RTO-REV-OTHER`, `BNK-RTO-CHARGES`

### A21 - Cancelled after invoicing, before the courier picks up

- **What happens:** Invoice exists but the goods never left.
- **Stock:** Stock returns to available.
- **Journal entry:** Order marked Cancelled -> credit note posts automatically (own store prepaid: Cr Customer Refunds Payable; otherwise Cr Trade Receivables).
- **GST:** Credit note reverses GST.
- **Claim / recovery:** No.
- **In the app:** Automatic - Order must have an invoice for the hook to fire.
- **Rules involved:** `ORD-CANCEL-D2C-PREPAID`, `ORD-CANCEL-OTHER`

### A22 - Fake / prank / duplicate order

- **What happens:** Typical on COD: wrong phone number, someone else's address, same order placed twice.
- **Stock:** Becomes an RTO.
- **Journal entry:** As B11. The cost is the two-way freight plus packaging.
- **GST:** Credit note on receipt.
- **Claim / recovery:** No.
- **In the app:** Not yet in app - No risk scoring. Recommend a per-pincode and per-customer RTO rate on the Insights screen to push risky COD orders to prepaid.
- **Rules involved:** `RTO-REV-COD`

### A23 - Delivered to the wrong person

- **What happens:** Neighbour / watchman / wrong flat.
- **Stock:** Goods are with someone else.
- **Journal entry:** Treat like A17 and file a lost-shipment claim if the courier agrees it was mis-delivered.
- **GST:** -
- **Claim / recovery:** Yes.
- **In the app:** Manual

## B. RTO - return to origin (undelivered)

*The parcel never reached the customer and comes back to us.*

### B01 - RTO initiated by the courier

- **What happens:** Three failed attempts, refusal, wrong address left unfixed, or seller instruction.
- **Stock:** Goods are travelling back (RTO in transit). Not in any warehouse yet.
- **Journal entry:** No entry yet - the sale is only reversed when the goods are physically received back.
- **GST:** Output GST stays until the credit note.
- **Claim / recovery:** -
- **In the app:** Tracked - Courier webhook creates the RTO as 'initiated' / 'in transit'. Your CA may prefer reversing at initiation; the hook fires on receipt - change the event if policy differs.

### B02 - RTO in transit (4-10 days)

- **What happens:** Reverse leg of the journey; same delays and loss risks as the forward leg.
- **Stock:** In transit.
- **Journal entry:** No entry.
- **GST:** -
- **Claim / recovery:** Lost on the way back -> B07.
- **In the app:** Tracked

### B03 - RTO received - parcel intact, goods resaleable

- **What happens:** Seal intact, tags intact, quantities match.
- **Stock:** Restocked into the chosen warehouse. With the Inventory pack: Dr Inventory, Cr COGS.
- **Journal entry:** Credit note posts automatically: Dr Sales Returns & RTO Reversals, Dr CGST/SGST or IGST, Cr Trade Receivables (COD / marketplace) or Cr Customer Refunds Payable (own-store prepaid).
- **GST:** Credit note mirrors the invoice's GST split. Appears in the GST summary credit notes.
- **Claim / recovery:** No.
- **In the app:** Automatic - A second event (inspected, restocked) never double-posts.
- **Rules involved:** `RTO-REV-COD`, `RTO-REV-PREPAID-D2C`, `RTO-REV-OTHER`, `INV-RTO-RESTOCK`

### B04 - RTO received - damaged by the courier

- **What happens:** Torn, crushed, wet, tampered.
- **Stock:** Quarantined; not available to sell.
- **Journal entry:** Credit note as B03. Inspection 'damaged' -> Claimed. With the Inventory pack: cost moves from COGS to Damaged & Lost Stock Loss. Claim approved -> Dr Claims Receivable, Cr Claim Recoveries.
- **GST:** Credit note reverses GST. Claim recovery is not a supply (no GST).
- **Claim / recovery:** Yes - damaged_return against the courier.
- **In the app:** Automatic
- **Rules involved:** `RTO-REV-COD`, `RTO-REV-PREPAID-D2C`, `RTO-REV-OTHER`, `INV-WRITEOFF-RTO`, `CLM-APPROVED`, `CLM-RECOVERED`

### B05 - RTO received - different item inside (swapped)

- **What happens:** Customer or someone en route swapped the garment for a cheap one.
- **Stock:** Wrong item quarantined.
- **Journal entry:** As B04, inspection 'wrong_item'. Evidence: unboxing video, weight at dispatch vs receipt.
- **GST:** As B04.
- **Claim / recovery:** Yes - against the courier or (marketplaces) SAFE-T / SPF.
- **In the app:** Automatic
- **Rules involved:** `INV-WRITEOFF-RTO`, `CLM-APPROVED`

### B06 - RTO received - used, washed, tag removed

- **What happens:** Worn once and refused.
- **Stock:** Quarantined -> may be resold as B-grade.
- **Journal entry:** Credit note as B03. Stock is held in quarantine (no write-off by default). If sold as B-grade at a discount, the difference is a loss.
- **GST:** As B03.
- **Claim / recovery:** Sometimes.
- **In the app:** Automatic - Quarantine is not written off automatically because it may be resold - change the rule condition if your policy differs.
- **Rules involved:** `RTO-REV-COD`, `RTO-REV-OTHER`

### B07 - RTO never arrives (lost on the way back)

- **What happens:** Courier shows RTO delivered / lost but the warehouse never receives it.
- **Stock:** Stock is gone.
- **Journal entry:** Mark RTO Claimed -> credit note + write-off + lost_shipment claim, as A11.
- **GST:** As A11.
- **Claim / recovery:** Yes - lost_shipment.
- **In the app:** Automatic
- **Rules involved:** `INV-WRITEOFF-RTO`, `CLM-APPROVED`

### B08 - RTO received after the month (or year) was closed

- **What happens:** Parcel arrives weeks later.
- **Stock:** Restocked when it arrives.
- **Journal entry:** Credit note is dated the day it is processed, in the current OPEN period - closed periods are never reopened.
- **GST:** Sec 34(2): credit notes must be issued by 30 November after the financial year-end or the annual return date, whichever is earlier, or the output-tax reduction is lost.
- **Claim / recovery:** -
- **In the app:** Automatic - If the date falls in a closed period the event is logged as an error for the accountant, never silently dropped.

### B09 - RTO of a prepaid own-store order

- **What happens:** Customer paid on Shopify, parcel returned.
- **Stock:** As B03.
- **Journal entry:** Credit note creates Customer Refunds Payable. Pay the refund from the bank and record it (refund rule: Dr Customer Refunds Payable, Cr Bank).
- **GST:** As B03.
- **Claim / recovery:** -
- **In the app:** Partly automatic - There is no refund screen for RTOs (only for customer returns). Recommend adding a 'Mark refunded' action on the RTO page.
- **Rules involved:** `RTO-REV-PREPAID-D2C`, `RET-REFUND-D2C`

### B10 - RTO of a prepaid marketplace order

- **What happens:** Marketplace refunds the customer and adjusts our payout.
- **Stock:** As B03.
- **Journal entry:** Credit note reduces Trade Receivables (what the marketplace owes us). No bank entry - the marketplace nets it in a settlement.
- **GST:** As B03.
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `RTO-REV-OTHER`

### B11 - RTO of a COD order

- **What happens:** No cash was ever collected.
- **Stock:** As B03.
- **Journal entry:** Credit note reduces Trade Receivables (nothing was collected from the customer). The real cost is freight both ways + the COD handling fee.
- **GST:** As B03.
- **Claim / recovery:** No.
- **In the app:** Automatic
- **Rules involved:** `RTO-REV-COD`, `BNK-RTO-CHARGES`

### B12 - RTO charges and COD fees

- **What happens:** Forward freight + reverse freight + COD fee are non-refundable. Marketplaces show an 'RTO fee' inside settlements.
- **Stock:** -
- **Journal entry:** Courier bills paid from the bank: Dr Reverse Logistics & RTO Charges, Dr ITC (18%), Cr Bank. Settlement deductions are currently booked as one commission expense.
- **GST:** 18% GST on courier services is input credit.
- **Claim / recovery:** Dispute wrong charges.
- **In the app:** Partly automatic - Courier bills: automatic. Settlement fees are lumped together - recommend splitting by fee_type (commission / shipping / RTO / gateway) into separate expense ledgers.
- **Rules involved:** `BNK-RTO-CHARGES`, `BNK-COURIER`

### B13 - Chronic RTO pincodes and customers

- **What happens:** 30-40% RTO in some regions on COD.
- **Stock:** -
- **Journal entry:** -
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Not yet in app - Recommend RTO rate by pincode / courier / SKU on the Business Insights screen.

### B14 - Courier re-attempts after RTO was initiated

- **What happens:** Customer calls and accepts delivery after all.
- **Stock:** Back to forward delivery.
- **Journal entry:** No entry (nothing was posted at initiation).
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Not yet in app - An RTO cannot be cancelled in the app. Recommend a 'Cancel RTO / re-attempt' action.

## C. Customer returns (reverse pickup)

*The customer received the parcel and sends it back.*

### C01 - Return policy and window

- **What happens:** 7 / 10 / 15 / 30 day windows; non-returnable items (innerwear, altered or customised pieces, sarees with falls attached).
- **Stock:** -
- **Journal entry:** No entry.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Not yet in app - The app does not enforce a return window or category rules. Recommend a window per category and a warning on late return requests.

### C02 - Return requested -> approved -> pickup scheduled

- **What happens:** Customer raises it, support approves, courier pickup is booked.
- **Stock:** Goods still with the customer.
- **Journal entry:** No entry.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked - Statuses: Requested, Approved, Pickup, In transit.

### C03 - Pickup fails - customer not ready / not available

- **What happens:** Reverse pickup attempts fail up to 3 times; request auto-closes.
- **Stock:** No change.
- **Journal entry:** No entry. Reverse pickup fee may still be billed (BNK-RTO-CHARGES).
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked
- **Rules involved:** `BNK-RTO-CHARGES`

### C04 - Customer self-ships the return

- **What happens:** Remote area without pickup; customer sends it by post/courier and is reimbursed.
- **Stock:** Goods arrive at the warehouse.
- **Journal entry:** Reimbursement: Dr Reverse Logistics & RTO Charges, Cr Bank.
- **GST:** GST only if the customer provides a valid invoice (rare).
- **Claim / recovery:** -
- **In the app:** Manual
- **Rules involved:** `BNK-RTO-CHARGES`

### C05 - Reason: size / fit

- **What happens:** Top reason in garments (30-40% of returns). Wrong size ordered or the brand runs small/large.
- **Stock:** Restock if tags intact.
- **Journal entry:** Credit note (C13). Consider an exchange (D01) rather than a refund to keep the sale.
- **GST:** As C13.
- **Claim / recovery:** No.
- **In the app:** Automatic - Track fit-returns by SKU and size to fix the size chart.
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### C06 - Reason: colour / look different from the photo

- **What happens:** Fabric shade differs on screen vs in hand.
- **Stock:** Restock if tags intact.
- **Journal entry:** Credit note (C13).
- **GST:** As C13.
- **Claim / recovery:** No.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### C07 - Reason: quality / stitching / fabric defect

- **What happens:** Seams open, colour bleeds, fabric thin - seller-side problem.
- **Stock:** Quarantine; not resold as new.
- **Journal entry:** Credit note (C13). Inspection 'damaged' -> Claimed with the Inventory pack: cost moves to Damaged & Lost Stock Loss. Supplier / karigar debit note is manual.
- **GST:** As C13.
- **Claim / recovery:** Supplier recovery (not a courier claim).
- **In the app:** Partly automatic - No supplier debit-note flow. Recommend a defect register by supplier / production lot.
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`, `INV-WRITEOFF-RETURN`

### C08 - Reason: damaged on arrival

- **What happens:** Transit damage reported on delivery.
- **Stock:** Quarantine.
- **Journal entry:** Credit note + write-off + damaged_return claim against the courier.
- **GST:** As C13.
- **Claim / recovery:** Yes - courier.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`, `INV-WRITEOFF-RETURN`, `CLM-APPROVED`

### C09 - Reason: wrong item received

- **What happens:** See A15 - our picking error.
- **Stock:** Restock the returned item.
- **Journal entry:** Credit note + replacement (D03).
- **GST:** As C13.
- **Claim / recovery:** No.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### C10 - Reason: changed mind / found cheaper / not needed

- **What happens:** No fault anywhere.
- **Stock:** Restock if unused.
- **Journal entry:** Credit note (C13). Some marketplaces charge the customer a fee instead.
- **GST:** As C13.
- **Claim / recovery:** No.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### C11 - Reason: delivered too late

- **What happens:** Event or festival has passed.
- **Stock:** Restock if unused.
- **Journal entry:** Credit note (C13).
- **GST:** As C13.
- **Claim / recovery:** Maybe: late-delivery compensation from the courier.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### C12 - Reason: missing piece in a set / combo

- **What happens:** Kurta set without the dupatta.
- **Stock:** Restock what comes back.
- **Journal entry:** Full return (C13) or partial credit note (C19).
- **GST:** As C13.
- **Claim / recovery:** Maybe.
- **In the app:** Partly automatic
- **Rules involved:** `RET-CN-D2C`

### C13 - Return received - good condition

- **What happens:** Tags intact, unwashed, as sent.
- **Stock:** Restocked into the chosen warehouse. With the Inventory pack: Dr Inventory, Cr COGS at cost.
- **Journal entry:** Credit note posts automatically: Dr Sales Returns, Dr GST (same split as the invoice), Cr Customer Refunds Payable (own store) or Cr Trade Receivables (marketplace).
- **GST:** Appears in the GST summary under credit notes; reduces output tax in the month it is issued.
- **Claim / recovery:** No.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`, `RET-CN-OTHER`, `INV-RETURN-RESTOCK`

### C14 - Return received - worn, washed, stained, perfume smell, tags removed

- **What happens:** 'Wardrobing' - worn once and returned.
- **Stock:** Quarantined; may be resold as B-grade.
- **Journal entry:** Options: reject the refund (C18) or accept with a deduction (C19). Default: credit note + quarantine.
- **GST:** As C13.
- **Claim / recovery:** Sometimes.
- **In the app:** Partly automatic - Deduction-based partial refunds are manual (C19).
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### C15 - Return received - a different item sent back

- **What happens:** Customer sends back a cheaper garment, or a brick in the box.
- **Stock:** Wrong item quarantined.
- **Journal entry:** Refund should be withheld / reversed. Marketplace: SAFE-T / SPF claim. Inspection 'wrong_item' -> Claimed.
- **GST:** Credit note only if the refund is finally granted.
- **Claim / recovery:** Yes - marketplace protection claim.
- **In the app:** Partly automatic
- **Rules involved:** `INV-WRITEOFF-RETURN`, `CLM-APPROVED`

### C16 - Return received - empty box / missing items

- **What happens:** Parcel arrived light.
- **Stock:** Nothing to restock.
- **Journal entry:** As C15, inspection 'missing'.
- **GST:** As C15.
- **Claim / recovery:** Yes - courier (tampering) or marketplace.
- **In the app:** Partly automatic
- **Rules involved:** `CLM-APPROVED`

### C17 - Return received - damaged

- **What happens:** Torn or soiled beyond normal use.
- **Stock:** Quarantined / written off.
- **Journal entry:** Credit note (if refund granted) + write-off with the Inventory pack. Claim if the damage happened in transit.
- **GST:** As C13.
- **Claim / recovery:** Sometimes.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`, `INV-WRITEOFF-RETURN`

### C18 - Return rejected at inspection

- **What happens:** Does not meet the return policy (outside window, used, no tags).
- **Stock:** Returned to the customer (RTC).
- **Journal entry:** No credit note, no revenue reversal. Refund status Rejected. Outbound freight to send it back is an expense.
- **GST:** None.
- **Claim / recovery:** No.
- **In the app:** Tracked - The credit-note hook only fires on received / inspected / restocked / quarantined / claimed. A 'rejected' return posts nothing.
- **Rules involved:** `BNK-COURIER`

### C19 - Partial refund (deduction for wear, missing tag, restocking fee)

- **What happens:** Customer is refunded less than the invoice.
- **Stock:** Restock or quarantine.
- **Journal entry:** Needs a credit note for the refunded value only.
- **GST:** Credit note for the reduced value; GST recomputed on it.
- **Claim / recovery:** No.
- **In the app:** Not yet in app - Credit notes are whole-invoice today. Recommend a partial credit-note amount on the return.

### C20 - Partial return - 1 of 3 items sent back

- **What happens:** Multi-item order, only some pieces returned.
- **Stock:** Only the returned lines restock.
- **Journal entry:** Credit note for the returned lines only.
- **GST:** GST on the returned lines.
- **Claim / recovery:** -
- **In the app:** Not yet in app - disposition_return() restocks every line of the order, and the credit note covers the whole invoice. Recommend line-level returns (return_lines table). Highest-value next improvement for returns.

### C21 - Return lost in reverse transit

- **What happens:** Reverse pickup lost by the courier.
- **Stock:** Stock gone.
- **Journal entry:** Credit note + write-off + claim, as A11 / B07.
- **GST:** As A11.
- **Claim / recovery:** Yes - lost_shipment.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`, `INV-WRITEOFF-RETURN`, `CLM-APPROVED`

### C22 - Refund of a COD order

- **What happens:** Customer paid cash, wants money back.
- **Stock:** As C13.
- **Journal entry:** Credit note creates a refund liability; pay by NEFT/UPI and record the refund: Dr Customer Refunds Payable, Cr Bank. Wrong bank details = failed refund (loop).
- **GST:** As C13.
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-REFUND-D2C`

### C23 - Refund mode: original source, store credit, bank transfer

- **What happens:** Card/UPI refunds go back instantly via the gateway; store credit keeps the money with us.
- **Stock:** -
- **Journal entry:** Gateway/UPI/bank refund: Dr Customer Refunds Payable, Cr Bank. Store credit keeps the liability open until redeemed (leave Customer Refunds Payable, or add a Store Credit ledger).
- **GST:** Store credit issued against a return is not a new supply; GST on the eventual redemption sale.
- **Claim / recovery:** -
- **In the app:** Partly automatic - Store-credit liability has no ledger or screen yet.
- **Rules involved:** `RET-REFUND-D2C`

### C24 - Refund timing: instant on pickup vs after quality check

- **What happens:** Marketplaces refund the customer early to trusted buyers.
- **Stock:** -
- **Journal entry:** Our credit note posts when goods are physically received; the marketplace's early refund is netted in settlement.
- **GST:** Credit note date = date we process it.
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `RET-CN-MKT`, `RET-REFUND-MKT`

### C25 - Refund fails or customer disputes with the bank

- **What happens:** Wrong account number, card closed, chargeback.
- **Stock:** -
- **Journal entry:** Chargeback fee / penalty: Dr Marketplace Penalties & Chargebacks. Refund liability stays open until paid.
- **GST:** No GST on penalties.
- **Claim / recovery:** Dispute with evidence.
- **In the app:** Manual
- **Rules involved:** `BNK-PENALTY`

### C26 - Marketplace-fulfilled returns (grading at the fulfilment centre)

- **What happens:** Amazon / Flipkart receive the return and grade it: sellable, unsellable, customer-damaged, carrier-damaged, defective.
- **Stock:** Marketplace stock, not ours until returned to us.
- **Journal entry:** Credit note as C13 when we confirm receipt/grade; carrier-damaged -> platform reimburses (claim).
- **GST:** As C13.
- **Claim / recovery:** Yes - SAFE-T / SPF for carrier-damaged or not received.
- **In the app:** Partly automatic - Grades map onto the app's four results (good / damaged / wrong_item / missing). Recommend a 'grade' field to keep the platform's wording.
- **Rules involved:** `RET-CN-MKT`, `CLM-APPROVED`

### C27 - Return never reaches the seller but the customer was refunded

- **What happens:** Marketplace refunded early; parcel lost or returned to the wrong place.
- **Stock:** Stock gone.
- **Journal entry:** Claim reimbursement from the marketplace within its window.
- **GST:** -
- **Claim / recovery:** Yes.
- **In the app:** Manual
- **Rules involved:** `CLM-APPROVED`

### C28 - Return of a discounted / coupon order

- **What happens:** Customer paid less than list price.
- **Stock:** As C13.
- **Journal entry:** Credit note is for the amount actually paid (the invoice value), not the list price.
- **GST:** GST on the paid value.
- **Claim / recovery:** No.
- **In the app:** Automatic - Credit-note amounts come from the invoice, so discounts are respected.
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### C29 - Serial returners / wardrobing

- **What happens:** A few customers account for a large share of returns.
- **Stock:** -
- **Journal entry:** -
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Not yet in app - Recommend a repeat-returner list and a return-rate by customer.

## D. Exchanges and replacements

*Customer wants a different size/colour, or we owe a replacement.*

### D01 - Exchange - size or colour swap

- **What happens:** Customer sends back M and wants L.
- **Stock:** M comes back (restock); L goes out.
- **Journal entry:** Model it as a return (credit note, restock) plus a new order for the replacement. Price difference is collected / refunded on the new order.
- **GST:** Credit note for the old invoice; fresh invoice for the new.
- **Claim / recovery:** No.
- **In the app:** Partly automatic - No exchange object linking the two orders. Recommend an 'Exchange' return type that auto-creates the replacement order.
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### D02 - Exchange not possible - replacement size out of stock

- **What happens:** Customer wanted L, only M was available.
- **Stock:** M returns.
- **Journal entry:** Converts to a normal refund (C13).
- **GST:** As C13.
- **Claim / recovery:** No.
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`

### D03 - Free replacement for a defective or wrong item

- **What happens:** We ship a new piece at no charge.
- **Stock:** New piece leaves stock; defective piece is written off or returned to supplier.
- **Journal entry:** Credit note for the original, zero-value (or no) invoice for the replacement; cost of the replacement is a loss (Damaged & Lost Stock Loss).
- **GST:** Zero-value supply - confirm treatment with your CA.
- **Claim / recovery:** Supplier recovery.
- **In the app:** Manual
- **Rules involved:** `INV-ADJ-LOSS`

## E. Cash on delivery (COD)

*Cash collected by the courier and remitted to us later.*

### E01 - COD cash collected by the courier

- **What happens:** Courier collects at the door.
- **Stock:** -
- **Journal entry:** Dr COD Receivable from Couriers, Cr Trade Receivables. The money now sits with the courier.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `COD-COLLECTED`

### E02 - COD remitted in full

- **What happens:** Courier pays out T+2 to T+7 / weekly.
- **Stock:** -
- **Journal entry:** Dr Bank, Cr COD Receivable from Couriers.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `COD-REMITTED`

### E03 - COD remitted short

- **What happens:** Courier deducts a COD fee (about 1.5-2.5% or Rs25-40 per parcel), or amounts don't tally.
- **Stock:** -
- **Journal entry:** Remitted part posts normally; the balance stays visible in COD Receivable (status short_remit). Fee deductions: add a rule line (Dr Freight & Courier Charges + ITC) or book from the courier invoice.
- **GST:** COD fee is a service (18% GST, ITC).
- **Claim / recovery:** Yes - incorrect_deduction.
- **In the app:** Partly automatic - Fee-from-remittance is not split automatically.
- **Rules involved:** `COD-REMITTED`, `CLM-APPROVED-DEDUCTION`

### E04 - COD collected amount differs from order value

- **What happens:** Customer negotiated, no change, or paid part.
- **Stock:** -
- **Journal entry:** Collected amount is what moves into COD Receivable; the difference remains in Trade Receivables to be written off or recovered.
- **GST:** Discount after invoice -> credit note.
- **Claim / recovery:** -
- **In the app:** Manual

### E05 - COD order returned after cash was collected

- **What happens:** Customer paid, then returns the item.
- **Stock:** As C13.
- **Journal entry:** Credit note creates a refund liability; refund paid from the bank.
- **GST:** As C13.
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-REFUND-D2C`

### E06 - Courier delays remittance

- **What happens:** Cash sits with the courier beyond the agreed cycle.
- **Stock:** -
- **Journal entry:** Outstanding in COD Receivable from Couriers - age it and chase.
- **GST:** -
- **Claim / recovery:** Escalate / interest.
- **In the app:** Tracked - COD screen lists pending remittances.

### E07 - Unidentified COD credit in the bank

- **What happens:** Lump-sum NEFT from a courier with no order breakdown.
- **Stock:** -
- **Journal entry:** Left unmatched on purpose (BNK-IGNORE-SETTLEMENT) so the COD screen reconciles it; does not hit the books twice.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `BNK-IGNORE-SETTLEMENT`

### E08 - Courier default / write-off

- **What happens:** Courier shuts down owing cash.
- **Stock:** -
- **Journal entry:** Dr Short-Pay & Bad Debts Written Off, Cr COD Receivable from Couriers (manual journal).
- **GST:** Bad-debt GST treatment: CA to confirm.
- **Claim / recovery:** Legal recovery.
- **In the app:** Manual

## F. Marketplace settlements and fees

*Amazon / Flipkart / gateway payouts, fees and deductions.*

### F01 - Settlement received in full

- **What happens:** Payout equals gross sales minus fees.
- **Stock:** -
- **Journal entry:** Fees and ITC are booked on reconciliation. The receipt: Dr Bank, Cr Trade Receivables.
- **GST:** ITC on the 18% GST in fees.
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `STL-RECEIPT`

### F02 - Settlement short-paid

- **What happens:** Bank received less than the statement says.
- **Stock:** -
- **Journal entry:** Dr Bank (actual), Dr Settlement Short-Pay Receivable (shortfall), Cr Trade Receivables (expected). Raise an incorrect_deduction claim.
- **GST:** -
- **Claim / recovery:** Yes.
- **In the app:** Automatic
- **Rules involved:** `STL-RECEIPT`, `CLM-APPROVED-DEDUCTION`

### F03 - Settlement paid in excess

- **What happens:** Payout is more than expected (reversal of an earlier deduction, error).
- **Stock:** -
- **Journal entry:** Cr Settlement Excess Received - a liability until explained or returned.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `STL-RECEIPT`

### F04 - Commission, closing fee, shipping fee, collection fee

- **What happens:** Marketplace deductions with 18% GST.
- **Stock:** -
- **Journal entry:** Booked on reconciliation as Marketplace Commission Expense + GST Input Tax Credit.
- **GST:** ITC claim on the marketplace's tax invoice.
- **Claim / recovery:** Dispute wrong rates.
- **In the app:** Partly automatic - All deductions land in one expense ledger. Recommend fee-type ledgers (commission, shipping, closing, collection, RTO).

### F05 - Commission refunded on returns

- **What happens:** Marketplaces return part of the commission when an item is returned, but keep fixed fees and shipping.
- **Stock:** -
- **Journal entry:** Appears as a credit in the next settlement.
- **GST:** ITC reversal on the refunded part.
- **Claim / recovery:** Check the calculation.
- **In the app:** Not yet in app - Settlement lines model deductions only, not refund-type credits.

### F06 - GST TCS and income-tax TDS on payouts

- **What happens:** Marketplace collects GST TCS (0.5% as of 2025; confirm current rate) and TDS under Sec 194-O (0.1% as of 2025; confirm) before paying you.
- **Stock:** -
- **Journal entry:** Dr GST TCS Credit Receivable and Dr TDS Receivable, reducing the cash received. Claimed in GSTR-2B / Form 26AS.
- **GST:** TCS credit is set off in GSTR-3B; TDS against income tax.
- **Claim / recovery:** -
- **In the app:** Not yet in app - Ledgers exist but settlements do not capture TCS/TDS yet. Recommend two extra settlement fields and lines in STL-RECEIPT.

### F07 - Payout withheld as a reserve / hold

- **What happens:** Marketplace holds funds for the return window or a pending dispute.
- **Stock:** -
- **Journal entry:** Stays in Trade Receivables until released.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked

### F08 - Penalties (late dispatch, cancellations, high RTO / return rate)

- **What happens:** Deducted from the payout.
- **Stock:** -
- **Journal entry:** Dr Marketplace Penalties & Chargebacks.
- **GST:** No GST on penalties.
- **Claim / recovery:** Dispute where not our fault.
- **In the app:** Partly automatic - In settlements these are lumped into deductions; paid by bank they use BNK-PENALTY.
- **Rules involved:** `BNK-PENALTY`

### F09 - Advertising and promotion fees inside the settlement

- **What happens:** Sponsored-product charges netted from the payout.
- **Stock:** -
- **Journal entry:** Should be Advertising & Promotion expense with ITC.
- **GST:** 18% GST.
- **Claim / recovery:** -
- **In the app:** Not yet in app - Needs fee-type split (F04).
- **Rules involved:** `BNK-ADS`

### F10 - Marketplace reimburses lost / damaged inventory

- **What happens:** Credit appears in a settlement for goods lost at the fulfilment centre.
- **Stock:** -
- **Journal entry:** Dr Bank, Cr Claims Receivable (or Claim Recoveries if not pre-booked).
- **GST:** No GST.
- **Claim / recovery:** Yes.
- **In the app:** Partly automatic
- **Rules involved:** `CLM-RECOVERED`

## G. Claims and disputes

*Getting money back from couriers, marketplaces and suppliers.*

### G01 - Lost-shipment claim against the courier

- **What happens:** Compensation is usually the declared value up to a cap; strict filing deadlines.
- **Stock:** Stock already written off.
- **Journal entry:** Booked only on approval: Dr Claims Receivable, Cr Claim Recoveries. Recovery: Dr Bank, Cr Claims Receivable.
- **GST:** Compensation is not a supply.
- **Claim / recovery:** -
- **In the app:** Automatic - Contingent assets are not booked until recovery is virtually certain.
- **Rules involved:** `CLM-APPROVED`, `CLM-RECOVERED`

### G02 - Damaged-in-transit claim

- **What happens:** Needs unboxing photos / video and the damage report.
- **Stock:** Goods quarantined or written off.
- **Journal entry:** As G01.
- **GST:** As G01.
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `CLM-APPROVED`, `CLM-RECOVERED`

### G03 - Weight discrepancy / volumetric weight overcharge

- **What happens:** Courier bills more weight than shipped.
- **Stock:** -
- **Journal entry:** Approved recovery should reduce the freight expense, not be income. Default deduction rule credits Marketplace Commission Expense - add a rule for courier claims if you want Freight.
- **GST:** ITC adjustment.
- **Claim / recovery:** Yes - excess_deduction.
- **In the app:** Partly automatic
- **Rules involved:** `CLM-APPROVED-DEDUCTION`

### G04 - Wrongly deducted marketplace fee

- **What happens:** Wrong commission slab, duplicate fee.
- **Stock:** -
- **Journal entry:** Approved: Dr Claims Receivable, Cr Marketplace Commission Expense.
- **GST:** ITC adjustment.
- **Claim / recovery:** Yes - incorrect_deduction.
- **In the app:** Automatic
- **Rules involved:** `CLM-APPROVED-DEDUCTION`

### G05 - Claim filed after the deadline

- **What happens:** Window missed.
- **Stock:** -
- **Journal entry:** Nothing was booked, so nothing to reverse. The loss stays in expenses.
- **GST:** -
- **Claim / recovery:** Lost.
- **In the app:** Tracked - Deadline is stored per claim.

### G06 - Claim partially approved

- **What happens:** Approved amount is lower than claimed.
- **Stock:** -
- **Journal entry:** Booked at the approved amount.
- **GST:** -
- **Claim / recovery:** Yes.
- **In the app:** Automatic
- **Rules involved:** `CLM-APPROVED`

### G07 - Claim rejected

- **What happens:** Evidence insufficient or policy excludes it.
- **Stock:** -
- **Journal entry:** No entry by default (nothing was recognised on filing).
- **GST:** -
- **Claim / recovery:** Appeal.
- **In the app:** Automatic - A claim.rejected event exists so you can attach a rule if your CA wants a write-off.

### G08 - Claim recovered in instalments or via a settlement credit

- **What happens:** Money arrives in pieces.
- **Stock:** -
- **Journal entry:** Each recovery posts its own entry (Dr Bank, Cr Claims Receivable) for the amount received that time.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `CLM-RECOVERED`

### G09 - Supplier claim for defective goods

- **What happens:** Quality defect traced to a supplier or karigar.
- **Stock:** Defective stock returned to the supplier.
- **Journal entry:** Debit note to the supplier; Dr Supplier Payable, Cr Purchases / Inventory.
- **GST:** Debit note adjusts input tax.
- **Claim / recovery:** Yes.
- **In the app:** Not yet in app - No suppliers or purchases module yet.

## H. GST, valuation and period-end

*What the CA cares about when the books are closed.*

### H01 - Credit-note time limit (Sec 34(2))

- **What happens:** Output tax can be reduced only if the credit note is issued by 30 November following the financial year, or the annual return date, whichever is earlier.
- **Stock:** -
- **Journal entry:** Credit notes are dated when processed.
- **GST:** Hard statutory limit.
- **Claim / recovery:** -
- **In the app:** Tracked - Process year-end returns before the cut-off.

### H02 - Credit note mirrors the original GST split

- **What happens:** Intrastate sale reversed with CGST+SGST; interstate with IGST.
- **Stock:** -
- **Journal entry:** Handled automatically from the invoice.
- **GST:** Required.
- **Claim / recovery:** -
- **In the app:** Automatic
- **Rules involved:** `RET-CN-D2C`, `RET-CN-MKT`, `RTO-REV-COD`

### H03 - ITC reversal on goods lost, stolen or destroyed

- **What happens:** Sec 17(5)(h): ITC on stock lost or written off must be reversed.
- **Stock:** -
- **Journal entry:** Add a line to the write-off rules: Dr Damaged & Lost Stock Loss, Cr GST Input Tax Credit.
- **GST:** ITC reversal.
- **Claim / recovery:** If the loss is recovered from the courier, ask your CA whether the reversal still applies.
- **In the app:** Partly automatic - Documented on the rule; not on by default.
- **Rules involved:** `INV-ADJ-LOSS`

### H04 - Inventory write-down to net realisable value

- **What happens:** B-grade and aged seasonal stock sells below cost.
- **Stock:** Quantity unchanged, value lower.
- **Journal entry:** Dr Damaged & Lost Stock Loss (or Inventory write-down), Cr Inventory. Manual journal at period end.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Manual - The stock time-out feature flags the SKUs that need this.

### H05 - Provision for expected returns at month-end

- **What happens:** Sales made in the last days of a month will be returned next month; many CAs book a provision based on the historical return rate.
- **Stock:** -
- **Journal entry:** Dr Sales Returns, Cr Provision for Returns; reversed next month. A period-end batch job - not automated.
- **GST:** None until the credit notes are issued.
- **Claim / recovery:** -
- **In the app:** Not yet in app - Recommend a period-end 'returns provision' helper using the last 90 days' return rate.

### H06 - Cut-off: RTO and returns in transit at month-end

- **What happens:** Goods on their way back when the period closes.
- **Stock:** Not in the warehouse.
- **Journal entry:** Revenue is reversed only on receipt, so it stays in the old month. Disclose / provide.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked

### H07 - Round-off differences

- **What happens:** Paise differences between invoice, refund and gateway.
- **Stock:** -
- **Journal entry:** Small differences: add a Round Off line using the remainder balancing figure.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Manual - Rules support a balancing-figure line.

## I. Warehouse and stock

*What physically happens to the goods that come back.*

### I01 - Goods received note for returns

- **What happens:** Quantity received vs expected; photos at the dock.
- **Stock:** Count checked.
- **Journal entry:** No entry.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked - Received date is stored; inspection result records the outcome.

### I02 - Quality grading - A, B, C, D

- **What happens:** A: resell as new. B: minor defect, discount. C: repair / re-pack. D: scrap or donate.
- **Stock:** A restocks; B/C quarantined; D written off.
- **Journal entry:** A: Dr Inventory, Cr COGS. D: Dr Damaged & Lost Stock Loss.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Partly automatic - The app has good / damaged / wrong_item / missing + restocked / quarantined / claimed. Recommend a grade field.
- **Rules involved:** `INV-RETURN-RESTOCK`, `INV-WRITEOFF-RETURN`

### I03 - Restock into which warehouse

- **What happens:** Own warehouse vs the nearest 3PL.
- **Stock:** Goes to the selected warehouse.
- **Journal entry:** No entry (same company).
- **GST:** Stock transfer between GSTINs would need a delivery challan.
- **Claim / recovery:** -
- **In the app:** Tracked - Warehouse is chosen when dispositioning.

### I04 - Quarantine bin

- **What happens:** Held for inspection, repair or claim evidence.
- **Stock:** Not counted as available stock.
- **Journal entry:** No entry unless it is written off.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked - Only restocked goods enter the sellable balance.

### I05 - Cycle-count differences

- **What happens:** Count differs from the system.
- **Stock:** Adjusted up or down.
- **Journal entry:** Shortage: Dr Damaged & Lost Stock Loss, Cr Inventory. Excess: reverse.
- **GST:** ITC reversal on shortage (H03).
- **Claim / recovery:** -
- **In the app:** Automatic - Inventory pack.
- **Rules involved:** `INV-ADJ-LOSS`, `INV-ADJ-GAIN`

### I06 - Return with an unmapped SKU

- **What happens:** Product on the order line has no SKU mapping.
- **Stock:** Not restocked - the app warns.
- **Journal entry:** No inventory movement, so no COGS entry.
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked - Map the SKU, then restock manually.

### I07 - Aged returned stock (seasonal garments)

- **What happens:** Returned winterwear in March loses value.
- **Stock:** Sits in stock.
- **Journal entry:** Write-down (H04).
- **GST:** -
- **Claim / recovery:** -
- **In the app:** Tracked - Per-SKU stock time-out highlights these on the Inventory screen.

## What to build next (from the gaps above)

The scenarios marked *Not yet in app*, in rough order of value:

- **C20 Partial return - 1 of 3 items sent back** - disposition_return() restocks every line of the order, and the credit note covers the whole invoice. Recommend line-level returns (return_lines table). Highest-value next improvement for returns.
- **C19 Partial refund (deduction for wear, missing tag, restocking fee)** - Credit notes are whole-invoice today. Recommend a partial credit-note amount on the return.
- **D01 Exchange - size or colour swap** - No exchange object linking the two orders. Recommend an 'Exchange' return type that auto-creates the replacement order.
- **F06 GST TCS and income-tax TDS on payouts** - Ledgers exist but settlements do not capture TCS/TDS yet. Recommend two extra settlement fields and lines in STL-RECEIPT.
- **B09 RTO of a prepaid own-store order** - There is no refund screen for RTOs (only for customer returns). Recommend adding a 'Mark refunded' action on the RTO page.
- **A05 Attempt failed - address wrong or incomplete** - No NDR queue in the app. Recommend an 'Action needed' list fed by the courier webhook so someone calls the customer before the parcel turns around.
- **B13 Chronic RTO pincodes and customers** - Recommend RTO rate by pincode / courier / SKU on the Business Insights screen.
- **H05 Provision for expected returns at month-end** - Recommend a period-end 'returns provision' helper using the last 90 days' return rate.
- **F04 Commission, closing fee, shipping fee, collection fee** - All deductions land in one expense ledger. Recommend fee-type ledgers (commission, shipping, closing, collection, RTO).
- **A03 Delivery delayed beyond the promised date** - No promised-date / SLA tracking in the app. Recommend adding expected_delivery_date to orders and an 'overdue in transit' list.
- **C01 Return policy and window** - The app does not enforce a return window or category rules. Recommend a window per category and a warning on late return requests.
- **G09 Supplier claim for defective goods** - No suppliers or purchases module yet.
