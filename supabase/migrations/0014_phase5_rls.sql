-- ============================================================================
-- Super Seller 360 — Phase 5: RLS for Claims, Tax
-- Claims: Full = Super Admin, Finance Manager, Claims Manager.
--         Create+View = Operations Manager, Marketplace Manager.
--         View only = CEO/Owner, Warehouse Manager ("Evidence" simplified to
--         view-only here), Auditor. None = Accountant, Tax Manager.
-- Tax: Full = Super Admin, Finance Manager, Accountant, Tax Manager.
--      View = CEO/Owner, Operations Manager, Marketplace Manager, Auditor.
--      None = Warehouse Manager, Claims Manager.
-- ============================================================================

create or replace function has_claims_view()
returns boolean language sql stable as $$
  select coalesce(current_role_name() not in ('Accountant','Tax Manager'), false)
$$;
alter function has_claims_view() set search_path = public, pg_temp;

create or replace function has_claims_create()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in (
    'Super Admin','Finance Manager','Claims Manager','Operations Manager','Marketplace Manager'
  ), false)
$$;
alter function has_claims_create() set search_path = public, pg_temp;

create or replace function has_claims_manage()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin','Finance Manager','Claims Manager'), false)
$$;
alter function has_claims_manage() set search_path = public, pg_temp;

create or replace function has_tax_view()
returns boolean language sql stable as $$
  select coalesce(current_role_name() not in ('Warehouse Manager','Claims Manager'), false)
$$;
alter function has_tax_view() set search_path = public, pg_temp;

create or replace function has_tax_write()
returns boolean language sql stable as $$
  select coalesce(current_role_name() in ('Super Admin','Finance Manager','Accountant','Tax Manager'), false)
$$;
alter function has_tax_write() set search_path = public, pg_temp;

alter table claims           enable row level security;
alter table tax_transactions enable row level security;

create policy "claims view" on claims for select using (has_claims_view());
create policy "claims create" on claims for insert with check (has_claims_create());
create policy "claims manage" on claims for update using (has_claims_manage());

create policy "tax view" on tax_transactions for select using (has_tax_view());
create policy "tax write" on tax_transactions for all
  using (has_tax_write()) with check (has_tax_write());
