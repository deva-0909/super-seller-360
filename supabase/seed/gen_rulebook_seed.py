#!/usr/bin/env python3
"""Generates supabase/migrations/0051_default_rule_book.sql - the CA default rule book.

Everything a 10-year CA would set up for a multi-channel garment seller, as DATA (editable in the app):
event catalogue + field dictionary + ~45 rules. Run:  python3 supabase/seed/gen_rulebook_seed.py
"""
import json, pathlib

def q(s):
    return "'" + str(s).replace("'", "''") + "'"

# ------------------------------------------------------------------ event catalogue
ORDER_FIELDS = [
    ("order_ref", "Order reference", "text", "Marketplace / store order id"),
    ("channel", "Channel", "text", "Channel name, e.g. Amazon India"),
    ("channel_type", "Channel type", "text", "d2c or marketplace"),
    ("payment_type", "Payment type", "text", "prepaid or cod"),
    ("ship_state", "Ship-to state", "text", "Place of supply"),
    ("interstate", "Interstate supply", "boolean", "true when ship-to state differs from company state (IGST)"),
    ("amount", "Invoice total", "number", "GST-inclusive invoice value"),
    ("taxable", "Taxable value", "number", "Invoice total minus GST"),
    ("tax", "GST amount", "number", "Total GST on the invoice"),
    ("cgst", "CGST", "number", "Half of GST for intrastate supplies, else 0"),
    ("sgst", "SGST", "number", "Half of GST for intrastate supplies, else 0"),
    ("igst", "IGST", "number", "Full GST for interstate supplies, else 0"),
    ("has_invoice", "Order was invoiced", "boolean", "false means there is nothing to reverse"),
    ("already_credited", "Credit note already exists", "boolean", "prevents double reversal"),
]
SAMPLE_ORDER = {"order_ref": "SHOP-1101", "channel": "Shopify Store", "channel_type": "d2c", "payment_type": "prepaid",
                "ship_state": "Gujarat", "interstate": False, "amount": 1049.0, "taxable": 999.05, "tax": 49.95,
                "cgst": 24.98, "sgst": 24.97, "igst": 0, "has_invoice": True, "already_credited": False}

def ev(code, label, desc, trig, src, pack, fields, sample, order=100):
    return dict(code=code, label=label, desc=desc, trig=trig, src=src, pack=pack, fields=fields, sample=sample, order=order)

