-- 0078: Marketplace tax credits: GST TCS (section 52 CGST) and income-tax TDS on e-commerce sales (194-O).
--
-- A marketplace holds back two small taxes from every payout and files them in your name:
--   * GST TCS: a percentage of the net taxable value of what you sold through it. Shows up for you in GSTR-2A / 2B and in the
--     electronic cash ledger once the marketplace files its GSTR-8.
--   * Income-tax TDS (194-O; section 393 of the Income-tax Act 2025 from 1 April 2026): a percentage of the sale amount. Shows up in
--     Form 26AS / AIS once the marketplace files its quarterly TDS return, and is set off against your income tax.
-- If either is deducted wrongly, or never reaches your portal, you lose real money. This migration works out what should have been
-- held, compares it with what the settlement reports say was held, and with what your portal shows as credited.
--
-- Rates and the value they are charged on are stored by effective date and are editable. They are standard values, to be confirmed by your CA.

-- ---------------------------------------------------------------- settlement lines can now carry the two taxes
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'settlement_lines'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%fee_type%' loop
    execute format('alter table settlement_lines drop constraint %I', c);
  end loop;
end $$;
alter table settlement_lines add constraint settlement_lines_fee_type_check
  check (fee_type in ('order_value', 'commission', 'shipping', 'gateway_fee', 'tax', 'refund', 'other', 'tcs', 'tds_194o'));
create index if not exists settlement_lines_settlement_ix on settlement_lines (settlement_id, fee_type);

