# CA confirmation list (researched 5 Oct 2026)

Sources are public guides, not the statute. Your CA should confirm each row.

| Item | What the app had | What research found | Action |
|---|---|---|---|
| Gujarat Professional Tax | Slabs 6,000 -> 80, 9,000 -> 150, 12,000 -> 200 | Nil up to Rs 12,000/month, Rs 200/month above (older slabs withdrawn 1 Apr 2022). Annual cap Rs 2,500 | Run `0095_gujarat_pt_update.sql` |
| Women's PT exemption | Women exempt below Rs 12,000 | None in Gujarat (Maharashtra has one, not Gujarat) | Set to 0 in 0095 |
| Bonus defaults | 8.33%, eligibility Rs 21,000, calc cap Rs 7,000, 30 days | All match the Payment of Bonus Act. Calculation wage is Rs 7,000 or the state minimum wage, whichever is HIGHER; bonus range 8.33% to 20%; pay within 8 months of year end (30 Nov for Apr-Mar) | Ask CA for the Gujarat minimum wage for your staff category; if above 7,000, enter it as the bonus calc cap in Payroll settings |
| COD fees | No ledger accrual; "awaiting settlement" report only | Output GST is due at invoice, not when COD cash arrives. Courier/marketplace fees carry 18% GST with credit available if the invoice shows your GSTIN | Keep as is; CA to confirm marketplace fees are booked from the settlement/invoice, not estimated |
| Month-end cut-off | Report of bills booked in a later month than the supplier invoice | Standard practice; credit is claimed in the month the bill is booked and appears in GSTR-2B | CA to decide whether late bills need an accrual journal at year end |

## Webhooks (deploy only when connected)
- `bank-statement-sync`: deploy when a bank feed is connected; needs the bank's feed credentials as secrets.
- `returns-rto-webhook`: deploy when a courier (Delhivery/Shiprocket etc.) is chosen; give them the function URL and a shared secret.