EVENTS = [
    ev("return.accepted", "Customer return accepted",
       "Goods came back from the customer (reverse pickup received). Revenue and GST are reversed with a credit note.",
       "Return status becomes Received / Inspected / Restocked / Quarantined / Claimed", "return", "core",
       ORDER_FIELDS + [("reason", "Return reason", "text", "e.g. Size/fit issue, Damaged on arrival, Wrong item")],
       {**SAMPLE_ORDER, "reason": "Size/fit issue", "date": "2026-10-04"}, 10),
    ev("return.refund_paid", "Customer refund paid",
       "The refund has been paid to the customer (return refund status = Refunded).",
       "Return refund status becomes Refunded", "return", "core",
       ORDER_FIELDS + [("reason", "Return reason", "text", "")], {**SAMPLE_ORDER, "reason": "Size/fit issue", "date": "2026-10-04"}, 20),
    ev("return.writeoff", "Returned goods not resaleable",
       "Returned goods were quarantined or claimed - cost is moved out of COGS into losses.",
       "Return status becomes Quarantined or Claimed", "return", "inventory_cogs",
       ORDER_FIELDS + [("reason", "Return reason", "text", ""), ("inspection_result", "Inspection result", "text", "good / damaged / wrong_item / missing"),
                       ("disposition", "Disposition", "text", "quarantined or claimed"), ("cogs", "Cost of goods", "number", "Quantity x cost price of the order lines")],
       {**SAMPLE_ORDER, "reason": "Damaged on arrival", "inspection_result": "damaged", "disposition": "claimed", "cogs": 640.0, "date": "2026-10-04"}, 30),
    ev("order.cancelled", "Invoiced order cancelled",
       "An order that was already invoiced is cancelled before delivery - the invoice is reversed.",
       "Order fulfilment status becomes Cancelled and an invoice exists", "order", "core",
       ORDER_FIELDS, {**SAMPLE_ORDER, "date": "2026-10-04"}, 40),
    ev("rto.received", "RTO received at warehouse",
       "A shipment that could not be delivered is back at the warehouse. The sale is reversed with a credit note.",
       "RTO status becomes Received / Inspected / Restocked / Quarantined / Claimed", "rto", "core",
       ORDER_FIELDS + [("reason", "RTO reason", "text", "e.g. Customer unreachable, Address incomplete, Refused"), ("awb", "AWB", "text", "Courier waybill")],
       {**SAMPLE_ORDER, "payment_type": "cod", "reason": "Customer unreachable", "awb": "AWB1234567890", "date": "2026-10-04"}, 50),
    ev("rto.writeoff", "RTO goods not resaleable",
       "RTO goods came back damaged / swapped / incomplete - cost is moved out of COGS into losses.",
       "RTO status becomes Quarantined or Claimed", "rto", "inventory_cogs",
       ORDER_FIELDS + [("reason", "RTO reason", "text", ""), ("awb", "AWB", "text", ""), ("inspection_result", "Inspection result", "text", ""),
                       ("disposition", "Disposition", "text", ""), ("cogs", "Cost of goods", "number", "")],
       {**SAMPLE_ORDER, "reason": "Customer refused", "inspection_result": "damaged", "disposition": "quarantined", "cogs": 640.0, "date": "2026-10-04"}, 60),
    ev("cod.collected", "COD cash collected by courier",
       "The courier collected cash from the customer. The money now sits with the courier, not with the customer.",
       "COD collected amount increases", "cod", "core",
       [("courier", "Courier", "text", "Courier name"), ("order_ref", "Order reference", "text", ""), ("amount", "Amount collected now", "number", ""),
        ("cod_amount", "COD order value", "number", "")],
       {"courier": "Delhivery", "order_ref": "SHOP-1105", "amount": 1299.0, "cod_amount": 1299.0, "date": "2026-10-04"}, 70),
    ev("cod.remitted", "COD remittance received",
       "The courier remitted COD cash to the bank.", "COD remitted amount increases", "cod", "core",
       [("courier", "Courier", "text", ""), ("order_ref", "Order reference", "text", ""), ("amount", "Amount remitted now", "number", ""),
        ("total_remitted", "Total remitted so far", "number", ""), ("cod_amount", "COD order value", "number", ""),
        ("short", "Still short", "number", "COD value minus total remitted")],
       {"courier": "Delhivery", "order_ref": "SHOP-1105", "amount": 1299.0, "total_remitted": 1299.0, "cod_amount": 1299.0, "short": 0, "date": "2026-10-04"}, 80),
    ev("settlement.reconciled", "Marketplace settlement reconciled",
       "A marketplace / gateway payout has been matched to the bank. Money received, shortfall or excess recognised.",
       "Settlement status moves from Pending to Reconciled / Short pay / Excess", "settlement", "core",
       [("channel", "Channel", "text", ""), ("channel_type", "Channel type", "text", ""), ("settlement_ref", "Settlement id", "text", ""),
        ("gross", "Gross sales in settlement", "number", ""), ("deductions", "Fees deducted (incl. GST)", "number", ""),
        ("expected", "Expected payout", "number", "gross minus deductions"), ("actual", "Actual payout received", "number", ""),
        ("short", "Short-paid", "number", "expected minus actual, if positive"), ("excess", "Excess received", "number", "actual minus expected, if positive")],
       {"channel": "Amazon India", "channel_type": "marketplace", "settlement_ref": "AMZ-SETTLE-2026-09-S1", "gross": 52000.0,
        "deductions": 8120.0, "expected": 43880.0, "actual": 43740.0, "short": 140.0, "excess": 0, "date": "2026-10-04"}, 90),
    ev("claim.approved", "Claim approved",
       "A courier / marketplace claim was approved. The recovery is now virtually certain, so it is recognised.",
       "Claim status becomes Approved", "claim", "core",
       [("claim_type", "Claim type", "text", "lost_shipment / damaged_return / incorrect_deduction / excess_deduction / other"),
        ("order_ref", "Order reference", "text", ""), ("amount", "Approved amount", "number", ""), ("channel", "Channel", "text", "")],
       {"claim_type": "lost_shipment", "order_ref": "AMAZ-1114", "amount": 1099.0, "channel": "Amazon India", "date": "2026-10-04"}, 100),
    ev("claim.recovered", "Claim amount recovered",
       "Money for an approved claim was received.", "Claim recovered amount increases", "claim", "core",
       [("claim_type", "Claim type", "text", ""), ("order_ref", "Order reference", "text", ""), ("amount", "Amount recovered now", "number", ""),
        ("total_recovered", "Total recovered so far", "number", "")],
       {"claim_type": "lost_shipment", "order_ref": "AMAZ-1114", "amount": 1099.0, "total_recovered": 1099.0, "date": "2026-10-04"}, 110),
    ev("claim.rejected", "Claim rejected",
       "A claim was rejected. Nothing was recognised on filing, so by default there is no entry.", "Claim status becomes Rejected", "claim", "core",
       [("claim_type", "Claim type", "text", ""), ("order_ref", "Order reference", "text", ""), ("amount", "Claimed amount", "number", "")],
       {"claim_type": "damaged_return", "order_ref": "FLIP-1106", "amount": 799.0, "date": "2026-10-04"}, 120),
]
INV_FIELDS = [("movement_type", "Movement type", "text", ""), ("sku", "SKU", "text", ""), ("product", "Product", "text", ""),
              ("warehouse", "Warehouse", "text", ""), ("quantity", "Quantity (signed)", "number", "negative = stock going out"), ("qty", "Quantity (absolute)", "number", "always positive"),
              ("unit_cost", "Unit cost price", "number", ""), ("cogs", "Cost value", "number", "absolute quantity x unit cost")]