create or replace function imp_settlement(p_rows jsonb, p_apply boolean, p_opt jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; i int; rn int; v_out jsonb := '[]'; v_err text; v_warn text; v_act text;
  v_cid uuid := nullif(p_opt ->> 'channel_id', '')::uuid; v_cname text;
  v_sid text; v_oid text; v_ft text; v_amt numeric; v_tax numeric; v_ps date; v_pe date; v_ord uuid;
  v_keys text[] := '{}'; v_errk text[] := '{}'; k text; v_ex settlements%rowtype; v_new uuid; g record;
  v_gross numeric; v_ded numeric; v_n int;
  a_rn int[] := '{}'; a_key text[] := '{}'; a_ord uuid[] := '{}'; a_ft text[] := '{}'; a_amt numeric[] := '{}'; a_tax numeric[] := '{}'; a_ps date[] := '{}'; a_pe date[] := '{}';
  a_err text[] := '{}'; a_warn text[] := '{}'; j int;
begin
  if v_cid is null then raise exception 'Choose the channel this settlement belongs to'; end if;
  select name into v_cname from channels where channel_id = v_cid;
  if v_cname is null then raise exception 'Channel not found'; end if;
  if not has_channel_scope(v_cid) then raise exception 'You are not assigned to channel %', v_cname; end if;

  for i in 0 .. jsonb_array_length(p_rows) - 1 loop
    r := p_rows -> i; rn := coalesce(nullif(r ->> '_row', '')::int, i + 2);
    v_err := null; v_warn := null; v_ord := null; v_amt := null; v_tax := 0; v_ps := null; v_pe := null;
    v_sid := imp_txt(r, 'settlement_id'); v_oid := imp_txt(r, 'order_id'); v_ft := lower(coalesce(imp_txt(r, 'fee_type'), ''));
    v_ft := replace(replace(v_ft, ' ', '_'), '-', '_');
    if v_sid is null then v_err := 'Settlement id is required';
    elsif v_sid ~* '^[0-9.]+e\+?[0-9]+$' then v_err := 'Settlement id ' || v_sid || ' was turned into a short number by Excel. Format the column as Text and download the report again';
    elsif v_ft not in ('order_value', 'commission', 'shipping', 'gateway_fee', 'tax', 'refund', 'other', 'tcs', 'tds_194o') then v_err := 'Fee type "' || v_ft || '" must be one of order_value, commission, shipping, gateway_fee, tax, refund, other, tcs, tds_194o';
    else
      v_amt := imp_num(imp_txt(r, 'amount'));
      if imp_txt(r, 'tax_amount') is not null then v_tax := imp_num(imp_txt(r, 'tax_amount')); end if;
      if v_amt is null or v_tax is null or v_amt < 0 or v_tax < 0 then v_err := 'Amount and tax amount must be numbers, zero or more. Show fees as positive amounts';
      elsif v_ft = 'order_value' and v_oid is null then v_err := 'An order_value row needs the order id';
      end if;
    end if;
    if v_err is null and imp_txt(r, 'period_start') is not null then begin v_ps := imp_txt(r, 'period_start')::date; exception when others then v_err := 'Period start is not a date (use YYYY-MM-DD)'; end; end if;
    if v_err is null and imp_txt(r, 'period_end') is not null then begin v_pe := imp_txt(r, 'period_end')::date; exception when others then v_err := 'Period end is not a date (use YYYY-MM-DD)'; end; end if;
    if v_err is null and v_oid is not null then
      select order_id into v_ord from orders where channel_id = v_cid and external_order_id = v_oid;
      if v_ord is null then v_warn := 'Order ' || v_oid || ' is not in the app, so its fees cannot be checked against the order'; end if;
    end if;
    a_rn := a_rn || rn; a_key := a_key || coalesce(v_sid, ''); a_ord := a_ord || v_ord; a_ft := a_ft || coalesce(v_ft, ''); a_amt := a_amt || coalesce(v_amt, 0); a_tax := a_tax || coalesce(v_tax, 0);
    a_ps := a_ps || v_ps; a_pe := a_pe || v_pe; a_err := a_err || v_err; a_warn := a_warn || v_warn;
    if v_err is not null and v_sid is not null then v_errk := v_errk || v_sid; end if;
  end loop;

  -- per settlement: all or nothing
  for k in select distinct a_key[x] from generate_subscripts(a_key, 1) x where a_key[x] <> '' loop
    select * into v_ex from settlements where channel_id = v_cid and external_settlement_id = k;
    select count(*) into v_n from generate_subscripts(a_key, 1) x where a_key[x] = k;
    v_gross := 0; v_ded := 0; v_ps := null; v_pe := null;
    for j in 1 .. coalesce(array_length(a_key, 1), 0) loop
      if a_key[j] = k then
        if a_ft[j] = 'order_value' then v_gross := v_gross + a_amt[j]; else v_ded := v_ded + a_amt[j] + a_tax[j]; end if;
        v_ps := coalesce(v_ps, a_ps[j]); v_pe := coalesce(v_pe, a_pe[j]);
      end if;
    end loop;
    v_act := null;
    if k = any (v_errk) then v_act := null;
    elsif v_ex.settlement_id is not null and exists (select 1 from settlement_lines where settlement_id = v_ex.settlement_id) then v_act := 'unchanged';
    elsif v_ex.settlement_id is not null and v_ex.status <> 'pending' then v_act := 'blocked';
    elsif v_ex.settlement_id is not null then v_act := 'update';
    else v_act := 'add';
    end if;
    if v_act = 'blocked' then
      for j in 1 .. array_length(a_key, 1) loop if a_key[j] = k and a_err[j] is null then a_err[j] := 'Settlement ' || k || ' is already ' || v_ex.status || ' and has no lines. It cannot be rewritten'; end if; end loop;
    elsif v_act in ('add', 'update') then
      if v_gross = 0 then
        for j in 1 .. array_length(a_key, 1) loop if a_key[j] = k and a_err[j] is null then a_err[j] := 'Settlement ' || k || ' has no order_value rows, so nothing was collected to pay out'; end if; end loop;
        v_act := null;
      elsif v_ded > v_gross then
        for j in 1 .. array_length(a_key, 1) loop if a_key[j] = k and a_err[j] is null then a_err[j] := 'Settlement ' || k || ': deductions (' || v_ded || ') are more than the order value (' || v_gross || '). Check the sign of refunds'; end if; end loop;
        v_act := null;
      elsif p_apply then
        if v_act = 'add' then
          insert into settlements (channel_id, external_settlement_id, period_start, period_end, gross, deductions, expected_amount) values (v_cid, k, v_ps, v_pe, v_gross, v_ded, v_gross - v_ded) returning settlement_id into v_new;
        else
          update settlements set period_start = coalesce(v_ps, period_start), period_end = coalesce(v_pe, period_end), gross = v_gross, deductions = v_ded, expected_amount = v_gross - v_ded where settlement_id = v_ex.settlement_id;
          v_new := v_ex.settlement_id;
        end if;
        for j in 1 .. array_length(a_key, 1) loop
          if a_key[j] = k then insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (v_new, a_ord[j], a_ft[j], a_amt[j], a_tax[j]); end if;
        end loop;
      end if;
    end if;
    -- remember the action per row
    for j in 1 .. array_length(a_key, 1) loop
      if a_key[j] = k and a_err[j] is null then a_warn[j] := coalesce(a_warn[j], case when v_act = 'update' then 'This settlement was entered by hand; its totals are replaced by the file''s' end); end if;
    end loop;
    v_errk := v_errk;
    -- store the chosen action in the key array suffix
    for j in 1 .. array_length(a_key, 1) loop if a_key[j] = k then a_key[j] := k || '|' || coalesce(v_act, ''); end if; end loop;
  end loop;

  for j in 1 .. coalesce(array_length(a_rn, 1), 0) loop
    v_out := v_out || imp_res(a_rn[j], case when a_err[j] is null and a_key[j] like '%|' and a_key[j] <> '|' then 'Held back because another row of this settlement has an error' else a_err[j] end, a_warn[j], nullif(split_part(a_key[j], '|', 2), ''));
  end loop;
  return jsonb_build_object('rows', v_out);
end $$;

-- ---------------------------------------------------------------- rules, settings, marketplace identifiers
create table if not exists marketplace_tax_rules (
  rule_id        uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('gst_tcs', 'tds_194o')),
  rate           numeric(6,3) not null check (rate >= 0 and rate <= 20),
  base           text not null check (base in ('excl_gst_gross', 'excl_gst_net', 'incl_gst_gross', 'incl_gst_net')),
  effective_from date not null,
  note           text,
  updated_by     uuid,
  updated_at     timestamptz not null default now(),
  unique (kind, effective_from)
);
insert into marketplace_tax_rules (kind, rate, base, effective_from, note) values
  ('gst_tcs',  1.000, 'excl_gst_net', date '2018-10-01', 'GST TCS 1% (0.5% CGST + 0.5% SGST, or 1% IGST) until 9 Jul 2024'),
  ('gst_tcs',  0.500, 'excl_gst_net', date '2024-07-10', 'GST TCS 0.5% (0.25% CGST + 0.25% SGST, or 0.5% IGST) from 10 Jul 2024. On net value of taxable supplies, after returns. Confirm with your CA.'),
  ('tds_194o', 1.000, 'excl_gst_net', date '2020-10-01', '194-O TDS 1% until 30 Sep 2024'),
  ('tds_194o', 0.100, 'excl_gst_net', date '2024-10-01', '194-O TDS 0.1% from 1 Oct 2024 (section 393 of the Income-tax Act 2025 from 1 Apr 2026). Whether the marketplace charges it on the value with or without GST differs; the diagnostic on the reconciliation page shows which one your marketplaces use. Confirm with your CA.')
