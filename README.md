# Super Seller 360°

Multi-channel e-commerce control tower — Next.js + Supabase.
Spec source: `Super_Seller_360_Developer_Ready_BRD_Figma_Specification.xlsx` (143 screens, 40 entities, 5-phase build).

## Repo structure

```
super-seller-360/
├── apps/
│   └── web/                    # Next.js app (App Router) — not yet scaffolded
├── supabase/
│   └── migrations/
│       └── 0001_phase1_foundation.sql   # Roles, Users, Company, Channel, Warehouse, Product, ChannelSKUMap
└── README.md
```

## Phase 1 — Foundation (this migration)

Tables created:
- `roles` — the 10 fixed roles from the Role Permission sheet (Super Admin, CEO/Owner, Operations Manager, Warehouse Manager, Finance Manager, Accountant, Claims Manager, Tax Manager, Marketplace Manager, Auditor)
- `user_profiles` — extends Supabase `auth.users` with role + status
- `user_warehouse_scope` / `user_channel_scope` — implements "Assigned warehouses" / "Assigned channels" scoping for Warehouse Manager and Marketplace Manager roles
- `companies`, `channels`, `warehouses`, `products`, `channel_sku_map`
- Row Level Security policies enforcing read/write access per role, matching the Role Permission sheet

## Why RLS is set up before any screens exist

Permissions are enforced in Postgres itself, not just hidden in the UI — a Warehouse Manager's Supabase query for Finance data returns nothing, regardless of what the frontend does. Retrofitting this after 140 screens exist is much harder than starting with it, which is why it's step one.

## Next steps (not yet done — confirm before I proceed)

1. Create the actual Supabase project (dev environment) and apply this migration
2. Scaffold the Next.js app (`apps/web`) with Supabase Auth wired to `user_profiles`
3. Build Auth screens (Login, OTP/2FA, Forgot/Reset Password) + Admin screens (user + role management)
4. Push this repo to GitHub

## Phase roadmap

| Phase | Focus | Est. time |
|---|---|---|
| 1 | Foundation — auth, RLS, masters | 3–4 wks |
| 2 | Order ingestion + native accounting engine (ledger/voucher core) | 5–7 wks |
| 3 | Returns/RTO + inventory state machine | 4 wks |
| 4 | Settlements, bank, COD reconciliation | 5 wks |
| 5 | Claims, tax (GST/TDS/TCS), profitability, dashboards | 4–5 wks |
