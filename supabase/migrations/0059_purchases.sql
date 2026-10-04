-- 0059: Suppliers, purchase bills (with GST input credit and TDS), supplier payments (maker-checker) and creditors ageing.
--
-- The rules here follow what a practising CA would expect, but every rate and threshold below is a STARTING VALUE
-- to be confirmed by your CA (see tds_sections and the allowed GST rates in pb_calc). Nothing is hard-wired to one rate.
--
-- Flow:  supplier (maker adds, checker approves)  ->  purchase bill (maker enters, checker approves = posts the voucher)
--        ->  payment (maker enters against bills, checker approves = posts the voucher)  ->  ageing / MSME watch.
-- Posted vouchers are never edited: a cancelled bill or payment posts a reversal voucher.
-- A checker cannot approve their own entry unless the owner switches that on in purchase_settings (single-person shops).

-- ---------------------------------------------------------------- 1. GST state codes (also used by the GST reports later)
create table if not exists gst_states (
  code text primary key check (code ~ '^[0-9]{2}$'),
  name text not null unique
);
insert into gst_states (code, name) values
 ('01','Jammu and Kashmir'),('02','Himachal Pradesh'),('03','Punjab'),('04','Chandigarh'),('05','Uttarakhand'),('06','Haryana'),
 ('07','Delhi'),('08','Rajasthan'),('09','Uttar Pradesh'),('10','Bihar'),('11','Sikkim'),('12','Arunachal Pradesh'),('13','Nagaland'),
 ('14','Manipur'),('15','Mizoram'),('16','Tripura'),('17','Meghalaya'),('18','Assam'),('19','West Bengal'),('20','Jharkhand'),
 ('21','Odisha'),('22','Chhattisgarh'),('23','Madhya Pradesh'),('24','Gujarat'),('26','Dadra and Nagar Haveli and Daman and Diu'),
 ('27','Maharashtra'),('29','Karnataka'),('30','Goa'),('31','Lakshadweep'),('32','Kerala'),('33','Tamil Nadu'),('34','Puducherry'),
 ('35','Andaman and Nicobar Islands'),('36','Telangana'),('37','Andhra Pradesh'),('38','Ladakh'),('97','Other Territory'),('99','Centre Jurisdiction')
on conflict (code) do nothing;
alter table gst_states enable row level security;
drop policy if exists "gst_states read" on gst_states;
create policy "gst_states read" on gst_states for select to authenticated using (true);
grant select on gst_states to authenticated;

-- GSTIN: 15 characters, state code, PAN, entity number, Z, and a check character (mod 36). Catches typing mistakes before they reach a return.
create or replace function gstin_valid(p text) returns boolean
language plpgsql immutable as $$
declare chars text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'; i int; v int; f int; pr int; s int := 0; g text := upper(btrim(coalesce(p, '')));
begin
  if g !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then return false; end if;
  for i in 1..14 loop
    v := position(substr(g, i, 1) in chars) - 1;
    f := case when i % 2 = 1 then 1 else 2 end;
    pr := v * f;
    s := s + pr / 36 + pr % 36;
  end loop;
  return substr(chars, ((36 - s % 36) % 36) + 1, 1) = substr(g, 15, 1);
end $$;

-- ---------------------------------------------------------------- 2. ledgers the purchase postings need
insert into account_groups (parent_group_id, name, nature, is_primary, status)
select (select account_group_id from account_groups where name = 'Liabilities' and is_primary), 'Sundry Creditors', 'liability', false, 'active'
where not exists (select 1 from account_groups where name = 'Sundry Creditors');

insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = v.grp limit 1), v.name, v.nature, 0,
       case when v.nature in ('asset', 'expense') then 'debit' else 'credit' end, v.gst, false, 'active'
from (values
  ('Sundry Creditors', 'Sundry Creditors',  'liability', false),
  ('Current Assets',   'Input CGST',        'asset',     true),
  ('Current Assets',   'Input SGST',        'asset',     true),
  ('Current Assets',   'Input IGST',        'asset',     true),
  ('Duties & Taxes',   'TDS Payable',       'liability', false)
) as v(grp, name, nature, gst)
where not exists (select 1 from ledgers l where l.name = v.name);

-- ---------------------------------------------------------------- 3. settings and TDS sections
create table if not exists purchase_settings (
  id                    int primary key default 1 check (id = 1),
  allow_self_approval   boolean not null default false,   -- a one-person shop can switch this on; everyone else keeps the second pair of eyes
  msme_limit_days       int not null default 45 check (msme_limit_days between 1 and 90),
  updated_at            timestamptz not null default now()
);
insert into purchase_settings (id) values (1) on conflict do nothing;

create table if not exists tds_sections (
  section           text primary key,
  description       text not null,
  rate              numeric(5,2) not null check (rate >= 0 and rate <= 100),
  single_threshold  numeric(14,2),     -- deduct on a single bill at or above this
  annual_threshold  numeric(14,2),     -- or once the supplier's total in the financial year reaches this
  active            boolean not null default true
);
insert into tds_sections (section, description, rate, single_threshold, annual_threshold) values
  ('194C-IND', 'Contractor / transporter: individual or HUF (confirm with CA)',          1,    30000, 100000),
  ('194C-OTH', 'Contractor / transporter: company, firm or others (confirm with CA)',    2,    30000, 100000),
  ('194J-PRO', 'Professional fees (confirm with CA)',                                    10,   50000, null),
  ('194J-TEC', 'Technical services / call centre (confirm with CA)',                     2,    50000, null),
  ('194H',     'Commission or brokerage (confirm with CA)',                              2,    20000, null),
  ('194I-BLD', 'Rent: land, building, furniture (confirm with CA)',                      10,   null,  600000),
  ('194I-PLM', 'Rent: plant and machinery (confirm with CA)',                            2,    null,  600000)