on conflict (kind, effective_from) do nothing;

create table if not exists marketplace_tax_settings (
  id               int primary key default 1 check (id = 1),
  individual_huf   boolean not null default false,      -- an individual or HUF seller: no 194-O deduction until the year's sales pass the threshold
  threshold_194o   numeric(14,2) not null default 500000,
  tolerance        numeric(10,2) not null default 5,
  tolerance_pct    numeric(5,2) not null default 1,
  updated_by       uuid,
  updated_at       timestamptz not null default now()
);
insert into marketplace_tax_settings (id) values (1) on conflict do nothing;

create table if not exists marketplace_tax_ids (
  channel_id     uuid primary key references channels(channel_id),
  operator_name  text,
  operator_gstin text check (operator_gstin is null or operator_gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  operator_tan   text check (operator_tan is null or operator_tan ~ '^[A-Z]{4}[0-9]{5}[A-Z]$'),
  updated_at     timestamptz not null default now()
);

create table if not exists marketplace_credit_entries (
  credit_id    uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('gst_tcs', 'tds_194o')),
  channel_id   uuid not null references channels(channel_id),
  month        date not null check (month = date_trunc('month', month)::date),
  amount       numeric(14,2) not null check (amount >= 0),
  taxable_value numeric(14,2),
  source       text not null default 'other' check (source in ('gstr2a', 'gstr2b', 'cash_ledger', 'form26as', 'ais', 'form16a', 'other')),
  claimed      boolean not null default false,
  note         text,
  entered_by   uuid default auth.uid(),
  entered_at   timestamptz not null default now(),
  unique (kind, channel_id, month)
);
alter table marketplace_tax_rules enable row level security; alter table marketplace_tax_settings enable row level security;
alter table marketplace_tax_ids enable row level security; alter table marketplace_credit_entries enable row level security;
drop policy if exists "mtr read" on marketplace_tax_rules; create policy "mtr read" on marketplace_tax_rules for select to authenticated using (has_settlements_view());
drop policy if exists "mts read" on marketplace_tax_settings; create policy "mts read" on marketplace_tax_settings for select to authenticated using (has_settlements_view());
drop policy if exists "mti read" on marketplace_tax_ids; create policy "mti read" on marketplace_tax_ids for select to authenticated using (has_settlements_view() and has_channel_scope(channel_id));
drop policy if exists "mce read" on marketplace_credit_entries; create policy "mce read" on marketplace_credit_entries for select to authenticated using (has_settlements_view() and has_channel_scope(channel_id));
grant select on marketplace_tax_rules, marketplace_tax_settings, marketplace_tax_ids, marketplace_credit_entries to authenticated;

