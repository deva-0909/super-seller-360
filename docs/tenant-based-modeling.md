# Tenant Based Modeling (parked)

Status: **parked on 2026-10-05. Design only, nothing built.** Pick this up later by reading section 1 and 2, then the two full design documents in Part A and Part B below.

## 1. What this topic is

Selling Super Seller 360 to clients on a **prepaid, per-transaction model** (₹1 per transaction, excluding GST), with **monthly packages** for high-usage clients, a pooled wallet per client, low-balance warnings on every user's screen, and online refill.

## 2. Decisions already made

| Topic | Decision |
|-------|----------|
| Price | ₹1 per transaction, exclusive of GST (18% added at top-up; CA to confirm) |
| Unit of tenancy | **One database (one deployment) per client**, with a central billing service you control so the client cannot edit the wallet |
| Users | Unlimited per client; all their transactions bill to one pooled wallet |
| Zero balance | **No grace period. The application stops for all users, including viewing.** Only sign-in and the Recharge screen stay open |
| Warnings | Based on days of cover at the client's own usage; banners on every user's screen; full wallet screen only for the Super Admin and billing contact |
| Credit expiry | None for wallet balance. Package units expire at month end |
| Third-party costs | Not inside the ₹1 (e-invoice, e-way bill, WhatsApp, courier, bank feed): pass-through at cost plus margin, or the client brings their own keys via the Connection Centre |
| Cancellations | Refunded within 24 hours, before an external document (IRN, AWB) is produced |
| Packages | Fixed monthly fee in advance for X included transactions plus value adds; wallet stays as the overage safety net. Order of use: package, then add-on pack, then wallet |

## 3. Still open (before anything is built)

1. The real price ladder, after working out the **fixed monthly cost of one client deployment** (database, hosting, backups, support). The sample Growth fee of ₹4,000 may not cover it.
2. Which value adds go in which package, and which cost real money (WhatsApp and e-invoice credits, support hours).
3. The exact transaction list (rate card) agreed with the client in writing.
4. Contract wording for the hard stop: access to the client's own data while paused, the goodwill-unlock rule, the marketplace history window, the pre-lock notice period.
5. Handling charge on third-party costs.
6. Rollover rule (none vs a small one-time carry-over), first-month rule (prorate or free partial month), annual discount.
7. Failed-renewal rule and notice period.
8. GST and TDS treatment of top-ups, monthly fees and annual advances, confirmed by your CA.
9. Refund window length (24 hours suggested) and which events count as "external document produced".
10. Whether very small clients are worth a separate deployment at all, or whether a shared option is needed later.

## 4. Client-facing document

A client-facing "Pricing and Plans" document was written as a doc in the artifacts list (title: *Super Seller 360: Pricing and Plans*). It uses **placeholder** prices and inclusions: the package fees, included counts, extra-transaction rates, support times, onboarding hours, credit amounts, audit-trail years, the 99.5% uptime, the 30-day price-change notice and the ~10% annual discount all need confirming before it is sent.

## 5. Suggested build order when resumed

1. Agree the rate card and price ladder (items 1 to 3 above).
2. Metering layer in the app, in **dry-run** mode (records what would be charged without charging).
3. Central billing service: wallet, ledger, usage events, idempotency, signed leases.
4. Low-balance alerts and banners; the hard-stop pause screen.
5. Gateway top-up with webhook, top-up invoice, wallet screen.
6. Packages: plans, monthly renewal, add-on packs, pace reminders.
7. Usage report and monthly statement; vendor console.
8. Enforcement switched on last, after a few weeks of dry-run data.

---

# Part A: Billing and metering (full design document)

# Super Seller 360: Prepaid Per-Transaction Billing, Structure Document

Status: design only, nothing is built. Purpose: agree what is charged, how the prepaid wallet works, and how low-balance warnings behave, before any code is written.

Commercial model as given: ₹1 per chargeable transaction, prepaid wallet, charges deducted as the client uses the system, client refills online, unlimited users per client, all users of one client share one pooled wallet, low-balance warning shown on every user's screen.

---

## 1. Decisions that need the owner first

