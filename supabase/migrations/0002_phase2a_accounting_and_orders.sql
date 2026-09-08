-- ============================================================================
-- Super Seller 360 — Phase 2A: Accounting Engine + Order Ingestion (schema)
-- AccountGroup, Ledger, VoucherType, Voucher, VoucherLine, JournalEntry,
-- JournalRule, AccountingPeriod, OpeningBalance, CostCentre, CostCategory,
-- Order, OrderLine, Invoice, CreditNote.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. CHART OF ACCOUNTS
-- ---------------------------------------------------------------------------
create table account_groups (
  account_group_id uuid primary key default gen_random_uuid(),
  parent_group_id  uuid references account_groups(account_group_id),
  name             text not null,
  nature           text not null check (nature in ('asset','liability','income','expense','equity')),
  is_primary       boolean not null default false,
  status           text not null default 'active' check (status in ('active','inactive')),
  created_at       timestamptz not null default now()
);

create table cost_centres (
  cost_centre_id uuid primary key default gen_random_uuid(),
  company_id     uuid not null references companies(company_id),
  name           text not null,
  status         text not null default 'active' check (status in ('active','inactive')),
  created_at     timestamptz not null default now()
);

create table cost_categories (
  cost_category_id uuid primary key default gen_random_uuid(),
  name             text not null,
  status           text not null default 'active' check (status in ('active','inactive'))
);