SAMPLE_INV = {"movement_type": "sale_dispatch", "sku": "MTEE-BLK-M", "product": "Men Round Neck Cotton T-Shirt - Black", "warehouse": "Surat Warehouse",
              "quantity": -1, "qty": 1, "unit_cost": 160.0, "cogs": 160.0, "date": "2026-10-04"}
for mv, lab in [("sale_dispatch", "Stock dispatched for a sale"), ("return_restock", "Stock restocked from a return"),
                ("rto_restock", "Stock restocked from an RTO"), ("adjustment", "Stock adjustment (count difference, damage, found stock)"),
                ("initial_stock", "Opening stock loaded")]:
    EVENTS.append(ev("inventory." + mv, lab, "Perpetual-inventory entry for a stock movement.", "A stock movement of type " + mv + " is recorded",
                     "inventory", "inventory_cogs", INV_FIELDS, {**SAMPLE_INV, "movement_type": mv}, 200))
BANK_FIELDS = [("description", "Bank narration", "text", "The reference / narration on the bank statement line"),
               ("amount", "Amount", "number", "GST-inclusive amount of the bank line"),
               ("direction", "Direction", "text", "debit (money out) or credit (money in)"),
               ("bank_account", "Bank", "text", "Bank name"),
               ("base", "Amount before GST", "number", "Filled using the rule's GST rate"),
               ("tax", "GST in the amount", "number", "Filled using the rule's GST rate")]
EVENTS.append(ev("bank.debit", "Bank statement line - money out",
                 "QuickBooks-style bank rule: classify a payment by keywords in the bank narration.",
                 "A bank line (debit) is imported or added and is still unmatched", "bank_txn", "core", BANK_FIELDS,
                 {"description": "DELHIVERY FREIGHT INV 5521", "amount": 4260.0, "direction": "debit", "bank_account": "HDFC Bank", "date": "2026-10-04"}, 300))
EVENTS.append(ev("bank.credit", "Bank statement line - money in",
                 "Classify a receipt by keywords in the bank narration.", "A bank line (credit) is imported or added and is still unmatched",
                 "bank_txn", "core", BANK_FIELDS,
                 {"description": "UPI-CR-7734209981", "amount": 1250.0, "direction": "credit", "bank_account": "HDFC Bank", "date": "2026-10-04"}, 310))

# ------------------------------------------------------------------ rules
# line: (side, ledger name | 'BANK', amount_source, percent)
RULES = []
def rule(code, name, group, event, lines, conds=(), priority=100, vt="JOURNAL", auto=True, action="post", stop=True,
         gst=None, narr=None, notes=None, pack="core", active=True, mode="all"):
    RULES.append(dict(code=code, name=name, group=group, event=event, lines=lines, conds=list(conds), priority=priority, vt=vt,
                      auto=auto, action=action, stop=stop, gst=gst, narr=narr, notes=notes, pack=pack, active=active, mode=mode))

SR, GST_C, GST_S, GST_I = "Sales Returns & RTO Reversals", "CGST Payable (Output)", "SGST Payable (Output)", "IGST Payable (Output)"
REC, CRP, BANKL = "Trade Receivables", "Customer Refunds Payable", "BANK"
def credit_note_lines(cr_ledger):
    return [("debit", SR, "taxable"), ("debit", GST_C, "cgst"), ("debit", GST_S, "sgst"), ("debit", GST_I, "igst"), ("credit", cr_ledger, "amount")]
HAS = [("has_invoice", "equals", "true"), ("already_credited", "equals", "false")]

# ---- Customer returns
rule("RET-CN-MKT", "Return accepted - marketplace order (credit note)", "Customer returns", "return.accepted",
     credit_note_lines(REC), HAS + [("channel_type", "equals", "marketplace")], 10, "CREDIT_NOTE",
     narr="Credit note - customer return {order_ref} ({reason}) - refund is netted in the {channel} settlement",
     notes="On a marketplace sale the platform collects the money and refunds the customer itself, then adjusts our next settlement. So we reverse revenue and GST and reduce what the marketplace owes us (Trade Receivables). No cash leaves our bank.")
