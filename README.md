# Super Seller 360°

Multi-channel e-commerce control tower — Next.js + Supabase.
Spec source: `Super_Seller_360_Developer_Ready_BRD_Figma_Specification.xlsx` (143 screens, 40 entities, 5-phase build).

## Repo structure

```
super-seller-360/
├── apps/
│   └── web/                    # Next.js 16 app (App Router, TypeScript, Tailwind v4)
│       ├── app/
│       │   ├── (auth)/         # Login, OTP/2FA, Forgot Password, Reset Password (AUTH-001..004)
│       │   └── (dashboard)/
│       │       └── settings/sessions/   # Session Management (AUTH-005)
│       ├── components/
│       │   ├── auth/           # AuthShell — shared frame for auth screens
│       │   └── ui/             # Field, Button, StatusPill — shared primitives
│       └── lib/supabase/       # Browser client, server client, middleware session refresh
├── supabase/
│   └── migrations/
│       └── 0001_phase1_foundation.sql   # Roles, Users, Company, Channel, Warehouse, Product, ChannelSKUMap
└── README.md
```

## Running the app locally

```bash
cd apps/web
npm install
npm run dev
```

Needs `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` in `apps/web/.env.local` — see `.env.example` for the shape. These are already set locally to the `super-seller-360-dev` Supabase project.

## Design system (Phase 1)

Token-based, not a component library skin — see `app/globals.css`:
- **Palette**: quiet paper-grey canvas (`--canvas`), flat bordered panels instead of shadowed cards, a deep ledger-teal accent (`--accent`) — deliberately not a default SaaS blue/purple or warm-cream/terracotta
- **Type**: IBM Plex Sans for interface text, IBM Plex Mono for all data — order IDs, SKUs, amounts, timestamps (`.font-data` class) — so numbers and identifiers are always visually distinct from language
- **Status**: `StatusPill` component — bordered, muted colors, not solid saturated badges — reused for every module's Loading/Success/Warning/Error states

## Supabase project (dev)

- Project: `super-seller-360-dev` (ref `enyjtwbksjdrjhkcwkem`, region `ap-south-1`)
- Migrations applied: `0001_phase1_foundation`, `phase1_security_fixes`
- RLS: enabled on every table, security advisor clean

## Phase 1 — Foundation (this migration)

Tables created:
- `roles` — the 10 fixed roles from the Role Permission sheet (Super Admin, CEO/Owner, Operations Manager, Warehouse Manager, Finance Manager, Accountant, Claims Manager, Tax Manager, Marketplace Manager, Auditor)
- `user_profiles` — extends Supabase `auth.users` with role + status
- `user_warehouse_scope` / `user_channel_scope` — implements "Assigned warehouses" / "Assigned channels" scoping for Warehouse Manager and Marketplace Manager roles
- `companies`, `channels`, `warehouses`, `products`, `channel_sku_map`
- Row Level Security policies enforcing read/write access per role, matching the Role Permission sheet

## Why RLS is set up before any screens exist

Permissions are enforced in Postgres itself, not just hidden in the UI — a Warehouse Manager's Supabase query for Finance data returns nothing, regardless of what the frontend does. Retrofitting this after 140 screens exist is much harder than starting with it, which is why it's step one.

## Done so far

1. ✅ Supabase dev project created, Phase 1 migration + RLS applied
2. ✅ Next.js app scaffolded with Supabase Auth client (browser + server + middleware)
3. ✅ Auth screens built: Login, OTP/2FA, Forgot Password, Reset Password, Session Management
4. ✅ Dashboard shell (sidebar + top bar), reused by every screen below
5. ✅ Users screen (ADM-132) — list + invite, backed by an `invite-user` Edge Function
6. ✅ Roles screen (ADM-133) — read-only view of the 10 fixed roles
7. ✅ First Super Admin account bootstrapped directly in the database (see note below)
8. ✅ **Phase 2A: native accounting engine** — chart of accounts, voucher types, accounting
   periods, immutable double-entry vouchers/voucher lines, a derived journal_entries table,
   and `post_sales_voucher()` — the function that turns an order into a balanced invoice +
   posted voucher in one transaction (Order → Invoice → Accounting entry, per WF-002)
9. ✅ Channels screen (channel master data — required before any order can exist)
10. ✅ Order List (ORD-012) + Order Detail (ORD-013) screens, with a "Generate invoice & post"
    action on unposted orders
11. ✅ CSV order import (`/orders/import`) — the documented fallback ingestion method from the
    Integration Matrix, works today without needing live Shopify/Amazon API credentials
12. ✅ Ledgers screen (`/accounting/ledgers`) + per-ledger transaction history — browse the
    running balance and every posted entry behind it, computed from `journal_entries`
13. ✅ Shopify order webhook (`shopify-order-webhook`) — HMAC-verified receiver that normalizes
    `orders/create`/`orders/updated` into our Order/OrderLine shape. **Not yet tested against a
    live store** (none connected) — fails closed (503) until `SHOPIFY_WEBHOOK_SECRET` is set,
    so it can't silently trust an unverified request in the meantime
14. ✅ Pushed to GitHub

## Bugs caught and fixed during Phase 2 testing

Three real bugs surfaced while testing the accounting engine — worth documenting honestly,
including where the testing method itself was initially inadequate:

**1. NULL-handling bypassed the authorization check.** `post_sales_voucher()`'s check used
`if not (has_orders_write() or has_accounting_write())` — but when a caller has no
`user_profiles` row, `current_role_name()` returns SQL `NULL`, and `NULL in (...)` evaluates to
`NULL`, not `false`. `if not NULL` is falsy in plpgsql, so the check silently didn't raise — an
order posted successfully for a caller with no role whatsoever. Fixed by having every
`has_*_write()`/`has_*_view()` helper coalesce to `false` explicitly (migration `0003`).