create or replace function has_mtax_write() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Finance Manager', 'Accountant'), false)
$$;

create or replace function mtax_rule_save(p_kind text, p_rate numeric, p_base text, p_from date, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can change tax rates'; end if;
  if p_kind not in ('gst_tcs', 'tds_194o') then raise exception 'Choose GST TCS or 194-O TDS'; end if;
  if p_rate is null or p_rate < 0 or p_rate > 20 then raise exception 'The rate must be between 0 and 20 percent'; end if;
  if p_base not in ('excl_gst_gross', 'excl_gst_net', 'incl_gst_gross', 'incl_gst_net') then raise exception 'Choose what the tax is charged on'; end if;
  if p_from is null then raise exception 'Enter the date the rate starts from'; end if;
  insert into marketplace_tax_rules (kind, rate, base, effective_from, note, updated_by) values (p_kind, p_rate, p_base, p_from, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  on conflict (kind, effective_from) do update set rate = excluded.rate, base = excluded.base, note = excluded.note, updated_by = auth.uid(), updated_at = now();
end $$;

create or replace function mtax_settings_save(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can change these settings'; end if;
  update marketplace_tax_settings set
    individual_huf = coalesce((p ->> 'individual_huf')::boolean, individual_huf),
    threshold_194o = coalesce(nullif(p ->> 'threshold_194o', '')::numeric, threshold_194o),
    tolerance = coalesce(nullif(p ->> 'tolerance', '')::numeric, tolerance),
    tolerance_pct = coalesce(nullif(p ->> 'tolerance_pct', '')::numeric, tolerance_pct), updated_by = auth.uid(), updated_at = now() where id = 1;
  if exists (select 1 from marketplace_tax_settings where threshold_194o < 0 or tolerance < 0 or tolerance_pct < 0 or tolerance_pct > 100) then raise exception 'Amounts cannot be negative and the percentage must be 0 to 100'; end if;
end $$;

create or replace function mtax_ids_save(p_channel uuid, p_name text, p_gstin text, p_tan text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_mtax_write() then raise exception 'Only a Super Admin, Finance Manager or Accountant can save this'; end if;
  if not has_channel_scope(p_channel) then raise exception 'You are not assigned to this channel'; end if;
  insert into marketplace_tax_ids (channel_id, operator_name, operator_gstin, operator_tan) values (p_channel, nullif(btrim(coalesce(p_name, '')), ''), nullif(upper(btrim(coalesce(p_gstin, ''))), ''), nullif(upper(btrim(coalesce(p_tan, ''))), ''))
  on conflict (channel_id) do update set operator_name = excluded.operator_name, operator_gstin = excluded.operator_gstin, operator_tan = excluded.operator_tan, updated_at = now();
exception when check_violation then raise exception 'The GSTIN must be 15 characters (like 29AAACA1234A1Z5) and the TAN 10 characters (like BLRA12345B)';
end $$;

-- what your portal shows for a month: GSTR-2A / 2B (TCS) or Form 26AS / AIS (TDS). A blank amount removes the entry.
create or replace function mtax_credit_set(p_kind text, p_channel uuid, p_month date, p_amount numeric, p_taxable numeric default null,
                                           p_source text default 'other', p_claimed boolean default false, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m date := date_trunc('month', p_month)::date;
begin
  if not has_mtax_write() then raise exception 'Only a Super Admin, Finance Manager or Accountant can enter portal credits'; end if;
  if not has_channel_scope(p_channel) then raise exception 'You are not assigned to this channel'; end if;
  if not exists (select 1 from channels where channel_id = p_channel and type = 'marketplace') then raise exception 'This applies to marketplace channels only'; end if;
  if p_kind not in ('gst_tcs', 'tds_194o') then raise exception 'Choose GST TCS or 194-O TDS'; end if;
  if p_amount is null then delete from marketplace_credit_entries where kind = p_kind and channel_id = p_channel and month = m; return; end if;
  if p_amount < 0 then raise exception 'The amount cannot be negative'; end if;
  if m > date_trunc('month', current_date)::date then raise exception 'That month has not happened yet'; end if;
  insert into marketplace_credit_entries (kind, channel_id, month, amount, taxable_value, source, claimed, note)
  values (p_kind, p_channel, m, round(p_amount, 2), p_taxable, coalesce(nullif(p_source, ''), 'other'), coalesce(p_claimed, false), nullif(btrim(coalesce(p_note, '')), ''))
  on conflict (kind, channel_id, month) do update set amount = excluded.amount, taxable_value = excluded.taxable_value, source = excluded.source, claimed = excluded.claimed, note = excluded.note, entered_by = auth.uid(), entered_at = now();
end $$;

-- ---------------------------------------------------------------- the reconciliation
create or replace function mtax_rate_on(p_kind text, p_on date) returns table (rate numeric, base text)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.rate, r.base from marketplace_tax_rules r where r.kind = p_kind and r.effective_from <= p_on order by r.effective_from desc limit 1
$$;

create or replace function mtax_reconcile(p_from date, p_to date) returns table (
  channel_id uuid, channel_name text, kind text, month date, rate numeric, base text, base_value numeric, expected numeric, deducted numeric, deduct_diff numeric, deduct_status text,
  credited numeric, claimed boolean, credit_source text, credit_diff numeric, credit_status text, due_by date, op_gstin text, op_tan text, unmatched_rows bigint, hint jsonb)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare cfg marketplace_tax_settings%rowtype; v_from date := date_trunc('month', p_from)::date; v_start date;
begin
  if not has_settlements_view() then return; end if;
  select * into cfg from marketplace_tax_settings where id = 1;
  v_start := make_date(case when extract(month from v_from) >= 4 then extract(year from v_from)::int else extract(year from v_from)::int - 1 end, 4, 1);
  return query
  with sl as (
    select s.channel_id as ch, s.settlement_id, date_trunc('month', coalesce(s.period_end, s.period_start, s.created_at::date))::date as mth,
           coalesce(s.period_end, s.period_start, s.created_at::date) as sdate, l.fee_type, l.amount, l.order_id,
           case when o.order_id is not null and o.net_amount > 0 then least(1, greatest(0, o.tax_amount / o.net_amount)) else 0 end as taxr,
           (o.order_id is null) as no_order
      from settlement_lines l join settlements s on s.settlement_id = l.settlement_id join channels c on c.channel_id = s.channel_id and c.type = 'marketplace'
      left join orders o on o.order_id = l.order_id
     where coalesce(s.period_end, s.period_start, s.created_at::date) between v_start and p_to and has_channel_scope(s.channel_id)
       and l.fee_type in ('order_value', 'refund', 'tcs', 'tds_194o')),
  per_s as (
    select ch, settlement_id, mth, sdate,
           sum(amount) filter (where fee_type = 'order_value') as g_incl,
           sum(amount * (1 - taxr)) filter (where fee_type = 'order_value') as g_excl,
           sum(amount) filter (where fee_type = 'refund') as r_incl,
           sum(amount * (1 - taxr)) filter (where fee_type = 'refund') as r_excl,
           sum(amount) filter (where fee_type = 'tcs') as ded_tcs,
           sum(amount) filter (where fee_type = 'tds_194o') as ded_tds,
           count(*) filter (where no_order and fee_type in ('order_value', 'refund')) as nomatch
      from sl group by ch, settlement_id, mth, sdate),
  calc as (
    select p.ch, p.mth, k.kind, p.sdate,
           coalesce(p.g_incl, 0) as g_incl, coalesce(p.g_excl, 0) as g_excl, coalesce(p.r_incl, 0) as r_incl, coalesce(p.r_excl, 0) as r_excl,
           case k.kind when 'gst_tcs' then coalesce(p.ded_tcs, 0) else coalesce(p.ded_tds, 0) end as ded, p.nomatch,
           rt.rate, rt.base,
           case rt.base when 'excl_gst_gross' then coalesce(p.g_excl, 0) when 'excl_gst_net' then coalesce(p.g_excl, 0) - coalesce(p.r_excl, 0)
                        when 'incl_gst_gross' then coalesce(p.g_incl, 0) else coalesce(p.g_incl, 0) - coalesce(p.r_incl, 0) end as bval
      from per_s p cross join (values ('gst_tcs'), ('tds_194o')) k(kind) cross join lateral mtax_rate_on(k.kind, p.sdate) rt),
  m as (
    select ch, mth, kind, max(rate) as rate, max(base) as base, sum(bval) as bval, sum(bval * rate / 100) as exp, sum(ded) as ded,
           sum(g_incl) as g_incl, sum(g_excl) as g_excl, sum(g_incl - r_incl) as n_incl, sum(g_excl - r_excl) as n_excl, sum(nomatch) as nomatch
      from calc group by ch, mth, kind),
  cum as (
    select m.*, sum(case when m.kind = 'tds_194o' then m.bval else 0 end) over (partition by m.ch, m.kind order by m.mth, m.kind
             rows between unbounded preceding and current row) as cum_end
      from m where m.mth >= v_start),
  fin as (
    select c.ch, c.mth, c.kind, c.rate, c.base, c.bval,
           case when c.kind = 'tds_194o' and cfg.individual_huf and c.bval > 0 then
                  c.exp * greatest(0, least(c.bval, greatest(0, c.cum_end - cfg.threshold_194o) - greatest(0, c.cum_end - c.bval - cfg.threshold_194o))) / c.bval
                else c.exp end as exp, c.ded, c.g_incl, c.g_excl, c.n_incl, c.n_excl, c.nomatch
      from cum c)
  select f.ch, ch.name, f.kind, f.mth, f.rate, f.base, round(f.bval, 2), round(f.exp, 2), round(f.ded, 2), round(f.ded - f.exp, 2),
         case when f.exp < 0.005 and f.ded < 0.005 then 'none'
              when abs(f.ded - f.exp) <= greatest(cfg.tolerance, f.exp * cfg.tolerance_pct / 100) then 'ok'
              when f.ded < f.exp then 'under' else 'over' end,
         ce.amount, coalesce(ce.claimed, false), ce.source, round(ce.amount - f.ded, 2),
         case when f.ded < 0.005 and coalesce(ce.amount, 0) < 0.005 then 'none'
              when ce.amount is null then case when current_date <= du.d then 'pending' else 'missing' end
              when abs(ce.amount - f.ded) <= greatest(cfg.tolerance, f.ded * cfg.tolerance_pct / 100) then 'ok'
              when ce.amount < f.ded then 'short' else 'excess' end,
         du.d, ti.operator_gstin, ti.operator_tan, f.nomatch::bigint,
         jsonb_build_object('excl_gross', case when f.g_excl > 0 then round(f.ded * 100 / f.g_excl, 3) end, 'excl_net', case when f.n_excl > 0 then round(f.ded * 100 / f.n_excl, 3) end,
                            'incl_gross', case when f.g_incl > 0 then round(f.ded * 100 / f.g_incl, 3) end, 'incl_net', case when f.n_incl > 0 then round(f.ded * 100 / f.n_incl, 3) end)
    from fin f
    join channels ch on ch.channel_id = f.ch
    left join marketplace_credit_entries ce on ce.kind = f.kind and ce.channel_id = f.ch and ce.month = f.mth
    left join marketplace_tax_ids ti on ti.channel_id = f.ch
    cross join lateral (select case when f.kind = 'gst_tcs' then (f.mth + interval '1 month' + interval '14 days')::date
        else (make_date(extract(year from f.mth)::int, ((extract(month from f.mth)::int - 1) / 3 * 3) + 1, 1) + case when extract(month from f.mth)::int <= 3 then interval '5 months' else interval '4 months' end - interval '1 day' + interval '15 days')::date end as d) du
   where f.mth >= v_from and f.mth <= p_to and (f.ded > 0 or f.exp > 0 or ce.amount is not null)
   order by f.mth desc, ch.name, f.kind;
end $$;

-- ---------------------------------------------------------------- work queue
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
having count(*) > 0 and has_accounting_view()
union all
select 'payroll-approve', 'Payroll', 'high', 'Payroll waiting for approval', count(*) || ' payroll run(s) are drafted and need a Finance Manager to approve them so salaries can be paid.',
       '/payroll', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from payroll_runs where status = 'draft' having count(*) > 0 and has_purchase_approve()
union all
select 'payroll-pay', 'Payroll', 'high', 'Approved payroll not yet paid', count(*) || ' approved run(s) are waiting for the salary payment to be recorded.',
       '/payroll', array['Accountant', 'Finance Manager']::text[], null, null, count(*)::int, min(approved_at)
from payroll_runs where status = 'approved' having count(*) > 0 and has_payroll_write()
union all
select 'payroll-start', 'Payroll', 'medium', 'This month''s payroll is not started', 'It is past the 25th and there is no payroll run for ' || to_char(current_date, 'Mon YYYY') || ' yet.',
       '/payroll', array['Accountant', 'Finance Manager']::text[], null, null, 1, date_trunc('month', current_date)
where extract(day from current_date) >= 25 and has_payroll_write() and exists (select 1 from employees where status = 'active')
  and not exists (select 1 from payroll_runs where month = date_trunc('month', current_date)::date and status <> 'cancelled')
union all
select 'jr-held', 'Accounting', 'high', 'Journal entries waiting for approval', count(*) || ' large entry(ies) are saved but not in the books until a manager approves them.',
       '/accounting/journal/review', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from journal_review where status = 'held' having count(*) > 0 and has_purchase_approve()
union all
select 'jr-pending', 'Accounting', case when min(due_on) < current_date then 'high' else 'medium' end, 'Journal entries to review', count(*) || ' risky entry(ies) need a check' || case when min(due_on) < current_date then ' (some are past the review deadline).' else '.' end,
       '/accounting/journal/review', array['Finance Manager']::text[], null, null, count(*)::int, min(created_at)
from journal_review where status = 'pending' and review_class = 'must' having count(*) > 0 and has_purchase_approve()
union all
select 'mtax-credit', 'Settlements', 'high', 'Marketplace tax credit missing or short', count(*) || ' month(s) where GST TCS or 194-O TDS deducted by a marketplace is not fully showing in your GST or 26AS data.',
       '/settlements/tax-credits', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, min(month)::timestamptz
from mtax_reconcile(current_date - 150, current_date) where credit_status in ('missing', 'short') having count(*) > 0 and has_mtax_write()
union all
select 'mtax-deduct', 'Settlements', 'medium', 'Marketplace tax deducted differs from the rate', count(*) || ' month(s) where the TCS or TDS held back is not what the rate gives.',
       '/settlements/tax-credits', array['Finance Manager', 'Accountant']::text[], null, null, count(*)::int, min(month)::timestamptz
from mtax_reconcile(current_date - 150, current_date) where deduct_status in ('under', 'over') having count(*) > 0 and has_mtax_write();

revoke execute on function has_mtax_write(), mtax_rule_save(text, numeric, text, date, text), mtax_settings_save(jsonb), mtax_ids_save(uuid, text, text, text),
  mtax_credit_set(text, uuid, date, numeric, numeric, text, boolean, text), mtax_rate_on(text, date), mtax_reconcile(date, date), imp_settlement(jsonb, boolean, jsonb) from public, anon, authenticated;
grant execute on function has_mtax_write(), mtax_rule_save(text, numeric, text, date, text), mtax_settings_save(jsonb), mtax_ids_save(uuid, text, text, text),
  mtax_credit_set(text, uuid, date, numeric, numeric, text, boolean, text), mtax_reconcile(date, date) to authenticated;
