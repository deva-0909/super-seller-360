# Demo data guide (round 12): what was added and what to check

Run `supabase/migrations/0101_demo_data_round2.sql` once. It adds sample data for the newer screens only; your existing orders, bills, settlements, payroll and ledgers are untouched. Running it twice does nothing the second time. Everything is posted through the app's own functions, so the books stay balanced (Trial Balance difference stays 0.00).

Dates are fixed to early October 2026. Amounts below are exact, so you can tick them off.

## 1. Bank → For review (HDFC ••4821)
12 statement lines were added. Two were booked automatically by the Rule Book on arrival, which is normal behaviour. Ten wait for review:

| Bank description | Paid out | Received | What you should see |
|---|---|---|---|
| NEFT/AIRNET BROADBAND/INV 8841 | 1,499.00 | | Vendor Airnet, account Telephone & Internet, **high** confidence (hand-added name) |
| NEFT/CLOUDKART SOFTWARE/SUBSCRIPTION | 6,800.00 | | Vendor CloudKart, account Software & Subscriptions, **high** |
| SMS ALERT CHARGES Q2 | 354.00 | | Account Bank Charges, **high** |
| GOOGLE ADS OCT PREPAID | 1,180.00 | | Account Advertising & Promotion, **good** (learned 4 times) |
| UPI/DAKSHIN GUJARAT VIJ CO/OCT BILL | 4,210.00 | | Vendor Dakshin Gujarat Vij recognised, **no account yet** (pick Electricity & Utilities) |
| NEFT/SHREE GANESH ESTATES/OFFICE RENT OCT | 29,500.00 | | Vendor recognised, no account. **Use Split:** Rent 25,000 + Input CGST 2,250 + Input SGST 2,250 |
| NEFT/ADBOOST DIGITAL MEDIA/CAMPAIGN | 8,750.00 | | Vendor recognised and a **warning**: an entry for this already exists in the books (JV on 1 Oct). Check in Reconcile instead of booking twice |
| UPI/CHAI POINT/OFFICE TEA | 640.00 | | No suggestion. Book to Staff Welfare |
| UPI/RAMESH K/9981 | 12,000.00 | | No suggestion (unknown person) |
| UPI/PRIYA S/ADJ | | 3,540.00 | No suggestion (unknown receipt) |

Auto-booked by the Rule Book (see Reconcile → Reconciled): interest received ₹1,842.50 and SwiftRoute courier freight ₹3,150.00.

Things to try: accept Airnet (one click); press "Accept all confident" (should book Airnet, CloudKart, Bank Charges and Google Ads: 4 lines); split the rent; accept the Dakshin line with "Remember my choices" on, then check **Remembered names** shows DAKSHIN. After each booking, Trial Balance still balances and the bank ledger moves by the amount paid.

## 2. Purchases → Recurring bills
| Template | Repeats | Next bill | Amount with GST |
|---|---|---|---|
| Warehouse rent - Andheri | monthly | 1 Oct 2026 (due) | 40,000 + 18% = **47,200.00** |
| Office broadband - Airnet | monthly | 5 Oct 2026 (due) | 1,270 + 18% = **1,498.60** |
| CloudKart software - quarterly | every 3 months | 1 Nov 2026 | 15,000 + 18% = 17,700.00 |
| Old courier retainer (paused) | monthly | 10 Oct 2026 | paused, nothing created |

Press "Create all due bills": two pending bills appear in Purchases → Bills (invoice numbers ANDR-202610 and AIRN-202610). Pressing it again creates nothing. Approving needs a second person.

## 3. Supplier credit notes (Purchases → Credit notes)
On a new unpaid fabric bill from Tiruppur Knit Fashions (invoice TKF/2610/DEMO: 200 kg × ₹150 = ₹30,000 + 5% = ₹31,500), so there is always something owed to reduce.
- CN/DEMO/01: ₹1,500 + 5% = **₹1,575.00**, approved (reduces what you owe on that bill).
- CN/DEMO/02: ₹2,000 + 5% = **₹2,100.00**, waiting for approval by a second person.

## 4. Month-end checklist (Accounting → Month-end checklist, month 2026-09 and 2026-10)
- A purchase bill for Gujarat Pack Industries dated 27 Sep but booked 2 Oct (invoice GPI/2609/118): 500 × ₹14 = ₹7,000 + 12% = **₹7,840.00**. September shows it under "booked later"; the late-bills list shows 1 month.
- Bank lines still to review: **10** for October.
- GST credit entered from GSTR-2B for September: CGST ₹1,620 + SGST ₹1,620 (GST Returns → September, "Credit from GSTR-2B").

## 5. Cash forecast and journals
- Planned items: out ₹45,000 on 15 Oct (bonus advance); out ₹12,000 on 20 Oct repeating monthly to Mar 2027 (insurance); in ₹80,000 on 25 Oct (buyer advance). They appear in Cash Forecast.
- Repeating journal: "Monthly staff tea and snacks (cash)" ₹3,000 Staff Welfare / Cash in Hand, first posted 1 Oct, next 1 Nov.

## Cross-check queries (optional, Supabase SQL Editor)
```sql
select count(*) from bank_transactions where raw->>'demo' = 'true';          -- 12
select count(*) from bank_transactions where raw->>'demo' = 'true' and recon_status in ('unreconciled','suggested'); -- 10
select name, status, next_date from recurring_bills order by next_date;       -- 4 rows
select supplier_note_no, status, total from supplier_credit_notes where supplier_note_no like 'CN/DEMO/%'; -- 1575 approved, 2100 pending
select sum(closing) from trial_balance(date '2000-01-01', current_date);      -- 0.00
```

## Still empty, on purpose
Shipments, e-invoice records, connector instances/logs and notifications fill up only when a courier, e-invoice provider or marketplace connector is connected. Cost centres have no screen yet.

## Also in 0101
Two small corrections: vendor-name recognition now ignores everyday words like "office", and the late-booked bills list shows whole months instead of days.