rule("RET-CN-D2C", "Return accepted - own store order (credit note)", "Customer returns", "return.accepted",
     credit_note_lines(CRP), HAS + [("channel_type", "equals", "d2c")], 20, "CREDIT_NOTE",
     narr="Credit note - customer return {order_ref} ({reason}) - refund due to customer",
     notes="On our own store we already hold (or will hold) the customer's money. Reversing the sale creates a liability to refund the customer (Customer Refunds Payable), cleared when the refund is paid.")
rule("RET-CN-OTHER", "Return accepted - any other channel (credit note)", "Customer returns", "return.accepted",
     credit_note_lines(REC), HAS, 90, "CREDIT_NOTE", narr="Credit note - customer return {order_ref} ({reason})",
     notes="Safety net so a return on a new channel type is never left without a credit note.")
rule("RET-REFUND-D2C", "Refund paid to customer - own store", "Customer returns", "return.refund_paid",
     [("debit", CRP, "amount"), ("credit", BANKL, "amount")], [("channel_type", "equals", "d2c")], 10, "PAYMENT",
     narr="Refund paid to customer - return {order_ref}",
     notes="Clears the refund liability raised when the credit note was issued.")
rule("RET-REFUND-MKT", "Refund on marketplace order - leave to settlement", "Customer returns", "return.refund_paid",
     [], [("channel_type", "equals", "marketplace")], 20, action="ignore",
     notes="The marketplace refunds the customer and recovers it through the settlement. No bank entry in our books.")
rule("ORD-CANCEL-D2C-PREPAID", "Invoiced order cancelled - own store, prepaid (credit note)", "Cancellations", "order.cancelled",
     credit_note_lines(CRP), HAS + [("channel_type", "equals", "d2c"), ("payment_type", "equals", "prepaid")], 10, "CREDIT_NOTE",
     narr="Credit note - order {order_ref} cancelled after invoicing - prepaid amount to be refunded")
rule("ORD-CANCEL-OTHER", "Invoiced order cancelled - everything else (credit note)", "Cancellations", "order.cancelled",
     credit_note_lines(REC), HAS, 90, "CREDIT_NOTE", narr="Credit note - order {order_ref} cancelled after invoicing",
     notes="COD and marketplace orders: nothing was collected from the customer by us, so the receivable is reduced.")

# ---- RTO
rule("RTO-REV-COD", "RTO received - COD order (credit note)", "RTO / undelivered", "rto.received",
     credit_note_lines(REC), HAS + [("payment_type", "equals", "cod")], 10, "CREDIT_NOTE",
     narr="Credit note - RTO of order {order_ref} ({reason}), AWB {awb}",
     notes="The parcel never reached the customer, so the sale did not happen. COD means no money was collected, so only the receivable is reversed.")
rule("RTO-REV-PREPAID-D2C", "RTO received - own store, prepaid (credit note)", "RTO / undelivered", "rto.received",
     credit_note_lines(CRP), HAS + [("payment_type", "equals", "prepaid"), ("channel_type", "equals", "d2c")], 20, "CREDIT_NOTE",
     narr="Credit note - RTO of order {order_ref} ({reason}), AWB {awb} - prepaid amount to be refunded",
     notes="Customer already paid us, so reversing the sale creates a refund liability.")
rule("RTO-REV-OTHER", "RTO received - marketplace / other (credit note)", "RTO / undelivered", "rto.received",
     credit_note_lines(REC), HAS, 90, "CREDIT_NOTE", narr="Credit note - RTO of order {order_ref} ({reason}), AWB {awb}")

# ---- COD
rule("COD-COLLECTED", "COD cash collected by courier", "Cash on delivery", "cod.collected",
     [("debit", "COD Receivable from Couriers", "amount"), ("credit", REC, "amount")], [], 10,
     narr="COD collected by {courier} for order {order_ref}",
     notes="Moves the amount from 'customer owes us' to 'courier owes us'. Whatever the courier has not remitted stays visible here.")
rule("COD-REMITTED", "COD remittance received from courier", "Cash on delivery", "cod.remitted",
     [("debit", BANKL, "amount"), ("credit", "COD Receivable from Couriers", "amount")], [], 10, "RECEIPT",
     narr="COD remittance from {courier} for order {order_ref}")