**2. A self-referential RLS policy caused infinite recursion.** `current_role_name()` queries
`user_profiles`, and `user_profiles`'s own RLS policy calls `current_role_name()` — a loop. This
was completely invisible through bug #1's testing, because that testing ran through a privileged
database connection that bypasses RLS entirely (only the JWT identity was simulated, not a
genuinely restricted session) — so the recursive path was never actually exercised. It only
surfaced once testing was redone by explicitly switching to the low-privilege `authenticated`
Postgres role, which crashed with "stack depth limit exceeded" on the very first real attempt.
Fixed by making `current_role_name()` `SECURITY DEFINER` (migration `0003`) — the standard
Supabase pattern for exactly this case, safe here because it only ever reads the caller's own row.

**3. The journal-sync trigger lacked permission to write its own derived table.**
`journal_entries` intentionally has no direct INSERT policy for anyone (it's system-derived).
`sync_journal_entries()` (the trigger that populates it) wasn't `SECURITY DEFINER`, so it ran as
whichever role fired it — fine when fired inside `post_sales_voucher()` (already elevated), but a
Finance Manager posting a voucher *directly* (the manual-journal path the RLS policies explicitly
allow) hit a permission error the instant their voucher tried to sync. Also only found once
testing exercised that direct path under genuine RLS. Fixed by making `sync_journal_entries()`
`SECURITY DEFINER` too (migration `0002`).

All three were re-tested after fixing — under a real `SET ROLE authenticated` session this time,
not a privileged connection — confirming: manual voucher posting now syncs correctly, an
unauthorized caller is still correctly rejected, and `post_sales_voucher()` still works for
legitimate callers. The lockdown migration (`0004`) also revokes `EXECUTE` on all three
`SECURITY DEFINER` functions from the `anon` role, and `sync_journal_entries()` from
`authenticated` too, since it should only ever run via its trigger, never be called directly.

## How inviting users works

Creating an auth account requires Supabase's admin API (service-role privileges), which must never
reach the browser. `supabase/functions/invite-user` is the only place that privilege exists — it
re-checks the caller is Super Admin, invites the new user, then creates their `user_profiles` row.
The Users screen calls this function; nobody can invite from the browser directly.

**Bootstrapping the very first account** (before anyone exists to send an invite) was done once via
direct SQL against `auth.users` — this is why there's no public sign-up screen: every user after
the first is created through the Invite flow, by design.

**Gotcha if you ever need to bootstrap another environment (e.g. production) this same way:** a
manual `INSERT` into `auth.users` leaves several token columns (`recovery_token`,
`email_change_token_new`, `email_change`, etc.) as `NULL` unless you set them explicitly — and
Supabase's auth server expects empty strings there, not `NULL`. The symptom is sign-in failing
with **"Database error querying schema"**, which doesn't obviously point at the real cause. Fixed
here in `0005_fix_bootstrap_auth_tokens.sql`; if bootstrapping fresh elsewhere, set those columns
to `''` in the original `INSERT` rather than leaving them to default.

## Role preview ("View as…" — top right of every screen)

Super Admin can preview the app as any of the 10 roles, and it's backed by **real RLS**, not a
client-side toggle hiding buttons while still fetching unrestricted data. `current_role_name()`
(the function every RLS policy in the app calls) checks for an active `role_preview` row first,
and only honors it if the caller's *actual* role is Super Admin — so nobody can preview their way
into more access than they really have, only less. Verified live: previewing as Warehouse Manager
correctly hides all 3 ledgers, which are visible again the instant the preview clears.

Only Super Admin sees the switcher at all (`RoleSwitcher` returns `null` for anyone else), and the
`role_preview` table's own RLS policy independently enforces the same restriction server-side.

## Seed data

`0007_phase2_seed_demo_data.sql` + `0008_seed_demo_team.sql` populate a realistic dataset so the
whole app has real data to click through, not empty screens:

- 3 channels (Shopify, Amazon, Flipkart), 2 warehouses, 8 products, 16 channel-SKU mappings
- 18 orders over the last ~28 days with a realistic mix of statuses (delivered/shipped/pending/RTO,
  paid/pending/refunded, prepaid/COD)
- 10 of those orders posted through the **real** `post_sales_voucher()` — not pre-computed fake
  numbers — producing 10 vouchers, 30 balanced voucher lines, and 10 invoices. Verified: total
  debits equal total credits exactly (₹7,639.53 = ₹7,639.53) across all of it
- 5 additional team member profiles across 5 different roles (Priya - Operations, Rohan - Finance,
  Kavita - Warehouse [scoped to Surat only], Arjun - Marketplace [scoped to Amazon+Flipkart only],
  Sneha - Auditor) — these demonstrate the scoped-visibility RLS policies too, not just role-level
  ones. Their accounts have random unusable passwords; they exist for role realism, not real login.

## Phase 3: Returns, RTO, Inventory

This directly closes the #1 original pain point: accounting records vs. physical inventory
mismatch. The core rule (BR-003 — saleable stock changes only after physical receipt AND
inspection with a "good" disposition) is enforced in a single controlled function
(`disposition_return()` / `disposition_rto()`), not left to application-layer discipline.

**Verified live, under genuine RLS:**
- A return dispositioned as "damaged → quarantined" does NOT credit stock (confirmed: stock stayed
  at 0 after quarantining a return with mug/sleeve line items)
- A return dispositioned as "good → restocked" DOES credit stock, exactly matching order line
  quantities, with a full before/after audit trail (confirmed: 0 → 1 unit, traceable to the exact
  return that caused it)
- Returns and RTOs are two completely separate tables (BR-004) — never conflated
- A caller with no valid role is blocked from even creating a return (RLS rejects the INSERT
  outright)
- Warehouse Manager's visibility is scoped to their assigned warehouse(s), consistent with the
  Phase 1 pattern already used for the `warehouses` table itself

**Live screens:** Returns (list + create + received/disposition workflow), RTO (same pattern,
kept structurally separate), Inventory (current stock per warehouse, read-only — the only way
stock changes is through a real disposition, never a direct edit).

## Phase 4: Settlements, Bank, COD reconciliation

Addresses pain points #2 (verifying portal/gateway payments after deductions) and #4 (COD
collection tracking) from the original brief.