| # | Decision | Status |
|---|----------|--------|
| 1 | Is ₹1 inclusive or exclusive of GST? | **Decided: exclusive.** 18% GST is added on top at top-up time (section 8; CA to confirm the rate). |
| 2 | What happens at zero balance? | **Decided: no grace period. At zero the application stops working completely, including viewing.** Only sign-in and the Recharge screen stay open (section 6.2). |
| 3 | Do top-up credits expire? | **Decided: no expiry** in the first version. |
| 4 | Are third-party costs (e-invoice, WhatsApp, courier) inside the ₹1? | **Decided: no.** Pass-through at cost plus margin, or the client brings their own keys through the Connection Centre. |
| 5 | One database per client, or one shared system? | **Decided: one database (one deployment) per client**, with a central billing service you control (section 3, Option 1). |
| 6 | Is a cancelled transaction refunded? | **Decided: yes**, within the refund window (24 hours suggested) and only before an external document (IRN, AWB) has been produced. |

---

## 2. What should be charged (the transaction list)

Principle: charge for a **business event that creates value or cost**, once. Never charge for looking, searching, editing a draft, downloading a report or logging in. Never charge twice for the same business event as it flows through several modules (an order that becomes an invoice that becomes a voucher is one order, not three).

### A. Charge ₹1 each (core)

| Event | Counted when | Notes |
|-------|--------------|-------|
| Sales order created or synced | Order is saved (manual, Excel row, or marketplace sync) | One per order, not per line. This is the main driver. |
| Sales invoice generated | Invoice number issued | Only if auto-invoice is on; a bundle option is in section 2D. |
| E-invoice (IRN) generated | IRN returned | Also carries the pass-through cost. |
| E-way bill generated | EWB number returned | Same. |
| Shipment booked (courier AWB) | AWB returned | One per shipment. |
| Return / RTO processed | Return received and inspected | One per return. |
| Purchase order raised | Approved | One per PO. |
| Goods receipt (GRN) posted | Posted | One per GRN. |
| Supplier bill approved | Approved | One per bill. |
| Supplier credit note approved | Approved | One per note. |
| Payment run executed | Payments marked paid | One per payment, not per run. |
| Manual journal voucher posted | Posted | System-made vouchers are not charged separately. |
| Payroll payslip generated | Pay run approved | One per employee per month. |
| Final settlement, bonus line | Approved | One per person. |
| Expense claim approved | Approved | One per claim. |
| Fixed-asset purchase or disposal | Recorded | One per asset event. |

### B. Charge, but in a cheaper bundle (high volume, low value; decide with the client)

| Event | Why bundle |
|-------|-----------|
| Settlement report lines (marketplace) | One settlement file can have thousands of lines. Suggest ₹1 per **settlement file**, or per order settled, not per fee line. |
| Bank statement lines imported | Suggest ₹1 per **100 lines**, or per statement file. |
| COD remittance lines reconciled | Per COD order matched, or per file. |
| Stock movements (inventory) | Do not charge. The order or GRN that caused them is already charged. |
| Excel import rows | Do not charge the import itself. The orders, products or bills it creates are charged under A. |

### C. Never charge (keeps the product feeling fair)

Viewing any screen or report, dashboards, the Ask a Question search, downloads and exports, drafts and edits before posting, user creation and role changes, GST return working sheets and filing exports, statutory calendar and reminders, forecasts, the work queue, notifications, login, audit trail views, rate changes in Rates and Compliance, wallet top-ups.

### D. Options that change revenue

- **Order bundle**: charge ₹1 per order and include its invoice, voucher and shipment record. Simpler to explain, lower revenue per order. Event-level charging (A) earns more but is harder to defend ("why was I charged 4 times for one sale?").
- **Minimum monthly commitment** or tiered price (₹1 up to N, ₹0.80 above) can be added later by changing the rate card, with no code change (section 4).

Recommendation: start with A plus the bundles in B, publish the list to the client as a one-page rate card, and keep the rate card editable (section 4).

---

## 3. Architecture decision: where the wallet lives

The current app has one company per database. Selling to many clients needs one of two shapes.

**Option 1. One deployment per client (own Supabase project and Vercel project), one central billing service run by you.**
- Each client system sends a signed usage event to your central billing service when a chargeable event happens, and asks "may I proceed?" before expensive or external actions.
- The wallet balance lives only in your central service, so a client's Super Admin cannot edit it.
- Pros: strongest data isolation, no refactor of the existing schema, easy to hand over or host elsewhere.
- Cons: you maintain many deployments; the central check adds a network call; offline handling is needed (section 6).

