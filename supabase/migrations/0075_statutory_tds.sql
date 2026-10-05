-- 0075: Statutory compliance, part 1: TDS under the Income-tax Act, 2025 (in force from 1 April 2026) and the statutory calendar.
--
-- The 1961 Act is replaced from 1 April 2026. Non-salary TDS is now section 393 (one table instead of sections 194A..194T), salary TDS is section 392.
-- The quarterly statements are renamed: 26Q -> Form 140 (resident non-salary), 24Q -> Form 138 (salary), 27Q -> Form 144, 27EQ -> Form 143.
-- TDS certificates: Form 16A -> Form 131, Form 16 -> Form 130. Late filing fee: Rs 200 a day, capped at the tax, now section 427 (was 234E).
-- Rates, thresholds and due dates below are working rules built from published guidance. Every one is editable and flagged for your CA to confirm.
--
-- What this adds:
--   * company statutory settings (TAN, PAN, whether goods-purchase TDS 194Q applies, employer registrations)
--   * corrected TDS rules: 194J and 194H thresholds are per financial year (they were applied per bill), 194Q (goods) on the excess over Rs 50 lakh,
--     194A, 194T, the lower no-PAN rate for 194Q, lower-deduction certificates with validity dates, and an audit trail of any rate change
--   * the quarterly statement working papers (Form 140), the deductee certificate data (Form 131), interest on late deposit (1.5% per month or part),
--     the late filing fee, and pre-filing checks that stop a wrong return before it is filed
--   * a statutory calendar for the whole business (TDS, advance tax, GST, and PF/ESI/professional tax/labour welfare once you have employees)
--     with "mark as filed" and a work-queue item when something is due within 5 days or late

-- ---------------------------------------------------------------- settings
create table if not exists statutory_settings (
  id                 int primary key default 1 check (id = 1),
  tan                text check (tan is null or tan ~ '^[A-Z]{4}[0-9]{5}[A-Z]$'),
  pan                text check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  deductor_name      text,
  turnover_over_10cr boolean not null default false,   -- 194Q: only a buyer whose turnover in the previous year was over Rs 10 crore deducts tax on goods
  has_employees      boolean not null default false,   -- switches on the payroll items in the calendar
  pt_frequency       text not null default 'monthly' check (pt_frequency in ('monthly', 'annual')),
  pt_registration    text,
  pf_code            text,
  esic_code          text,
  lwf_registration   text,
  updated_by         uuid,
  updated_at         timestamptz not null default now()
);
insert into statutory_settings (id) values (1) on conflict do nothing;
alter table statutory_settings enable row level security;
drop policy if exists "ss read" on statutory_settings;
create policy "ss read" on statutory_settings for select to authenticated using (has_accounting_view());
grant select on statutory_settings to authenticated;

