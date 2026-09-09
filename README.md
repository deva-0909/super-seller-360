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

## Next steps

1. Actually connect a Shopify store and register the webhook — still genuinely untested
2. Order Timeline, order-line CSV import
3. Phase 5: Claims, Tax reconciliation, Reports/Dashboards

## Phase roadmap

| Phase | Focus | Est. time |
|---|---|---|
| 1 | Foundation — auth, RLS, masters | 3–4 wks |
| 2 | Order ingestion + native accounting engine (ledger/voucher core) | 5–7 wks |
| 3 | Returns/RTO + inventory state machine | 4 wks |
| 4 | Settlements, bank, COD reconciliation | 5 wks |
| 5 | Claims, tax (GST/TDS/TCS), profitability, dashboards | 4–5 wks |