**Option 2. One shared multi-client system (add a `tenant_id` to every table, enforce it in row-level security).**
- The wallet is a table in the same database, checked inside the same database transaction as the business event (clean and atomic).
- Pros: one deployment to maintain, atomic charging.
- Cons: large refactor of every table and policy, higher risk of one client seeing another's data, harder per-client backup and exit.

**Decided: Option 1.** (Option 2 is kept below only for reference.)  It needs no refactor of what is built, protects the wallet from tampering, and keeps client data separate. Move to Option 2 only if the number of clients makes operating separate deployments painful.

Everything below is written for Option 1; Option 2 would simply put the wallet tables in the same database. Where the wording says "billing service", read it as "the wallet tables" under Option 2.

---

## 4. Data structure (billing service)

```
client                 one row per paying customer
  client_id, name, gstin, state, billing_email, status (active, suspended, closed),
  currency (INR), created_at

client_system          one row per deployed instance (Option 1) or the single instance (Option 2)
  system_id, client_id, api_key_hash, last_seen_at

wallet                 exactly one per client; the pooled balance
  client_id, balance (paise, integer), overdraft_limit, low_threshold_days,
  critical_threshold_days, min_balance_floor, auto_topup_enabled, auto_topup_amount,
  updated_at

wallet_ledger          append-only, never edited; balance = sum of this
  entry_id, client_id, entry_type (topup, charge, refund, adjustment, expiry),
  amount (paise, signed), balance_after, usage_event_id nullable, payment_id nullable,
  note, created_by, created_at

rate_card              what each event costs; changeable without code
  event_code, price (paise), effective_from, effective_to, bundle_size nullable,
  active, description

usage_event            one row per chargeable business event
  usage_event_id, client_id, system_id, event_code, source_table, source_id,
  user_id, user_name, occurred_at, quantity, price_applied, status (charged, reversed),
  idempotency_key (unique: client + event_code + source_id)

topup_payment          one row per online payment attempt
  payment_id, client_id, amount, gst_amount, gateway, gateway_order_id,
  gateway_payment_id, status (created, paid, failed, refunded), invoice_no,
  created_by, created_at, paid_at

alert_state            what has already been warned, to avoid repeating
  client_id, level (ok, low, critical, zero), since, last_emailed_at
```

Key rules:
- **Idempotency**: the same business event (same order id) can only be charged once, even if the app retries. Enforced by the unique key on `usage_event`.
- **Money in paise as integers**, no decimals.
- **Ledger is append-only**; a mistake is corrected by a new `adjustment` row, never an edit.
- **Reversal**: if an order is cancelled inside the refund window and nothing external was produced, add a `refund` ledger row and mark the event `reversed`.

---

## 5. How a charge happens (flow)

1. A user does something chargeable (for example approves a supplier bill).
2. The app finishes its own business transaction and records a `usage_event` with its idempotency key.
3. The billing layer deducts the rate-card price from the wallet and writes the `wallet_ledger` row. Under Option 2 this is the same database transaction as step 2, so either both happen or neither. Under Option 1 it is a signed call to the billing service; if the call fails, the event is queued locally and sent when the service is reachable (retry with the same idempotency key).
4. The balance is recalculated and the alert level is updated.
5. All users of that client receive the new balance state on their next screen refresh or notification poll.

For events that produce an external cost (IRN, e-way bill, courier booking, WhatsApp), check the wallet **before** calling the external service, so the client is never given something you cannot bill.

---

## 6. Low balance, zero balance and what stays working

### 6.1 Reminder based on actual usage (not a fixed amount)

Each client has a different volume, so warn on **days of cover left**:

```
average_daily_charges = total charges in the last 14 days / 14        (use the last 7 days if the client is under 14 days old; use a default of 1 day's expected volume for the first 3 days)
days_of_cover         = wallet balance / average_daily_charges
```

| Level | When | What the users see |
|-------|------|--------------------|
| OK | cover above 7 days | nothing |
| Low | cover 7 days or less | yellow banner: "Balance ₹X, about N days of use left. Recharge now." |
| Critical | cover 3 days or less | red banner on every page, plus a notification and e-mail to the client's billing contact |
| Zero | balance at or below zero | blocking banner and the rules in 6.2 |

Also keep an **absolute floor** (for example ₹500, editable per client) so a client with tiny usage still gets a warning, and a **spike rule**: if today's usage is more than 3 times the daily average, warn even if cover looks fine.