**Verified live, under genuine RLS (using a real Finance Manager test session):**
- Logged a settlement expecting ₹850, matched it against a real bank transaction of ₹800 —
  `reconcile_settlement()` correctly computed `short_pay` status and linked the bank transaction
  as matched, in one atomic call
- Confirmed a Warehouse Manager (who has no Settlements/Bank/COD access at all per the Role
  Permission sheet) genuinely sees 0 settlements — not hidden by the UI, actually invisible at
  the database level

**Live screens:** Settlements (log + reconcile against a bank transaction, shows variance),
Bank transactions (log credits/debits, see match status), COD Collections (log what a courier
collected, mark remittances, see pending amount and ageing in days on what's still outstanding).

Note: `ageing_days` (listed in the BRD's CODCollection entity) is computed at query time from
`collected_date` rather than stored — a stored value would go stale the moment a day passes
without a background job updating it.

## Phase 5: Claims, Tax, Dashboard — all P0 modules from the original roadmap are now live

**Claims** — tracks losses (lost shipments, damaged returns, incorrect deductions) from potential
through recovery. `advance_claim()` keeps status and amount fields moving together (an "approved"
claim always has an `approved_amount`).

**Verified live, under genuine RLS:**
- Marketplace Manager (Create+View tier) could create a claim, but was correctly **blocked** from
  approving it — "Not authorized to update claim status"
- A real Finance Manager then filed → approved it (₹350 claimed → ₹300 approved), exactly matching
  what was submitted

**Tax** — logs GST/TDS/TCS records, and — the part that actually matters — reconciles the logged
GST total against the real GST Payable ledger balance (computed from `journal_entries`, the same
data the Ledgers screen already uses). This is a genuine books-vs-records comparison, not two
disconnected numbers sitting next to each other.

**Dashboard** — every KPI is computed live from the actual database on page load: Gross/Net Sales,
Settlement Pending/Shortfall, COD Pending, Return Rate, RTO Rate, Inventory Value, Claims
Recoverable, Trial Balance. None of it is hardcoded — it reads real rows from every module built
across Phases 2–5.

This completes all P0 modules from the original roadmap. What's left: connecting a live portal
(the Shopify webhook is built but untested), and P1 items from the Reports KPI sheet (Cash Flow,
full P&L/Balance Sheet statements) that weren't in the original 5-phase scope.

## Order Timeline + line-item CSV import

Two gaps closed from the roadmap:

**Order Timeline** — `order_status_history` now logs automatically via a trigger every time an
order's fulfilment or payment status changes (verified live: updating SHOP-1009 to "delivered"
correctly appended a second history row alongside its original state). Order Detail's Timeline
section merges this with invoice posting, returns, RTOs, and claims tied to that order into one
chronological view — not just a raw status log.

**Line-item CSV import** — the importer now expects one row per line item (order-level fields
repeated), matching real portal export shapes, groups rows by `external_order_id`, and computes
gross/tax/net from the actual line items rather than trusting a separate total column. Known
limitation, stated honestly in the UI: re-importing the same file skips orders that already exist,
but doesn't yet dedupe line items within a brand-new order across two overlapping files — fine for
a clean one-time batch, not yet a robust re-sync path.

## Profit & Loss and Balance Sheet

Both computed live from `journal_entries` — the same real, tested data every other accounting
screen uses. No fabricated numbers.

**Verified by hand before shipping:** with the real posted vouchers currently in the database
(Trade Receivables ₹7,639.53 debit, Sales Revenue ₹6,711.30 credit, GST Payable ₹928.23 credit),
Assets (₹7,639.53) = Liabilities (₹928.23) + Equity/unclosed profit (₹6,711.30) = ₹7,639.53 exactly.

**Honest gap stated in the P&L UI itself:** no expense ledgers exist yet — the accounting engine
currently only auto-posts Sales Revenue via order invoicing, so the P&L will show revenue with
zero expenses until expense ledgers (commission, shipping, packaging) are added and posted
against. That's a true reflection of what's been built, not a bug.

**Honest gap stated in the Balance Sheet UI itself:** no formal period-close process exists yet
(a feature in its own right), so current-period profit hasn't been transferred to a retained
earnings ledger — it's shown explicitly as "Current period profit (unclosed)" rather than silently
folded into an equity ledger that doesn't actually reflect it.

## Period Close, Cash Flow, and CSV dedup — the last roadmap items

**Period Close** — `close_accounting_period()` posts a genuine closing entry (not just a status
flag): each income/expense ledger's activity *for that period only* is zeroed out and transferred
to a new Retained Earnings ledger. Deliberate separation of duties honored exactly from the Role
Permission sheet: Period Close is Full for Finance Manager, Configured for Accountant, and "—" for
**every other role — including Super Admin**. Verified live: Super Admin was correctly blocked
("Not authorized to close accounting periods"), a real Finance Manager then closed August 2026
successfully — ₹4,992.89 moved from Sales Revenue to Retained Earnings, and the closing voucher
balances exactly. Also verified: attempting to invoice an order dated in the now-closed period is
correctly rejected. Because these are real transactions (not a flag), the existing P&L and Balance
Sheet screens automatically reflect the closure correctly with no code changes needed — closed
periods' income naturally drops out of the all-time ledger balance since the closing entry itself
reduced it.

**Cash Flow** — built from real `bank_transactions`, categorized by what each one is matched to
(settlement receipts, COD remittances, other). Investing/Financing sections are omitted rather
than shown as a false zero, since no such activity is modeled yet.

**CSV import dedup fix** — a genuine gap, now fixed: if the same order+SKU combination appears
twice within a single uploaded file, the importer now merges them into one line (summing
quantity/discount/tax) instead of silently double-counting. Cross-file re-import of an
already-existing order was actually already safe (Postgres's `ON CONFLICT DO NOTHING` doesn't
return skipped rows, and the import code already checks for that) — the earlier README wording
overstated this as a limitation when it wasn't one for that specific case.

**Security note:** two new trigger-only functions (`log_order_status_change`,
`prevent_voucher_in_closed_period`) got flagged by the security advisor as directly callable via
RPC — locked down to trigger-only use, then verified the triggers still fire correctly afterward
(same pattern already proven safe with `sync_journal_entries` back in Phase 2A).

## Audit round — closing the testing gaps found

Worked through the audit list in risk order. Results:

**RPCs tested for the first time (previously only code-reviewed, never invoked):**
- `disposition_rto` — restocked both order lines correctly (SLEEVE-14, BOTL-750: 0→1 each)
- `record_cod_remittance` — tested both partial (₹1,000 of ₹1,477.20 → correctly `short_remit`)
  and completing remittance (→ correctly flips to `remitted`)
- `advance_claim`'s `rejected` path — correctly sets status, leaves `approved_amount` null
- `advance_claim`'s `recovered` path — tested two partial recoveries (₹200 + ₹250), correctly
  accumulated to ₹450 matching the approved amount

**A real bug found and fixed:** dispositioning a return/RTO as "restocked" for an order with an
unmapped SKU crashed with a raw Postgres NOT NULL constraint error. Confirmed live the crash
rolled back cleanly (no data corruption — a single function call is atomic) but the UX was broken.
Fixed: unmapped lines are now skipped with a notice reporting how many, instead of crashing the
whole operation.

**A real limitation, stated honestly:** the `invite-user` Edge Function's authorization depends on
verifying a genuine, cryptographically-signed JWT from a real browser session. The SQL-based role
simulation used throughout this project's testing (setting `request.jwt.claims` directly) works
for testing RLS policies, but does **not** produce a token Supabase's Auth server would accept —
so the live HTTP invite flow remains unverified from this environment. What *was* verified: the
database-side preconditions (role lookup query, the `user_profiles` insert shape) work correctly
in isolation. The end-to-end flow — actually clicking "Send invite" in the browser — still needs
verification by an actual logged-in user.

**Still not done from the original audit list:**
- Clicking through the screens that were never opened in a browser (Dashboard, Ledgers, Order
  Timeline, CSV import, most create-forms) — verified via equivalent SQL, not via the actual UI
- Products and Warehouses master-data screens (still don't exist — see audit)
- Edit/delete capability anywhere (still create-only everywhere)
- The remaining Admin screens (Permissions, Integrations, Audit Trail, etc.)

## Products and Warehouses master screens (audit follow-up)

Turned out these didn't need any new database work — the RLS policies for both already existed
from Phase 1 (`operations and admin manage products`, `admin manages warehouses`), I'd just never
built a UI on top of them. Built list + create screens for both.

**This also closed two more audit gaps while testing them:**
- **Operations Manager** (Priya) — never independently tested before this — correctly created a
  product and a warehouse
- **Auditor** (Sneha) — seeded from the start but never actually used in any test until now —
  correctly blocked from creating a product (RLS rejected the insert), and correctly sees all
  existing products (read access confirmed)

## Audit round 2 — all 10 roles now tested, colorful reskin

**All 10 roles have now actually been tested**, not just reasoned about from RLS policy code.
The 4 that had never been exercised at all (no seeded user existed) — Accountant, Tax Manager,
Claims Manager, CEO/Owner — now have demo accounts and were verified live:
- **Accountant**'s distinct "Reconcile" tier on Settlements: correctly blocked from *creating* a
  settlement, correctly *could* reconcile an existing one (Full write is Finance-Manager-only,
  Reconcile is broader)
- **Tax Manager**: confirmed genuinely sees 0 claims even with a real claim in the database
  (Claims = "—" for this role)
- **Claims Manager**: correctly approved a claim (Full tier), correctly blocked from creating a
  tax record (Tax = "—" for this role)
- **CEO/Owner**: correctly views orders/ledgers but a status update was silently rejected —
  view-only confirmed for real, not just assumed

Kept these 4 as permanent seed accounts (matching the reasoning for the original 5) — the Users
screen and role switcher now demonstrate all 10 roles, not 6.

**Full visual reskin** — moved from the original quiet ledger-paper aesthetic to a colorful,
Zoho-style look: vivid blue accent (`#2563EB`) replacing the deep teal, a deep-navy sidebar with a
bright blue active state, rounded-full status pills, softly rounded cards with a subtle lift
(shadow), and a bold colorful "S" brand badge used consistently in both the Topbar and the
pre-login Auth screens. Because the whole app was already built on CSS custom-property tokens
(`--accent`, `--success`, etc.) rather than hardcoded colors scattered through 30+ page files,
this took editing `globals.css` plus 4 shared components (Sidebar, Topbar, Button, StatusPill,
AuthShell) — every page picked up the new look automatically with zero page-level edits.

## Back navigation fix

Real gap you caught: 5 of 6 detail screens (Order, Return, RTO, Claim, Settlement) had no way to
get back to their list except the sidebar — only Ledger Detail had a "← All ledgers" link. Added
the same consistent pattern to all of them, plus Order Import and Session Management, which had
the same gap.

## Edit capability (audit follow-up — was create-only everywhere)

- **Users**: Super Admin can now change anyone's role inline, and suspend/reactivate accounts.
  Verified live: successfully changed Priya's role and back; separately confirmed Priya herself
  (Operations Manager) is correctly blocked from promoting herself to Super Admin — the RLS policy
  restricting `user_profiles` writes to Super Admin holds regardless of what the UI shows
- **Products**: inline edit (name, category, HSN, GST rate, cost price) + click-to-toggle
  active/inactive, for Super Admin and Operations Manager
- **Warehouses**: inline edit (name, address) + active/inactive toggle
- **Channels**: active/inactive toggle for Super Admin

**A real bug caught before shipping:** the Channels deactivate feature referenced a `status`
column that turned out not to exist on that table at all (only `api_status`, a different concept
— connection status, not active/inactive). Would have crashed immediately in the browser. Caught
by testing against the real database before considering it done, not by inspection — added the
missing column via migration `0020`, then re-verified the fix live.

## Audit Trail and Permissions screens — plus a systemic attribution bug fixed first

Before building Audit Trail, checked whether the data it would show was even real: **it wasn't**.
`post_sales_voucher()` and `close_accounting_period()` never set `vouchers.created_by` despite the
column existing — confirmed live, 11 real posted vouchers, 0 attributed to anyone. Same gap in the
Return/RTO/Claim create forms (`created_by`/`owner` columns existed, never populated). Fixed the
two SQL functions, fixed the three forms, and backfilled the 11 existing vouchers with their real
creators (10 sales postings → Super Admin, 1 period close → the Finance Manager who actually did
it, per this session's own testing history). Re-verified live afterward: real attribution now
flows through correctly (confirmed `inventory_transactions.created_by` was already working
correctly — only vouchers and the three create forms had the gap).

**Audit Trail** (ADM-143) now aggregates real attributed events — voucher postings, order status
changes, return/RTO/claim creation, inventory movements — sorted by time, with actual actor names,
not "Unknown" everywhere. Honestly scoped in the screen itself: this is action attribution, not a
full field-level change-history log, and Settlements/Bank/COD don't have creator tracking yet so
they're not included.

**Permissions** (ADM-134) is a read-only reference rendering the exact permission matrix every RLS
policy in this app implements — including the finer-grained tiers (Accountant's "Reconcile",
Warehouse Manager's "Evidence") that got collapsed to nothing in earlier phases' documentation.

## Friendlier errors and input validation (audit follow-up)

**Raw Postgres errors were leaking straight to the UI** — e.g. a duplicate SKU would show
`duplicate key value violates unique constraint "products_company_id_sku_key"` verbatim. Added a
shared `friendlyError()` helper and wired it into all 20 forms that previously showed
`error.message` raw. Custom RPC exceptions (`post_sales_voucher`, `disposition_return`, etc.) were
already written as clear messages via `raise exception` — those pass through unchanged; this only
rewrites the generic Postgres/PostgREST ones.

**Verified the regex patterns against real error strings, not guessed formats** — tested live
against three actual error cases (RLS denial, duplicate SKU, missing required field) before
wiring it in, and caught one wrong assumption in the process: the specific conflicting value in a
unique-constraint violation lives in Postgres's separate `DETAIL` line, which `error.message` from
supabase-js doesn't include — only the generic constraint-violation message does. Adjusted the
duplicate-key message accordingly rather than shipping a pattern that would never match.

**Added missing input validation**: negative amounts blocked on Settlements, Claims, COD, Bank
transactions, and settlement reconciliation; `period_end` before `period_start` blocked on
Settlements.

## Integrations screen + Dashboard verification

**Integrations** (ADM-137) shows real data, not placeholders: actual channel connection statuses
from the database, and the Shopify webhook's genuine deployment state pulled from Supabase (both
Edge Functions confirmed `ACTIVE`). States plainly that the webhook is deployed but unverified
against a real store, and gives the exact real endpoint URL (built from the actual project URL)
plus the exact setup steps needed to connect one — not a vague "integrations coming soon" page.

**Dashboard** — this was one of the screens flagged in the earlier audit as never actually loaded
or verified, only reasoned about. Ran every one of its exact query patterns live against the
database before trusting it: all column references (`orders.gross_amount`, `settlements.status`,
`cod_collections.remitted_amount`, `inventory_balances.quantity`, `claims.approved_amount`,
`journal_entries.debit/credit`, `products.cost_price`) confirmed valid with zero errors — unlike
the Channels `status` column bug from the previous round, this page checked out clean.

## Verified the rest of the never-loaded screens

Continued the pattern from the Dashboard check: ran the exact query column-sets from every
remaining screen that had never actually been loaded in a browser, live against the database,
before trusting them. Checked: Tax, Cash Flow, Inventory, Accounting Periods, Ledgers list, Ledger
Detail, and Audit Trail's six parallel queries.

**Result: all clean, zero new bugs found this round.** Worth stating plainly rather than padding —
this is a real, useful outcome (these screens' query shapes are correct), not a gap to report. The
Channels `status` bug from an earlier round is still the only column-reference bug this method has
caught; everything else checked with this technique has passed.

What this verification method does *not* cover: client-side JS logic (e.g. the CSV import's
row-grouping/merging), actual rendering/layout in a browser, or interaction bugs (broken button
bindings, state management issues) — only whether each screen's database queries are valid against
the real schema. Genuine browser click-through remains the one form of testing only you can do.

## Comprehensive seed data — every module now has real, clickable examples

Audit finding: Phases 3–5 (Returns, RTO, Inventory, Settlements, Bank, Claims, Tax) had **zero**
permanent seed data — every test during development was created and cleaned up right after, so
despite the features being built and tested, there was nothing to actually click through. Fixed:
seeded real examples across every state each module supports, using real existing orders posted
through the actual workflow functions (not fabricated final rows), grounded in Surat throughout.

**Verified afterward:** books still balance exactly (₹13,067.92 debit = ₹13,067.92 credit) even
after all this new activity, including a credit note that now has a real reversing voucher behind
it — Sales Revenue and Trade Receivables both correctly reduced, not just a standalone record with
no accounting effect.

**Bank accounts** — HDFC Bank (Ring Road Branch, Surat) and ICICI Bank (Udhna Branch, Surat).

**Settlements** — Amazon Aug (reconciled), Flipkart Aug (short-pay — expected ₹3,485, got ₹3,180),
Flipkart Sep (pending, ready to reconcile from the UI).

**Bank transactions** — 2 matched to the settlements above, 1 unmatched credit, 1 unmatched debit
(bank charges) — so the "needs reconciliation" view has something real to show.

**COD collections** (Surat-area couriers) — Delhivery/Sachin GIDC (remitted), Ecom Express/Udhna
(remitted), DTDC/Ring Road (short-remit — ₹900 of ₹1,944.82), Bluedart/Surat City (collected,
pending remittance, real ageing visible).

**Returns** — FLIP-1010 (received → inspected good → **restocked**, real stock now sitting in
Surat Main Warehouse), SHOP-1016 (received → damaged → **quarantined**, correctly zero stock
impact), SHOP-1005 (just **requested**, not yet received — shows the "Mark received" action).

**RTOs** — FLIP-1017 (received → good → **restocked**), SHOP-1007 (still **in transit** back).

**Claims** — one in each of the 5 states: AMAZ-1003 (potential), FLIP-1011 (claimed), FLIP-1006
(approved — shows in "recoverable"), SHOP-1002 (fully recovered, closed), FLIP-1001 (rejected).

**Tax transactions** — one GST record matched, one unmatched, one TDS matched, one TCS disputed.

**Credit note** — against FLIP-1010's return, with a real posted reversing voucher (Dr Sales
Revenue ₹386.66, Dr GST Payable ₹48.84, Cr Trade Receivables ₹435.50) — not a standalone record.

## Role-aware sidebar

You asked directly whether the sidebar differs per role — checking the code, it didn't: `NAV_SECTIONS`
was a flat static list with zero role-awareness, so every role saw every link, even ones RLS would
block them from seeing any data on. Fixed by mapping each nav item to the *exact* `has_*_view()`
RLS function that governs its screen (confirmed by reading the actual function source from the
database, not from memory) — a role only has an item hidden if it would see genuinely zero rows,
not just "limited" access. Screens where everyone sees *something* (Users, Roles, Channels,
Products, Warehouses, Permissions, Integrations, Audit Trail) are deliberately left visible to all,
since hiding them would misrepresent limited access as none.

Uses the *effective* role (`roleName`, which reflects an active role-preview), not the real one —
so when Super Admin previews as another role via the switcher, the sidebar genuinely shows what
that role would see too, not just the data restrictions underneath.

Verified the filter logic against the real permission functions: Warehouse Manager correctly hides
Settlements/Bank/Tax/Accounting (9 items), Accountant and Tax Manager correctly hide
Inventory/Returns/RTO/Claims, Claims Manager hides only Tax, Marketplace Manager hides only the
Accounting-tier screens — matching `has_returns_view()`, `has_settlements_view()`, etc. exactly.

## Server-side validation — a real security gap, not just UX polish

Checked whether the amount validation added earlier was actually enforced, or just a UI nicety —
it was only the latter. Confirmed live: calling `reconcile_settlement()` **directly** with `-100`
as the amount succeeded with zero server-side check, silently saving a negative "money received"
value that passed right through the client-side guard's back. Client-side validation is UX, not
security — any direct API call skips it entirely.

Fixed by adding the same checks inside all three amount-accepting RPCs
(`reconcile_settlement`, `record_cod_remittance`, `advance_claim`), then re-verified the exact same
attack is now blocked. Two more business-logic guards came out of this pass, worth having found
while already in there: a COD remittance can no longer be recorded in excess of the total amount
owed, and a claim's recovered amount can no longer exceed what was actually approved — tested live,
both correctly rejected.

**Confirmed the fix didn't break existing data**: re-checked all 5 seeded claims against the new
"recovered ≤ approved" rule — all pass, nothing needed correcting.

## Senior-QA-style pass: found and fixed a critical authorization bug

Doing structured testing beyond happy-path RLS checks — starting with the highest-severity class:
**does what the UI claims actually hold at the authorization layer?** First test: suspend a user,
then check whether their still-valid session actually loses access.

**It didn't.** `current_role_name()` — the function every single permission check and RLS policy
in this app depends on — never checked `user_profiles.status` at all. A suspended user retained
full, unrestricted access to everything their role permitted. The "Suspend" button built earlier
was cosmetic: it flipped a label that nothing else ever read.

Fixed at the root, in the one function that underpins everything, rather than patching every
individual policy. **Caught a second issue while fixing the first**: an initial fix restricting to
`status = 'active'` would have permanently locked out every newly-invited user too, since nothing
in this app ever transitions a user from `invited` to `active` after they accept — that's a real,
separate gap, but not a reason to lock them out. Narrowed the fix to exactly the bug being closed
(`status <> 'suspended'`) instead. Verified live both ways afterward: a suspended user is now
correctly blocked from even creating a product; an invited user's access is completely unaffected.

## Senior-QA pass round 2: a second real write-scoping bug, plus state-machine checks

**Bug found and fixed: Warehouse Manager write-scoping was missing entirely.** The returns/rtos
SELECT policy correctly scopes a Warehouse Manager to their assigned warehouse(s), but the
INSERT/UPDATE policies never did — only checking role. First attempt to prove this looked
blocked, but for the wrong reason (an `INSERT ... RETURNING` incidentally fails when the inserted
row wouldn't pass the SELECT policy — a Postgres side-effect, not real protection). Re-tested
with a plain `INSERT` and no `RETURNING` — matching exactly how the app's real `.insert()` calls
work — and it succeeded silently: Kavita (Warehouse Manager, scoped to Surat only) created a
return against **Mumbai's** warehouse with zero error. Fixed by applying the same scope check the
SELECT policy already uses to INSERT and UPDATE, for both `returns` and `rtos`. Re-verified after
the fix: the same attack is blocked, writing to her own warehouse still works, Super Admin is
unaffected.

**State-machine integrity re-confirmed under adversarial conditions** (not just happy-path):
closing an already-closed accounting period is correctly rejected ("Period Aug 2026 is already
closed"); dispositioning an already-restocked return a second time is correctly rejected ("Return
must be received before it can be dispositioned") — no double-crediting of stock is possible.

## Senior-QA pass round 3: two more real bugs, same pattern each time

Following the same adversarial method — trying to break state integrity, not just permissions.

**Bug: settlements could be silently re-reconciled.** `reconcile_settlement()` had no check
against running on a settlement that was already resolved. Confirmed live: an already-reconciled
settlement (real ₹5,270) was silently overwritten to a fabricated ₹9,999 — the UI hides the form
once status isn't `pending`, but the function itself enforced nothing. Fixed: reconciling now
requires `pending` status, re-verified the same attack is blocked and restored the real value.

**Bug: claims had no state-transition rules at all.** `advance_claim()` let any status jump to any
other status in any order. Confirmed live: a terminal `rejected` claim was silently reopened and
"approved" for a fabricated ₹5,000. **First fix attempt broke a legitimate flow** — it required
status to be exactly `approved` before recording a recovery, which blocked the multi-installment
recovery pattern (several partial recoveries in sequence) built and tested earlier in this
project. Caught before shipping by re-testing that exact flow, not just the exploit: a second
partial recovery failed with "must be approved." Corrected to allow `recovered → recovered`
(another installment) alongside `approved → recovered` (the first one). Re-verified three ways
afterward: multi-installment recovery works again (₹200 + ₹300 = ₹500), the original rejected-claim
exploit is still blocked, and all 5 originally-seeded claims still show their correct values with
zero corruption from the testing process itself.

## Senior-QA pass round 4: a revenue-recognition bug, plus a testing-process mistake worth being honest about

**Bug: cancelled orders could still be invoiced.** `post_sales_voucher()` checked that an order
existed and wasn't already invoiced, but never checked its fulfilment status at all. Confirmed
live: a **cancelled** order was successfully invoiced, generating ₹1,180 of phantom revenue for
something that was never actually sold. Fixed by rejecting `cancelled` and `rto` orders explicitly.
Re-verified: the same order is now correctly refused ("Cannot invoice an order with fulfilment
status cancelled"). None of the 10 originally-seeded invoices are affected — all were posted for
genuinely delivered orders.

**Also worth stating plainly**: my own test cleanup was incomplete on the first pass — I deleted
what I believed was the phantom voucher, but the trial balance came back ₹1,180 off afterward,
which is exactly how this was caught. Rather than assume the number was right, I queried for any
voucher whose source order no longer existed, found the real leftover, removed it properly, and
confirmed the books returned to their exact correct value (₹13,067.92 = ₹13,067.92) with zero
stray test orders remaining. Flagging this because the same discipline — verify the cleanup
worked, don't just assume it did — is the same standard this whole QA process depends on.

**Other checks this round that came back clean**: COD remittance already correctly blocked
over-remittance (protected by an earlier fix) when tested against an already-fully-remitted
collection.

## Senior-QA pass round 5: the warehouse-scope fix had a hole of its own

Directly following up on the write-scoping fix from round 2 — with a specific, well-founded
suspicion: `disposition_return()` and `disposition_rto()` are `SECURITY DEFINER`, meaning their
internal `UPDATE` statements **bypass RLS entirely**, including the exact policy just fixed.
Tested it deliberately rather than assuming the earlier fix was sufficient: created a return
against Mumbai's warehouse as Super Admin, then had Kavita (Warehouse Manager, scoped to Surat
only) call `disposition_return()` on it directly.

**It worked. No error at all** — she successfully restocked real inventory into a warehouse she
has zero authority over. The RLS fix genuinely does protect direct table writes (confirmed back
in round 2), but a `SECURITY DEFINER` function deliberately runs with elevated privilege and was
never touched by that fix — it needed its own explicit check.

Fixed by adding the same warehouse-scope check directly inside both functions. Re-verified three
ways: the exact same attack is now blocked ("Not authorized to disposition a return for a
warehouse outside your assignment"), her legitimate Surat-scoped disposition still works with zero
regression, and — checked rather than assumed — inventory balances came back to **exactly** the
original correct seed state (T-Shirt White ×1, Laptop Sleeve ×1, both at Surat, nothing else) with
books still balanced at ₹13,067.92.

**The general lesson, worth stating for anyone extending this codebase**: an RLS fix on a table
never automatically protects a `SECURITY DEFINER` function that writes to that table — each one
needs to be checked and fixed independently, since it's deliberately bypassing RLS by design.

## Senior-QA pass round 6: a status-check gap in invite-user — found, fixed in code, NOT yet redeployed

Extending the suspended-user fix's logic: does it actually cover every code path, or just the ones
going through `current_role_name()`? Checked `invite-user`'s Edge Function specifically, since it
queries `user_profiles` directly via the admin client (bypassing RLS by design, the same way the
disposition functions do) rather than calling `current_role_name()` at all.

**Confirmed by code inspection**: it checked the caller's role, but never their `status`. A
suspended Super Admin's still-valid session could still invite new users through this specific
path — the exact same class of gap as round 5, on yet another different code path. Fixed in the
function source.

**Important limitation, stated plainly rather than glossed over**: I could not redeploy this fix
in this session — the Edge Function deployment tool returned an approval requirement I don't have
access to here. The fix exists correctly in `supabase/functions/invite-user/index.ts` in this
repo, but **the live deployed function on Supabase may still be running the old, unpatched
version** until it's redeployed (via the Supabase CLI, dashboard, or a future session with working
tool access). This is a genuine gap between "fixed in source" and "fixed in production" — worth
tracking as its own follow-up, not assuming it's closed.

## Senior-QA pass round 7: the direct analog of the warehouse bug, on orders

Specifically went looking for the Marketplace Manager equivalent of the Warehouse Manager
write-scoping bug, since channel visibility is scoped the same way warehouse visibility is.
Confirmed live: Arjun (Marketplace Manager, scoped to Amazon + Flipkart only) successfully
**cancelled a real Shopify order** with zero error — the orders INSERT/UPDATE policies checked
role only, never channel scope, despite his channel *visibility* already being correctly scoped.
Reverted the change immediately, then fixed the root cause with a `has_channel_scope()` check
mirroring the warehouse one. Re-verified three ways: the same attack is now blocked, writing to
his own scoped channels (Amazon) still works, and unscoped roles (Super Admin, Operations
Manager) are completely unaffected.

**Vercel deployment status, checked honestly**: the connected Vercel account doesn't include the
`super-seller-360` project (only two unrelated ones), so I can't verify build/deploy status
directly — same limitation noted before. Every `git push` so far has succeeded, and Vercel
auto-deploys on push by default, so a new deployment has very likely triggered each time, but this
is inferred, not confirmed. Checking the Vercel dashboard directly would give a definite answer.

## Senior-QA pass round 8: two more instances of the same channel-scoping gap

Having found the pattern once (orders, round 7), specifically checked the other two tables
Marketplace Manager can write to that reference a channel:

**`channel_sku_map`**: confirmed live — Arjun (scoped to Amazon + Flipkart) created a SKU mapping
for **Shopify** with zero error.

**`claims`**: confirmed live — Arjun created a claim against a real **Shopify** order with zero
error (claims has no channel column of its own, so this scopes through the order's channel).

Both cleaned up immediately, then fixed with the same `has_channel_scope()` helper added for
orders. Re-verified thoroughly: both attacks are now blocked, a legitimate claim against his own
Amazon order still works, and — checked, not assumed — Operations Manager (unscoped) can still
create a claim against that same Shopify order with no regression. Final state confirmed clean:
exactly 16 `channel_sku_map` rows and 5 claims, matching the original seed data precisely, books
still balanced.

## Senior-QA pass round 9: privilege-escalation check (clean) + a real inventory-draining bug

**Role-preview escalation, checked and clean**: Kavita (Warehouse Manager) tried to grant herself
a Super Admin preview, and separately tried to set a role-preview row for a *different* user
(Amit) — both correctly blocked by RLS. The mechanism controlling perceived permissions across the
whole app holds up under direct attack.

**Bug found: negative quantities could silently drain real stock.** `order_lines.quantity` had no
positivity constraint at all. Confirmed live: created a fake order with a **-1** quantity line
item, logged a return against it, dispositioned it as "restocked" — and it silently drained a real
unit of stock (a genuine T-Shirt at Surat Main Warehouse went from 1 to 0) with zero error. The
existing insufficient-stock guard only catches a balance going negative overall; it does nothing
to stop a negative quantity being fed in as a "credit" to begin with. Restored the real stock
immediately, then fixed it at the source with a CHECK constraint — closing every current and
future consumer of `order_lines.quantity` in one place, not just the specific path that was
exploited. Re-verified: the same insert is now rejected outright by Postgres, all 28 existing
legitimate order lines are unaffected, and the books remain correctly balanced.

## Senior-QA pass round 10: Period Close had a hole — draft vouchers could post after closure

Tested a specific edge case using an isolated test period (never touching real seed data, given
how disruptive accidentally closing the real September period would have been): what happens to a
**draft** voucher already sitting in a period when that period gets closed?

**It could still be posted afterward, with zero error** — completely defeating the purpose of
Period Close. The trigger blocking postings into closed periods
(`prevent_voucher_in_closed_period`) only fired on `INSERT`, never `UPDATE`, so a leftover draft
voucher slipped straight through. Anyone could have left draft vouchers lying around and posted
them retroactively into books that were supposed to be locked.

Fixed by firing the same check on `UPDATE` too. Re-verified carefully given how central this
function is: normal invoice posting (`post_sales_voucher`'s own internal draft→posted transition,
which happens while the period is still open) still works correctly, the exact same exploit
attempt now fails with "Cannot post a voucher into a closed accounting period," and the real books
came back to their correct balanced state (₹13,067.92) with exactly the 2 real accounting periods
intact, zero contamination from the test.

## Senior-QA pass round 11: same channel-scoping gap on returns/rtos, fixed at both layers this time

Extended the channel-scoping check to the last remaining write path Marketplace Manager can reach:
returns and RTOs. First test looked blocked, but for the wrong reason again — Marketplace Manager
has zero warehouse visibility at all (a separate, deliberate design choice, not real channel
enforcement), which incidentally stopped a return referencing a specific warehouse. Retested with
`warehouse_id` left null specifically to bypass that false protection: Arjun created a return
against a real **Shopify** order with zero error.

**Fixed at both layers immediately** — RLS and the `disposition_return`/`disposition_rto`
`SECURITY DEFINER` functions — rather than repeating the two-round pattern from the warehouse bug
(0025 fixed RLS, 0029 had to separately fix the functions after finding they still bypassed it).
Re-verified thoroughly: the same attack is blocked, his legitimate return against his own Amazon
order still works, Kavita's (Warehouse Manager) legitimate Surat return has zero regression, and
final counts confirmed exactly clean — 3 returns, books still balanced at ₹13,067.92.

## Next steps

1. **Redeploy `invite-user` Edge Function** — the suspended-caller fix is in the source but not
   yet live; deployment was blocked by a tool-permission issue this session
2. Actually connect a Shopify store and register the webhook — still genuinely untested
2. Admin screens not yet built: Permissions, Integrations, Audit Trail
3. A dedicated Reports/KPI browser beyond what's on the Dashboard (drill-downs, saved filters)

## Phase roadmap

| Phase | Focus | Est. time |
|---|---|---|
| 1 | Foundation — auth, RLS, masters | 3–4 wks |
| 2 | Order ingestion + native accounting engine (ledger/voucher core) | 5–7 wks |
| 3 | Returns/RTO + inventory state machine | 4 wks |
| 4 | Settlements, bank, COD reconciliation | 5 wks |
| 5 | Claims, tax (GST/TDS/TCS), profitability, dashboards | 4–5 wks |