# ---- Settlements
rule("STL-RECEIPT", "Marketplace / gateway settlement received", "Settlements", "settlement.reconciled",
     [("debit", BANKL, "actual"), ("debit", "Settlement Short-Pay Receivable", "short"), ("credit", REC, "expected"),
      ("credit", "Settlement Excess Received", "excess")], [], 10, "RECEIPT",
     narr="Settlement {settlement_ref} from {channel}",
     notes="Fees and ITC were already booked when the settlement was reconciled. This entry records the cash: the payout hits the bank, any short-payment becomes a receivable to chase, any excess becomes a liability.")

# ---- Claims
rule("CLM-APPROVED-DEDUCTION", "Claim approved - wrongly deducted fee", "Claims", "claim.approved",
     [("debit", "Claims Receivable - Courier & Marketplace", "amount"), ("credit", "Marketplace Commission Expense", "amount")],
     [("claim_type", "in", "incorrect_deduction|excess_deduction")], 10, narr="Claim approved - fee wrongly deducted, order {order_ref}",
     notes="A recovered over-deduction is not income - it reverses the expense that was wrongly booked.")
rule("CLM-APPROVED", "Claim approved - lost / damaged shipment", "Claims", "claim.approved",
     [("debit", "Claims Receivable - Courier & Marketplace", "amount"), ("credit", "Courier & Marketplace Claim Recoveries", "amount")],
     [], 20, narr="Claim approved ({claim_type}) - order {order_ref}",
     notes="Recognised only on approval - a filed claim is a contingent asset and is not booked until recovery is virtually certain.")
rule("CLM-RECOVERED", "Claim amount received", "Claims", "claim.recovered",
     [("debit", BANKL, "amount"), ("credit", "Claims Receivable - Courier & Marketplace", "amount")], [], 10, "RECEIPT",
     narr="Claim recovery received - order {order_ref}")

# ---- Perpetual inventory & COGS pack (OFF by default)
PACK_NOTE = " Switch the whole 'Inventory & COGS' pack on only after posting an opening-stock valuation entry, otherwise the Inventory ledger starts negative."
rule("INV-INITIAL", "Opening stock loaded", "Inventory & COGS", "inventory.initial_stock",
     [("debit", "Inventory - Stock-in-Trade", "cogs"), ("credit", "Opening Balance Equity", "cogs")], [], 10, narr="Opening stock - {sku}", pack="inventory_cogs", active=False,
     notes="Stock brought in at go-live." + PACK_NOTE)
rule("INV-DISPATCH-COGS", "Stock dispatched - cost of goods sold", "Inventory & COGS", "inventory.sale_dispatch",
     [("debit", "Cost of Goods Sold", "cogs"), ("credit", "Inventory - Stock-in-Trade", "cogs")], [], 10, narr="COGS - {sku} x {qty}", pack="inventory_cogs", active=False,
     notes="Cost moves from stock to COGS when goods leave the warehouse." + PACK_NOTE)
rule("INV-RETURN-RESTOCK", "Returned stock back in warehouse", "Inventory & COGS", "inventory.return_restock",
     [("debit", "Inventory - Stock-in-Trade", "cogs"), ("credit", "Cost of Goods Sold", "cogs")], [], 10, narr="Return restock - {sku} x {qty}", pack="inventory_cogs", active=False,
     notes="Resaleable returned goods go back into stock at cost and COGS is reversed.")
rule("INV-RTO-RESTOCK", "RTO stock back in warehouse", "Inventory & COGS", "inventory.rto_restock",
     [("debit", "Inventory - Stock-in-Trade", "cogs"), ("credit", "Cost of Goods Sold", "cogs")], [], 10, narr="RTO restock - {sku} x {qty}", pack="inventory_cogs", active=False)
rule("INV-ADJ-LOSS", "Stock adjustment - shortage / damage", "Inventory & COGS", "inventory.adjustment",
     [("debit", "Damaged & Lost Stock Loss", "cogs"), ("credit", "Inventory - Stock-in-Trade", "cogs")], [("quantity", "lt", "0")], 10,
     narr="Stock shortage / damage - {sku} x {qty}", pack="inventory_cogs", active=False,
     notes="Counted short or damaged in the warehouse. Under GST Sec 17(5)(h) ITC on goods lost, stolen or destroyed must be reversed - your CA can add that as an extra line.")
rule("INV-ADJ-GAIN", "Stock adjustment - excess found", "Inventory & COGS", "inventory.adjustment",
     [("debit", "Inventory - Stock-in-Trade", "cogs"), ("credit", "Damaged & Lost Stock Loss", "cogs")], [("quantity", "gt", "0")], 20,
     narr="Stock excess found - {sku} x {qty}", pack="inventory_cogs", active=False)