The thresholds (7 days, 3 days, floor, spike factor) live on the `wallet` row and are editable by you per client.

### 6.2 What happens at zero (decided: hard stop, no grace)

At a balance of zero the application stops working for **all users of that client, including viewing**. The balance can never go negative, so every chargeable action must be checked **before** it runs.

What stays open at zero (without these the client could never recover):
- Sign-in and sign-out.
- A **Recharge screen** showing the balance, the amount needed, and the Pay button. Only the Super Admin and the Billing Contact can pay; other users see "Service paused. Please ask your administrator to recharge."
- The payment confirmation page. As soon as the gateway confirms payment, the lock lifts for everyone without a new sign-in.

What this means in practice:
- **Pre-check, not after-the-fact deduction.** Before any chargeable action, the app confirms the wallet can cover it. For multi-item actions (a pay run of 50 payslips, an Excel import of 2,000 orders) the check is for the **whole batch up front**; if the balance cannot cover it, nothing happens and the user is told the amount needed.
- **Incoming marketplace and courier syncs pause** while locked. After recharge the system catches up from the last sync point so no orders are missed. Warn the client in the contract that marketplaces keep their reports only for a limited window, so a very long lock can lose history that cannot be fetched again.
- **Scheduled jobs pause** (recurring journals, reminders, auto-invoicing) and resume after recharge. Statutory deadlines do not pause, so the warnings before zero matter more under this rule (see 6.1 and the stronger warning ladder below).
- **Data access.** A full lock means the client cannot reach their own books until they pay. Put this in the contract in plain words. Also keep a way for you to lift the lock manually (a goodwill unlock for N hours, logged) for disputes or a payment that has been made but not yet confirmed.
- **Fail-closed when the billing service cannot be reached?** An outage on your side must not lock paying clients. Recommended: the billing service issues a **signed lease** to each client system ("active, balance good for about N charges, valid for 24 hours"). The app spends against the lease and renews it in the background. If the service is unreachable the app keeps working until the lease expires, then asks for renewal; the lock is applied only when the service answers "balance zero", never because the service did not answer.

Because the stop is absolute, strengthen the warning ladder in 6.1 for these clients:

