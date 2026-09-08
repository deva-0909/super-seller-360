-- ============================================================================
-- Super Seller 360 — Phase 1: Foundation
-- Roles, Users, Company, Channel, Warehouse, Product, ChannelSKUMap
-- Maps directly to Data Dictionary + Role Permission sheets in the BRD.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. ROLES  (fixed set from Role Permission sheet — not user-editable list)
-- ---------------------------------------------------------------------------
create table roles (
  role_id     uuid primary key default gen_random_uuid(),
  name        text not null unique,   -- 'Super Admin' | 'CEO/Owner' | 'Operations Manager' | ...
  scope       text not null,          -- human-readable scope description from BRD
  created_at  timestamptz not null default now()
);

insert into roles (name, scope) values
  ('Super Admin',         'All entities'),
  ('CEO/Owner',           'All read + dashboards'),
  ('Operations Manager',  'Operations scope'),
  ('Warehouse Manager',   'Assigned warehouses'),
  ('Finance Manager',     'Finance + all required linked records'),
  ('Accountant',          'Accounting scope'),
  ('Claims Manager',      'Claims + linked transactions'),
  ('Tax Manager',         'Tax scope'),
  ('Marketplace Manager', 'Assigned channels'),
  ('Auditor',             'Read-only');

-- ---------------------------------------------------------------------------
-- 2. USERS  (extends Supabase auth.users — one row per authenticated person)
-- ---------------------------------------------------------------------------
create table user_profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  email       text not null,
  role_id     uuid not null references roles(role_id),
  status      text not null default 'active' check (status in ('active','suspended','invited')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Scoping tables: Warehouse Manager -> assigned warehouses, Marketplace Manager -> assigned channels
create table user_warehouse_scope (
  user_id      uuid not null references user_profiles(user_id) on delete cascade,
  warehouse_id uuid not null,  -- FK added after warehouses table below
  primary key (user_id, warehouse_id)
);

create table user_channel_scope (
  user_id     uuid not null references user_profiles(user_id) on delete cascade,
  channel_id  uuid not null,   -- FK added after channels table below
  primary key (user_id, channel_id)
);

-- ---------------------------------------------------------------------------
-- 3. COMPANY  (single-tenant today; structured for multi-entity later)
-- ---------------------------------------------------------------------------
create table companies (
  company_id      uuid primary key default gen_random_uuid(),
  name            text not null,
  legal_entity_id text,               -- GSTIN / PAN / CIN etc.
  status          text not null default 'active' check (status in ('active','inactive')),
  created_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 4. CHANNEL  (Amazon, Flipkart, Myntra, Shopify, ... one row per seller account)
-- ---------------------------------------------------------------------------
create table channels (
  channel_id        uuid primary key default gen_random_uuid(),
  company_id        uuid not null references companies(company_id),
  name              text not null,               -- e.g. "Amazon - Main Account"
  type              text not null,                -- 'marketplace' | 'd2c' | 'payment_gateway'
  seller_account     text,                        -- portal seller/account ID
  api_status        text not null default 'not_connected'
                      check (api_status in ('not_connected','connected','error','disabled')),
  settlement_cycle  text,                          -- e.g. 'weekly', 'daily', 'T+7'
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table user_channel_scope
  add constraint user_channel_scope_channel_fk
  foreign key (channel_id) references channels(channel_id) on delete cascade;

-- ---------------------------------------------------------------------------
-- 5. WAREHOUSE
-- ---------------------------------------------------------------------------
create table warehouses (
  warehouse_id  uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(company_id),
  name          text not null,
  type          text not null default 'own' check (type in ('own','marketplace_fulfilled','3pl')),
  address       text,
  status        text not null default 'active' check (status in ('active','inactive')),
  created_at    timestamptz not null default now()
);

alter table user_warehouse_scope
  add constraint user_warehouse_scope_warehouse_fk
  foreign key (warehouse_id) references warehouses(warehouse_id) on delete cascade;

-- ---------------------------------------------------------------------------
-- 6. PRODUCT  (one canonical product per SKU, independent of any channel)
-- ---------------------------------------------------------------------------
create table products (
  product_id      uuid primary key default gen_random_uuid(),
  company_id      uuid not null references companies(company_id),
  sku             text not null,
  name            text not null,
  variant         text,
  barcode         text,
  hsn             text,                          -- HSN code for GST
  gst_rate        numeric(5,2),                  -- e.g. 18.00
  brand           text,
  category        text,
  cost_price      numeric(12,2),
  packaging_cost  numeric(12,2),
  status          text not null default 'active' check (status in ('active','inactive','discontinued')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (company_id, sku)
);

-- ---------------------------------------------------------------------------
-- 7. CHANNEL_SKU_MAP  (links your one product to each portal's own SKU/listing)
-- ---------------------------------------------------------------------------
create table channel_sku_map (
  mapping_id  uuid primary key default gen_random_uuid(),
  product_id  uuid not null references products(product_id) on delete cascade,
  channel_id  uuid not null references channels(channel_id) on delete cascade,
  channel_sku text,
  listing_id  text not null,      -- portal's listing/ASIN/FSN id
  status      text not null default 'active' check (status in ('active','inactive')),
  created_at  timestamptz not null default now(),
  unique (channel_id, listing_id)
);

-- ---------------------------------------------------------------------------
-- 8. updated_at triggers (kept generic, reused by every future table)
-- ---------------------------------------------------------------------------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_user_profiles_updated_at before update on user_profiles
  for each row execute function set_updated_at();
create trigger trg_channels_updated_at before update on channels
  for each row execute function set_updated_at();
create trigger trg_products_updated_at before update on products
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- 9. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------
alter table user_profiles      enable row level security;
alter table companies          enable row level security;
alter table channels           enable row level security;
alter table warehouses         enable row level security;
alter table products           enable row level security;
alter table channel_sku_map    enable row level security;
alter table user_warehouse_scope enable row level security;
alter table user_channel_scope   enable row level security;

-- Helper: current user's role name.
-- NOTE: this original definition has a self-referential RLS recursion bug
-- (it queries user_profiles, whose own RLS policy calls this function) —
-- found during Phase 2 testing, fixed by redefining it SECURITY DEFINER in
-- migration 0003_phase2a_rls_and_seed.sql. Left as-is here for history;
-- 0003's `create or replace` supersedes it on any fresh install.
create or replace function current_role_name()
returns text language sql stable as $$
  select r.name from user_profiles up
  join roles r on r.role_id = up.role_id
  where up.user_id = auth.uid()
$$;

-- Foundation-phase policy: Super Admin, CEO/Owner, Finance Manager, Auditor see everything (read);
-- Operations/Marketplace/Warehouse Managers see their own scope.
-- Full write-permission matrix (per-module Full/View/Limited from Role Permission sheet)
-- gets built out module-by-module as those tables land in later phases —
-- this phase only establishes the pattern and secures master data.

create policy "read own profile or admin"
  on user_profiles for select
  using (
    user_id = auth.uid()
    or current_role_name() in ('Super Admin','CEO/Owner')
  );

create policy "admin manages profiles"
  on user_profiles for all
  using (current_role_name() = 'Super Admin')
  with check (current_role_name() = 'Super Admin');

create policy "company readable by all authenticated"
  on companies for select
  using (auth.uid() is not null);

create policy "channels readable, scoped for marketplace manager"
  on channels for select
  using (
    current_role_name() in ('Super Admin','CEO/Owner','Operations Manager','Finance Manager','Auditor')
    or exists (
      select 1 from user_channel_scope ucs
      where ucs.user_id = auth.uid() and ucs.channel_id = channels.channel_id
    )
  );

create policy "warehouses readable, scoped for warehouse manager"
  on warehouses for select
  using (
    current_role_name() in ('Super Admin','CEO/Owner','Operations Manager','Finance Manager','Auditor')
    or exists (
      select 1 from user_warehouse_scope uws
      where uws.user_id = auth.uid() and uws.warehouse_id = warehouses.warehouse_id
    )
  );

create policy "products readable by all authenticated"
  on products for select
  using (auth.uid() is not null);

create policy "channel_sku_map readable by all authenticated"
  on channel_sku_map for select
  using (auth.uid() is not null);

-- Write access (create/update) for masters: Super Admin + Operations Manager per BRD "Full" grants.
create policy "operations and admin manage products"
  on products for insert with check (current_role_name() in ('Super Admin','Operations Manager'));
create policy "operations and admin update products"
  on products for update using (current_role_name() in ('Super Admin','Operations Manager'));

create policy "admin manages channels" on channels for insert
  with check (current_role_name() = 'Super Admin');
create policy "admin updates channels" on channels for update
  using (current_role_name() = 'Super Admin');

create policy "admin manages warehouses" on warehouses for insert
  with check (current_role_name() in ('Super Admin','Operations Manager'));
create policy "admin updates warehouses" on warehouses for update
  using (current_role_name() in ('Super Admin','Operations Manager'));

create policy "operations manages channel_sku_map"
  on channel_sku_map for all
  using (current_role_name() in ('Super Admin','Operations Manager','Marketplace Manager'))
  with check (current_role_name() in ('Super Admin','Operations Manager','Marketplace Manager'));