create table ledgers (
  ledger_id                uuid primary key default gen_random_uuid(),
  account_group_id         uuid not null references account_groups(account_group_id),
  name                     text not null,
  nature                   text not null check (nature in ('asset','liability','income','expense','equity')),
  opening_balance          numeric(14,2) not null default 0,
  opening_balance_type     text check (opening_balance_type in ('debit','credit')),
  gst_applicable           boolean not null default false,
  reconciliation_required  boolean not null default false,
  channel_id               uuid references channels(channel_id),
  warehouse_id             uuid references warehouses(warehouse_id),
  status                   text not null default 'active' check (status in ('active','inactive')),
  created_at               timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. VOUCHER TYPES + ACCOUNTING PERIODS
-- ---------------------------------------------------------------------------
create table voucher_types (
  voucher_type_id    uuid primary key default gen_random_uuid(),
  code               text not null unique,       -- 'SALES' | 'CREDIT_NOTE' | 'PAYMENT' | 'RECEIPT' | 'JOURNAL'
  name               text not null,
  numbering_prefix   text,
  approval_required  boolean not null default false,
  source_event_type  text,                        -- e.g. 'order.invoiced'
  status             text not null default 'active' check (status in ('active','inactive'))
);

create table accounting_periods (
  accounting_period_id uuid primary key default gen_random_uuid(),
  financial_year_id    text not null,             -- e.g. 'FY2026-27'
  period_name          text not null,             -- e.g. 'Sep 2026'
  start_date           date not null,
  end_date             date not null,
  status               text not null default 'open' check (status in ('open','locked','closed')),
  locked_at            timestamptz,
  closed_by            uuid references user_profiles(user_id),
  created_at           timestamptz not null default now(),
  unique (financial_year_id, period_name)
);

-- ---------------------------------------------------------------------------
-- 3. VOUCHERS  (the immutable double-entry core — BR: posted vouchers are
--    immutable; corrections happen through reversal/adjustment vouchers)
-- ---------------------------------------------------------------------------
create table vouchers (
  voucher_id            uuid primary key default gen_random_uuid(),
  voucher_type_id       uuid not null references voucher_types(voucher_type_id),
  voucher_no            text not null,
  voucher_date          date not null default current_date,
  accounting_period_id  uuid not null references accounting_periods(accounting_period_id),
  status                text not null default 'posted' check (status in ('draft','posted','cancelled')),
  source_type           text,                     -- 'order' | 'return' | 'settlement' | ...
  source_id             uuid,
  narration             text,
  total_debit           numeric(14,2) not null default 0,
  total_credit          numeric(14,2) not null default 0,
  created_by            uuid references user_profiles(user_id),
  approved_by           uuid references user_profiles(user_id),
  created_at            timestamptz not null default now(),
  unique (voucher_type_id, voucher_no),
  constraint voucher_balanced check (total_debit = total_credit)
);

create table voucher_lines (
  voucher_line_id   uuid primary key default gen_random_uuid(),
  voucher_id        uuid not null references vouchers(voucher_id) on delete cascade,
  ledger_id         uuid not null references ledgers(ledger_id),
  debit             numeric(14,2) not null default 0,
  credit            numeric(14,2) not null default 0,
  cost_centre_id    uuid references cost_centres(cost_centre_id),
  cost_category_id  uuid references cost_categories(cost_category_id),
  tax_code          text,
  reference_type    text,
  reference_id      uuid,
  narration         text,
  constraint voucher_line_single_side check (
    (debit = 0 or credit = 0) and (debit <> 0 or credit <> 0)
  )
);

-- Flattened general-ledger view, auto-populated from voucher_lines whenever
-- a voucher posts. Reporting/ledger screens read this instead of joining
-- vouchers+voucher_lines every time — it mirrors the BRD's JournalEntry entity.
create table journal_entries (
  journal_id      uuid primary key default gen_random_uuid(),
  date            date not null,
  account_id      uuid not null references ledgers(ledger_id),
  debit           numeric(14,2) not null default 0,
  credit          numeric(14,2) not null default 0,
  reference_type  text,
  reference_id    uuid,
  status          text not null default 'posted' check (status in ('posted','cancelled')),
  voucher_id      uuid references vouchers(voucher_id),
  created_at      timestamptz not null default now()
);

-- Configuration for a future auto-posting rule engine (event_type -> ledger
-- mapping). Not executed yet in Phase 2 — see post_sales_voucher() below,
-- which posts sales vouchers directly with a fixed ledger mapping. This
-- table exists now so the configuration model matches the BRD from day one.
create table journal_rules (
  journal_rule_id     uuid primary key default gen_random_uuid(),
  event_type          text not null,
  condition           text,
  debit_ledger_rule   text,
  credit_ledger_rule  text,
  tax_rule            text,
  effective_from      date,
  status              text not null default 'active' check (status in ('active','inactive'))
);

create table opening_balances (
  opening_balance_id  uuid primary key default gen_random_uuid(),
  financial_year_id   text not null,
  ledger_id           uuid not null references ledgers(ledger_id),
  amount              numeric(14,2) not null,
  balance_type        text not null check (balance_type in ('debit','credit')),
  source              text,
  approved_by         uuid references user_profiles(user_id),
  created_at          timestamptz not null default now()
);

-- Block edits/deletes on posted vouchers and their lines — corrections must
-- go through a new reversal voucher, never an edit to history.
create or replace function prevent_posted_voucher_mutation()
returns trigger language plpgsql as $$
begin
  if TG_OP = 'DELETE' then
    if old.status = 'posted' then
      raise exception 'Posted vouchers cannot be deleted — post a reversal voucher instead.';
    end if;
    return old;
  end if;
  if old.status = 'posted' and (new.status is distinct from old.status or new.status = 'posted') then
    raise exception 'Posted vouchers cannot be edited — post a reversal voucher instead.';
  end if;
  return new;
end;
$$;
alter function prevent_posted_voucher_mutation() set search_path = public, pg_temp;

create trigger trg_vouchers_immutable
  before update or delete on vouchers
  for each row execute function prevent_posted_voucher_mutation();

create or replace function prevent_posted_voucher_line_mutation()
returns trigger language plpgsql as $$
declare
  v_status text;
begin
  select status into v_status from vouchers
    where voucher_id = coalesce(new.voucher_id, old.voucher_id);
  if v_status = 'posted' then
    raise exception 'Lines of a posted voucher cannot be changed — post a reversal voucher instead.';
  end if;
  if TG_OP = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
alter function prevent_posted_voucher_line_mutation() set search_path = public, pg_temp;

create trigger trg_voucher_lines_immutable
  before update or delete on voucher_lines
  for each row execute function prevent_posted_voucher_line_mutation();

-- Mirror every voucher_line into journal_entries the moment its voucher is posted.
create or replace function sync_journal_entries()
returns trigger language plpgsql as $$
begin
  delete from journal_entries where voucher_id = new.voucher_id;
  if new.status = 'posted' then
    insert into journal_entries (date, account_id, debit, credit, reference_type, reference_id, voucher_id)
    select v.voucher_date, vl.ledger_id, vl.debit, vl.credit, vl.reference_type, vl.reference_id, v.voucher_id
    from vouchers v
    join voucher_lines vl on vl.voucher_id = v.voucher_id
    where v.voucher_id = new.voucher_id;
  end if;
  return new;
end;
$$;
alter function sync_journal_entries() set search_path = public, pg_temp;

-- Fires after the voucher's lines are inserted (see post_sales_voucher),
-- keyed off an explicit call rather than a raw insert trigger on
-- voucher_lines so partially-built vouchers never sync early.
create trigger trg_sync_journal_entries
  after insert or update on vouchers
  for each row execute function sync_journal_entries();

-- ---------------------------------------------------------------------------
-- 4. ORDERS
-- ---------------------------------------------------------------------------
create table orders (
  order_id            uuid primary key default gen_random_uuid(),
  external_order_id   text not null,             -- portal's own order ID
  channel_id          uuid not null references channels(channel_id),
  order_date          timestamptz not null default now(),
  customer_ref        text,
  payment_type        text check (payment_type in ('prepaid','cod')),
  gross_amount        numeric(14,2) not null default 0,
  discount             numeric(14,2) not null default 0,
  tax_amount           numeric(14,2) not null default 0,
  net_amount           numeric(14,2) not null default 0,
  fulfilment_status   text not null default 'pending'
                        check (fulfilment_status in ('pending','processing','shipped','delivered','cancelled','rto')),
  payment_status       text not null default 'pending'
                        check (payment_status in ('pending','paid','partially_paid','refunded','failed')),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  -- BR-001: unique source-transaction key blocks duplicate imports.
  unique (channel_id, external_order_id)
);

create table order_lines (
  order_line_id  uuid primary key default gen_random_uuid(),
  order_id       uuid not null references orders(order_id) on delete cascade,
  product_id     uuid references products(product_id),
  quantity       numeric(10,2) not null default 1,
  unit_price     numeric(14,2) not null default 0,
  discount       numeric(14,2) not null default 0,
  tax            numeric(14,2) not null default 0
);

create table invoices (
  invoice_id       uuid primary key default gen_random_uuid(),
  order_id         uuid not null references orders(order_id),
  invoice_number   text not null unique,
  invoice_date     date not null default current_date,
  taxable_value    numeric(14,2) not null default 0,
  gst_amount       numeric(14,2) not null default 0,
  total            numeric(14,2) not null default 0,
  voucher_id       uuid references vouchers(voucher_id),
  created_at       timestamptz not null default now()
);

create table credit_notes (
  credit_note_id  uuid primary key default gen_random_uuid(),
  invoice_id      uuid not null references invoices(invoice_id),
  return_id       uuid,          -- FK added in Phase 3 once the Return table exists
  amount          numeric(14,2) not null default 0,
  tax_amount      numeric(14,2) not null default 0,
  date            date not null default current_date,
  status          text not null default 'draft' check (status in ('draft','posted','cancelled')),
  voucher_id      uuid references vouchers(voucher_id),
  created_at      timestamptz not null default now()
);

create trigger trg_orders_updated_at before update on orders
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. WF-002 "Sales accounting": Order -> Invoice -> Accounting entry.
--    Fixed ledger mapping for Phase 2 (Trade Receivables / Sales Revenue /
--    GST Payable). Runs as one transaction — no order is left invoiced
--    without a balanced posted voucher, or vice versa.
-- ---------------------------------------------------------------------------
create or replace function post_sales_voucher(p_order_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order            orders%rowtype;
  v_period_id        uuid;
  v_voucher_type_id  uuid;
  v_voucher_id       uuid;
  v_invoice_id       uuid;
  v_invoice_number   text;
  v_receivable_ledger uuid;
  v_sales_ledger      uuid;
  v_gst_ledger        uuid;
begin
  -- SECURITY DEFINER bypasses RLS on the tables it touches, so the
  -- permission check has to happen explicitly here rather than relying
  -- on row-level policies. has_accounting_write() is referenced from the
  -- Phase 2A RLS migration, which must run before this function is called.
  if not (has_orders_write() or has_accounting_write()) then
    raise exception 'Not authorized to post sales vouchers';
  end if;

  select * into v_order from orders where order_id = p_order_id;
  if not found then
    raise exception 'Order % not found', p_order_id;
  end if;

  if exists (select 1 from invoices where order_id = p_order_id) then
    raise exception 'Order % is already invoiced', p_order_id;
  end if;

  select accounting_period_id into v_period_id from accounting_periods
    where v_order.order_date::date between start_date and end_date and status = 'open'
    limit 1;
  if v_period_id is null then
    raise exception 'No open accounting period covers order date %', v_order.order_date;
  end if;

  select voucher_type_id into v_voucher_type_id from voucher_types where code = 'SALES';
  select ledger_id into v_receivable_ledger from ledgers where name = 'Trade Receivables';
  select ledger_id into v_sales_ledger from ledgers where name = 'Sales Revenue';
  select ledger_id into v_gst_ledger from ledgers where name = 'GST Payable (Output)';

  if v_voucher_type_id is null or v_receivable_ledger is null or v_sales_ledger is null then
    raise exception 'Accounting masters not seeded — run the Phase 2 seed data first.';
  end if;

  v_invoice_number := 'INV-' || to_char(now(), 'YYYYMM') || '-' ||
    lpad((select count(*) + 1 from invoices where invoice_number like 'INV-' || to_char(now(), 'YYYYMM') || '-%')::text, 5, '0');

  -- Inserted as 'draft' first: lines don't exist yet, and the immutability
  -- trigger only blocks a voucher that was ALREADY posted, so this leaves
  -- room for the draft -> posted transition below once lines are in place.
  insert into vouchers (
    voucher_type_id, voucher_no, voucher_date, accounting_period_id,
    status, source_type, source_id, narration, total_debit, total_credit
  ) values (
    v_voucher_type_id, v_invoice_number, v_order.order_date::date, v_period_id,
    'draft', 'order', p_order_id, 'Sales invoice for order ' || v_order.external_order_id,
    v_order.net_amount, v_order.net_amount
  ) returning voucher_id into v_voucher_id;

  insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
  values (v_voucher_id, v_receivable_ledger, v_order.net_amount, 0, 'order', p_order_id);

  if v_order.tax_amount > 0 and v_gst_ledger is not null then
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_sales_ledger, 0, v_order.net_amount - v_order.tax_amount, 'order', p_order_id);
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_gst_ledger, 0, v_order.tax_amount, 'order', p_order_id);
  else
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
    values (v_voucher_id, v_sales_ledger, 0, v_order.net_amount, 'order', p_order_id);
  end if;

  -- Post it now that all lines exist — this is the transition that fires
  -- sync_journal_entries with the real lines in place, and the moment the
  -- immutability trigger locks the voucher against further changes.
  update vouchers set status = 'posted' where voucher_id = v_voucher_id;

  insert into invoices (order_id, invoice_number, invoice_date, taxable_value, gst_amount, total, voucher_id)
  values (
    p_order_id, v_invoice_number, v_order.order_date::date,
    v_order.net_amount - v_order.tax_amount, v_order.tax_amount, v_order.net_amount, v_voucher_id
  ) returning invoice_id into v_invoice_id;

  return v_invoice_id;
end;
$$;