rule("INV-WRITEOFF-RETURN", "Returned goods not resaleable - move cost to loss", "Inventory & COGS", "return.writeoff",
     [("debit", "Damaged & Lost Stock Loss", "cogs"), ("credit", "Cost of Goods Sold", "cogs")],
     [("disposition", "equals", "claimed")], 10, narr="Returned goods written off - {order_ref} ({inspection_result})", pack="inventory_cogs", active=False,
     notes="Goods that will not be resold are a loss, not COGS. Quarantined stock is NOT written off by default (it may be resold as B-grade); change the condition if your policy differs.")
rule("INV-WRITEOFF-RTO", "RTO goods not resaleable - move cost to loss", "Inventory & COGS", "rto.writeoff",
     [("debit", "Damaged & Lost Stock Loss", "cogs"), ("credit", "Cost of Goods Sold", "cogs")],
     [("disposition", "equals", "claimed")], 10, narr="RTO goods written off - {order_ref} ({inspection_result})", pack="inventory_cogs", active=False)

# ---- Bank rules: money out (QuickBooks-style keyword rules)
def bank_out(code, name, kw, ledger, gst, prio, auto, notes=None, extra=(), active=True, op="contains_any"):
    lines = [("debit", ledger, "base")]
    if gst:
        lines.append(("debit", "GST Input Tax Credit (ITC)", "tax"))
    lines.append(("credit", BANKL, "amount"))
    rule(code, name, "Bank rules - money out", "bank.debit", lines, [("description", op, kw)] + list(extra), prio, "PAYMENT", auto,
         gst=gst, narr=name.split(" - ")[0] + " - {description}", notes=notes, active=active)

bank_out("BNK-RTO-CHARGES", "RTO / reverse pickup charges", "RTO CHARGE|RTO FEE|\\yRVP\\y|REVERSE PICKUP|RETURN SHIPPING|REVERSE LOGISTICS", "Reverse Logistics & RTO Charges", 18, 5, True,
         "Kept separate from forward freight so you can see what returns really cost you.", op="regex")
bank_out("BNK-COURIER", "Courier / freight charges", "BLUEDART|BLUE DART|DELHIVERY|DTDC|ECOM EXPRESS|XPRESSBEES|SHADOWFAX|EKART|SHIPROCKET|COURIER|FREIGHT|LOGISTICS", "Freight & Courier Charges - Outward", 18, 10, True,
         "Courier services carry 18% GST. The GST part is booked as input tax credit; the rest is expense.")
bank_out("BNK-GATEWAY", "Payment gateway charges", "RAZORPAY FEE|RAZORPAY CHG|PAYU FEE|CASHFREE FEE|PAYTM PG|STRIPE FEE|CCAVENUE FEE|\\yMDR\\y|GATEWAY CHARGE", "Payment Gateway Charges", 18, 12, True, op="regex")
bank_out("BNK-BANK-CHARGES", "Bank charges", "BANK CHARGES|BANK-CHARGES|SMS CHARGES|AMC CHARGES|ANNUAL FEE|MIN BAL|NEFT CHG|IMPS CHG|DEBIT CARD FEE|CHEQUE BOOK", "Bank Charges", 18, 15, True,
         "Bank service charges attract 18% GST.")
bank_out("BNK-PENALTY", "Marketplace penalties / chargebacks", "PENALTY|CHARGEBACK|A-TO-Z|ATOZ|SPF DEDUCTION|CANCELLATION FEE|LATE DISPATCH", "Marketplace Penalties & Chargebacks", None, 20, False,
         "Penalties are not a supply - no GST credit. Left for review because a penalty is often disputable (and claimable).")
bank_out("BNK-PACKAGING", "Packaging materials", "\\y(PACKAGING|PACKING|CARTON|BUBBLE|POLY ?BAG|TAPE|BOX)", "Packaging Materials Consumed", 18, 30, False,
         "Posted as a draft for review - purchases usually need a supplier invoice check before ITC is claimed.", op="regex")
bank_out("BNK-ADS", "Advertising / promotion", "FACEBOOK|META ADS|GOOGLE ADS|GOOGLEADS|INSTAGRAM|FB ADS|AMAZON ADS|FLIPKART ADS", "Advertising & Promotion", 18, 32, False,
         "Foreign platforms are billed under reverse charge - the CA may want 0% here and a separate RCM entry.")
bank_out("BNK-SOFTWARE", "Software / subscriptions", "\\y(SHOPIFY|AWS|AMAZON WEB|GODADDY|VERCEL|SUPABASE|ZOHO|GOOGLE WORKSPACE|MICROSOFT|CANVA|NOTION)\\y", "Software & Subscriptions", 18, 34, False, op="regex")
bank_out("BNK-PROF-FEES", "Professional / audit fees", "CA FEES|AUDIT FEE|PROFESSIONAL|CONSULTANT|LEGAL FEE|RETAINER", "Professional & Audit Fees", 18, 36, False,
         "TDS under Sec 194J may apply on professional fees - confirm with your CA.")