| Cover left | Extra action |
|------------|--------------|
| 7 days | banner and e-mail to billing contact |
| 3 days | red banner on every page, e-mail and WhatsApp to the Super Admin and Billing Contact |
| 1 day | full-screen reminder once per sign-in for the Super Admin and Billing Contact, daily e-mail |
| Under 200 transactions (or the client's own number) | a countdown banner "about N transactions left" for all users |

**Auto top-up** (section 7) becomes much more valuable under a hard stop. Offer it as the default recommendation at sign-up, and make it easy to switch on.

### 6.3 Showing it to every user

- A thin banner at the top of every screen for every user of that client, for Low, Critical and Zero.
- Only the client's Super Admin and a nominated Billing Contact see the full wallet screen and the Recharge button. Other users see the banner text "Balance is low. Please ask your administrator to recharge." (They are not shown the exact balance unless you decide so.)
- The banner is driven by the client's shared `alert_state`, so it appears for everyone at the same time. Implementation: the app reads the alert level with the existing notification poll (the app already refreshes the bell and the cash reminder this way).
- E-mail (and optionally WhatsApp, using the Connection Centre) to the billing contact at Low, Critical, Zero and after a successful top-up. Do not repeat the same level more than once a day.

---

## 7. Online refill

- Gateway: Razorpay, Cashfree or PayU (UPI, cards, net banking). Pick one; the structure is the same.
- Screen: "Wallet" showing balance, days of cover, last 30 days usage, a top-up amount box with suggested amounts (based on 30 days of average usage), Pay button, and history of top-ups.
- Flow: create a `topup_payment` (status created) → open gateway checkout → the gateway **webhook** (not the browser return) confirms payment → verify the signature → mark paid → add a `topup` ledger row once (idempotent on `gateway_payment_id`) → clear the alert.
- Minimum top-up amount (for example ₹500) and a maximum per payment (editable).
- **Auto top-up** (optional per client): when balance falls below a limit, charge the saved mandate for a set amount. Needs a gateway mandate; leave for a later phase.
- Failed or abandoned payments never touch the wallet.
- Refunds of unused balance: manual, by you, recorded as a `refund` ledger row.

---

## 8. Tax and invoicing (confirm with your CA)

- You are selling a service. A prepaid top-up is an **advance**: GST is generally payable when the advance is received, so issue a **receipt voucher or tax invoice for each top-up** with GST at the applicable rate on the amount (shown as 18% in this document; your CA must confirm the rate and the treatment).
- The client's GSTIN and state decide CGST+SGST versus IGST on the top-up invoice.
- Monthly **usage statement** (not a tax invoice) listing charges by event type, so the client can reconcile. If your CA prefers consumption-based invoicing, the statement can become the invoice.
- Keep the top-up invoice number series separate and gap-free.
- TDS: a client may deduct TDS on your invoices; allow a "TDS deducted" entry when reconciling payments if the client is a company.

---

## 9. Screens

**Client side**
1. Wallet (Super Admin and Billing Contact): balance, days of cover, recharge, top-up history, download top-up invoices.
2. Usage (Super Admin, Billing Contact, optionally Finance Manager): charges by date, event type and user; filter and export. Lets the client see who is using what.
3. Low-balance banner (all users).
4. Billing settings (Super Admin): billing contact e-mail and phone, GSTIN, alert preferences (not the thresholds you control).

**Your side (vendor console, separate from the client app)**
1. Clients list with balance, days of cover, status.
2. Rate card editor with effective dates.
3. Per-client overrides: price, thresholds, overdraft, auto-suspend.
4. Manual adjustment and refund with reason (logged).
5. Revenue and usage reports; clients at risk (low cover); failed payments.
6. Suspend or reactivate a client.

---

## 10. Roles and permissions

- Wallet recharge and top-up invoices: client Super Admin and the nominated Billing Contact only.
- Usage report: add a permission `billing_view` so the client can give it to a Finance Manager.
- Banner: every user.
- Vendor console: your staff only, separate sign-in. Client users never see it.
- Wallet and rate-card changes cannot be made by any client user, including their Super Admin.

---

## 11. Edge cases to decide

- **Bulk Excel import of 2,000 orders** with a ₹1,500 balance: decided by the hard-stop rule. Check up front, import nothing, and show "this import needs about ₹2,000, balance ₹1,500".
- **Two users acting at the same moment** with the last ₹1 left: the deduction is atomic, the second action is refused with the Recharge message.
- **Duplicate orders** rejected by the importer are not charged.
- **Failed external calls** (IRN rejected, courier error): charge only on success.
- **Order edited after charge**: no new charge. **Order split or merged**: charge by the final order count, adjust by ledger.
- **Backdated entries**: charge on the day entered, not the document date.
- **Client closes**: unused balance refunded on request, less any dues.
- **Rate change**: applies from its effective date to new events only.
- **Time zone**: all usage days are IST.
- **Disputes**: every charge links to its source document (`source_table`, `source_id`), so a client can click from a charge to the order or bill.
- **Tampering**: under Option 1, usage events are signed with the system's key and the billing service rejects unsigned or replayed events.
- **Audit**: wallet ledger and rate-card changes are immutable and logged.

---

## 12. Suggested build order (when you decide to build)

1. Rate card, event codes and the list in section 2 agreed with the client in writing.
2. Metering layer in the app: one function `record_usage(event_code, source, user)` called at each chargeable point (this is the only change needed inside existing modules), running in "dry run" mode first so you can see what would have been charged without charging.
3. Billing service: wallet, ledger, usage events, idempotency, signed calls.
4. Alert calculation and the banner.
5. Gateway top-up with webhook, top-up invoice, wallet screen.
6. Usage report and monthly statement.
7. Vendor console.
8. Enforcement (block at zero) switched on last, after a few weeks of dry-run data to check that the numbers match what the client expects.

Dry-run first is important: it lets you show a client "this is what you would have paid last month" before any money moves.

---

## 13. Questions still open

1. Which events are on the rate card (section 2)? Agree this with the client in writing.
2. Minimum first top-up and minimum balance (suggest ₹500 minimum top-up).
3. Who is the billing contact?
4. Contract wording for the hard stop: access to the client's own data while locked, the goodwill-unlock rule, the marketplace history window, and the pre-lock notice period.
5. GST and TDS treatment of top-ups, confirmed by both CAs.
6. Notice period and process for a rate change.
7. Length of the refund window (24 hours suggested) and which events count as "external document produced".


---

# Part B: Monthly packages (full design document)

# Super Seller 360: Monthly Packages for High-Usage Clients, Structure Document

Status: design only, nothing is built. Companion to `BILLING_AND_METERING_STRUCTURE.md` (same wallet, same event list, same hard-stop rule). All prices below are **illustrations to show the structure**; the owner sets the real numbers.

Already decided (carried over): ₹1 per transaction pay-as-you-go, exclusive of GST; one database per client; central billing service; no grace at zero, the application stops; no expiry of wallet credit; third-party costs billed separately; refund of a cancelled transaction inside the window.

---

## 1. Idea in one paragraph

A high-usage client pays a fixed monthly fee in advance and gets **X transactions included** (at a lower effective price than ₹1) plus **value adds** (extra features, support and pass-through credits). The pay-as-you-go wallet does not go away: it becomes the **safety net for overage**. Consumption order each month: **package allotment first, then any add-on packs, then the wallet**. If all three are empty the application stops, exactly as decided for the wallet.

---

## 2. Why packages (and who should be on one)

- Client: lower per-transaction price, a predictable bill, features they would otherwise ask for.
- You: predictable monthly revenue, less dependence on clients remembering to top up, a reason for clients to move up.
- Suggested rule: a client whose last three months of usage average **more than about 3,000 chargeable transactions a month** is a package candidate. Show the Usage screen a line "On a Growth package you would have paid ₹X less" (calculated from their own history). That is the sales tool.

---

## 3. Illustrative package ladder

| Package | Monthly fee (excl. GST) | Included transactions | Effective price per transaction | Overage price | Users |
|---------|-------------------------|-----------------------|----------------------------------|---------------|-------|
| Pay-as-you-go (existing) | none | none | ₹1.00 | ₹1.00 | unlimited |
| Growth | ₹4,000 | 5,000 | ₹0.80 | ₹0.90 | unlimited |
| Scale | ₹10,500 | 15,000 | ₹0.70 | ₹0.80 | unlimited |
| Enterprise | ₹30,000 | 50,000 | ₹0.60 | ₹0.70 | unlimited |
| Custom | quoted | 1,00,000+ | by negotiation | by negotiation | unlimited |

Notes:
- Overage is **cheaper than ₹1 but dearer than the package rate**, so staying in the package is always better than overflowing. If a client overflows three months in a row, the system suggests the next package.
- Unlimited users stays true on every package (as decided).
- Annual option: pay 12 months in advance for about 10% off (GST on the advance applies, see section 9).

### The floor you must check before fixing any price

Because each client has **its own database and deployment**, each client has a fixed running cost to you (database, hosting, backups, monitoring, support time) whether or not they transact. Rough rule: look up the current Supabase and Vercel plan prices, add support time, and make sure the **lowest package fee covers this floor with margin**. For example, if the fixed cost per client is around ₹4,000 a month, the Growth package above would not be profitable on its own. Work this out first, then set the ladder above it. Also decide whether small clients (under the package threshold) are worth hosting separately at all, or whether a shared option is kept for them later.

---

## 4. What counts as a transaction inside a package

Exactly the events on the rate card (section 2A of the billing document), plus the bundled items in 2B with their own weights. Each event has a **weight** (default 1). Examples: order created = 1; bank statement lines = 1 per 100 lines; settlement file = 1. Weights live in the same rate-card table and can differ by package.

**Never counted** (same list as before): viewing, reports, exports, drafts, users, forecasts, GST working sheets, top-ups.

**Not included in any package unless named as a value add**: pass-through costs (e-invoice, e-way bill, WhatsApp, courier, bank-feed fees). They stay billed at cost plus margin, or the client brings their own keys.

---

## 5. Value adds (what a higher package gets besides cheaper transactions)

Choose from what the product already has or can switch on cheaply. Entitlements are switched on by a **feature flag per package**, delivered to the client system inside the signed lease (see section 7), so they turn on and off without a new deployment.

| Value add | What the client gets | Cost to you | Suggested tiers |
|-----------|----------------------|-------------|-----------------|
| Priority support and response time | e.g. reply within 4 working hours (Growth: next working day) | support time | Growth: standard; Scale: priority; Enterprise: dedicated contact |
| Onboarding and training hours | set-up help, importer mapping for their real files, user training | your time | Scale and up |
| Demand forecast and cash forecast | switched on only for packages that include them | none | Scale and up (or all, decide) |
| Journal guard rails and review workbench | maker-checker and review sampling for high voucher volume | none | Scale and up |
| Extra pass-through credits | e.g. 500 WhatsApp messages and 200 e-invoices a month included, beyond that at cost | real third-party cost | Scale and up |
| Scheduled data backup export | monthly full export of the client's data in Excel/CSV, delivered to their e-mail | small | Growth and up |
| Longer audit-trail retention | e.g. 3 years vs 1 year | storage | Scale and up |
| Custom reports | N custom reports built per quarter | your time | Enterprise |
| Quarterly business review | a call with usage, forecast accuracy and rate-change summary (the Rates and Compliance change log helps here) | your time | Enterprise |
| Statutory rate maintenance | you update GST, TDS, payroll and TCS/194-O rates through Rates and Compliance when the law changes | your time | all packages, or a paid extra for pay-as-you-go |
| Uptime commitment (SLA) | e.g. 99.5% monthly, with service credit if missed | risk | Enterprise |
| Bank-feed or marketplace connector set-up | live connector set-up when the client has real keys | your time | Scale and up |
| Early access to new modules | pilot new features first | none | Enterprise |

Keep the list short on the rate card sent to the client (5 or 6 lines per package); the full table is for your internal use.

---

## 6. Data structure (additions to the billing service)

```
package_plan             the ladder; editable without code
  plan_code, name, monthly_fee (paise), included_transactions, overage_price (paise),
  annual_discount_pct, features jsonb (feature flags and credit quantities),
  event_weights jsonb (overrides), active, effective_from

client_subscription      one active row per client
  subscription_id, client_id, plan_code, status (active, past_due, cancelled, scheduled_change),
  billing_anchor (calendar month start), period_start, period_end, auto_renew,
  next_plan_code nullable (a downgrade takes effect next cycle), annual boolean

package_period           one row per client per month
  period_id, client_id, plan_code, period_start, period_end,
  allotment, addon_allotment, used, overage_used, overage_amount (paise),
  credits_used jsonb (whatsapp, einvoice ...), closed_at

addon_pack               extra transaction packs bought mid-month
  pack_id, client_id, period_id, quantity, price, created_at, expires_at (end of period)

subscription_invoice     monthly fee invoice (a tax invoice)
  invoice_no, client_id, period_id, amount, gst_amount, status (issued, paid, failed),
  paid_at, payment_id
```

`usage_event` and `wallet_ledger` stay as they are. A usage event now records **which bucket paid for it** (`package`, `addon`, `wallet`), so reports and disputes show clearly what was covered.

Consumption function (the only logic that changes):
1. If the package period has allotment left, deduct there.
2. Else if an add-on pack has quantity left, deduct there.
3. Else deduct from the wallet at the overage price.
4. Else (wallet cannot cover it) refuse and show the Recharge or Upgrade screen. Hard stop as decided.

---

## 7. Lease and enforcement (one database per client)

The client system already holds a signed lease from the billing service. Extend the lease to carry:
- plan code and period end
- transactions left in the allotment and in add-on packs
- wallet balance in whole transactions at the overage price
- feature flags and pass-through credits left

The app spends against the lease and renews it in the background; a package expiry or a plan change reaches the client within the lease interval, or immediately on payment. As before, an unreachable billing service never locks a paying client; only an answer of "nothing left in any bucket" does.

---

## 8. Monthly cycle

1. **Anchor**: calendar month (simplest for the client's accounts). First month is prorated by days, or starts the next 1st with a free partial month. Decide one rule.
2. **Renewal**: on the 1st, the next month's fee is invoiced and collected (saved mandate, UPI AutoPay or a pay link). On success a new `package_period` opens with a fresh allotment.
3. **Unused transactions**: recommended **expire at month end** (no rollover). It keeps pricing simple and protects your forecast. Soften this with a single rule such as "up to 10% of the allotment carries over once", or leave it out for the first version.
4. **Failed renewal**: because the stop at zero is absolute, treat it consistently: the package lapses at midnight of the 1st (or after a stated 2-day notice that you write into the contract), the client falls back to the **wallet at ₹1**, and if the wallet is empty the application stops until they pay. State this in the contract in plain words.
5. **Upgrade mid-month**: immediate; charge the fee difference prorated, and add the extra allotment for the rest of the month.
6. **Downgrade**: takes effect at the next renewal.
7. **Cancel**: effective at the end of the paid month; remaining wallet balance stays and is usable at ₹1.
8. **Overage**: drawn from the wallet automatically. If the wallet is empty the stop applies (or the client buys an add-on pack at the package rate, see section 10).

---

## 9. Tax and invoicing (CA to confirm)

- The monthly fee is a **supply of service**: issue a **GST tax invoice** each month with GST on the fee (shown at 18% in this document; CA to confirm). For annual prepayment, GST applies on the advance.
- Overage drawn from the wallet is covered by the wallet **top-up invoices** already described; the monthly **usage statement** shows package usage, add-on packs and wallet-paid overage separately so the client can reconcile.
- Keep separate invoice number series for subscription invoices and for wallet top-up receipts.
- TDS may be deducted by company clients on the fee; allow a "TDS deducted" entry when matching the payment.

---

## 10. Reminders and the client experience

Package reminders work on **pace**, not just the amount used:

```
projected_exhaustion_date = today + (allotment left / average daily usage this month)
```

| Trigger | Message to all users | Message to the Super Admin and Billing Contact |
|---------|----------------------|--------------------------------------------------|
| 80% of allotment used, or projected to run out before month end | banner "Package transactions are running low" | e-mail with the projected date and the options below |
| 95% used | red banner | e-mail and WhatsApp |
| Allotment finished, now using the wallet | banner "Package used up. Now using wallet balance at ₹0.90" | e-mail |
| Wallet below the cover levels in the billing document | the existing low-balance banner | existing e-mails |
| Renewal in 3 days | none | e-mail "Renewing on the 1st for ₹X" |
| Renewal failed | blocking Recharge screen once the lapse rules apply | immediate e-mail and WhatsApp |

Options offered on the reminder: buy an **add-on pack** at the package rate (for example 1,000 transactions), upgrade to the next package, or top up the wallet.

Screens (client): Plan and usage (plan, days left in month, allotment bar, projected exhaustion date, wallet balance, value adds in use), Change plan, Add-on packs, Invoices. Vendor console: plan editor, assign or change a plan for a client, comp or extend an allotment with a reason, view clients by plan and utilisation, clients near their limit (upsell list), clients overflowing three months running.

---

## 11. Edge cases to decide

- **Refund of a cancelled transaction** inside the window returns the unit to the **bucket that paid for it** (package units are restored to the period, wallet units refunded to the wallet).
- **A heavy import at month end** that straddles two periods: charged to the period in which each event occurs; pre-check for the whole batch uses allotment plus add-on plus wallet together.
- **Plan price change**: applies from the next renewal; existing clients keep their price for the stated notice period.
- **Dry run first**: during the dry-run phase (billing document section 12), also show each client "your month under Growth / Scale", using real usage. This is the evidence for the price ladder and for the sale.
- **Package for part of the client's work**: not offered; one plan per client, pooled across all users.
- **Discounts and free trial month**: handled by assigning a plan with a start date and a comp reason in the vendor console, never by editing ledgers.
- **Disputes**: every unit used is linked to its source document and to the bucket that paid.

---

## 12. Suggested build order (after the wallet exists)

1. Plan table, subscription table and the consumption order (package, add-on, wallet) in dry-run mode.
2. Lease extension carrying allotment, wallet and feature flags; feature-flag checks in the app for the value adds.
3. Monthly renewal job, subscription invoice, failed-renewal rule.
4. Pace reminders and the Plan and usage screen.
5. Add-on packs and upgrade or downgrade flow.
6. Vendor console: plans, assignments, utilisation and upsell lists.
7. Switch on enforcement only after a few cycles of dry-run data.

---

## 13. Questions to settle with the owner

1. The real price ladder, after working out the fixed monthly cost of one client deployment (section 3).
2. Which value adds go in which package, and which cost you real money (extra pass-through credits, support hours).
3. Rollover: none, a small one-time carry-over, or a paid carry-over.
4. First-month rule (prorate or free partial month) and the annual discount.
5. The failed-renewal rule and notice period in the contract.
6. Whether pay-as-you-go clients can buy individual value adds (for example statutory rate maintenance) for a fee.
7. GST treatment of the monthly fee and of annual advances, confirmed by your CA.