create or replace function statutory_settings_save(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tan text := nullif(upper(btrim(coalesce(p ->> 'tan', ''))), ''); v_pan text := nullif(upper(btrim(coalesce(p ->> 'pan', ''))), '');
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can change statutory settings'; end if;
  if v_tan is not null and v_tan !~ '^[A-Z]{4}[0-9]{5}[A-Z]$' then raise exception 'TAN must look like SRTA12345B (4 letters, 5 digits, 1 letter)'; end if;
  if v_pan is not null and v_pan !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' then raise exception 'PAN must look like ABCDE1234F'; end if;
  if coalesce(p ->> 'pt_frequency', 'monthly') not in ('monthly', 'annual') then raise exception 'Professional tax frequency must be monthly or annual'; end if;
  update statutory_settings set tan = v_tan, pan = v_pan, deductor_name = nullif(btrim(coalesce(p ->> 'deductor_name', '')), ''),
         turnover_over_10cr = coalesce((p ->> 'turnover_over_10cr')::boolean, false), has_employees = coalesce((p ->> 'has_employees')::boolean, false),
         pt_frequency = coalesce(p ->> 'pt_frequency', 'monthly'), pt_registration = nullif(btrim(coalesce(p ->> 'pt_registration', '')), ''),
         pf_code = nullif(btrim(coalesce(p ->> 'pf_code', '')), ''), esic_code = nullif(btrim(coalesce(p ->> 'esic_code', '')), ''),
         lwf_registration = nullif(btrim(coalesce(p ->> 'lwf_registration', '')), ''), updated_by = auth.uid(), updated_at = now()
   where id = 1;
end $$;

-- ---------------------------------------------------------------- TDS rules
alter table tds_sections add column if not exists no_pan_rate numeric(5,2) not null default 20;
alter table tds_sections add column if not exists on_excess boolean not null default false;     -- tax only on the amount above the annual threshold (194Q)
alter table tds_sections add column if not exists new_act_ref text;
alter table tds_sections add column if not exists payment_code text;                              -- the code the Form 140 utility asks for; enter it from the utility
alter table tds_sections add column if not exists note text;

-- thresholds for fees, commission and rent are totals for the year per payee, not per bill
update tds_sections set annual_threshold = 50000, single_threshold = null where section in ('194J-PRO', '194J-TEC');
update tds_sections set annual_threshold = 20000, single_threshold = null where section = '194H';
insert into tds_sections (section, description, rate, single_threshold, annual_threshold, on_excess, no_pan_rate, note) values
  ('194Q', 'Purchase of goods from a resident seller (only if your turnover last year was over Rs 10 crore)', 0.1, null, 5000000, true, 5,
   'Tax only on the part of the year''s purchases above Rs 50 lakh. Switch on in Statutory settings if your turnover last year was over Rs 10 crore.'),
  ('194A', 'Interest other than on securities (for example on a loan from a person)', 10, null, 10000, false, 20, null),
  ('194T', 'Salary, remuneration, commission, bonus or interest paid to a partner of a firm', 10, null, 20000, false, 20, null)
on conflict (section) do nothing;
update tds_sections set new_act_ref = 'Section 393 (Income-tax Act, 2025)' where new_act_ref is null;
update tds_sections set note = 'Fees for technical services, call centre and royalty on films are 2%. Professional fees are 10%.' where section in ('194J-PRO', '194J-TEC') and note is null;
update tds_sections set note = 'Rate 1% when the payee is an individual or HUF (PAN starts ABCP/ABCH), otherwise 2%.' where section in ('194C-IND', '194C-OTH') and note is null;

create table if not exists tds_section_history (
  history_id  uuid primary key default gen_random_uuid(),
  section     text not null,
  old_values  jsonb,
  new_values  jsonb,
  changed_by  uuid default auth.uid(),
  changed_at  timestamptz not null default now()
);
alter table tds_section_history enable row level security;
drop policy if exists "tsh read" on tds_section_history;
create policy "tsh read" on tds_section_history for select to authenticated using (has_accounting_view());
grant select on tds_section_history to authenticated;

create or replace function tds_section_update(p_section text, p_rate numeric, p_single numeric, p_annual numeric, p_payment_code text, p_active boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o tds_sections%rowtype;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can change TDS rules'; end if;
  select * into o from tds_sections where section = p_section;
  if not found then raise exception 'Unknown TDS section'; end if;
  if p_rate is null or p_rate < 0 or p_rate > 100 then raise exception 'Rate must be between 0 and 100'; end if;
  if (p_single is not null and p_single < 0) or (p_annual is not null and p_annual < 0) then raise exception 'Thresholds cannot be negative'; end if;
  update tds_sections set rate = p_rate, single_threshold = p_single, annual_threshold = p_annual, payment_code = nullif(btrim(coalesce(p_payment_code, '')), ''), active = coalesce(p_active, active)
   where section = p_section;
  insert into tds_section_history (section, old_values, new_values)
  values (p_section, jsonb_build_object('rate', o.rate, 'single', o.single_threshold, 'annual', o.annual_threshold, 'payment_code', o.payment_code, 'active', o.active),
          jsonb_build_object('rate', p_rate, 'single', p_single, 'annual', p_annual, 'payment_code', nullif(btrim(coalesce(p_payment_code, '')), ''), 'active', coalesce(p_active, o.active)));
end $$;

-- lower-deduction certificate (section 197 order): rate plus validity
alter table suppliers add column if not exists ldc_no text;
alter table suppliers add column if not exists ldc_valid_from date;
alter table suppliers add column if not exists ldc_valid_to date;

create or replace function supplier_set_ldc(p_supplier uuid, p_no text, p_rate numeric, p_from date, p_to date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can record a lower-deduction certificate'; end if;
  if p_rate is null then
    update suppliers set tds_rate_override = null, ldc_no = null, ldc_valid_from = null, ldc_valid_to = null where supplier_id = p_supplier;
    return;
  end if;
  if p_rate < 0 or p_rate > 100 then raise exception 'Rate must be between 0 and 100'; end if;
  if nullif(btrim(coalesce(p_no, '')), '') is null then raise exception 'Enter the certificate number'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Enter the certificate''s valid-from and valid-to dates'; end if;
  update suppliers set tds_rate_override = p_rate, ldc_no = btrim(p_no), ldc_valid_from = p_from, ldc_valid_to = p_to where supplier_id = p_supplier;
end $$;

create or replace function pan_holder_type(p text) returns text language sql immutable as $$
  select case substr(coalesce(p, ''), 4, 1)
    when 'P' then 'Individual' when 'H' then 'HUF' when 'C' then 'Company' when 'F' then 'Firm / LLP' when 'A' then 'Association of persons'
    when 'B' then 'Body of individuals' when 'T' then 'Trust' when 'L' then 'Local authority' when 'J' then 'Artificial juridical person' when 'G' then 'Government'
    else null end
$$;

create or replace function pb_tds(p_supplier uuid, p_bill_date date, p_taxable numeric, p_exclude uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype; t tds_sections%rowtype; v_rate numeric; v_prior numeric; v_prior_base numeric; v_cum numeric; v_base numeric := 0; v_fy date; v_open numeric;
        v_ss statutory_settings%rowtype; v_zero jsonb;
begin
  select * into s from suppliers where supplier_id = p_supplier;
  v_zero := jsonb_build_object('section', null, 'base', 0, 'rate', 0, 'amount', 0);
  if s.tds_section is null then return v_zero; end if;
  select * into t from tds_sections where section = s.tds_section;
  if not found or not t.active then return v_zero; end if;
  select * into v_ss from statutory_settings where id = 1;
  if t.section = '194Q' and not coalesce(v_ss.turnover_over_10cr, false) then return v_zero; end if;
  v_rate := t.rate;
  if s.tds_rate_override is not null and (s.ldc_valid_from is null or p_bill_date between s.ldc_valid_from and coalesce(s.ldc_valid_to, p_bill_date)) then
    v_rate := s.tds_rate_override;
  end if;
  if s.pan is null then v_rate := greatest(v_rate, t.no_pan_rate); end if;   -- no PAN: higher rate applies (5% for 194Q, otherwise 20%)
  v_fy := pur_fy_start(p_bill_date);
  select coalesce(sum(taxable_value), 0), coalesce(sum(tds_base), 0), coalesce(sum(taxable_value) filter (where is_opening), 0) into v_prior, v_prior_base, v_open
    from purchase_bills where supplier_id = p_supplier and status = 'approved' and bill_id is distinct from p_exclude
     and bill_date >= v_fy and bill_date < v_fy + interval '1 year';
  v_cum := v_prior + p_taxable;
  if t.on_excess and t.annual_threshold is not null then
    v_base := least(greatest(v_cum - t.annual_threshold, 0) - v_prior_base, p_taxable);
    if v_base < 0 then v_base := 0; end if;
  elsif t.annual_threshold is not null and v_cum >= t.annual_threshold then v_base := v_cum - v_prior_base - v_open;
  elsif t.single_threshold is not null and p_taxable >= t.single_threshold then v_base := p_taxable;
  elsif t.single_threshold is null and t.annual_threshold is null then v_base := p_taxable; end if;
  return jsonb_build_object('section', s.tds_section, 'base', v_base, 'rate', v_rate, 'amount', round(v_base * v_rate / 100, 0));
end $$;

-- ---------------------------------------------------------------- interest, late fee, quarters
-- Interest for late deposit is 1.5% per month or part of a month, from the date tax was deducted to the date it is deposited.
create or replace function tds_interest_months(p_from date, p_to date) returns int language sql immutable as $$
  select case when p_to is null or p_from is null or p_to <= p_from then 0
         else (extract(year from p_to)::int - extract(year from p_from)::int) * 12 + extract(month from p_to)::int - extract(month from p_from)::int
              + case when extract(day from p_to) > extract(day from p_from) then 1 else 0 end end
$$;

create or replace function tds_late_deposit_interest(p_tax numeric, p_deducted_on date, p_deposited_on date, p_due date) returns numeric
language sql immutable as $$
  select case when p_deposited_on is null or p_deposited_on <= p_due then 0
         else round(p_tax * 0.015 * tds_interest_months(p_deducted_on, p_deposited_on), 2) end
$$;

-- late filing fee: Rs 200 for every day of delay, never more than the tax deducted in the statement
create or replace function tds_late_fee(p_tax numeric, p_due date, p_filed_on date default current_date) returns numeric
language sql immutable as $$
  select least(200 * greatest(p_filed_on - p_due, 0), greatest(coalesce(p_tax, 0), 0))
$$;

create or replace function tds_quarter(p_fy int, p_q int) returns table (q_from date, q_to date, return_due date, cert_due date)
language sql immutable as $$
  select case p_q when 1 then make_date(p_fy, 4, 1) when 2 then make_date(p_fy, 7, 1) when 3 then make_date(p_fy, 10, 1) else make_date(p_fy + 1, 1, 1) end,
         case p_q when 1 then make_date(p_fy, 6, 30) when 2 then make_date(p_fy, 9, 30) when 3 then make_date(p_fy, 12, 31) else make_date(p_fy + 1, 3, 31) end,
         case p_q when 1 then make_date(p_fy, 7, 31) when 2 then make_date(p_fy, 10, 31) when 3 then make_date(p_fy + 1, 1, 31) else make_date(p_fy + 1, 5, 31) end,
         case p_q when 1 then make_date(p_fy, 8, 15) when 2 then make_date(p_fy, 11, 15) when 3 then make_date(p_fy + 1, 2, 15) else make_date(p_fy + 1, 6, 15) end
$$;

-- ---------------------------------------------------------------- filings record
create table if not exists compliance_filings (
  filing_key text primary key,
  kind       text not null,
  period     text,
  filed_on   date not null,
  ack_no     text,
  note       text,
  filed_by   uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table compliance_filings enable row level security;
drop policy if exists "cf read" on compliance_filings;
create policy "cf read" on compliance_filings for select to authenticated using (has_accounting_view());
grant select on compliance_filings to authenticated;

create or replace function compliance_mark_filed(p_key text, p_kind text, p_period text, p_filed_on date, p_ack text, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can record a filing'; end if;
  if nullif(btrim(coalesce(p_key, '')), '') is null then raise exception 'Missing filing reference'; end if;
  if p_filed_on is null or p_filed_on > current_date then raise exception 'The filing date cannot be empty or in the future'; end if;
  insert into compliance_filings (filing_key, kind, period, filed_on, ack_no, note)
  values (p_key, coalesce(p_kind, 'OTHER'), p_period, p_filed_on, nullif(btrim(coalesce(p_ack, '')), ''), nullif(btrim(coalesce(p_note, '')), ''))
  on conflict (filing_key) do update set filed_on = excluded.filed_on, ack_no = excluded.ack_no, note = excluded.note, filed_by = auth.uid();
end $$;

create or replace function compliance_unmark(p_key text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can undo a filing record'; end if;
  delete from compliance_filings where filing_key = p_key;
end $$;

-- ---------------------------------------------------------------- Form 140 working papers
create or replace function tds_statement_rows(p_fy int, p_q int) returns table (
  bill_no text, deducted_on date, deductee text, pan text, holder_type text, section text, payment_code text, amount_credited numeric, amount_deducted_on numeric,
  rate numeric, tds numeric, challan_cin text, deposited_on date, due_date date, interest_due numeric, remark text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare qb record;
begin
  if not has_accounting_view() then return; end if;
  select * into qb from tds_quarter(p_fy, p_q);
  return query
  select b.bill_no, b.bill_date, s.name, s.pan, pan_holder_type(s.pan), b.tds_section, t.payment_code, b.taxable_value, b.tds_base, b.tds_rate, b.tds_amount,
         c.cin, c.dep_on, tds_due_date(to_char(b.bill_date, 'YYYY-MM')),
         case when tds_due_date(to_char(b.bill_date, 'YYYY-MM')) < coalesce(c.dep_on, current_date)
              then tds_late_deposit_interest(b.tds_amount, b.bill_date, coalesce(c.dep_on, current_date), tds_due_date(to_char(b.bill_date, 'YYYY-MM'))) else 0 end,
         case when s.pan is null then 'No PAN: deducted at the higher rate' when c.cin is null then 'Challan not recorded' else null end
    from purchase_bills b
    join suppliers s on s.supplier_id = b.supplier_id
    left join tds_sections t on t.section = b.tds_section
    left join lateral (
      select string_agg(k.bsr_code || '/' || k.challan_serial || '/' || to_char(k.deposit_date, 'DD-MM-YYYY'), '; ' order by k.deposit_date) as cin, max(k.deposit_date) as dep_on
        from tds_challans k where k.status = 'approved' and k.period = to_char(b.bill_date, 'YYYY-MM') and k.section = b.tds_section) c on true
   where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between qb.q_from and qb.q_to
   order by b.bill_date, b.bill_no;
end $$;

-- ---------------------------------------------------------------- Form 131 data
create or replace function tds_certificate_rows(p_fy int, p_q int) returns table (
  deductee text, pan text, section text, amount_credited numeric, tds numeric, challans text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare qb record;
begin
  if not has_accounting_view() then return; end if;
  select * into qb from tds_quarter(p_fy, p_q);
  return query
  select s.name, s.pan, b.tds_section, sum(b.taxable_value), sum(b.tds_amount),
         (select string_agg(distinct k.bsr_code || '/' || k.challan_serial || '/' || to_char(k.deposit_date, 'DD-MM-YYYY'), '; ')
            from tds_challans k where k.status = 'approved' and k.section = b.tds_section and k.period in (select to_char(x.bill_date, 'YYYY-MM') from purchase_bills x
                  where x.supplier_id = s.supplier_id and x.status = 'approved' and x.tds_amount > 0 and x.tds_section = b.tds_section and x.bill_date between qb.q_from and qb.q_to))
    from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
   where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between qb.q_from and qb.q_to
   group by s.supplier_id, s.name, s.pan, b.tds_section
   order by s.name, b.tds_section;
end $$;

-- ---------------------------------------------------------------- quarter summary and pre-filing checks
create or replace function tds_quarter_summary(p_fy int, p_q int) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare qb record; v_ded numeric; v_n int; v_paid numeric; v_int numeric; v_filed compliance_filings%rowtype; v_key text := 'TDS-140:' || p_fy || '-Q' || p_q; v_fee numeric;
begin
  if not has_accounting_view() then raise exception 'Not authorized'; end if;
  select * into qb from tds_quarter(p_fy, p_q);
  select coalesce(sum(tds_amount), 0), count(*) into v_ded, v_n from purchase_bills where status = 'approved' and tds_amount > 0 and bill_date between qb.q_from and qb.q_to;
  select coalesce(sum(tax), 0) into v_paid from tds_challans where status = 'approved' and period between to_char(qb.q_from, 'YYYY-MM') and to_char(qb.q_to, 'YYYY-MM');
  select coalesce(sum(interest_due), 0) into v_int from tds_statement_rows(p_fy, p_q);
  select * into v_filed from compliance_filings where filing_key = v_key;
  v_fee := tds_late_fee(v_ded, qb.return_due, coalesce(v_filed.filed_on, current_date));
  return jsonb_build_object('from', qb.q_from, 'to', qb.q_to, 'return_due', qb.return_due, 'cert_due', qb.cert_due, 'deducted', v_ded, 'deductions', v_n, 'deposited', v_paid,
    'interest_due', v_int, 'filed', v_filed.filing_key is not null, 'filed_on', v_filed.filed_on, 'ack_no', v_filed.ack_no,
    'late_fee', case when v_n = 0 then 0 else v_fee end, 'filing_key', v_key);
end $$;

create or replace function tds_statement_validate(p_fy int, p_q int) returns table (severity text, code text, message text, n int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare qb record; v_tan text; v_cnt int; v_filed boolean; v_ded numeric; v_any boolean := false;
begin
  if not has_accounting_view() then return; end if;
  select * into qb from tds_quarter(p_fy, p_q);
  select tan into v_tan from statutory_settings where id = 1;
  select coalesce(sum(tds_amount), 0), count(*) into v_ded, v_cnt from purchase_bills where status = 'approved' and tds_amount > 0 and bill_date between qb.q_from and qb.q_to;
  if v_cnt = 0 then
    return query select 'ok'::text, 'none'::text, 'No tax was deducted in this quarter, so there is nothing to file.'::text, 0;
    return;
  end if;
  if v_tan is null then v_any := true; return query select 'error', 'tan', 'Your TAN is not set. The statement cannot be prepared without it. Add it in Statutory settings.', 1; end if;

  select count(*) into v_cnt from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
   where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between qb.q_from and qb.q_to and s.pan is null;
  if v_cnt > 0 then v_any := true; return query select 'warning', 'no_pan', 'Tax was deducted at the higher rate because the deductee has no PAN. Get the PAN and update the supplier; a wrong or missing PAN cuts the deductee''s credit.', v_cnt; end if;

  select count(*) into v_cnt from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
   where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between qb.q_from and qb.q_to and b.tds_section = '194C-IND' and s.pan is not null and substr(s.pan, 4, 1) not in ('P', 'H');
  if v_cnt > 0 then v_any := true; return query select 'error', 'rate_short', 'Contractor tax was deducted at 1% but the PAN shows the payee is not an individual or HUF. The rate should be 2%. Short deduction brings interest and a demand.', v_cnt; end if;

  select count(*) into v_cnt from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
   where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between qb.q_from and qb.q_to and b.tds_section = '194C-OTH' and s.pan is not null and substr(s.pan, 4, 1) in ('P', 'H');
  if v_cnt > 0 then v_any := true; return query select 'warning', 'rate_excess', 'Contractor tax was deducted at 2% but the PAN shows an individual or HUF, where 1% applies. Check the supplier''s section.', v_cnt; end if;

  select count(*) into v_cnt from (
    select d.per, d.sec from (select to_char(b.bill_date, 'YYYY-MM') per, b.tds_section sec, sum(b.tds_amount) ded from purchase_bills b
                               where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between qb.q_from and qb.q_to group by 1, 2) d
    left join (select period per, section sec, sum(tax) pd from tds_challans where status = 'approved' group by 1, 2) c on c.per = d.per and c.sec = d.sec
    where coalesce(c.pd, 0) < d.ded) q;
  if v_cnt > 0 then v_any := true; return query select 'error', 'unpaid', 'Tax was deducted but not fully deposited (or the challan is not approved yet) for this many month and section combinations. Deposit it and record the challan before filing.', v_cnt; end if;

  select count(*) into v_cnt from tds_statement_rows(p_fy, p_q) r where r.interest_due > 0;
  if v_cnt > 0 then v_any := true; return query select 'warning', 'late_deposit', 'Some tax was deposited after the 7th of the next month. Interest at 1.5% per month or part is due. Pay it with the next challan.', v_cnt; end if;

  select count(*) into v_cnt from purchase_bills b where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between qb.q_from and qb.q_to and not exists (select 1 from tds_sections t where t.section = b.tds_section and t.payment_code is not null);
  if v_cnt > 0 then v_any := true; return query select 'info', 'payment_code', 'The new Form 140 asks for a payment code against each deduction. Enter the code for each section in TDS rules (take it from the utility).', v_cnt; end if;

  select count(*) into v_cnt from (
    select b.supplier_id from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
     where b.status = 'approved' and s.tds_section is null and not b.is_opening and b.bill_date between pur_fy_start(qb.q_from) and qb.q_to
     group by b.supplier_id having sum(b.taxable_value) >= 100000) m;
  if v_cnt > 0 then v_any := true; return query select 'info', 'no_section', 'Suppliers with no TDS section have bought over Rs 1,00,000 this year. Confirm each supplies goods only (no tax) and not services, rent, commission or contract work.', v_cnt; end if;

  select exists (select 1 from compliance_filings where filing_key = 'TDS-140:' || p_fy || '-Q' || p_q) into v_filed;
  if not v_filed and qb.return_due < current_date then
    v_any := true;
    return query select 'error', 'late_filing', 'The due date of ' || to_char(qb.return_due, 'DD Mon YYYY') || ' has passed. A fee of Rs 200 a day (up to Rs ' || v_ded || ') is running. File now.', (current_date - qb.return_due);
  end if;
  if not v_any then return query select 'ok', 'clear', 'All checks passed. The statement is ready to prepare.', 0; end if;
end $$;

-- ---------------------------------------------------------------- statutory calendar
-- Every date below is a working rule from published guidance; confirm with your CA. Items are generated from the rules, so nothing needs to be typed in.
create or replace function compliance_calendar(p_from date, p_to date) returns table (
  item_key text, kind text, title text, period text, due_date date, authority text, form text, note text,
  filed boolean, filed_on date, ack_no text, status text, days_left int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_emp boolean; v_ptf text;
begin
  if not has_accounting_view() then return; end if;
  select has_employees, pt_frequency into v_emp, v_ptf from statutory_settings where id = 1;
  return query
  with m as (select d::date as m_start from generate_series(date_trunc('month', p_from - interval '3 months'), date_trunc('month', p_to), interval '1 month') d),
  fy as (select y from generate_series(extract(year from p_from)::int - 1, extract(year from p_to)::int) y),
  q as (select fy.y as fy, n as qn, qq.q_from, qq.q_to, qq.return_due, qq.cert_due from fy cross join generate_series(1, 4) n cross join lateral tds_quarter(fy.y, n) qq),
  x as (
    -- TDS deposit, one per deduction month that actually had deductions
    select 'TDS-DEP:' || to_char(m.m_start, 'YYYY-MM') as item_key, 'TDS'::text as kind, 'TDS deposit for ' || to_char(m.m_start, 'Mon YYYY') as title, to_char(m.m_start, 'YYYY-MM') as period,
           tds_due_date(to_char(m.m_start, 'YYYY-MM')) as due_date, 'Income Tax Department (challan at your bank)'::text as authority, null::text as form,
           'Due on the 7th of the next month; 30 April for March.'::text as note,
           (coalesce((select sum(tds_amount) from purchase_bills where status = 'approved' and bill_date >= m.m_start and bill_date < m.m_start + interval '1 month'), 0)
            <= coalesce((select sum(tax) from tds_challans where status = 'approved' and period = to_char(m.m_start, 'YYYY-MM')), 0)) as auto_filed
      from m where exists (select 1 from purchase_bills where status = 'approved' and tds_amount > 0 and bill_date >= m.m_start and bill_date < m.m_start + interval '1 month')
    union all
    select 'TDS-140:' || q.fy || '-Q' || q.qn, 'TDS', 'TDS statement (Form 140) for ' || q.fy || '-' || right((q.fy + 1)::text, 2) || ' Q' || q.qn, q.fy || '-Q' || q.qn, q.return_due,
           'Income Tax Department (TRACES / e-filing)', 'Form 140 (was 26Q)', 'Late fee Rs 200 a day, up to the tax deducted.', null::boolean
      from q where exists (select 1 from purchase_bills where status = 'approved' and tds_amount > 0 and bill_date between q.q_from and q.q_to)
    union all
    select 'TDS-131:' || q.fy || '-Q' || q.qn, 'TDS', 'TDS certificates (Form 131) for ' || q.fy || '-' || right((q.fy + 1)::text, 2) || ' Q' || q.qn, q.fy || '-Q' || q.qn, q.cert_due,
           'Give to each supplier', 'Form 131 (was 16A)', 'Due 15 days after the statement due date.', null::boolean
      from q where exists (select 1 from purchase_bills where status = 'approved' and tds_amount > 0 and bill_date between q.q_from and q.q_to)
    union all
    select 'GSTR1:' || to_char(m.m_start, 'YYYY-MM'), 'GST', 'GSTR-1 for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '10 days')::date,
           'GST portal', 'GSTR-1', 'Monthly filer. A quarterly (QRMP) filer follows a different date.', gst_period_filed(to_char(m.m_start, 'YYYY-MM'), 'GSTR1')
      from m
    union all
    select 'GSTR3B:' || to_char(m.m_start, 'YYYY-MM'), 'GST', 'GSTR-3B for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '19 days')::date,
           'GST portal', 'GSTR-3B', 'Monthly filer. A quarterly (QRMP) filer follows a different date.', gst_period_filed(to_char(m.m_start, 'YYYY-MM'), 'GSTR3B')
      from m
    union all
    -- advance tax: 15 June, 15 September, 15 December, 15 March
    select 'ADVTAX:' || fy.y || '-' || a.n, 'Income tax', 'Advance tax instalment (' || a.pct || ') for ' || fy.y || '-' || right((fy.y + 1)::text, 2),
           fy.y || '-' || a.n, make_date(fy.y + a.yoff, a.mon, 15), 'Income Tax Department (challan at your bank)', null,
           'Cumulative: 15% by 15 June, 45% by 15 September, 75% by 15 December, 100% by 15 March. Needed only if the year''s tax will exceed Rs 10,000.', null::boolean
      from fy cross join (values (1, 6, 0, '15%'), (2, 9, 0, '45%'), (3, 12, 0, '75%'), (4, 3, 1, '100%')) as a(n, mon, yoff, pct)
    union all
    select 'PF:' || to_char(m.m_start, 'YYYY-MM'), 'Payroll', 'Provident fund (PF) for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '14 days')::date,
           'EPFO', 'ECR and challan', 'Due on the 15th of the next month.', null::boolean from m where v_emp
    union all
    select 'ESI:' || to_char(m.m_start, 'YYYY-MM'), 'Payroll', 'Employees'' State Insurance (ESI) for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '14 days')::date,
           'ESIC', 'Monthly contribution', 'Due on the 15th of the next month.', null::boolean from m where v_emp
    union all
    select 'PT:' || to_char(m.m_start, 'YYYY-MM'), 'Payroll', 'Gujarat professional tax for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '14 days')::date,
           'Gujarat Commercial Tax Department', 'Form 5 (monthly)', 'Working rule: 15th of the next month. Confirm your due date on your certificate.', null::boolean from m where v_emp and v_ptf = 'monthly'
    union all
    select 'LWF:' || fy.y || '-' || h.n, 'Payroll', 'Gujarat labour welfare fund, ' || h.label || ' ' || (fy.y + h.yoff), fy.y || '-' || h.n, make_date(fy.y + h.yoff + h.dyoff, h.dmon, 15),
           'Gujarat Labour Welfare Board', 'Half-yearly return', 'Contribution is deducted in June and December. Working rule: pay by 15 July and 15 January.', null::boolean
      from fy cross join (values (1, 'January to June', 0, 0, 7), (2, 'July to December', 0, 1, 1)) as h(n, label, yoff, dyoff, dmon) where v_emp
    union all
    select 'TDS-138:' || q.fy || '-Q' || q.qn, 'Payroll', 'Salary TDS statement (Form 138) for ' || q.fy || '-' || right((q.fy + 1)::text, 2) || ' Q' || q.qn, q.fy || '-Q' || q.qn, q.return_due,
           'Income Tax Department (TRACES / e-filing)', 'Form 138 (was 24Q)', 'Late fee Rs 200 a day, up to the tax deducted.', null::boolean from q where v_emp
    union all
    select 'TDS-130:' || fy.y, 'Payroll', 'Salary TDS certificates (Form 130) for ' || fy.y || '-' || right((fy.y + 1)::text, 2), fy.y::text, make_date(fy.y + 1, 6, 15),
           'Give to each employee', 'Form 130 (was Form 16)', 'Due by 15 June after the year ends.', null::boolean from fy where v_emp
  )
  select x.item_key, x.kind, x.title, x.period, x.due_date::date, x.authority, x.form, x.note,
         coalesce(x.auto_filed, f.filing_key is not null) as filed, f.filed_on, f.ack_no,
         case when coalesce(x.auto_filed, f.filing_key is not null) then 'filed' when x.due_date < current_date then 'overdue' when x.due_date <= current_date + 7 then 'due_soon' else 'upcoming' end,
         (x.due_date::date - current_date)
    from x left join compliance_filings f on f.filing_key = x.item_key
   where x.due_date between p_from and p_to
   order by x.due_date, x.title;
end $$;

-- ---------------------------------------------------------------- work queue: statutory filings due within 5 days or late
create or replace view work_queue with (security_invoker = true) as
-- failed automatic steps (stock-out, invoice, cancelled after dispatch)
select 'issue:' || i.issue_id as item_key, 'Automation' as category, case when i.kind = 'cancelled_after_dispatch' then 'medium' else 'high' end as severity,
       case i.kind when 'dispatch_failed' then 'Stock could not be taken out' when 'invoice_failed' then 'Invoice could not be posted' when 'cancelled_after_dispatch' then 'Cancelled after dispatch' else i.kind end as title,
       i.message as detail, '/orders/' || i.entity_id as href, array['Operations Manager', 'Accountant']::text[] as for_roles,
       i.kind as action_kind, i.issue_id as action_id, 1 as n, i.created_at as since
from automation_issues i where i.status = 'open'
union all
select 'rule-errors', 'Accounting', 'high', 'Entries that did not post automatically', count(*) || ' event(s) failed to create their journal entry in the last 30 days. Open the rule activity to see why.',
       '/accounting/rule-book/activity', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from journal_rule_log where status = 'error' and created_at > now() - interval '30 days' having count(*) > 0
union all
select 'bank-unreconciled', 'Bank', case when min(txn_date) < current_date - 7 then 'high' else 'medium' end, 'Bank lines not reconciled', count(*) || ' bank line(s) are waiting to be matched. Oldest: ' || min(txn_date) || '.',
       '/bank/reconcile', array['Accountant']::text[], null, null, count(*)::int, min(txn_date)::timestamptz
from bank_transactions where recon_status in ('unreconciled', 'suggested') and txn_date < current_date - 1 having count(*) > 0
union all
select 'bills-pending', 'Purchases', 'medium', 'Supplier bills waiting for approval', count(*) || ' bill(s) pending. Oldest raised ' || min(created_at)::date || '.',
       '/purchases/bills', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from purchase_bills where status = 'pending' having count(*) > 0 and has_purchase_approve()
union all
select 'bills-overdue', 'Purchases', 'high', 'Supplier bills past their due date', count(*) || ' approved bill(s) are overdue. Oldest due ' || min(due_date) || '.',
       '/purchases/ageing', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(due_date)::timestamptz
from purchase_bills where status = 'approved' and due_date < current_date and net_payable > 0
  and net_payable > coalesce((select sum(a.amount) from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id where a.bill_id = purchase_bills.bill_id and p.status = 'approved'), 0)
having count(*) > 0 and has_accounting_write()
union all
select 'claims-expense', 'Expenses', 'medium', 'Expense claims waiting for a decision', count(*) || ' claim(s) are waiting. Oldest submitted ' || min(submitted_at)::date || '.',
       '/expenses', array['Operations Manager', 'Finance Manager']::text[], null, null, count(*)::int, min(submitted_at)
from expense_claims where status in ('submitted', 'manager_approved') having count(*) > 0 and (has_expense_review() or has_accounting_write())
union all
select 'returns-inspect', 'Returns', case when min(received_date) < current_date - 4 then 'high' else 'medium' end, 'Returns received but not inspected', count(*) || ' return(s) are sitting in the warehouse. Oldest received ' || min(received_date) || '.',
       '/returns', array['Warehouse Manager']::text[], null, null, count(*)::int, min(received_date)::timestamptz
from returns where status = 'received' and has_returns_view() having count(*) > 0
union all
select 'rto-inspect', 'RTO', case when min(received_date) < current_date - 4 then 'high' else 'medium' end, 'RTO parcels received but not inspected', count(*) || ' RTO parcel(s) are waiting. Oldest received ' || min(received_date) || '.',
       '/rto', array['Warehouse Manager']::text[], null, null, count(*)::int, min(received_date)::timestamptz
from rtos where status = 'received' and has_returns_view() having count(*) > 0
union all
select 'settlements-late', 'Settlements', 'high', 'Settlements not received or reconciled', count(*) || ' settlement(s) are still pending a week after their period ended.',
       '/settlements', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, min(period_end)::timestamptz
from settlements where status = 'pending' and period_end < current_date - 7 and has_settlements_view() having count(*) > 0
union all
select 'settlements-short', 'Settlements', 'high', 'Settlements paid short or in excess', count(*) || ' settlement(s) did not match what was expected.',
       '/settlements', array['Finance Manager', 'Claims Manager']::text[], null, null, count(*)::int, min(created_at)
from settlements where status in ('short_pay', 'excess') and has_settlements_view() having count(*) > 0
union all
select 'cod-late', 'COD', 'high', 'COD cash not remitted by the courier', count(*) || ' COD collection(s) are over 7 days without a remittance.',
       '/cod', array['Accountant']::text[], null, null, count(*)::int, min(collected_date)::timestamptz
from cod_collections where status in ('collected', 'short_remit') and collected_date < current_date - 7 and has_bankcod_view() having count(*) > 0
union all
select 'claims-deadline', 'Claims', case when min(deadline) < current_date then 'high' else 'medium' end, 'Claims close to their deadline', count(*) || ' claim(s) are due within 7 days or already past the deadline.',
       '/claims', array['Claims Manager']::text[], null, null, count(*)::int, min(deadline)::timestamptz
from claims where status in ('potential', 'claimed') and deadline is not null and deadline <= current_date + 7 and has_claims_view() having count(*) > 0
union all
select 'period-close', 'Accounting', 'medium', 'Accounting periods ready to close', count(*) || ' period(s) ended more than 5 days ago and are still open (' || string_agg(period_name, ', ' order by start_date) || ').',
       '/accounting/periods', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(end_date)::timestamptz
from accounting_periods where status = 'open' and end_date < current_date - 5 having count(*) > 0 and has_accounting_view()
union all
select 'recurring-error', 'Accounting', 'high', 'Recurring entries that could not post', count(*) || ' recurring journal(s) are waiting because of an error (for example a closed period).',
       '/accounting/journal', array['Accountant']::text[], null, null, count(*)::int, min(next_run_date)::timestamptz
from recurring_journals where status = 'active' and last_error is not null having count(*) > 0 and has_accounting_view()
union all
select 'gstr1-due', 'GST', case when extract(day from current_date) > 11 then 'high' else 'medium' end, 'GSTR-1 not recorded as filed', 'GSTR-1 for ' || to_char(date_trunc('month', current_date) - interval '1 month', 'Mon YYYY') || ' has no filing record yet (due about the 11th; confirm with your CA).',
       '/gst/gstr1', array['Tax Manager', 'Accountant']::text[], null, null, 1, date_trunc('month', current_date)
where extract(day from current_date) >= 5 and has_gst_view()
  and not gst_period_filed(to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM'), 'GSTR1')
union all
select 'gstr3b-due', 'GST', case when extract(day from current_date) > 20 then 'high' else 'medium' end, 'GSTR-3B not recorded as filed', 'GSTR-3B for ' || to_char(date_trunc('month', current_date) - interval '1 month', 'Mon YYYY') || ' has no filing record yet (due about the 20th; confirm with your CA).',
       '/gst', array['Tax Manager', 'Accountant']::text[], null, null, 1, date_trunc('month', current_date)
where extract(day from current_date) >= 12 and has_gst_view()
  and not gst_period_filed(to_char(date_trunc('month', current_date) - interval '1 month', 'YYYY-MM'), 'GSTR3B')
union all
select 'stock-timeout', 'Inventory', 'medium', 'SKUs past their stock time-out', count(*) || ' SKU(s) have stock older than their time-out.',
       '/insights', array['Operations Manager']::text[], null, null, count(*)::int, now()
from sku_stock_aging where timeout_state = 'overdue' having count(*) > 0
union all
select 'job-failed:' || j.job_key, 'System', 'high', 'Scheduled job failed: ' || j.label, coalesce(j.last_message, 'The last run failed.'),
       '/admin/automation', array['Super Admin']::text[], null, null, 1, j.last_run_at
from scheduled_jobs j where j.enabled and j.last_status = 'error'
union all
select 'po-pending', 'Purchases', 'medium', 'Purchase orders waiting for approval', count(*) || ' purchase order(s) need approval.',
       '/purchases/orders', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from purchase_orders where status = 'pending' having count(*) > 0 and has_purchase_approve()
union all
select 'po-late', 'Purchases', 'medium', 'Purchase orders past their expected date', count(*) || ' order(s) not fully received. Oldest was due ' || min(expected_date) || '.',
       '/purchases/orders', array['Operations Manager', 'Warehouse Manager']::text[], null, null, count(*)::int, min(expected_date)::timestamptz
from purchase_orders where status in ('approved', 'part_received') and expected_date < current_date
having count(*) > 0 and (has_po_write() or has_grn_write())
union all
select 'grn-unbilled', 'Purchases', 'medium', 'Goods received but no supplier bill entered', count(*) || ' receipt(s) have no bill yet. Oldest ' || min(received_on) || '.',
       '/purchases/orders', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(received_on)::timestamptz
from po_unbilled where unbilled_qty > 0 having count(*) > 0 and has_accounting_write()
union all
select 'reorder-low', 'Inventory', 'medium', 'Products below their reorder level', count(*) || ' product(s) need re-ordering.',
       '/purchases/reorder', array['Operations Manager']::text[], null, null, count(*)::int, now()
from reorder_suggestions where needs_reorder having count(*) > 0 and has_po_write()
union all
select 'fee-overcharged', 'Settlements', 'high', 'Marketplace fees higher than the agreed rate',
       count(*) || ' fee line(s) are above the agreed rate, about Rs ' || round(sum(variance), 2) || ' in total. Raise a claim with the marketplace.',
       '/settlements/fees', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, min(created_at)
from settlement_fee_check where flagged and variance > 0 and not coalesce(dismissed, false) having count(*) > 0 and has_settlements_view() and has_accounting_view()
union all
select 'settle-match-ready', 'Settlements', 'medium', 'Settlements with an exact bank match waiting',
       count(*) || ' settlement(s) have one bank credit for exactly the expected amount. One click reconciles them.',
       '/settlements', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, now()
from settlement_bank_matches having count(*) > 0 and has_settlements_reconcile()
union all
select 'anom-' || kind, 'Check these', 'medium', title, detail, '/work-queue/anomalies', array['Operations Manager', 'Finance Manager']::text[], null, null, n, since
from anomalies where has_orders_write() or has_accounting_view()
union all
select 'payrun-open', 'Purchases', 'medium', 'Payment runs sent to the bank, UTRs not entered',
       count(*) || ' payment run(s) were exported to the bank. Enter the UTRs once the bank has paid.',
       '/purchases/payment-runs', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(exported_at)
from payment_runs where status = 'exported' having count(*) > 0 and has_accounting_write()
union all
select 'payrun-approve', 'Purchases', 'high', 'Supplier payments waiting for approval from a payment run',
       count(distinct r.run_id) || ' run(s) have payments waiting for your approval.',
       '/purchases/payment-runs', array['Finance Manager']::text[], null, null, count(distinct r.run_id)::int, min(r.completed_at)
from payment_runs r join payment_run_items i on i.run_id = r.run_id join supplier_payments p on p.payment_id = i.payment_id
where r.status = 'completed' and p.status = 'pending' having count(*) > 0 and has_purchase_approve()
union all
select 'depr-due', 'Accounting', 'medium', 'Depreciation not posted for last month',
       count(*) || ' asset(s) have no depreciation for ' || to_char(date_trunc('month', current_date) - interval '1 month', 'Mon YYYY') || '. It is posted on the 2nd of each month, or post it now.',
       '/accounting/assets', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, now()
from asset_register a where a.status = 'active' and a.depreciable_left > 0 and a.dep_from <= (date_trunc('month', current_date) - interval '1 month')::date
  and a.put_to_use_date < date_trunc('month', current_date)
  and not exists (select 1 from asset_depreciation d where d.asset_id = a.asset_id and d.month = (date_trunc('month', current_date) - interval '1 month')::date)
having count(*) > 0 and has_accounting_write()
union all
select 'stat-due', 'Compliance', case when min(c.due_date) < current_date then 'high' else 'medium' end, 'Statutory filings due or overdue',
       count(*) || ' filing(s) are due within 5 days or already late. Next: ' || (array_agg(c.title order by c.due_date))[1] || '.',
       '/accounting/statutory', array['Accountant', 'Finance Manager', 'Tax Manager']::text[], null, null, count(*)::int, min(c.due_date)::timestamptz
from compliance_calendar(current_date - 90, current_date + 5) c where not c.filed and c.kind <> 'GST'
having count(*) > 0 and has_accounting_view();

-- ---------------------------------------------------------------- permissions
revoke execute on function statutory_settings_save(jsonb), tds_section_update(text, numeric, numeric, numeric, text, boolean), supplier_set_ldc(uuid, text, numeric, date, date),
  compliance_mark_filed(text, text, text, date, text, text), compliance_unmark(text), tds_statement_rows(int, int), tds_certificate_rows(int, int), tds_quarter_summary(int, int),
  tds_statement_validate(int, int), compliance_calendar(date, date), pb_tds(uuid, date, numeric, uuid), pan_holder_type(text), tds_interest_months(date, date),
  tds_late_deposit_interest(numeric, date, date, date), tds_late_fee(numeric, date, date), tds_quarter(int, int) from public, anon, authenticated;
grant execute on function statutory_settings_save(jsonb), tds_section_update(text, numeric, numeric, numeric, text, boolean), supplier_set_ldc(uuid, text, numeric, date, date),
  compliance_mark_filed(text, text, text, date, text, text), compliance_unmark(text), tds_statement_rows(int, int), tds_certificate_rows(int, int), tds_quarter_summary(int, int),
  tds_statement_validate(int, int), compliance_calendar(date, date), pb_tds(uuid, date, numeric, uuid), pan_holder_type(text), tds_interest_months(date, date),
  tds_late_deposit_interest(numeric, date, date, date), tds_late_fee(numeric, date, date), tds_quarter(int, int) to authenticated;
