-- Rates & Compliance: one place where a Super Admin changes statutory rates without code, with a change log.
create or replace function has_rates_admin() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() = 'Super Admin', false)
$$;

-- ---------------------------------------------------------------- allowed GST slabs (were typed into several database functions)
create table if not exists gst_allowed_rates (
  rate    numeric(5,2) primary key check (rate >= 0 and rate <= 100),
  active  boolean not null default true,
  note    text
);
insert into gst_allowed_rates (rate) values (0), (0.25), (3), (5), (12), (18), (28), (40) on conflict do nothing;
alter table gst_allowed_rates enable row level security;
drop policy if exists "gar read" on gst_allowed_rates; create policy "gar read" on gst_allowed_rates for select to authenticated using (true);
grant select on gst_allowed_rates to authenticated;

create or replace function gst_slabs() returns numeric[] language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select array_agg(rate order by rate) from gst_allowed_rates where active), array[0, 0.25, 3, 5, 12, 18, 28, 40]::numeric[])
$$;

-- every existing function that carried the typed-in list now reads the table instead
do $$
declare r record; d text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prosrc like '%0.25, 3, 5, 12, 18, 28, 40%' and p.proname <> 'gst_slabs' loop
    d := pg_get_functiondef(r.oid);
    d := replace(d, 'array[0, 0.25, 3, 5, 12, 18, 28, 40]::numeric[]', 'gst_slabs()');
    d := replace(d, 'array[0, 0.25, 3, 5, 12, 18, 28, 40]', 'gst_slabs()');
    d := replace(d, 'is not one of 0, 0.25, 3, 5, 12, 18, 28, 40', 'is not an allowed GST slab (see Rates and Compliance)');
    d := replace(d, 'is not a GST slab (0, 0.25, 3, 5, 12, 18, 28 or 40)', 'is not an allowed GST slab (see Rates and Compliance)');
    if position('gst_slabs()' in d) > 0 and position(' immutable' in d) > 0 then d := replace(d, ' immutable', ' stable'); end if;
    execute d;
  end loop;
end $$;

