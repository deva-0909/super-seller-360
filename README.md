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

## A bug caught and fixed during Phase 2 testing

`post_sales_voucher()`'s authorization check used `if not (has_orders_write() or
has_accounting_write())` — but when a caller has no `user_profiles` row at all,
`current_role_name()` returns SQL `NULL`, and `NULL in (...)` evaluates to `NULL`, not `false`.
`if not NULL` is falsy in plpgsql, so the check silently **didn't** raise — an order posted
successfully for a caller with no role whatsoever. Found by testing exactly that case end-to-end
against the live database, not by inspection. Fixed by having every `has_*_write()`/
`has_*_view()` helper coalesce to `false` explicitly (migration `0003`, and the standalone
lockdown in `0004` that also revokes `EXECUTE` from the `anon` role). Re-tested after the fix —
the same call now correctly raises "Not authorized to post sales vouchers".

## How inviting users works

Creating an auth account requires Supabase's admin API (service-role privileges), which must never
reach the browser. `supabase/functions/invite-user` is the only place that privilege exists — it
re-checks the caller is Super Admin, invites the new user, then creates their `user_profiles` row.
The Users screen calls this function; nobody can invite from the browser directly.

**Bootstrapping the very first account** (before anyone exists to send an invite) was done once via
direct SQL against `auth.users` — this is why there's no public sign-up screen: every user after
the first is created through the Invite flow, by design.

## Next steps

1. Actually connect a Shopify store and register the webhook — the receiver is built and
   deployed but genuinely untested until then; treat the first real webhook as an integration
   test, not a known-working path
2. Order Timeline (ORD-014), and order-line CSV import (line items aren't imported yet — only
   order headers)
3. Continue Phase 2 toward Phase 3: Returns/RTO + inventory state machine

## Phase roadmap

| Phase | Focus | Est. time |
|---|---|---|
| 1 | Foundation — auth, RLS, masters | 3–4 wks |
| 2 | Order ingestion + native accounting engine (ledger/voucher core) | 5–7 wks |
| 3 | Returns/RTO + inventory state machine | 4 wks |
| 4 | Settlements, bank, COD reconciliation | 5 wks |
| 5 | Claims, tax (GST/TDS/TCS), profitability, dashboards | 4–5 wks |