bank_out("BNK-SALARY", "Salaries & wages", "SALARY|PAYROLL|WAGES|STAFF PAY|STIPEND", "Salaries & Wages", None, 40, False)
bank_out("BNK-RENT", "Rent", "\\y(RENT|LEASE)\\y", "Rent", None, 42, False, "Commercial rent may carry 18% GST and TDS 194-I. Set the GST rate here if your landlord is registered.", op="regex")
bank_out("BNK-UTILITIES", "Electricity & utilities", "ELECTRICITY|DGVCL|UGVCL|TORRENT POWER|WATER BILL|BROADBAND|AIRTEL|JIO FIBER|INTERNET", "Electricity & Utilities", None, 44, False)
bank_out("BNK-ADV-TAX", "Advance tax / TDS paid", "ADVANCE TAX|INCOME TAX|TDS PAYMENT|CHALLAN 280|CHALLAN 281|ITNS", "Advance Tax & TDS Paid", None, 50, False)
rule("BNK-GST-PAYMENT", "GST paid to government", "Bank rules - money out", "bank.debit",
     [("debit", "GST Payable (Output)", "amount"), ("credit", BANKL, "amount")],
     [("description", "contains_any", "GST PAYMENT|GSTN|CBIC|PMT-06|GST CHALLAN|GST-PMT")], 52, "PAYMENT", False,
     narr="GST paid - {description}", notes="Draft for review: the CA splits it between CGST / SGST / IGST ledgers and any interest or late fee.")
rule("BNK-FALLBACK-DEBIT", "Any other payment - hold in suspense for review", "Bank rules - money out", "bank.debit",
     [("debit", "Suspense - To Be Classified", "amount"), ("credit", BANKL, "amount")], [], 900, "PAYMENT", False,
     narr="Unclassified payment - {description}", notes="Catch-all so nothing is silently missed. Accountant reviews and reclassifies.")

# ---- Bank rules: money in
rule("BNK-IGNORE-SETTLEMENT", "Marketplace / gateway / courier payouts - leave for reconciliation", "Bank rules - money in", "bank.credit",
     [], [("description", "contains_any", "AMAZON|AMZN|FLIPKART|SHOPIFY|RAZORPAY|PAYU|CASHFREE|SETTLEMENT|PAYOUT|COD REMIT|COD-REMIT|DELHIVERY COD|BLUEDART COD|DTDC COD")],
     5, action="ignore", notes="These credits are matched on the Settlements / COD screens, which post the proper entry. Auto-posting them here would double count.")
rule("BNK-INTEREST", "Bank interest received", "Bank rules - money in", "bank.credit",
     [("debit", BANKL, "amount"), ("credit", "Interest Income", "amount")],
     [("description", "contains_any", "INT.PD|INT PD|INTEREST|INT CR|SAVINGS INT")], 10, "RECEIPT", True, narr="Interest received - {description}")
rule("BNK-UPI-RECEIPT", "Customer UPI receipt", "Bank rules - money in", "bank.credit",
     [("debit", BANKL, "amount"), ("credit", REC, "amount")], [("description", "starts_with", "UPI-CR")], 20, "RECEIPT", False,
     narr="UPI receipt - {description}", notes="Direct customer payment. Draft for review so the accountant can confirm which invoice it settles.")
rule("BNK-FALLBACK-CREDIT", "Any other receipt - hold in suspense for review", "Bank rules - money in", "bank.credit",
     [("debit", BANKL, "amount"), ("credit", "Suspense - To Be Classified", "amount")], [], 900, "RECEIPT", False,
     narr="Unclassified receipt - {description}")

# ------------------------------------------------------------------ emit SQL (compact: one JSON document + a generic loader)
def fieldset(fields):
    if fields[:len(ORDER_FIELDS)] == ORDER_FIELDS: return "order", fields[len(ORDER_FIELDS):]
    if fields == INV_FIELDS: return "inv", []
    if fields == BANK_FIELDS: return "bank", []
    return None, fields

doc = {"fieldsets": {"order": ORDER_FIELDS, "inv": INV_FIELDS, "bank": BANK_FIELDS}, "events": [], "rules": []}
for e in EVENTS:
    fs, extra = fieldset(e["fields"])
    doc["events"].append(dict(code=e["code"], label=e["label"], desc=e["desc"], trig=e["trig"], src=e["src"], pack=e["pack"],
                              sample=e["sample"], order=e["order"], fs=fs, extra=extra))