on conflict (section) do nothing;

alter table purchase_settings enable row level security;
alter table tds_sections      enable row level security;
drop policy if exists "ps read" on purchase_settings;  create policy "ps read" on purchase_settings for select to authenticated using (has_accounting_view());
drop policy if exists "tds read" on tds_sections;      create policy "tds read" on tds_sections      for select to authenticated using (has_accounting_view());
grant select on purchase_settings, tds_sections to authenticated;

create or replace function has_purchase_approve() returns boolean
language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Finance Manager'), false)
$$;

-- ---------------------------------------------------------------- 4. suppliers
create table if not exists suppliers (
  supplier_id          uuid primary key default gen_random_uuid(),
  name                 text not null check (btrim(name) <> ''),
  trade_name           text,
  gstin                text check (gstin is null or gstin_valid(gstin)),
  pan                  text check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  state_code           text not null references gst_states(code),
  is_msme              boolean not null default false,
  msme_reg_no          text,
  payment_terms_days   int not null default 30 check (payment_terms_days between 0 and 365),
  tds_section          text references tds_sections(section),
  tds_rate_override    numeric(5,2) check (tds_rate_override is null or (tds_rate_override >= 0 and tds_rate_override <= 100)),  -- lower-deduction certificate
  email                text,
  phone                text,
  address              text,
  status               text not null default 'pending' check (status in ('pending', 'active', 'blocked')),
  created_by           uuid default auth.uid(),
  approved_by          uuid,
  approved_at          timestamptz,
  created_at           timestamptz not null default now(),
  constraint supplier_gstin_state check (gstin is null or left(gstin, 2) = state_code),
  constraint supplier_gstin_pan   check (gstin is null or pan is null or substr(gstin, 3, 10) = pan)
);
create unique index if not exists suppliers_gstin_uq on suppliers (gstin) where gstin is not null;
create index if not exists suppliers_name on suppliers (lower(name));

