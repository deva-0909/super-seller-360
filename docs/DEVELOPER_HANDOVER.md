# Developer handover: what is still open

Everything that can be built and tested without real accounts or real files is done. The items below depend on the business owner. Each has a `DEV POINTER` comment in the code; search for `DEV POINTER` to find them all.

## 1. Live connections (keys entered by the Super Admin in the Connection Centre)
Marketplace, courier, GST e-invoice, WhatsApp, bank feed. Every connection runs on dummy data until its live adapter is installed.
- Add `apps/web/lib/connectors/live/<code>.ts` exporting the matching adapter (types in `lib/connectors/types.ts`) and register it in `lib/connectors/live.ts`.
- Marketplace sync must return rows in the `OrderRow` shape so it goes through the same checks as the Excel importer (`import_run`, migration 0067).
- Keys are stored by the Connection Centre (migration 0070); adapters receive them through the instance `config`. Never log keys.
- Test each adapter in a sandbox account first, then switch the connection from Dummy to Live.

## 2. CA review of statutory rates (all rates are editable in the app and seeded with current values; none is hard-coded)
- Payroll: PF, ESI, Gujarat professional tax, labour welfare, salary TDS: Payroll > Settings (`payroll_settings`, migration 0076).
- Bonus, gratuity, leave: Payroll > Settings, second block (`payroll_exit_settings`, migration 0080).
- Marketplace GST TCS and section 194-O (393 under the new Act): Settlements > Marketplace Tax Credits > rules (`marketplace_tax_rules`, migration 0078).
- Depreciation rates: Accounting > Fixed Assets (migration 0074).
- TDS sections and thresholds: Accounting > Statutory (migrations 0063, 0066, 0075).

## 3. Sample files for the Excel importers
The importers were built from the published formats, not from real files. When a real settlement report, SKU sheet, COD remittance file or bank statement is available, run it through the importer and fix any heading or format differences in `apps/web/lib/importer/kinds.ts` (headings) and `import_run` (checks). Bank CSV parsing is in `lib/bank-csv.ts`.

## 4. One-time setup in the app
- Statutory settings: TAN, PAN, deductor name. Tick "turnover above 10 crore" only if it applies.
- Marketplace GSTIN and TAN per channel (Marketplace Tax Credits).
- Journal review limits (Accounting > Journal Review > policy).
- Cash forecast: minimum cash buffer, and planned items for GST payment, non-salary TDS, rent and loans (these are not auto-included).
- Demand forecast: month-wise season boost percentages.
- Employee records need the e-mail the person signs in with, for My Payslips.

## 5. Known gaps (by design, not bugs)
- Payroll: PF, ESI and professional tax on the final month's salary go through a normal pay run; the settlement only covers leftover days. Tax on bonus and settlements is entered by hand. No gratuity provision is booked until exit. No surcharge marginal relief in salary TDS.
- Forecasts: simple weighted average with damped trend; no learned seasonality (insufficient history). Cash forecast does not auto-include GST payment or non-salary TDS.
- Visual check on the deployed app has not been done by the author: click through the new screens (Payroll tabs, Journal Review, Marketplace Tax Credits, Demand and Cash Forecast, My Payslips).

## Working method used
Business rules live in SECURITY DEFINER SQL functions; the web app only calls them. Each migration was tested against an in-memory Postgres (PGlite) before delivery. Run migrations in order in the Supabase SQL Editor (NEW query each time).