for r in RULES:
    doc["rules"].append(dict(code=r["code"], name=r["name"], notes=r["notes"], group=r["group"], pack=r["pack"], event=r["event"],
                             action=r["action"], vt=r["vt"], mode=r["mode"], priority=r["priority"], stop=r["stop"], auto=r["auto"],
                             gst=r["gst"], narr=r["narr"], active=r["active"], conds=[list(c) for c in r["conds"]],
                             lines=[list(l) for l in r["lines"]]))
payload = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
assert "$j$" not in payload

sql = """-- 0051: the CA default rule book (generated by supabase/seed/gen_rulebook_seed.py - edit the generator, not this file).
-- Event catalogue + field dictionary (drive the editor dropdowns) + the shipped rules. Every rule is editable in the app;
-- 'Restore default' puts back exactly what is defined here. Re-running this migration resets the SHIPPED rules only.
do $seed$
declare
  d jsonb := $j$@@PAYLOAD@@$j$::jsonb;
  e jsonb; r jsonb; f jsonb; c jsonb; l jsonb; v uuid; i int; fs text;
begin
  delete from journal_rules where is_system;
  delete from journal_event_fields;
  delete from journal_event_types where event_type not in (select event_type from journal_rules);

  for e in select * from jsonb_array_elements(d -> 'events') loop
    insert into journal_event_types (event_type, label, description, trigger_text, source_type, pack, sample_ctx, sort_order)
    values (e ->> 'code', e ->> 'label', e ->> 'desc', e ->> 'trig', e ->> 'src', e ->> 'pack', e -> 'sample', (e ->> 'order')::int)
    on conflict (event_type) do update set label = excluded.label, description = excluded.description, trigger_text = excluded.trigger_text,
      source_type = excluded.source_type, pack = excluded.pack, sample_ctx = excluded.sample_ctx, sort_order = excluded.sort_order;
    fs := e ->> 'fs';
    if fs is not null then
      for f in select * from jsonb_array_elements(d -> 'fieldsets' -> fs) loop
        insert into journal_event_fields (event_type, field, label, data_type, description)
        values (e ->> 'code', f ->> 0, f ->> 1, f ->> 2, f ->> 3);
      end loop;
    end if;
    for f in select * from jsonb_array_elements(e -> 'extra') loop
      insert into journal_event_fields (event_type, field, label, data_type, description)
      values (e ->> 'code', f ->> 0, f ->> 1, f ->> 2, f ->> 3);
    end loop;
  end loop;

  for r in select * from jsonb_array_elements(d -> 'rules') loop
    insert into journal_rules (rule_code, name, notes, rule_group, pack, event_type, action, voucher_type_code, match_mode, priority,
                               stop_on_match, auto_post, gst_rate_pct, narration_template, effective_from, status, is_system)
    values (r ->> 'code', r ->> 'name', r ->> 'notes', r ->> 'group', r ->> 'pack', r ->> 'event', r ->> 'action', r ->> 'vt', r ->> 'mode',
            (r ->> 'priority')::int, (r ->> 'stop')::boolean, (r ->> 'auto')::boolean, nullif(r ->> 'gst', '')::numeric, r ->> 'narr',
            date '2000-01-01', case when (r ->> 'active')::boolean then 'active' else 'inactive' end, true)
    returning journal_rule_id into v;
    i := 0;
    for c in select * from jsonb_array_elements(r -> 'conds') loop
      i := i + 1;
      insert into journal_rule_conditions (journal_rule_id, sort_order, field, operator, value) values (v, i, c ->> 0, c ->> 1, c ->> 2);
    end loop;
    i := 0;
    for l in select * from jsonb_array_elements(r -> 'lines') loop
      i := i + 1;
      if l ->> 1 = 'BANK' then
        insert into journal_rule_lines (journal_rule_id, sort_order, side, ledger_role, amount_source) values (v, i, l ->> 0, 'bank', l ->> 2);
      else
        if not exists (select 1 from ledgers where name = l ->> 1) then
          raise exception 'Default rule % needs ledger "%" which does not exist - run migration 0049 first', r ->> 'code', l ->> 1;
        end if;
        insert into journal_rule_lines (journal_rule_id, sort_order, side, ledger_id, amount_source)
        values (v, i, l ->> 0, (select ledger_id from ledgers where name = l ->> 1 limit 1), l ->> 2);
      end if;
    end loop;
    perform jr_snapshot_default(v);
  end loop;
end
$seed$;
""".replace("@@PAYLOAD@@", payload)

path = pathlib.Path(__file__).resolve().parent.parent / "migrations" / "0051_default_rule_book.sql"
path.write_text(sql)
print("rules:", len(RULES), "events:", len(EVENTS), "bytes:", len(sql), "->", path)