-- bank details are kept apart so only people who can pay suppliers can read them
create table if not exists supplier_bank (
  supplier_id     uuid primary key references suppliers(supplier_id) on delete cascade,
  bank_name       text,
  ifsc            text check (ifsc is null or ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  account_number  text check (account_number is null or account_number ~ '^[0-9]{6,20}$'),
  account_holder  text
);

-- ---------------------------------------------------------------- 5. bills and payments
create sequence if not exists purchase_bill_seq;
create sequence if not exists supplier_payment_seq;

create table if not exists purchase_bills (
  bill_id               uuid primary key default gen_random_uuid(),
  bill_no               text not null unique,
  supplier_id           uuid not null references suppliers(supplier_id),
  supplier_invoice_no   text not null check (btrim(supplier_invoice_no) <> ''),
  supplier_invoice_date date not null,
  bill_date             date not null,                 -- the date it is booked (and posted) on
  due_date              date not null,
  is_intra_state        boolean not null,
  itc_eligible          boolean not null default true,
  itc_reason            text,
  taxable_value         numeric(14,2) not null default 0,
  cgst                  numeric(14,2) not null default 0,
  sgst                  numeric(14,2) not null default 0,
  igst                  numeric(14,2) not null default 0,
  total                 numeric(14,2) not null default 0,
  tds_section           text,
  tds_base              numeric(14,2) not null default 0,
  tds_rate              numeric(5,2) not null default 0,
  tds_amount            numeric(14,2) not null default 0,
  net_payable           numeric(14,2) not null default 0,   -- total less TDS
  status                text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  voucher_id            uuid references vouchers(voucher_id),
  reversal_voucher_id   uuid references vouchers(voucher_id),
  notes                 text,
  decision_note         text,
  created_by            uuid default auth.uid(),
  created_at            timestamptz not null default now(),
  decided_by            uuid,
  decided_at            timestamptz
);
create unique index if not exists purchase_bills_inv_uq on purchase_bills (supplier_id, lower(btrim(supplier_invoice_no))) where status in ('pending', 'approved');
create index if not exists purchase_bills_supplier on purchase_bills (supplier_id, status);

create table if not exists purchase_bill_lines (
  line_id      uuid primary key default gen_random_uuid(),
  bill_id      uuid not null references purchase_bills(bill_id) on delete cascade,
  line_no      int not null,
  description  text not null,
  hsn_code     text,
  quantity     numeric(14,3) not null check (quantity > 0),
  unit_price   numeric(14,2) not null check (unit_price >= 0),
  gst_rate     numeric(5,2) not null,
  ledger_id    uuid not null references ledgers(ledger_id),
  taxable      numeric(14,2) not null,
  cgst         numeric(14,2) not null default 0,
  sgst         numeric(14,2) not null default 0,
  igst         numeric(14,2) not null default 0
);

create table if not exists supplier_payments (
  payment_id          uuid primary key default gen_random_uuid(),
  payment_no          text not null unique,
  supplier_id         uuid not null references suppliers(supplier_id),
  payment_date        date not null,
  mode                text not null check (mode in ('bank', 'upi', 'cash')),
  bank_account_id     uuid references bank_accounts(bank_account_id),
  amount              numeric(14,2) not null check (amount > 0),
  utr                 text,
  notes               text,
  status              text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  voucher_id          uuid references vouchers(voucher_id),
  reversal_voucher_id uuid references vouchers(voucher_id),
  decision_note       text,
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  decided_by          uuid,
  decided_at          timestamptz,
  constraint payment_bank_needed check (mode = 'cash' or bank_account_id is not null),
  constraint payment_utr_needed  check (mode = 'cash' or nullif(btrim(coalesce(utr, '')), '') is not null)
);
create unique index if not exists supplier_payments_utr_uq on supplier_payments (lower(btrim(utr))) where utr is not null and status in ('pending', 'approved');

create table if not exists payment_allocations (
  payment_id  uuid not null references supplier_payments(payment_id) on delete cascade,
  bill_id     uuid not null references purchase_bills(bill_id),
  amount      numeric(14,2) not null check (amount > 0),
  primary key (payment_id, bill_id)
);

-- ---------------------------------------------------------------- 6. row-level security: read by accounting viewers, change only through the functions
alter table suppliers          enable row level security;
alter table supplier_bank      enable row level security;
alter table purchase_bills     enable row level security;
alter table purchase_bill_lines enable row level security;
alter table supplier_payments  enable row level security;
alter table payment_allocations enable row level security;
drop policy if exists "sup read" on suppliers;           create policy "sup read" on suppliers           for select to authenticated using (has_accounting_view());
drop policy if exists "supbank read" on supplier_bank;   create policy "supbank read" on supplier_bank   for select to authenticated using (has_accounting_write());
drop policy if exists "pb read" on purchase_bills;       create policy "pb read" on purchase_bills       for select to authenticated using (has_accounting_view());
drop policy if exists "pbl read" on purchase_bill_lines; create policy "pbl read" on purchase_bill_lines for select to authenticated using (has_accounting_view());
drop policy if exists "sp read" on supplier_payments;    create policy "sp read" on supplier_payments    for select to authenticated using (has_accounting_view());
drop policy if exists "pa read" on payment_allocations;  create policy "pa read" on payment_allocations  for select to authenticated using (has_accounting_view());
grant select on suppliers, supplier_bank, purchase_bills, purchase_bill_lines, supplier_payments, payment_allocations to authenticated;

-- ---------------------------------------------------------------- 7. helpers
create or replace function pur_company_state() returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select g.code from companies c join gst_states g on lower(g.name) = lower(btrim(c.state)) order by c.created_at limit 1
$$;

create or replace function pur_fy_start(p date) returns date
language sql immutable as $$
  select make_date(case when extract(month from p) >= 4 then extract(year from p)::int else extract(year from p)::int - 1 end, 4, 1)
$$;

create or replace function pur_self_ok(p_creator uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select p_creator is distinct from auth.uid() or coalesce((select allow_self_approval from purchase_settings where id = 1), false)
$$;

-- ---------------------------------------------------------------- 8. supplier save / approve / block
create or replace function supplier_save(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid; old suppliers%rowtype; ob supplier_bank%rowtype;
  v_gstin text := nullif(upper(btrim(coalesce(p ->> 'gstin', ''))), '');
  v_pan   text := nullif(upper(btrim(coalesce(p ->> 'pan', ''))), '');
  v_state text := nullif(btrim(coalesce(p ->> 'state_code', '')), '');
  v_acct  text := nullif(btrim(coalesce(p ->> 'account_number', '')), '');
  v_ifsc  text := nullif(upper(btrim(coalesce(p ->> 'ifsc', ''))), '');
  v_tds   text := nullif(btrim(coalesce(p ->> 'tds_section', '')), '');
  v_changed boolean := false;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can add or change a supplier'; end if;
  if nullif(btrim(coalesce(p ->> 'name', '')), '') is null then raise exception 'Supplier name is required'; end if;
  if v_gstin is not null then
    if not gstin_valid(v_gstin) then raise exception 'That GSTIN is not valid. Check it against the supplier''s invoice (15 characters).'; end if;
    v_state := left(v_gstin, 2);
    if v_pan is null then v_pan := substr(v_gstin, 3, 10); end if;
    if substr(v_gstin, 3, 10) <> v_pan then raise exception 'The PAN does not match the GSTIN'; end if;
  end if;
  if v_state is null then raise exception 'Choose the supplier''s state'; end if;
  if v_tds is not null and not exists (select 1 from tds_sections where section = v_tds and active) then raise exception 'Unknown TDS section'; end if;

  if p_id is null then
    insert into suppliers (name, trade_name, gstin, pan, state_code, is_msme, msme_reg_no, payment_terms_days, tds_section, tds_rate_override, email, phone, address)
    values (btrim(p ->> 'name'), nullif(btrim(coalesce(p ->> 'trade_name', '')), ''), v_gstin, v_pan, v_state,
            coalesce((p ->> 'is_msme')::boolean, false), nullif(btrim(coalesce(p ->> 'msme_reg_no', '')), ''),
            coalesce(nullif(p ->> 'payment_terms_days', '')::int, 30), v_tds, nullif(p ->> 'tds_rate_override', '')::numeric,
            nullif(btrim(coalesce(p ->> 'email', '')), ''), nullif(btrim(coalesce(p ->> 'phone', '')), ''), nullif(btrim(coalesce(p ->> 'address', '')), ''))
    returning supplier_id into v_id;
    insert into supplier_bank (supplier_id, bank_name, ifsc, account_number, account_holder)
    values (v_id, nullif(btrim(coalesce(p ->> 'bank_name', '')), ''), v_ifsc, v_acct, nullif(btrim(coalesce(p ->> 'account_holder', '')), ''));
    return v_id;
  end if;

  select * into old from suppliers where supplier_id = p_id for update;
  if not found then raise exception 'Supplier not found'; end if;
  select * into ob from supplier_bank where supplier_id = p_id;
  -- changes that could redirect money or change tax treatment need a second approval again
  v_changed := old.gstin is distinct from v_gstin or old.tds_section is distinct from v_tds
            or old.tds_rate_override is distinct from nullif(p ->> 'tds_rate_override', '')::numeric
            or ob.account_number is distinct from v_acct or ob.ifsc is distinct from v_ifsc;
  update suppliers set name = btrim(p ->> 'name'), trade_name = nullif(btrim(coalesce(p ->> 'trade_name', '')), ''), gstin = v_gstin, pan = v_pan,
         state_code = v_state, is_msme = coalesce((p ->> 'is_msme')::boolean, false), msme_reg_no = nullif(btrim(coalesce(p ->> 'msme_reg_no', '')), ''),
         payment_terms_days = coalesce(nullif(p ->> 'payment_terms_days', '')::int, 30), tds_section = v_tds,
         tds_rate_override = nullif(p ->> 'tds_rate_override', '')::numeric,
         email = nullif(btrim(coalesce(p ->> 'email', '')), ''), phone = nullif(btrim(coalesce(p ->> 'phone', '')), ''), address = nullif(btrim(coalesce(p ->> 'address', '')), ''),
         status = case when v_changed and old.status = 'active' then 'pending' else old.status end,
         created_by = case when v_changed and old.status = 'active' then auth.uid() else old.created_by end,
         approved_by = case when v_changed and old.status = 'active' then null else old.approved_by end,
         approved_at = case when v_changed and old.status = 'active' then null else old.approved_at end
   where supplier_id = p_id;
  insert into supplier_bank (supplier_id, bank_name, ifsc, account_number, account_holder)
  values (p_id, nullif(btrim(coalesce(p ->> 'bank_name', '')), ''), v_ifsc, v_acct, nullif(btrim(coalesce(p ->> 'account_holder', '')), ''))
  on conflict (supplier_id) do update set bank_name = excluded.bank_name, ifsc = excluded.ifsc, account_number = excluded.account_number, account_holder = excluded.account_holder;
  return p_id;
end $$;

create or replace function supplier_decide(p_id uuid, p_action text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve or block a supplier'; end if;
  select * into s from suppliers where supplier_id = p_id for update;
  if not found then raise exception 'Supplier not found'; end if;
  if p_action = 'approve' then
    if s.status = 'active' then return; end if;
    if not pur_self_ok(s.created_by) then raise exception 'A different person must approve this supplier (you entered or last changed it)'; end if;
    update suppliers set status = 'active', approved_by = auth.uid(), approved_at = now() where supplier_id = p_id;
  elsif p_action = 'block' then
    update suppliers set status = 'blocked' where supplier_id = p_id;
  elsif p_action = 'unblock' then
    update suppliers set status = 'active' where supplier_id = p_id and approved_by is not null;
    if not found then raise exception 'This supplier was never approved'; end if;
  else raise exception 'Unknown action'; end if;
end $$;

-- ---------------------------------------------------------------- 9. bill arithmetic (one place, used for the preview and the saved bill)
-- Tax is worked out line by line. For same-state purchases the CGST is half the tax rounded down to the paisa and SGST is the remainder, so
-- the two always add back to exactly the tax (no stray paisa).
create or replace function pb_calc(p_supplier uuid, p_lines jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s suppliers%rowtype; v_co text; v_intra boolean; ln jsonb; n int := 0; q numeric; pr numeric; rt numeric; tx numeric; tax numeric; c numeric; sg numeric; ig numeric;
  v_out jsonb := '[]'::jsonb; t_tax numeric := 0; t_c numeric := 0; t_s numeric := 0; t_i numeric := 0; t_tx numeric := 0; v_led uuid; v_def uuid;
  v_rates numeric[] := array[0, 0.25, 3, 5, 12, 18, 28, 40];
begin
  if not has_accounting_view() then raise exception 'Not authorized'; end if;
  select * into s from suppliers where supplier_id = p_supplier;
  if not found then raise exception 'Choose a supplier'; end if;
  v_co := pur_company_state();
  if v_co is null then raise exception 'The company''s state is not set to a valid Indian state, so CGST/SGST versus IGST cannot be decided'; end if;
  v_intra := (s.state_code = v_co);
  select ledger_id into v_def from ledgers where name = 'Inventory - Stock-in-Trade';
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one line'; end if;
  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    q  := coalesce(nullif(ln ->> 'quantity', '')::numeric, 0);
    pr := coalesce(nullif(ln ->> 'unit_price', '')::numeric, -1);
    rt := coalesce(nullif(ln ->> 'gst_rate', '')::numeric, 0);
    if q <= 0 then raise exception 'Line %: quantity must be more than zero', n; end if;
    if pr < 0 then raise exception 'Line %: enter the price', n; end if;
    if not (rt = any (v_rates)) then raise exception 'Line %: GST rate % is not one of 0, 0.25, 3, 5, 12, 18, 28, 40', n, rt; end if;
    if nullif(btrim(coalesce(ln ->> 'description', '')), '') is null then raise exception 'Line %: describe what was bought', n; end if;
    v_led := coalesce(nullif(ln ->> 'ledger_id', '')::uuid, v_def);
    if not exists (select 1 from ledgers where ledger_id = v_led and status = 'active' and nature in ('expense', 'asset')) then
      raise exception 'Line %: choose an expense or stock ledger', n;
    end if;
    tx  := round(q * pr, 2);
    tax := round(tx * rt / 100, 2);
    if v_intra then c := floor(tax * 100 / 2) / 100; sg := tax - c; ig := 0; else c := 0; sg := 0; ig := tax; end if;
    t_tx := t_tx + tx; t_tax := t_tax + tax; t_c := t_c + c; t_s := t_s + sg; t_i := t_i + ig;
    v_out := v_out || jsonb_build_object('line_no', n, 'description', btrim(ln ->> 'description'), 'hsn_code', nullif(btrim(coalesce(ln ->> 'hsn_code', '')), ''),
              'quantity', q, 'unit_price', pr, 'gst_rate', rt, 'ledger_id', v_led, 'taxable', tx, 'cgst', c, 'sgst', sg, 'igst', ig);
  end loop;
  if s.gstin is null and t_tax > 0 then raise exception 'This supplier has no GSTIN, so they cannot charge GST. Set the rate to 0, or add their GSTIN.'; end if;
  return jsonb_build_object('lines', v_out, 'intra', v_intra, 'taxable', t_tx, 'cgst', t_c, 'sgst', t_s, 'igst', t_i, 'tax', t_tax, 'total', t_tx + t_tax);
end $$;

-- TDS on this bill: deducted when the bill is booked (credit), on the value before GST.
create or replace function pb_tds(p_supplier uuid, p_bill_date date, p_taxable numeric, p_exclude uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype; t tds_sections%rowtype; v_rate numeric; v_prior numeric; v_prior_base numeric; v_cum numeric; v_base numeric := 0; v_fy date;
begin
  select * into s from suppliers where supplier_id = p_supplier;
  if s.tds_section is null then return jsonb_build_object('section', null, 'base', 0, 'rate', 0, 'amount', 0); end if;
  select * into t from tds_sections where section = s.tds_section;
  v_rate := coalesce(s.tds_rate_override, t.rate);
  if s.pan is null then v_rate := greatest(v_rate, 20); end if;   -- no PAN: higher rate applies
  v_fy := pur_fy_start(p_bill_date);
  select coalesce(sum(taxable_value), 0), coalesce(sum(tds_base), 0) into v_prior, v_prior_base
    from purchase_bills where supplier_id = p_supplier and status = 'approved' and bill_id is distinct from p_exclude
     and bill_date >= v_fy and bill_date < v_fy + interval '1 year';
  v_cum := v_prior + p_taxable;
  if t.annual_threshold is not null and v_cum >= t.annual_threshold then v_base := v_cum - v_prior_base;
  elsif t.single_threshold is not null and p_taxable >= t.single_threshold then v_base := p_taxable;
  elsif t.single_threshold is null and t.annual_threshold is null then v_base := p_taxable; end if;
  return jsonb_build_object('section', s.tds_section, 'base', v_base, 'rate', v_rate, 'amount', round(v_base * v_rate / 100, 0));
end $$;

-- ---------------------------------------------------------------- 10. purchase bills
create or replace function create_purchase_bill(p_supplier uuid, p_invoice_no text, p_invoice_date date, p_bill_date date, p_lines jsonb,
                                                p_itc boolean default true, p_itc_reason text default null, p_notes text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype; c jsonb; v_id uuid; v_no text; ln jsonb; v_itc boolean := coalesce(p_itc, true);
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can enter a purchase bill'; end if;
  select * into s from suppliers where supplier_id = p_supplier;
  if not found then raise exception 'Choose a supplier'; end if;
  if s.status <> 'active' then raise exception 'This supplier is % - it must be approved before bills can be entered', s.status; end if;
  if nullif(btrim(coalesce(p_invoice_no, '')), '') is null then raise exception 'Enter the supplier''s invoice number'; end if;
  if p_invoice_date is null or p_invoice_date > current_date then raise exception 'The supplier invoice date cannot be empty or in the future'; end if;
  if p_bill_date is null or p_bill_date < p_invoice_date then raise exception 'The booking date cannot be before the invoice date'; end if;
  if s.gstin is null then v_itc := false; end if;
  if not v_itc and nullif(btrim(coalesce(p_itc_reason, '')), '') is null and s.gstin is not null then
    raise exception 'Say why the GST credit is not being claimed (for example blocked credit, personal use)';
  end if;
  c := pb_calc(p_supplier, p_lines);
  v_no := 'PB-' || to_char(p_bill_date, 'YYMM') || '-' || lpad(nextval('purchase_bill_seq')::text, 6, '0');
  begin
    insert into purchase_bills (bill_no, supplier_id, supplier_invoice_no, supplier_invoice_date, bill_date, due_date, is_intra_state, itc_eligible, itc_reason,
                                taxable_value, cgst, sgst, igst, total, net_payable, notes)
    values (v_no, p_supplier, btrim(p_invoice_no), p_invoice_date, p_bill_date, p_invoice_date + s.payment_terms_days, (c ->> 'intra')::boolean, v_itc,
            case when v_itc then null else nullif(btrim(coalesce(p_itc_reason, '')), '') end,
            (c ->> 'taxable')::numeric, (c ->> 'cgst')::numeric, (c ->> 'sgst')::numeric, (c ->> 'igst')::numeric, (c ->> 'total')::numeric, (c ->> 'total')::numeric,
            nullif(btrim(coalesce(p_notes, '')), ''))
    returning bill_id into v_id;
  exception when unique_violation then
    raise exception 'A bill with invoice number % from this supplier is already entered', btrim(p_invoice_no);
  end;
  for ln in select * from jsonb_array_elements(c -> 'lines') loop
    insert into purchase_bill_lines (bill_id, line_no, description, hsn_code, quantity, unit_price, gst_rate, ledger_id, taxable, cgst, sgst, igst)
    values (v_id, (ln ->> 'line_no')::int, ln ->> 'description', ln ->> 'hsn_code', (ln ->> 'quantity')::numeric, (ln ->> 'unit_price')::numeric,
            (ln ->> 'gst_rate')::numeric, (ln ->> 'ledger_id')::uuid, (ln ->> 'taxable')::numeric, (ln ->> 'cgst')::numeric, (ln ->> 'sgst')::numeric, (ln ->> 'igst')::numeric);
  end loop;
  return v_id;
end $$;

create or replace function approve_purchase_bill(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b purchase_bills%rowtype; s suppliers%rowtype; t jsonb; v_lines jsonb := '[]'::jsonb; r record; v_res jsonb; v_cr numeric; v_tds numeric;
  l_creditors uuid; l_tds uuid; l_cgst uuid; l_sgst uuid; l_igst uuid;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve a purchase bill'; end if;
  select * into b from purchase_bills where bill_id = p_id for update;
  if not found then raise exception 'Bill not found'; end if;
  if b.status <> 'pending' then raise exception 'This bill is already %', b.status; end if;
  if not pur_self_ok(b.created_by) then raise exception 'A different person must approve this bill (you entered it)'; end if;
  select * into s from suppliers where supplier_id = b.supplier_id;
  if s.status <> 'active' then raise exception 'The supplier is %, so the bill cannot be approved', s.status; end if;
  select ledger_id into l_creditors from ledgers where name = 'Sundry Creditors';
  select ledger_id into l_tds from ledgers where name = 'TDS Payable';
  select ledger_id into l_cgst from ledgers where name = 'Input CGST';
  select ledger_id into l_sgst from ledgers where name = 'Input SGST';
  select ledger_id into l_igst from ledgers where name = 'Input IGST';
  if l_creditors is null or l_tds is null or l_cgst is null or l_sgst is null or l_igst is null then raise exception 'Purchase ledgers are missing (Sundry Creditors, TDS Payable, Input CGST/SGST/IGST)'; end if;

  t := pb_tds(b.supplier_id, b.bill_date, b.taxable_value, b.bill_id);
  v_tds := (t ->> 'amount')::numeric;
  v_cr := b.total - v_tds;

  -- debit side: each line's ledger (with its own tax added when the credit is not claimed)
  for r in select ledger_id, sum(taxable + case when b.itc_eligible then 0 else cgst + sgst + igst end) as amt
             from purchase_bill_lines where bill_id = p_id group by ledger_id order by ledger_id loop
    v_lines := v_lines || jsonb_build_object('ledger_id', r.ledger_id, 'debit', r.amt, 'credit', 0, 'narration', 'Purchase ' || b.supplier_invoice_no);
  end loop;
  if b.itc_eligible then
    if b.cgst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_cgst, 'debit', b.cgst, 'credit', 0, 'narration', 'Input CGST'); end if;
    if b.sgst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_sgst, 'debit', b.sgst, 'credit', 0, 'narration', 'Input SGST'); end if;
    if b.igst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_igst, 'debit', b.igst, 'credit', 0, 'narration', 'Input IGST'); end if;
  end if;
  v_lines := v_lines || jsonb_build_object('ledger_id', l_creditors, 'debit', 0, 'credit', v_cr, 'narration', s.name);
  if v_tds > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tds, 'debit', 0, 'credit', v_tds, 'narration', 'TDS ' || (t ->> 'section')); end if;

  v_res := acc_post_journal(b.bill_date, 'Purchase bill ' || b.bill_no || ' - ' || s.name || ' inv ' || b.supplier_invoice_no, v_lines, 'purchase_bill', b.bill_id, 'posted', auth.uid());
  update purchase_bills set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, decided_by = auth.uid(), decided_at = now(),
         tds_section = t ->> 'section', tds_base = (t ->> 'base')::numeric, tds_rate = (t ->> 'rate')::numeric, tds_amount = v_tds, net_payable = v_cr
   where bill_id = p_id;
  return v_res || jsonb_build_object('tds', v_tds, 'net_payable', v_cr);
end $$;

create or replace function reject_purchase_bill(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can reject a purchase bill'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  update purchase_bills set status = 'rejected', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where bill_id = p_id and status = 'pending';
  if not found then raise exception 'Only a pending bill can be rejected'; end if;
end $$;

-- the person who entered a pending bill may withdraw it; an approved bill is cancelled by a reversal voucher and only if nothing has been paid against it
create or replace function cancel_purchase_bill(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b purchase_bills%rowtype; v_rev uuid;
begin
  select * into b from purchase_bills where bill_id = p_id for update;
  if not found then raise exception 'Bill not found'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  if b.status = 'pending' then
    if not (b.created_by = auth.uid() or has_purchase_approve()) then raise exception 'Only the person who entered it, or an approver, can withdraw this bill'; end if;
    update purchase_bills set status = 'cancelled', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where bill_id = p_id;
  elsif b.status = 'approved' then
    if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can cancel an approved bill'; end if;
    if exists (select 1 from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id
                where a.bill_id = p_id and p.status in ('pending', 'approved')) then
      raise exception 'Payments are recorded against this bill. Cancel those payments first.';
    end if;
    v_rev := br_reverse_voucher(b.voucher_id, 'purchase bill ' || b.bill_no || ' cancelled: ' || btrim(p_reason));
    update purchase_bills set status = 'cancelled', reversal_voucher_id = v_rev, decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where bill_id = p_id;
  else
    raise exception 'This bill is already %', b.status;
  end if;
end $$;

-- ---------------------------------------------------------------- 11. outstanding per bill (approved bills less approved payments; pending payments are shown as reserved)
create or replace function bill_outstanding(p_bill uuid, p_as_of date default null, p_include_pending boolean default false) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select b.net_payable - coalesce((select sum(a.amount) from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id
                                    where a.bill_id = b.bill_id
                                      and (p.status = 'approved' or (p_include_pending and p.status = 'pending'))
                                      and (p_as_of is null or p.payment_date <= p_as_of)), 0)
    from purchase_bills b where b.bill_id = p_bill and b.status = 'approved'
$$;

-- ---------------------------------------------------------------- 12. supplier payments
create or replace function create_supplier_payment(p_supplier uuid, p_date date, p_mode text, p_bank_account uuid, p_amount numeric,
                                                   p_utr text, p_notes text, p_allocations jsonb)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype; a jsonb; v_id uuid; v_no text; v_sum numeric := 0; v_out numeric; v_amt numeric; v_b purchase_bills%rowtype;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can record a supplier payment'; end if;
  select * into s from suppliers where supplier_id = p_supplier;
  if not found then raise exception 'Choose a supplier'; end if;
  if s.status = 'blocked' then raise exception 'This supplier is blocked'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount paid'; end if;
  if p_date is null or p_date > current_date then raise exception 'The payment date cannot be empty or in the future'; end if;
  if p_mode not in ('bank', 'upi', 'cash') then raise exception 'Choose bank, UPI or cash'; end if;
  if p_mode <> 'cash' and (p_bank_account is null or nullif(btrim(coalesce(p_utr, '')), '') is null) then raise exception 'Choose the bank account and enter the UTR / reference'; end if;
  v_no := 'SP-' || to_char(p_date, 'YYMM') || '-' || lpad(nextval('supplier_payment_seq')::text, 6, '0');
  begin
    insert into supplier_payments (payment_no, supplier_id, payment_date, mode, bank_account_id, amount, utr, notes)
    values (v_no, p_supplier, p_date, p_mode, case when p_mode = 'cash' then null else p_bank_account end, round(p_amount, 2),
            case when p_mode = 'cash' then null else btrim(p_utr) end, nullif(btrim(coalesce(p_notes, '')), ''))
    returning payment_id into v_id;
  exception when unique_violation then raise exception 'That UTR / reference is already used on another payment';
  end;
  for a in select * from jsonb_array_elements(coalesce(p_allocations, '[]'::jsonb)) loop
    v_amt := round(coalesce(nullif(a ->> 'amount', '')::numeric, 0), 2);
    if v_amt <= 0 then continue; end if;
    select * into v_b from purchase_bills where bill_id = (a ->> 'bill_id')::uuid;
    if not found or v_b.supplier_id <> p_supplier or v_b.status <> 'approved' then raise exception 'A bill in the list is not an approved bill of this supplier'; end if;
    v_out := bill_outstanding(v_b.bill_id, null, true);
    if v_amt > v_out then raise exception 'Bill % has only % left to pay (including payments waiting for approval)', v_b.bill_no, v_out; end if;
    insert into payment_allocations (payment_id, bill_id, amount) values (v_id, v_b.bill_id, v_amt);
    v_sum := v_sum + v_amt;
  end loop;
  if v_sum > round(p_amount, 2) then raise exception 'The bills add up to more than the amount paid'; end if;
  return v_id;
end $$;

create or replace function approve_supplier_payment(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare p supplier_payments%rowtype; s suppliers%rowtype; v_dr uuid; v_cr uuid; v_res jsonb; a record; v_out numeric;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve a supplier payment'; end if;
  select * into p from supplier_payments where payment_id = p_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if p.status <> 'pending' then raise exception 'This payment is already %', p.status; end if;
  if not pur_self_ok(p.created_by) then raise exception 'A different person must approve this payment (you entered it)'; end if;
  select * into s from suppliers where supplier_id = p.supplier_id;
  if s.status = 'blocked' then raise exception 'The supplier is blocked'; end if;
  for a in select bill_id, amount from payment_allocations where payment_id = p_id loop
    v_out := bill_outstanding(a.bill_id, null, false);
    if v_out is null or a.amount > v_out then raise exception 'A bill in this payment no longer has that much outstanding'; end if;
  end loop;
  select ledger_id into v_dr from ledgers where name = 'Sundry Creditors';
  if p.mode = 'cash' then select ledger_id into v_cr from ledgers where name = 'Cash in Hand';
  else select ledger_id into v_cr from bank_accounts where bank_account_id = p.bank_account_id; end if;
  if v_dr is null or v_cr is null then raise exception 'The creditors or bank/cash ledger is missing'; end if;
  v_res := acc_post_journal(p.payment_date, 'Payment ' || p.payment_no || ' to ' || s.name || coalesce(' UTR ' || p.utr, ''),
            jsonb_build_array(jsonb_build_object('ledger_id', v_dr, 'debit', p.amount, 'credit', 0, 'narration', s.name),
                              jsonb_build_object('ledger_id', v_cr, 'debit', 0, 'credit', p.amount, 'narration', coalesce(p.utr, 'Cash'))),
            'supplier_payment', p.payment_id, 'posted', auth.uid());
  update supplier_payments set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, decided_by = auth.uid(), decided_at = now() where payment_id = p_id;
  return v_res;
end $$;

create or replace function reject_supplier_payment(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can reject a payment'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  update supplier_payments set status = 'rejected', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where payment_id = p_id and status = 'pending';
  if not found then raise exception 'Only a pending payment can be rejected'; end if;
end $$;

create or replace function cancel_supplier_payment(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p supplier_payments%rowtype; v_rev uuid;
begin
  select * into p from supplier_payments where payment_id = p_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  if p.status = 'pending' then
    if not (p.created_by = auth.uid() or has_purchase_approve()) then raise exception 'Only the person who entered it, or an approver, can withdraw this payment'; end if;
    update supplier_payments set status = 'cancelled', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where payment_id = p_id;
  elsif p.status = 'approved' then
    if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can cancel an approved payment'; end if;
    v_rev := br_reverse_voucher(p.voucher_id, 'supplier payment ' || p.payment_no || ' cancelled: ' || btrim(p_reason));
    update supplier_payments set status = 'cancelled', reversal_voucher_id = v_rev, decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where payment_id = p_id;
  else raise exception 'This payment is already %', p.status; end if;
end $$;

-- ---------------------------------------------------------------- 13. creditors ageing and MSME watch
create or replace function supplier_ageing(p_as_of date default current_date)
returns table (bill_id uuid, bill_no text, supplier_id uuid, supplier_name text, is_msme boolean, supplier_invoice_no text, invoice_date date, bill_date date,
               due_date date, net_payable numeric, paid numeric, outstanding numeric, days_overdue int, bucket text, msme_due_date date, msme_breach boolean)
language sql stable set search_path = public, pg_temp as $$
  with x as (
    select b.bill_id, b.bill_no, b.supplier_id, s.name as supplier_name, s.is_msme, b.supplier_invoice_no, b.supplier_invoice_date as invoice_date, b.bill_date, b.due_date,
           b.net_payable,
           coalesce((select sum(a.amount) from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id
                      where a.bill_id = b.bill_id and p.status = 'approved' and p.payment_date <= p_as_of), 0) as paid,
           (b.supplier_invoice_date + least(s.payment_terms_days, coalesce((select msme_limit_days from purchase_settings where id = 1), 45))) as msme_due
      from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
     where b.status = 'approved' and b.bill_date <= p_as_of
  )
  select x.bill_id, x.bill_no, x.supplier_id, x.supplier_name, x.is_msme, x.supplier_invoice_no, x.invoice_date, x.bill_date, x.due_date, x.net_payable, x.paid,
         x.net_payable - x.paid, greatest(p_as_of - x.due_date, 0),
         case when p_as_of <= x.due_date then 'Not due' when p_as_of - x.due_date <= 30 then '1-30' when p_as_of - x.due_date <= 60 then '31-60'
              when p_as_of - x.due_date <= 90 then '61-90' else '90+' end,
         case when x.is_msme then x.msme_due end,
         x.is_msme and p_as_of > x.msme_due
    from x where x.net_payable - x.paid > 0
   order by x.due_date, x.supplier_name
$$;

-- ---------------------------------------------------------------- 14. proofs on bills and payments
alter table attachments drop constraint if exists attachments_entity_type_check;
alter table attachments add constraint attachments_entity_type_check check (entity_type in
  ('voucher', 'cash_settlement_report', 'bank_transaction', 'cod_collection', 'settlement', 'claim', 'return', 'rto', 'tax_transaction', 'supplier_bill', 'supplier_payment'));

create or replace function attachment_parent_visible(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select case p_type
    when 'voucher'                then exists (select 1 from vouchers where voucher_id = p_id)
    when 'cash_settlement_report'  then exists (select 1 from cash_settlement_reports where report_id = p_id)
    when 'bank_transaction'        then exists (select 1 from bank_transactions where bank_txn_id = p_id)
    when 'cod_collection'          then exists (select 1 from cod_collections where cod_id = p_id)
    when 'settlement'              then exists (select 1 from settlements where settlement_id = p_id)
    when 'claim'                   then exists (select 1 from claims where claim_id = p_id)
    when 'return'                  then exists (select 1 from returns where return_id = p_id)
    when 'rto'                     then exists (select 1 from rtos where rto_id = p_id)
    when 'tax_transaction'         then exists (select 1 from tax_transactions where tax_txn_id = p_id)
    when 'supplier_bill'           then exists (select 1 from purchase_bills where bill_id = p_id)
    when 'supplier_payment'        then exists (select 1 from supplier_payments where payment_id = p_id)
    else false end
$$;

create or replace function can_attach(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select (case p_type
    when 'voucher'                then has_accounting_write()
    when 'cash_settlement_report'  then has_bankcod_write()
    when 'bank_transaction'        then has_bankcod_write()
    when 'cod_collection'          then has_bankcod_write()
    when 'settlement'              then has_settlements_reconcile()
    when 'claim'                   then has_claims_create() or has_claims_manage()
    when 'return'                  then has_returns_write()
    when 'rto'                     then has_returns_write()
    when 'tax_transaction'         then has_tax_write()
    when 'supplier_bill'           then has_accounting_write()
    when 'supplier_payment'        then has_accounting_write()
    else false end)
  and (p_id is null or attachment_parent_visible(p_type, p_id))
$$;

create or replace function can_view_attachment(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select p_id is not null and (case p_type
    when 'voucher'                then has_accounting_view()
    when 'cash_settlement_report'  then has_bankcod_view()
    when 'bank_transaction'        then has_bankcod_view()
    when 'cod_collection'          then has_bankcod_view()
    when 'settlement'              then has_settlements_view()
    when 'claim'                   then has_claims_view()
    when 'return'                  then has_returns_view()
    when 'rto'                     then has_returns_view()
    when 'tax_transaction'         then has_tax_view()
    when 'supplier_bill'           then has_accounting_view()
    when 'supplier_payment'        then has_accounting_view()
    else false end)
  and attachment_parent_visible(p_type, p_id)
$$;

-- ---------------------------------------------------------------- 15. grants
revoke execute on function supplier_save(uuid, jsonb), supplier_decide(uuid, text), pb_calc(uuid, jsonb), pb_tds(uuid, date, numeric, uuid),
  create_purchase_bill(uuid, text, date, date, jsonb, boolean, text, text), approve_purchase_bill(uuid), reject_purchase_bill(uuid, text), cancel_purchase_bill(uuid, text),
  bill_outstanding(uuid, date, boolean), create_supplier_payment(uuid, date, text, uuid, numeric, text, text, jsonb), approve_supplier_payment(uuid),
  reject_supplier_payment(uuid, text), cancel_supplier_payment(uuid, text), supplier_ageing(date), pur_company_state(), pur_self_ok(uuid), has_purchase_approve()
  from public, anon, authenticated;
grant execute on function supplier_save(uuid, jsonb), supplier_decide(uuid, text), pb_calc(uuid, jsonb), pb_tds(uuid, date, numeric, uuid),
  create_purchase_bill(uuid, text, date, date, jsonb, boolean, text, text), approve_purchase_bill(uuid), reject_purchase_bill(uuid, text), cancel_purchase_bill(uuid, text),
  bill_outstanding(uuid, date, boolean), create_supplier_payment(uuid, date, text, uuid, numeric, text, text, jsonb), approve_supplier_payment(uuid),
  reject_supplier_payment(uuid, text), cancel_supplier_payment(uuid, text), supplier_ageing(date), has_purchase_approve() to authenticated;
revoke execute on function gstin_valid(text) from public, anon;
grant execute on function gstin_valid(text) to authenticated;
