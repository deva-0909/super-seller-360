-- 0061: GST return workings (GSTR-1 and GSTR-3B) built from invoices, credit notes and purchase bills.
--
-- What this adds
--   * orders.customer_gstin (B2B sales) and orders.ship_to_state_code (place of supply as a 2-digit state code, worked out from the free-text state).
--   * credit_notes.note_number (a series), reason; numbers are given when a credit note is posted.
--   * channels.eco_gstin (the marketplace's GSTIN) so supplies through e-commerce operators can be shown separately.
--   * gst_settings (B2C-large limit), gst_itc_adjustments (ITC from GSTR-2B for marketplace and other invoices, and ITC reversals).
--   * Report functions: gstr1_* and gstr3b_* . They read from the invoices themselves, not from ledger balances.
--
-- Rates, limits and the sections a supply belongs to are WORKING FIGURES for your CA to confirm before anything is filed.

-- ---------------------------------------------------------------- 1. state names to codes
create table if not exists gst_state_aliases (alias text primary key, code text not null references gst_states(code));
insert into gst_state_aliases (alias, code) values
  ('new delhi', '07'), ('nct of delhi', '07'), ('delhi ncr', '07'), ('orissa', '21'), ('pondicherry', '34'), ('chattisgarh', '22'), ('uttaranchal', '05'),
  ('jammu & kashmir', '01'), ('jammu and kashmir', '01'), ('j&k', '01'), ('andaman & nicobar islands', '35'), ('andaman and nicobar', '35'),
  ('dadra and nagar haveli', '26'), ('daman and diu', '26'), ('dadra & nagar haveli and daman & diu', '26'), ('telengana', '36'), ('tamilnadu', '33'),
  ('west bangal', '19'), ('bengal', '19'), ('mumbai', '27'), ('bangalore', '29'), ('bengaluru', '29')
on conflict (alias) do nothing;
alter table gst_state_aliases enable row level security;
drop policy if exists "gsa read" on gst_state_aliases; create policy "gsa read" on gst_state_aliases for select to authenticated using (true);
grant select on gst_state_aliases to authenticated;

create or replace function gst_state_code(p text) returns text
language sql stable set search_path = public, pg_temp as $$
  with s as (select lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')) as k)
  select coalesce(
    (select code from gst_states, s where lower(name) = s.k),
    (select code from gst_state_aliases, s where alias = s.k),
    (select code from gst_states, s where s.k ~ '^[0-9]{2}$' and code = s.k),
    (select code from gst_states, s where s.k ~ '^[0-9]{2}[ -]' and code = left(s.k, 2))
  )
$$;

-- ---------------------------------------------------------------- 2. columns
alter table orders add column if not exists customer_gstin text;
alter table orders add column if not exists ship_to_state_code text references gst_states(code);
alter table orders drop constraint if exists orders_customer_gstin_valid;
alter table orders add constraint orders_customer_gstin_valid check (customer_gstin is null or gstin_valid(customer_gstin));

create or replace function trg_orders_state_code() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' or new.ship_to_state is distinct from old.ship_to_state or new.ship_to_state_code is null then
    new.ship_to_state_code := gst_state_code(new.ship_to_state);
  end if;
  if new.customer_gstin is not null then new.customer_gstin := upper(btrim(new.customer_gstin)); end if;
  return new;
end $$;
drop trigger if exists trg_orders_state_code on orders;
create trigger trg_orders_state_code before insert or update on orders for each row execute function trg_orders_state_code();
update orders set ship_to_state_code = gst_state_code(ship_to_state) where ship_to_state_code is null and ship_to_state is not null;

alter table channels add column if not exists eco_gstin text;
alter table channels drop constraint if exists channels_eco_gstin_valid;
alter table channels add constraint channels_eco_gstin_valid check (eco_gstin is null or gstin_valid(eco_gstin));

alter table credit_notes add column if not exists note_number text;
alter table credit_notes add column if not exists reason text not null default 'sales_return';
alter table credit_notes drop constraint if exists credit_notes_reason_check;
alter table credit_notes add constraint credit_notes_reason_check check (reason in ('sales_return', 'post_sale_discount', 'deficiency', 'correction', 'other'));
create unique index if not exists credit_notes_number_uq on credit_notes (note_number) where note_number is not null;
create sequence if not exists credit_note_seq;

create or replace function trg_credit_note_number() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.status = 'posted' and new.note_number is null then
    new.note_number := 'CN-' || to_char(new.date, 'YYMM') || '-' || lpad(nextval('credit_note_seq')::text, 6, '0');
  end if;
  return new;
end $$;
drop trigger if exists trg_credit_note_number on credit_notes;
create trigger trg_credit_note_number before insert or update of status on credit_notes for each row execute function trg_credit_note_number();
do $$
declare r record;
begin
  for r in select credit_note_id, date from credit_notes where status = 'posted' and note_number is null order by date, created_at loop
    update credit_notes set note_number = 'CN-' || to_char(r.date, 'YYMM') || '-' || lpad(nextval('credit_note_seq')::text, 6, '0') where credit_note_id = r.credit_note_id;
  end loop;
end $$;

-- ---------------------------------------------------------------- 3. settings and ITC adjustments
create table if not exists gst_settings (
  id          int primary key default 1 check (id = 1),
  b2cl_limit  numeric(14,2) not null default 250000     -- inter-state sales to unregistered buyers above this per invoice are reported invoice by invoice
);
insert into gst_settings (id) values (1) on conflict do nothing;

create table if not exists gst_itc_adjustments (
  adj_id      uuid primary key default gen_random_uuid(),
  period      text not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  kind        text not null check (kind in ('other_itc', 'reversal')),   -- other_itc: credit from GSTR-2B not entered as a purchase bill (marketplace fees etc.)
  igst        numeric(14,2) not null default 0 check (igst >= 0),
  cgst        numeric(14,2) not null default 0 check (cgst >= 0),
  sgst        numeric(14,2) not null default 0 check (sgst >= 0),
  note        text not null check (btrim(note) <> ''),
  voided      boolean not null default false,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  check (igst + cgst + sgst > 0)
);

create or replace function has_gst_view() returns boolean
language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Finance Manager', 'Accountant', 'Tax Manager', 'Auditor'), false)
$$;
create or replace function has_gst_write() returns boolean
language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Finance Manager', 'Accountant', 'Tax Manager'), false)
$$;

alter table gst_settings         enable row level security;
alter table gst_itc_adjustments  enable row level security;
drop policy if exists "gset read" on gst_settings;        create policy "gset read" on gst_settings        for select to authenticated using (has_gst_view());
drop policy if exists "gadj read" on gst_itc_adjustments; create policy "gadj read" on gst_itc_adjustments for select to authenticated using (has_gst_view());
grant select on gst_settings, gst_itc_adjustments to authenticated;

create or replace function add_gst_itc_adjustment(p_period text, p_kind text, p_igst numeric, p_cgst numeric, p_sgst numeric, p_note text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not has_gst_write() then raise exception 'Only a Super Admin, Finance Manager, Accountant or Tax Manager can enter GST credit adjustments'; end if;
  insert into gst_itc_adjustments (period, kind, igst, cgst, sgst, note)
  values (p_period, p_kind, coalesce(p_igst, 0), coalesce(p_cgst, 0), coalesce(p_sgst, 0), coalesce(p_note, '')) returning adj_id into v_id;
  return v_id;
end $$;
create or replace function void_gst_itc_adjustment(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_gst_write() then raise exception 'Not authorized'; end if;
  update gst_itc_adjustments set voided = true where adj_id = p_id and not voided;
  if not found then raise exception 'Entry not found'; end if;
end $$;
create or replace function save_gst_settings(p_b2cl numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if current_role_name() not in ('Super Admin', 'Finance Manager', 'Tax Manager') then raise exception 'Not authorized'; end if;
  if p_b2cl is null or p_b2cl < 0 then raise exception 'Enter the limit'; end if;
  update gst_settings set b2cl_limit = p_b2cl where id = 1;
end $$;
create or replace function set_order_customer_gstin(p_order uuid, p_gstin text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g text := nullif(upper(btrim(coalesce(p_gstin, ''))), '');
begin
  if not (has_orders_write() or has_accounting_write() or has_tax_write()) then raise exception 'Not authorized'; end if;
  if g is not null and not gstin_valid(g) then raise exception 'That GSTIN is not valid. Check all 15 characters.'; end if;
  update orders set customer_gstin = g where order_id = p_order;
  if not found then raise exception 'Order not found'; end if;
end $$;

-- ---------------------------------------------------------------- 4. the row sources
create or replace function gst_snap_rate(p numeric) returns numeric
language sql immutable as $$
  select coalesce((select r from unnest(array[0, 0.25, 3, 5, 12, 18, 28, 40]::numeric[]) r where abs(r - p) <= 0.15 order by abs(r - p) limit 1), round(p, 2))
$$;
create or replace function gst_rate_known(p numeric) returns boolean
language sql immutable as $$ select p = any (array[0, 0.25, 3, 5, 12, 18, 28, 40]::numeric[]) $$;

-- One row per invoice x HSN x rate. Each invoice's taxable value and GST are shared across its lines by line value, the rate comes from the
-- tax the line carries, and any paisa left over goes to the largest row so the rows always add back to the invoice exactly.
create or replace function gst_sales_rows(p_from date, p_to date) returns table (
  invoice_id uuid, invoice_number text, invoice_date date, channel_id uuid, customer_name text, customer_gstin text, pos_code text,
  is_inter boolean, posted_inter boolean, section text, hsn text, rate numeric, qty numeric, taxable numeric, igst numeric, cgst numeric, sgst numeric, invoice_total numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_co text; v_lim numeric; v_co_name text;
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  v_co := pur_company_state();
  select state into v_co_name from companies order by created_at limit 1;
  select b2cl_limit into v_lim from gst_settings where id = 1;
  return query
  with inv as (
    select i.invoice_id, i.invoice_number, i.invoice_date, i.order_id, i.taxable_value as t, i.gst_amount as g, i.total,
           o.channel_id, o.customer_ref, o.customer_gstin, o.ship_to_state, o.ship_to_state_code
      from invoices i join orders o on o.order_id = i.order_id
     where (p_from is null or i.invoice_date >= p_from) and (p_to is null or i.invoice_date <= p_to)
  ), ln as (
    select inv.invoice_id, pr.hsn, ol.quantity, ol.tax,
           greatest(ol.quantity * ol.unit_price - ol.discount, 0) as net, inv.t, inv.g
      from inv join order_lines ol on ol.order_id = inv.order_id left join products pr on pr.product_id = ol.product_id
  ), w as (
    select ln.*, sum(ln.net) over (partition by ln.invoice_id) as sum_net, count(*) over (partition by ln.invoice_id) as n from ln
  ), a as (
    select w.invoice_id, w.hsn, w.quantity, w.t, w.g,
           case when w.sum_net > 0 then round(w.t * w.net / w.sum_net, 2) else round(w.t / w.n, 2) end as ta,
           w.tax
      from w
  ), a2 as (
    select a.*, case when a.ta > 0 and a.tax > 0 then gst_snap_rate(a.tax / a.ta * 100) else 0 end as rate from a
  ), grp as (
    select a2.invoice_id, a2.hsn, a2.rate, sum(a2.quantity) as qty, sum(a2.ta) as ta, max(a2.t) as t, max(a2.g) as g from a2 group by a2.invoice_id, a2.hsn, a2.rate
  ), nolines as (   -- an invoice whose order has no lines still has to be reported
    select inv.invoice_id, null::text as hsn, case when inv.t > 0 and inv.g > 0 then gst_snap_rate(inv.g / inv.t * 100) else 0 end as rate,
           1::numeric as qty, inv.t as ta, inv.t as t, inv.g as g
      from inv where not exists (select 1 from order_lines ol where ol.order_id = inv.order_id)
  ), u as (
    select * from grp union all select * from nolines
  ), r1 as (
    select u.*, row_number() over (partition by u.invoice_id order by u.ta desc, u.rate desc, u.hsn nulls last) as rk,
           sum(u.ta) over (partition by u.invoice_id) as sum_ta from u
  ), r2 as (
    select r1.invoice_id, r1.hsn, r1.rate, r1.qty, r1.g,
           case when r1.rk = 1 then r1.ta + (r1.t - r1.sum_ta) else r1.ta end as taxable, r1.rk
      from r1
  ), r3 as (
    select r2.*, round(r2.taxable * r2.rate / 100, 2) as tax0, sum(round(r2.taxable * r2.rate / 100, 2)) over (partition by r2.invoice_id) as sum_tax0 from r2
  ), r4 as (
    select r3.*, case when r3.rk = 1 then r3.tax0 + (r3.g - r3.sum_tax0) else r3.tax0 end as tax from r3
  )
  select inv.invoice_id, inv.invoice_number, inv.invoice_date, inv.channel_id, inv.customer_ref, inv.customer_gstin, inv.ship_to_state_code,
         coalesce(inv.ship_to_state_code <> v_co, inv.ship_to_state is distinct from v_co_name) as is_inter,
         (inv.ship_to_state is distinct from v_co_name) as posted_inter,
         case when inv.customer_gstin is not null then 'B2B'
              when coalesce(inv.ship_to_state_code <> v_co, inv.ship_to_state is distinct from v_co_name) and inv.total > v_lim then 'B2CL'
              else 'B2CS' end as section,
         r4.hsn, r4.rate, r4.qty, r4.taxable,
         case when coalesce(inv.ship_to_state_code <> v_co, inv.ship_to_state is distinct from v_co_name) then r4.tax else 0 end as igst,
         case when coalesce(inv.ship_to_state_code <> v_co, inv.ship_to_state is distinct from v_co_name) then 0 else floor(r4.tax * 100 / 2) / 100 end as cgst,
         case when coalesce(inv.ship_to_state_code <> v_co, inv.ship_to_state is distinct from v_co_name) then 0 else r4.tax - floor(r4.tax * 100 / 2) / 100 end as sgst,
         inv.total
    from r4 join inv on inv.invoice_id = r4.invoice_id
   order by inv.invoice_date, inv.invoice_number, r4.rate, r4.hsn;
end $$;

-- One row per credit note x HSN x rate, taken from the invoice it reverses in proportion to the amount credited.
create or replace function gst_cn_rows(p_from date, p_to date) returns table (
  credit_note_id uuid, note_number text, note_date date, reason text, invoice_number text, invoice_date date, channel_id uuid, customer_name text,
  customer_gstin text, pos_code text, is_inter boolean, section text, hsn text, rate numeric, qty numeric, taxable numeric, igst numeric, cgst numeric, sgst numeric, note_value numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  return query
  with cn as (
    select c.credit_note_id, c.note_number, c.date, c.reason, c.invoice_id, c.amount, c.tax_amount, (c.amount - c.tax_amount) as cn_taxable
      from credit_notes c
     where c.status = 'posted' and (p_from is null or c.date >= p_from) and (p_to is null or c.date <= p_to)
  ), src as (
    select s.*, sum(s.taxable) over (partition by s.invoice_id) as inv_taxable from gst_sales_rows(null, null) s
     where s.invoice_id in (select invoice_id from cn)
  ), j as (
    select cn.credit_note_id, cn.note_number, cn.date, cn.reason, s.invoice_number, s.invoice_date, s.channel_id, s.customer_name, s.customer_gstin, s.pos_code,
           s.is_inter, s.section, s.hsn, s.rate, s.qty, cn.cn_taxable, cn.tax_amount, cn.amount, s.taxable as row_taxable, s.inv_taxable,
           case when s.inv_taxable > 0 then round(cn.cn_taxable * s.taxable / s.inv_taxable, 2) else 0 end as t0
      from cn join src s on s.invoice_id = cn.invoice_id
  ), k as (
    select j.*, row_number() over (partition by j.credit_note_id order by j.row_taxable desc, j.rate desc, j.hsn nulls last) as rk,
           sum(j.t0) over (partition by j.credit_note_id) as sum_t0 from j
  ), m as (
    select k.*, case when k.rk = 1 then k.t0 + (k.cn_taxable - k.sum_t0) else k.t0 end as taxable_row from k
  ), m2 as (
    select m.*, round(m.taxable_row * m.rate / 100, 2) as tax0, sum(round(m.taxable_row * m.rate / 100, 2)) over (partition by m.credit_note_id) as sum_tax0 from m
  )
  select m2.credit_note_id, m2.note_number, m2.date, m2.reason, m2.invoice_number, m2.invoice_date, m2.channel_id, m2.customer_name, m2.customer_gstin, m2.pos_code,
         m2.is_inter,
         case m2.section when 'B2B' then 'CDNR' when 'B2CL' then 'CDNUR' else 'B2CS' end,
         m2.hsn, m2.rate, m2.qty, m2.taxable_row,
         case when m2.is_inter then (case when m2.rk = 1 then m2.tax0 + (m2.tax_amount - m2.sum_tax0) else m2.tax0 end) else 0 end,
         case when m2.is_inter then 0 else floor((case when m2.rk = 1 then m2.tax0 + (m2.tax_amount - m2.sum_tax0) else m2.tax0 end) * 100 / 2) / 100 end,
         case when m2.is_inter then 0 else (case when m2.rk = 1 then m2.tax0 + (m2.tax_amount - m2.sum_tax0) else m2.tax0 end)
                                        - floor((case when m2.rk = 1 then m2.tax0 + (m2.tax_amount - m2.sum_tax0) else m2.tax0 end) * 100 / 2) / 100 end,
         m2.amount
    from m2 order by m2.date, m2.note_number, m2.rate, m2.hsn;
end $$;

-- ---------------------------------------------------------------- 5. GSTR-1 sections
create or replace function gstr1_invoices(p_from date, p_to date) returns table (
  section text, invoice_number text, invoice_date date, customer_name text, customer_gstin text, pos_code text, is_inter boolean, rate numeric,
  taxable numeric, igst numeric, cgst numeric, sgst numeric, invoice_total numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select s.section, s.invoice_number, s.invoice_date, s.customer_name, s.customer_gstin, s.pos_code, s.is_inter, s.rate,
         sum(s.taxable), sum(s.igst), sum(s.cgst), sum(s.sgst), max(s.invoice_total)
    from gst_sales_rows(p_from, p_to) s
   where s.section in ('B2B', 'B2CL')
   group by s.section, s.invoice_number, s.invoice_date, s.customer_name, s.customer_gstin, s.pos_code, s.is_inter, s.rate
   order by s.invoice_date, s.invoice_number, s.rate
$$;
-- B2C others: by place of supply and rate, with credit notes to unregistered buyers netted off; also split by channel so marketplace supplies can be reported separately
create or replace function gstr1_b2cs(p_from date, p_to date) returns table (
  channel_name text, eco_gstin text, pos_code text, is_inter boolean, rate numeric, taxable numeric, igst numeric, cgst numeric, sgst numeric, invoices bigint)
language sql stable security definer set search_path = public, pg_temp as $$
  with x as (
    select s.channel_id, s.pos_code, s.is_inter, s.rate, s.taxable, s.igst, s.cgst, s.sgst, 1 as inv from gst_sales_rows(p_from, p_to) s where s.section = 'B2CS'
    union all
    select c.channel_id, c.pos_code, c.is_inter, c.rate, -c.taxable, -c.igst, -c.cgst, -c.sgst, 0 from gst_cn_rows(p_from, p_to) c where c.section = 'B2CS'
  )
  select coalesce(ch.name, 'Unknown channel'), ch.eco_gstin, x.pos_code, x.is_inter, x.rate, sum(x.taxable), sum(x.igst), sum(x.cgst), sum(x.sgst), sum(x.inv)::bigint
    from x left join channels ch on ch.channel_id = x.channel_id
   group by ch.name, ch.eco_gstin, x.pos_code, x.is_inter, x.rate
   order by 1, 3, x.rate
$$;

create or replace function gstr1_cdn(p_from date, p_to date) returns table (
  section text, note_number text, note_date date, reason text, invoice_number text, invoice_date date, customer_name text, customer_gstin text, pos_code text,
  is_inter boolean, rate numeric, taxable numeric, igst numeric, cgst numeric, sgst numeric, note_value numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select c.section, c.note_number, c.note_date, c.reason, c.invoice_number, c.invoice_date, c.customer_name, c.customer_gstin, c.pos_code, c.is_inter, c.rate,
         sum(c.taxable), sum(c.igst), sum(c.cgst), sum(c.sgst), max(c.note_value)
    from gst_cn_rows(p_from, p_to) c
   where c.section in ('CDNR', 'CDNUR')
   group by c.section, c.note_number, c.note_date, c.reason, c.invoice_number, c.invoice_date, c.customer_name, c.customer_gstin, c.pos_code, c.is_inter, c.rate
   order by c.note_date, c.note_number, c.rate
$$;

-- HSN summary, net of credit notes
create or replace function gstr1_hsn(p_from date, p_to date) returns table (
  hsn text, rate numeric, qty numeric, taxable numeric, igst numeric, cgst numeric, sgst numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  with x as (
    select s.hsn, s.rate, s.qty, s.taxable, s.igst, s.cgst, s.sgst from gst_sales_rows(p_from, p_to) s
    union all
    select c.hsn, c.rate, -c.qty, -c.taxable, -c.igst, -c.cgst, -c.sgst from gst_cn_rows(p_from, p_to) c
  )
  select coalesce(x.hsn, 'MISSING'), x.rate, sum(x.qty), sum(x.taxable), sum(x.igst), sum(x.cgst), sum(x.sgst) from x group by 1, x.rate order by 1, x.rate
$$;

-- documents issued: first and last number and how many, for invoices and credit notes
create or replace function gstr1_docs(p_from date, p_to date) returns table (doc_type text, first_no text, last_no text, issued bigint, cancelled bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  return query
  select 'Invoices', min(i.invoice_number), max(i.invoice_number), count(*)::bigint, 0::bigint from invoices i
   where (p_from is null or i.invoice_date >= p_from) and (p_to is null or i.invoice_date <= p_to) having count(*) > 0
  union all
  select 'Credit notes', min(c.note_number), max(c.note_number), count(*)::bigint, 0::bigint from credit_notes c
   where c.status = 'posted' and (p_from is null or c.date >= p_from) and (p_to is null or c.date <= p_to) having count(*) > 0;
end $$;

-- things the CA must look at before filing
create or replace function gst_data_checks(p_from date, p_to date) returns table (code text, label text, n bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  return query
  with s as (select distinct x.invoice_id, x.invoice_number, x.pos_code, x.is_inter, x.posted_inter, x.customer_gstin, x.section from gst_sales_rows(p_from, p_to) x),
       r as (select x.invoice_number, x.hsn, x.rate, x.igst + x.cgst + x.sgst as tax from gst_sales_rows(p_from, p_to) x)
  select 'no_state', 'Invoices with a place of supply that could not be matched to an Indian state', count(*) from s where s.pos_code is null
  union all
  select 'split_mismatch', 'Invoices where the CGST/SGST/IGST posted in the books differs from the state-code rule (check the ship-to state spelling)', count(*) from s where s.pos_code is not null and s.is_inter <> s.posted_inter
  union all
  select 'no_hsn', 'Sales lines with no HSN code on the product', count(*) from r where r.hsn is null or btrim(r.hsn) = ''
  union all
  select 'odd_rate', 'Sales lines whose tax rate is not a standard slab', count(*) from r where not gst_rate_known(r.rate)
  union all
  select 'b2b_count', 'B2B invoices (customer GSTIN present)', count(*) from s where s.section = 'B2B'
  union all
  select 'no_cn_number', 'Posted credit notes in the period without a number', count(*) from credit_notes c
   where c.status = 'posted' and c.note_number is null and (p_from is null or c.date >= p_from) and (p_to is null or c.date <= p_to);
end $$;

-- ---------------------------------------------------------------- 6. GSTR-3B workings
-- outward supplies (net of credit notes) and the credit available, for one calendar month
create or replace function gstr3b_workings(p_month text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_from date; v_to date; o jsonb; i jsonb; inter jsonb; adj jsonb; v_lump numeric; v_tcs numeric;
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  if p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Choose a month'; end if;
  v_from := (p_month || '-01')::date; v_to := (v_from + interval '1 month - 1 day')::date;

  with x as (
    select s.rate, s.taxable, s.igst, s.cgst, s.sgst from gst_sales_rows(v_from, v_to) s
    union all
    select c.rate, -c.taxable, -c.igst, -c.cgst, -c.sgst from gst_cn_rows(v_from, v_to) c
  )
  select jsonb_build_object(
    'taxable',  coalesce(sum(taxable) filter (where rate > 0), 0), 'igst', coalesce(sum(igst) filter (where rate > 0), 0),
    'cgst', coalesce(sum(cgst) filter (where rate > 0), 0), 'sgst', coalesce(sum(sgst) filter (where rate > 0), 0),
    'nil_taxable', coalesce(sum(taxable) filter (where rate = 0), 0))
    into o from x;

  -- 3.2: inter-state supplies to unregistered buyers, by place of supply
  select coalesce(jsonb_agg(jsonb_build_object('pos', pos_code, 'taxable', taxable, 'igst', igst) order by pos_code), '[]'::jsonb) into inter from (
    select y.pos_code, sum(y.taxable) as taxable, sum(y.igst) as igst from (
      select s.pos_code, s.taxable, s.igst from gst_sales_rows(v_from, v_to) s where s.is_inter and s.section <> 'B2B' and s.rate > 0
      union all
      select c.pos_code, -c.taxable, -c.igst from gst_cn_rows(v_from, v_to) c where c.is_inter and c.rate > 0 and c.section in ('B2CS', 'CDNUR')
    ) y group by y.pos_code having sum(y.taxable) <> 0 or sum(y.igst) <> 0) z;

  -- ITC from purchase bills booked in the month and claimed
  select jsonb_build_object(
    'igst', coalesce(sum(b.igst) filter (where b.itc_eligible), 0), 'cgst', coalesce(sum(b.cgst) filter (where b.itc_eligible), 0), 'sgst', coalesce(sum(b.sgst) filter (where b.itc_eligible), 0),
    'ineligible', coalesce(sum(b.igst + b.cgst + b.sgst) filter (where not b.itc_eligible), 0), 'bills', count(*))
    into i from purchase_bills b where b.status = 'approved' and b.bill_date between v_from and v_to;

  select jsonb_build_object(
    'other_igst', coalesce(sum(a.igst) filter (where a.kind = 'other_itc'), 0), 'other_cgst', coalesce(sum(a.cgst) filter (where a.kind = 'other_itc'), 0), 'other_sgst', coalesce(sum(a.sgst) filter (where a.kind = 'other_itc'), 0),
    'rev_igst', coalesce(sum(a.igst) filter (where a.kind = 'reversal'), 0), 'rev_cgst', coalesce(sum(a.cgst) filter (where a.kind = 'reversal'), 0), 'rev_sgst', coalesce(sum(a.sgst) filter (where a.kind = 'reversal'), 0))
    into adj from gst_itc_adjustments a where a.period = p_month and not a.voided;

  -- reference only: what the books carry on the single ITC ledger (marketplace fees) and the TCS credit, for the month
  select coalesce(sum(vl.debit - vl.credit), 0) into v_lump from voucher_lines vl join vouchers v on v.voucher_id = vl.voucher_id join ledgers l on l.ledger_id = vl.ledger_id
   where l.name = 'GST Input Tax Credit (ITC)' and v.status = 'posted' and v.voucher_date between v_from and v_to;
  select coalesce(sum(vl.debit - vl.credit), 0) into v_tcs from voucher_lines vl join vouchers v on v.voucher_id = vl.voucher_id join ledgers l on l.ledger_id = vl.ledger_id
   where l.name = 'GST TCS Credit Receivable' and v.status = 'posted' and v.voucher_date between v_from and v_to;

  return jsonb_build_object('month', p_month, 'from', v_from, 'to', v_to, 'outward', o, 'inter_unreg', inter, 'itc_bills', i, 'itc_adj', adj,
                            'books_marketplace_itc', v_lump, 'books_tcs_credit', v_tcs);
end $$;

-- ---------------------------------------------------------------- 7. grants
revoke execute on function gst_state_code(text), gst_snap_rate(numeric), gst_rate_known(numeric), gst_sales_rows(date, date), gst_cn_rows(date, date), gstr1_invoices(date, date),
  gstr1_b2cs(date, date), gstr1_cdn(date, date), gstr1_hsn(date, date), gstr1_docs(date, date), gst_data_checks(date, date),
  gstr3b_workings(text), has_gst_view(), has_gst_write(), add_gst_itc_adjustment(text, text, numeric, numeric, numeric, text), void_gst_itc_adjustment(uuid),
  save_gst_settings(numeric), set_order_customer_gstin(uuid, text) from public, anon, authenticated;
grant execute on function gst_state_code(text), gst_sales_rows(date, date), gst_cn_rows(date, date), gstr1_invoices(date, date), gstr1_b2cs(date, date), gstr1_cdn(date, date),
  gstr1_hsn(date, date), gstr1_docs(date, date), gst_data_checks(date, date), gstr3b_workings(text), has_gst_view(), has_gst_write(),
  add_gst_itc_adjustment(text, text, numeric, numeric, numeric, text), void_gst_itc_adjustment(uuid), save_gst_settings(numeric), set_order_customer_gstin(uuid, text) to authenticated;