create or replace function gst_slab_set(p_rate numeric, p_active boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_rates_admin() then raise exception 'Only a Super Admin can change GST slabs'; end if;
  if p_rate is null or p_rate < 0 or p_rate > 100 then raise exception 'A GST rate must be between 0 and 100'; end if;
  if p_active is false and (select count(*) from gst_allowed_rates where active and rate <> p_rate) = 0 then raise exception 'At least one GST slab must stay switched on'; end if;
  insert into gst_allowed_rates (rate, active, note) values (round(p_rate, 2), coalesce(p_active, true), nullif(btrim(coalesce(p_note, '')), ''))
  on conflict (rate) do update set active = excluded.active, note = excluded.note;
end $$;

-- ---------------------------------------------------------------- TDS: add a new section
create or replace function tds_section_add(p_section text, p_description text, p_rate numeric, p_single numeric, p_annual numeric, p_payment_code text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_rates_admin() then raise exception 'Only a Super Admin can add a TDS section'; end if;
  if btrim(coalesce(p_section, '')) = '' or btrim(coalesce(p_description, '')) = '' then raise exception 'Enter the section name and what it is for'; end if;
  if p_rate is null or p_rate < 0 or p_rate > 100 then raise exception 'Rate must be between 0 and 100'; end if;
  if (p_single is not null and p_single < 0) or (p_annual is not null and p_annual < 0) then raise exception 'Thresholds cannot be negative'; end if;
  if exists (select 1 from tds_sections where section = btrim(p_section)) then raise exception 'This section already exists. Edit it instead.'; end if;
  insert into tds_sections (section, description, rate, single_threshold, annual_threshold, payment_code) values (btrim(p_section), btrim(p_description), p_rate, p_single, p_annual, nullif(btrim(coalesce(p_payment_code, '')), ''));
end $$;

-- ---------------------------------------------------------------- salary income-tax slabs
create or replace function payroll_slab_save(p_slab uuid, p_from numeric, p_to numeric, p_rate numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_rates_admin() then raise exception 'Only a Super Admin can change tax slabs'; end if;
  if p_from is null or p_from < 0 or (p_to is not null and p_to <= p_from) or p_rate is null or p_rate < 0 or p_rate > 100 then raise exception 'Check the slab: the upper limit must be above the lower limit and the rate between 0 and 100'; end if;
  update payroll_tax_slabs set from_amt = p_from, to_amt = p_to, rate = p_rate where slab_id = p_slab;
  if not found then raise exception 'Slab not found'; end if;
end $$;

create or replace function payroll_slab_add(p_regime text, p_fy int, p_band text, p_from numeric, p_to numeric, p_rate numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_rates_admin() then raise exception 'Only a Super Admin can change tax slabs'; end if;
  if p_regime not in ('new', 'old') then raise exception 'Choose the new or old regime'; end if;
  if p_fy is null or p_fy < 2020 then raise exception 'Enter the financial year the slab starts from (2026 means April 2026)'; end if;
  if p_from is null or p_from < 0 or (p_to is not null and p_to <= p_from) or p_rate is null or p_rate < 0 or p_rate > 100 then raise exception 'Check the slab: the upper limit must be above the lower limit and the rate between 0 and 100'; end if;
  insert into payroll_tax_slabs (regime, fy_from, age_band, from_amt, to_amt, rate) values (p_regime, p_fy, coalesce(nullif(p_band, ''), 'all'), p_from, p_to, p_rate);
end $$;

create or replace function payroll_slab_delete(p_slab uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_rates_admin() then raise exception 'Only a Super Admin can change tax slabs'; end if;
  delete from payroll_tax_slabs where slab_id = p_slab;
end $$;

-- ---------------------------------------------------------------- change log: who changed which rate, from what to what
create table if not exists rate_change_log (
  log_id      uuid primary key default gen_random_uuid(),
  area        text not null,
  item        text,
  action      text not null,
  changes     jsonb,
  changed_by  uuid default auth.uid(),
  changed_by_name text,
  changed_at  timestamptz not null default now()
);
alter table rate_change_log enable row level security;
drop policy if exists "rcl read" on rate_change_log; create policy "rcl read" on rate_change_log for select to authenticated using (has_accounting_view() or has_rates_admin());
grant select on rate_change_log to authenticated;

create or replace function trg_rate_log() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare o jsonb; n jsonb; ch jsonb; k text; v_item text; v_name text;
begin
  select name into v_name from user_profiles where user_id = auth.uid();
  if tg_op = 'DELETE' then o := to_jsonb(old); n := null; v_item := o ->> tg_argv[1];
  elsif tg_op = 'INSERT' then o := null; n := to_jsonb(new); v_item := n ->> tg_argv[1];
  else o := to_jsonb(old); n := to_jsonb(new); v_item := n ->> tg_argv[1]; end if;
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(key, jsonb_build_object('from', o -> key, 'to', n -> key)) into ch from jsonb_object_keys(n) key where (o -> key) is distinct from (n -> key) and key not in ('updated_at', 'updated_by');
    if ch is null then return new; end if;
  else ch := coalesce(n, o); end if;
  insert into rate_change_log (area, item, action, changes, changed_by_name) values (tg_argv[0], v_item, lower(tg_op), ch, v_name);
  return coalesce(new, old);
end $$;

do $$
declare t record;
begin
  for t in select * from (values
    ('tds_sections', 'TDS section', 'section'), ('payroll_settings', 'Payroll rates', 'id'), ('payroll_exit_settings', 'Bonus, gratuity, leave', 'id'), ('payroll_tax_slabs', 'Salary tax slab', 'slab_id'),
    ('marketplace_tax_rules', 'Marketplace TCS / 194-O', 'kind'), ('marketplace_tax_settings', 'Marketplace TCS / 194-O settings', 'id'), ('gst_settings', 'GST settings', 'id'),
    ('gst_allowed_rates', 'GST slab', 'rate'), ('asset_categories', 'Depreciation', 'name'), ('statutory_settings', 'Statutory settings', 'id'), ('journal_policy', 'Journal review limits', 'id'),
    ('forecast_settings', 'Forecast settings', 'id')) as x(tbl, area, keycol)
  loop
    if to_regclass('public.' || t.tbl) is not null then
      execute format('drop trigger if exists trg_rate_log on %I', t.tbl);
      execute format('create trigger trg_rate_log after insert or update or delete on %I for each row execute function trg_rate_log(%L, %L)', t.tbl, t.area, t.keycol);
    end if;
  end loop;
end $$;

revoke execute on function has_rates_admin(), gst_slabs(), gst_slab_set(numeric, boolean, text), tds_section_add(text, text, numeric, numeric, numeric, text),
  payroll_slab_save(uuid, numeric, numeric, numeric), payroll_slab_add(text, int, text, numeric, numeric, numeric), payroll_slab_delete(uuid), trg_rate_log() from public, anon, authenticated;
grant execute on function has_rates_admin(), gst_slabs(), gst_slab_set(numeric, boolean, text), tds_section_add(text, text, numeric, numeric, numeric, text),
  payroll_slab_save(uuid, numeric, numeric, numeric), payroll_slab_add(text, int, text, numeric, numeric, numeric), payroll_slab_delete(uuid) to authenticated;
