-- 0067: One shared importer for Excel / CSV uploads, and the first six uploads that plug into it.
--
--   products        SKU master (size, colour, barcode, brand, HSN, GST %, cost, packing cost)
--   opening_stock   opening stock per SKU and warehouse
--   stock_count     stock adjustment / cycle count (counted quantity per SKU and warehouse)
--   listing_map     our SKU <-> marketplace SKU / listing id, per channel
--   ledger_opening  ledger opening balances (Tally trial balance)
--   orders          marketplace / website orders (replaces the old CSV-only import)
--
-- How it works
--   The browser reads the .xlsx / .csv into rows and calls import_run(kind, rows, apply := false) to PREVIEW: every row comes back as
--   OK / Warning / Error with a plain-language reason and what would happen (add / update / unchanged). Nothing is saved.
--   Calling it again with apply := true saves the rows that are not in error and writes an import log (who, when, which file, how many
--   rows added, updated, rejected). The original file is kept in the private "imports" bucket as proof.
--   The same function does the checking and the saving, so what the preview says is what the import does.
--   Re-uploading never duplicates: rows are matched on SKU, SKU + warehouse, channel + listing id, ledger name or channel + order id.
--   Who may upload follows who may do the same thing on screen (import_can).
--
-- Also here (gaps found while checking where uploads belong)
--   * create_financial_year(): creates the twelve monthly accounting periods of a financial year in one go.
--   * has_warehouse_scope(): the warehouse equivalent of has_channel_scope(), used by the stock uploads.
--   * products get separate size and colour columns.

-- ---------------------------------------------------------------- products: size and colour
alter table products add column if not exists size text;
alter table products add column if not exists colour text;

-- ---------------------------------------------------------------- scope helper for warehouse managers
create or replace function has_warehouse_scope(p_warehouse_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select coalesce(
    current_role_name() <> 'Warehouse Manager'
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = p_warehouse_id),
    false)
$$;

-- ---------------------------------------------------------------- the import log
create table if not exists import_runs (
  run_id       uuid primary key default gen_random_uuid(),
  kind         text not null,
  file_name    text,
  file_path    text,                       -- in the private "imports" bucket
  uploaded_by  uuid not null default auth.uid(),
  uploaded_at  timestamptz not null default now(),
  total_rows   int not null default 0,
  added        int not null default 0,
  updated      int not null default 0,
  unchanged    int not null default 0,
  warnings     int not null default 0,
  rejected     int not null default 0,
  options      jsonb not null default '{}'::jsonb
);
create index if not exists import_runs_kind on import_runs (kind, uploaded_at desc);

create table if not exists import_run_rows (
  run_id   uuid not null references import_runs(run_id) on delete cascade,
  row_no   int not null,
  status   text not null check (status in ('ok', 'warning', 'error')),
  action   text,
  message  text,
  primary key (run_id, row_no)
);

alter table import_runs enable row level security;
alter table import_run_rows enable row level security;
-- you see the log of the uploads you are allowed to make; Super Admin, CEO and Auditor see all
create or replace function import_can(p_kind text) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select coalesce(case p_kind
    when 'products'       then current_role_name() in ('Super Admin', 'Operations Manager')
    when 'opening_stock'  then current_role_name() in ('Super Admin', 'Operations Manager', 'Warehouse Manager')
    when 'stock_count'    then current_role_name() in ('Super Admin', 'Operations Manager', 'Warehouse Manager')
    when 'listing_map'    then current_role_name() in ('Super Admin', 'Operations Manager', 'Marketplace Manager')
    when 'ledger_opening' then has_accounting_write()
    when 'orders'         then has_orders_write()
    else false end, false)
$$;

drop policy if exists "import log read" on import_runs;
create policy "import log read" on import_runs for select to authenticated
  using (import_can(kind) or current_role_name() in ('Super Admin', 'CEO/Owner', 'Auditor'));
drop policy if exists "import log rows read" on import_run_rows;
create policy "import log rows read" on import_run_rows for select to authenticated
  using (exists (select 1 from import_runs r where r.run_id = import_run_rows.run_id));
grant select on import_runs, import_run_rows to authenticated;

-- ---------------------------------------------------------------- small parsing helpers
create or replace function imp_txt(r jsonb, k text) returns text language sql immutable as $$
  select nullif(btrim(coalesce(r ->> k, '')), '')
$$;
-- a number typed in a spreadsheet: allows commas, a rupee sign and a trailing %; returns null when it is not a number
create or replace function imp_num(p text) returns numeric language plpgsql immutable as $$
declare s text;
begin
  if p is null then return null; end if;
  s := regexp_replace(btrim(p), '[,₹%\s]|^Rs\.?', '', 'gi');
  if s ~ '^-?[0-9]+(\.[0-9]+)?$' then return s::numeric; end if;
  return null;
end $$;
create or replace function imp_res(p_row int, p_err text, p_warn text, p_action text) returns jsonb language sql immutable as $$
  select jsonb_build_object('row', p_row,
    'status', case when p_err is not null then 'error' when p_warn is not null then 'warning' else 'ok' end,
    'action', case when p_err is not null then 'rejected' else p_action end,
    'message', coalesce(p_err, p_warn))
$$;
create or replace function imp_join(a text, b text) returns text language sql immutable as $$
  select case when a is null then b when b is null then a else a || '. ' || b end
$$;

-- ---------------------------------------------------------------- 1. SKU master
create or replace function imp_products(p_rows jsonb, p_apply boolean, p_opt jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; i int; rn int; v_out jsonb := '[]'; v_co uuid;
  v_err text; v_warn text; v_act text;
  v_sku text; v_name text; v_size text; v_colour text; v_bar text; v_brand text; v_cat text; v_hsn text; v_status text;
  v_rate numeric; v_cost numeric; v_pack numeric; v_raw text;
  e products%rowtype; v_seen_sku text[] := '{}'; v_seen_bar text[] := '{}'; v_variant text;
begin
  select company_id into v_co from companies order by created_at limit 1;
  for i in 0 .. jsonb_array_length(p_rows) - 1 loop
    r := p_rows -> i; rn := coalesce(nullif(r ->> '_row', '')::int, i + 2);
    v_err := null; v_warn := null; v_act := null; e := null;
    v_sku := upper(imp_txt(r, 'sku')); v_name := imp_txt(r, 'name'); v_size := imp_txt(r, 'size'); v_colour := imp_txt(r, 'colour');
    v_bar := imp_txt(r, 'barcode'); v_brand := imp_txt(r, 'brand'); v_cat := imp_txt(r, 'category');
    v_hsn := regexp_replace(coalesce(imp_txt(r, 'hsn'), ''), '\.0+$', ''); v_hsn := nullif(v_hsn, '');
    v_status := lower(imp_txt(r, 'status'));
    v_rate := null; v_cost := null; v_pack := null;

    if v_sku is null then v_err := 'SKU is required';
    elsif v_sku = any (v_seen_sku) then v_err := 'SKU ' || v_sku || ' appears more than once in this file';
    end if;
    if v_sku is not null then v_seen_sku := v_seen_sku || v_sku; select * into e from products where company_id = v_co and sku = v_sku; end if;

    if v_err is null and v_bar is not null then
      if v_bar ~* '^[0-9.]+e\+?[0-9]+$' then v_err := 'Barcode ' || v_bar || ' was turned into a short number by Excel. Format the barcode column as Text and type it again';
      elsif v_bar = any (v_seen_bar) then v_err := 'Barcode ' || v_bar || ' is used on two rows of this file';
      elsif exists (select 1 from products p where p.company_id = v_co and p.barcode = v_bar and p.sku is distinct from v_sku) then
        v_err := 'Barcode ' || v_bar || ' already belongs to SKU ' || (select p.sku from products p where p.company_id = v_co and p.barcode = v_bar limit 1);
      end if;
      v_seen_bar := v_seen_bar || v_bar;
    end if;

    if v_err is null and imp_txt(r, 'gst_rate') is not null then
      v_rate := imp_num(imp_txt(r, 'gst_rate'));
      if v_rate is null then v_err := 'GST % "' || imp_txt(r, 'gst_rate') || '" is not a number';
      elsif v_rate > 0 and v_rate < 1 and imp_txt(r, 'gst_rate') !~ '%' and v_rate not in (0.25) then v_rate := v_rate * 100;   -- 0.05 typed for 5%
      end if;
      if v_err is null and not gst_rate_known(v_rate) then v_err := 'GST % ' || v_rate || ' is not a GST slab (0, 0.25, 3, 5, 12, 18, 28 or 40)'; end if;
    end if;
    if v_err is null and imp_txt(r, 'cost_price') is not null then
      v_cost := imp_num(imp_txt(r, 'cost_price'));
      if v_cost is null or v_cost < 0 then v_err := 'Cost price "' || imp_txt(r, 'cost_price') || '" must be a number, zero or more'; end if;
    end if;
    if v_err is null and imp_txt(r, 'packing_cost') is not null then
      v_pack := imp_num(imp_txt(r, 'packing_cost'));
      if v_pack is null or v_pack < 0 then v_err := 'Packing cost "' || imp_txt(r, 'packing_cost') || '" must be a number, zero or more'; end if;
    end if;
    if v_err is null and v_status is not null and v_status not in ('active', 'inactive', 'discontinued') then
      v_err := 'Status "' || v_status || '" must be active, inactive or discontinued';
    end if;
    if v_err is null and e.product_id is null and v_name is null then v_err := 'Name is required for a new SKU'; end if;
    if v_err is null and v_hsn is not null and v_hsn !~ '^[0-9]{4}([0-9]{2}([0-9]{2})?)?$' then v_warn := 'HSN ' || v_hsn || ' should be 4, 6 or 8 digits'; end if;

    if v_err is null then
      if e.product_id is null then
        v_act := 'add';
        if v_hsn is null then v_warn := imp_join(v_warn, 'No HSN code: GSTR-1 will flag this SKU'); end if;
        if v_rate is null then v_warn := imp_join(v_warn, 'No GST %: GSTR-1 will flag this SKU'); end if;
        if v_cost is null then v_warn := imp_join(v_warn, 'No cost price: margins will not show'); end if;
      else
        if (coalesce(v_name, e.name), coalesce(v_size, e.size), coalesce(v_colour, e.colour), coalesce(v_bar, e.barcode), coalesce(v_brand, e.brand),
            coalesce(v_cat, e.category), coalesce(v_hsn, e.hsn), coalesce(v_rate, e.gst_rate), coalesce(v_cost, e.cost_price),
            coalesce(v_pack, e.packaging_cost), coalesce(v_status, e.status))
           is not distinct from (e.name, e.size, e.colour, e.barcode, e.brand, e.category, e.hsn, e.gst_rate, e.cost_price, e.packaging_cost, e.status)
        then v_act := 'unchanged'; else v_act := 'update'; end if;
      end if;

      if p_apply and v_act in ('add', 'update') then
        begin
          v_variant := nullif(concat_ws(' / ', coalesce(v_size, e.size), coalesce(v_colour, e.colour)), '');
          if e.product_id is null then
            insert into products (company_id, sku, name, size, colour, variant, barcode, brand, category, hsn, gst_rate, cost_price, packaging_cost, status)
            values (v_co, v_sku, v_name, v_size, v_colour, v_variant, v_bar, v_brand, v_cat, v_hsn, v_rate, v_cost, v_pack, coalesce(v_status, 'active'));
          else
            update products set name = coalesce(v_name, name), size = coalesce(v_size, size), colour = coalesce(v_colour, colour),
                   variant = coalesce(v_variant, variant), barcode = coalesce(v_bar, barcode), brand = coalesce(v_brand, brand),
                   category = coalesce(v_cat, category), hsn = coalesce(v_hsn, hsn), gst_rate = coalesce(v_rate, gst_rate),
                   cost_price = coalesce(v_cost, cost_price), packaging_cost = coalesce(v_pack, packaging_cost), status = coalesce(v_status, status)
             where product_id = e.product_id;
          end if;
        exception when others then v_err := sqlerrm;
        end;
      end if;
    end if;
    v_out := v_out || imp_res(rn, v_err, v_warn, v_act);
  end loop;
  return jsonb_build_object('rows', v_out);
end $$;

-- ---------------------------------------------------------------- 2 and 3. opening stock and stock count
create or replace function imp_stock(p_rows jsonb, p_apply boolean, p_opt jsonb, p_mode text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; i int; rn int; v_out jsonb := '[]'; v_err text; v_warn text; v_act text;
  v_sku text; v_wname text; v_pid uuid; v_wid uuid; v_qty numeric; v_cur numeric; v_delta numeric; v_seen text[] := '{}';
  v_has_initial boolean; v_has_other boolean; v_key text; v_run uuid := nullif(p_opt ->> 'run_id', '')::uuid; v_pstatus text;
  v_qkey text := case when p_mode = 'opening' then 'quantity' else 'counted_quantity' end;
begin
  for i in 0 .. jsonb_array_length(p_rows) - 1 loop
    r := p_rows -> i; rn := coalesce(nullif(r ->> '_row', '')::int, i + 2);
    v_err := null; v_warn := null; v_act := null; v_pid := null; v_wid := null; v_qty := null;
    v_sku := upper(imp_txt(r, 'sku')); v_wname := imp_txt(r, 'warehouse');
    if v_sku is null then v_err := 'SKU is required';
    elsif v_wname is null then v_err := 'Warehouse is required';
    else
      select product_id, status into v_pid, v_pstatus from products where sku = v_sku;
      select warehouse_id into v_wid from warehouses where lower(name) = lower(v_wname);
      if v_pid is null then v_err := 'SKU ' || v_sku || ' not found. Add it in Admin > Products or upload the SKU master first';
      elsif v_wid is null then v_err := 'Warehouse "' || v_wname || '" not found. Use the name exactly as in Admin > Warehouses';
      elsif not has_warehouse_scope(v_wid) then v_err := 'You are not assigned to warehouse ' || v_wname;
      else
        v_key := v_pid::text || '/' || v_wid::text;
        if v_key = any (v_seen) then v_err := 'SKU ' || v_sku || ' is listed twice for ' || v_wname || ' in this file'; end if;
        v_seen := v_seen || v_key;
      end if;
    end if;
    if v_err is null then
      if imp_txt(r, v_qkey) is null then v_err := case when p_mode = 'opening' then 'Quantity is required' else 'Counted quantity is required' end;
      else
        v_qty := imp_num(imp_txt(r, v_qkey));
        if v_qty is null then v_err := 'Quantity "' || imp_txt(r, v_qkey) || '" is not a number';
        elsif v_qty < 0 then v_err := 'Quantity cannot be negative';
        elsif v_qty > 1000000 then v_err := 'Quantity ' || v_qty || ' looks too large. Check the column';
        end if;
      end if;
    end if;

    if v_err is null then
      select coalesce((select quantity from inventory_balances where product_id = v_pid and warehouse_id = v_wid), 0) into v_cur;
      select exists (select 1 from inventory_transactions where product_id = v_pid and warehouse_id = v_wid and movement_type = 'initial_stock'),
             exists (select 1 from inventory_transactions where product_id = v_pid and warehouse_id = v_wid and movement_type not in ('initial_stock', 'adjustment'))
        into v_has_initial, v_has_other;
      v_delta := v_qty - v_cur;
      if v_pstatus <> 'active' then v_warn := 'SKU ' || v_sku || ' is ' || v_pstatus; end if;
      if p_mode = 'opening' and v_has_other then
        v_err := 'SKU ' || v_sku || ' already has sales or returns in ' || v_wname || '. Use the stock count upload to correct stock now';
      elsif v_delta = 0 then v_act := 'unchanged';
      else
        v_act := case when p_mode = 'opening' and not v_has_initial then 'add' else 'update' end;
        if p_mode = 'count' and v_cur > 0 and abs(v_delta) > 0.25 * v_cur and abs(v_delta) >= 5 then
          v_warn := imp_join(v_warn, 'Count is ' || v_qty || ' against ' || v_cur || ' in the system (' || case when v_delta > 0 then '+' else '' end || v_delta || '). Recount if this is not expected');
        end if;
        if p_apply then
          begin
            perform record_inventory_movement(v_pid, v_wid, case when p_mode = 'opening' and not v_has_initial then 'initial_stock' else 'adjustment' end,
                                              v_delta, case when p_mode = 'opening' then 'opening_stock_import' else 'stock_count_import' end, v_run);
          exception when others then v_err := sqlerrm;
          end;
        end if;
      end if;
    end if;
    v_out := v_out || imp_res(rn, v_err, v_warn, v_act);
  end loop;
  return jsonb_build_object('rows', v_out);
end $$;

-- ---------------------------------------------------------------- 4. marketplace listing map
create or replace function imp_listing_map(p_rows jsonb, p_apply boolean, p_opt jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; i int; rn int; v_out jsonb := '[]'; v_err text; v_warn text; v_act text;
  v_ch text; v_cid uuid; v_sku text; v_pid uuid; v_lid text; v_csku text; v_st text; v_seen text[] := '{}'; e channel_sku_map%rowtype;
begin
  for i in 0 .. jsonb_array_length(p_rows) - 1 loop
    r := p_rows -> i; rn := coalesce(nullif(r ->> '_row', '')::int, i + 2);
    v_err := null; v_warn := null; v_act := null; v_cid := null; v_pid := null; e := null;
    v_ch := imp_txt(r, 'channel'); v_sku := upper(imp_txt(r, 'sku')); v_lid := imp_txt(r, 'listing_id'); v_csku := imp_txt(r, 'channel_sku');
    v_st := coalesce(lower(imp_txt(r, 'status')), 'active');
    if v_ch is null then v_err := 'Channel is required';
    elsif v_sku is null then v_err := 'Our SKU is required';
    elsif v_lid is null then v_err := 'Listing id (ASIN / FSN / style id) is required';
    else
      select channel_id into v_cid from channels where lower(name) = lower(v_ch);
      select product_id into v_pid from products where sku = v_sku;
      if v_cid is null then v_err := 'Channel "' || v_ch || '" not found. Use the name exactly as in Admin > Channels';
      elsif not has_channel_scope(v_cid) then v_err := 'You are not assigned to channel ' || v_ch;
      elsif v_pid is null then v_err := 'SKU ' || v_sku || ' not found. Add it in Admin > Products or upload the SKU master first';
      elsif v_st not in ('active', 'inactive') then v_err := 'Status "' || v_st || '" must be active or inactive';
      elsif v_lid ~* '^[0-9.]+e\+?[0-9]+$' then v_err := 'Listing id ' || v_lid || ' was turned into a short number by Excel. Format the column as Text and type it again';
      elsif (v_cid::text || '/' || v_lid) = any (v_seen) then v_err := 'Listing id ' || v_lid || ' appears twice for ' || v_ch || ' in this file';
      end if;
    end if;
    if v_err is null then
      v_seen := v_seen || (v_cid::text || '/' || v_lid);
      select * into e from channel_sku_map where channel_id = v_cid and listing_id = v_lid;
      if e.mapping_id is null then v_act := 'add';
      elsif (e.product_id, e.channel_sku, e.status) is not distinct from (v_pid, coalesce(v_csku, e.channel_sku), v_st) then v_act := 'unchanged';
      else
        v_act := 'update';
        if e.product_id <> v_pid then v_warn := 'Listing ' || v_lid || ' was linked to SKU ' || (select sku from products where product_id = e.product_id) || ' and will now point to ' || v_sku; end if;
      end if;
      if p_apply and v_act in ('add', 'update') then
        begin
          if e.mapping_id is null then
            insert into channel_sku_map (product_id, channel_id, channel_sku, listing_id, status) values (v_pid, v_cid, v_csku, v_lid, v_st);
          else
            update channel_sku_map set product_id = v_pid, channel_sku = coalesce(v_csku, channel_sku), status = v_st where mapping_id = e.mapping_id;
          end if;
        exception when others then v_err := sqlerrm;
        end;
      end if;
    end if;
    v_out := v_out || imp_res(rn, v_err, v_warn, v_act);
  end loop;
  return jsonb_build_object('rows', v_out);
end $$;

-- ---------------------------------------------------------------- 5. ledger opening balances
-- Loaded all at once: the file must balance (debits = credits) and have no errors, otherwise nothing is saved.
create or replace function imp_ledger_opening(p_rows jsonb, p_apply boolean, p_opt jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; i int; rn int; v_out jsonb := '[]'; v_err text; v_warn text; v_act text; v_ferr text;
  v_name text; v_lid uuid; v_grp text; v_dr numeric; v_cr numeric; v_amt numeric; v_type text; l ledgers%rowtype;
  v_seen text[] := '{}'; v_fy text := nullif(btrim(coalesce(p_opt ->> 'financial_year', '')), '');
  v_errors int := 0; v_total numeric; v_closed int;
  v_ids uuid[] := '{}'; v_amts numeric[] := '{}'; v_types text[] := '{}'; k int;
begin
  if v_fy is null then select financial_year_id into v_fy from accounting_periods order by start_date limit 1; end if;
  if v_fy is null then v_fy := 'FY' || to_char(current_date, 'YYYY'); end if;
  select count(*) into v_closed from accounting_periods where status in ('closed', 'locked');

  for i in 0 .. jsonb_array_length(p_rows) - 1 loop
    r := p_rows -> i; rn := coalesce(nullif(r ->> '_row', '')::int, i + 2);
    v_err := null; v_warn := null; v_act := null; v_lid := null; v_dr := 0; v_cr := 0; l := null;
    v_name := imp_txt(r, 'ledger');
    if v_name is null then v_err := 'Ledger name is required';
    elsif lower(v_name) = any (v_seen) then v_err := 'Ledger "' || v_name || '" appears twice in this file';
    else
      v_seen := v_seen || lower(v_name);
      select * into l from ledgers where lower(name) = lower(v_name);
      if l.ledger_id is null then v_err := 'Ledger "' || v_name || '" not found. Create it in Accounting > Ledgers first, or fix the spelling';
      else select g.name into v_grp from account_groups g where g.account_group_id = l.account_group_id; end if;
    end if;
    if v_err is null then
      if v_grp = 'Sundry Creditors' then v_err := '"' || v_name || '" is the supplier control account. Enter supplier opening balances in Purchases > Bills > Opening balances';
      elsif l.name = 'Opening Balance Equity' then v_err := '"Opening Balance Equity" is the system balancing ledger and is not loaded from a file';
      end if;
    end if;
    if v_err is null then
      if imp_txt(r, 'debit') is not null then v_dr := imp_num(imp_txt(r, 'debit')); end if;
      if imp_txt(r, 'credit') is not null then v_cr := imp_num(imp_txt(r, 'credit')); end if;
      if (imp_txt(r, 'debit') is not null and v_dr is null) or (imp_txt(r, 'credit') is not null and v_cr is null) then v_err := 'Debit and credit must be numbers';
      elsif v_dr < 0 or v_cr < 0 then v_err := 'Debit and credit cannot be negative. Put the amount in the other column instead';
      elsif v_dr > 0 and v_cr > 0 then v_err := 'A ledger has either a debit or a credit balance, not both';
      end if;
    end if;
    if v_err is null then
      v_amt := round(greatest(v_dr, v_cr), 2); v_type := case when v_amt = 0 then null when v_dr > 0 then 'debit' else 'credit' end;
      if (l.opening_balance, l.opening_balance_type) is not distinct from (v_amt, v_type) or (l.opening_balance = 0 and v_amt = 0) then v_act := 'unchanged';
      elsif l.opening_balance = 0 then v_act := 'add'; else v_act := 'update'; end if;
      v_ids := v_ids || l.ledger_id; v_amts := v_amts || v_amt; v_types := v_types || coalesce(v_type, '');
    else v_errors := v_errors + 1; end if;
    v_out := v_out || imp_res(rn, v_err, v_warn, v_act);
  end loop;

  -- does the book balance once this file is applied? (ledgers not in the file keep what they have)
  select coalesce(sum(case when t.ty = 'debit' then t.am when t.ty = 'credit' then -t.am else 0 end), 0) into v_total from (
    select o.opening_balance am, o.opening_balance_type ty from ledgers o where o.ledger_id <> all (v_ids)
    union all select a, ty from unnest(v_amts, v_types) as u(a, ty)) t;
  if v_errors > 0 then v_ferr := 'Fix the rows in error first. Opening balances are loaded together so that debits equal credits, and nothing is saved until the whole file is clean';
  elsif jsonb_array_length(p_rows) = 0 then v_ferr := 'The file has no rows';
  elsif abs(v_total) > 0.005 then
    v_ferr := 'Debits and credits do not match: ' || case when v_total > 0 then 'debits are higher by ' else 'credits are higher by ' end || abs(v_total)
              || '. Check that every ledger of the trial balance is in the file';
  end if;
  if v_ferr is null and v_closed > 0 then
    v_out := v_out || jsonb_build_object('row', 0, 'status', 'warning', 'action', null,
      'message', v_closed || ' accounting period(s) are already closed or locked. Loading opening balances changes their figures');
  end if;

  if p_apply and v_ferr is null then
    for k in 1 .. coalesce(array_length(v_ids, 1), 0) loop
      update ledgers set opening_balance = v_amts[k], opening_balance_type = nullif(v_types[k], '') where ledger_id = v_ids[k];
      delete from opening_balances where ledger_id = v_ids[k] and financial_year_id = v_fy;
      if v_amts[k] > 0 then
        insert into opening_balances (financial_year_id, ledger_id, amount, balance_type, source, approved_by)
        values (v_fy, v_ids[k], v_amts[k], v_types[k], 'import', auth.uid());
      end if;
    end loop;
  end if;
  return jsonb_build_object('rows', v_out, 'file_error', v_ferr);
end $$;

-- ---------------------------------------------------------------- 9. orders
create or replace function imp_orders(p_rows jsonb, p_apply boolean, p_opt jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r jsonb; i int; rn int; v_cid uuid := nullif(p_opt ->> 'channel_id', '')::uuid; v_cname text;
  v_p jsonb := '[]'; v_o jsonb; v_out jsonb := '[]'; g record; q record;
  v_err text; v_warn text; v_oid text; v_pid uuid; v_sku text; v_qty numeric; v_price numeric; v_disc numeric; v_tax numeric;
  v_date timestamptz; v_state text; v_scode text; v_gstin text; v_pt text; v_fs text; v_ps text; v_ref text; v_raw text;
  v_order uuid; v_gross numeric; v_dtot numeric; v_ttot numeric; v_exist orders%rowtype; v_gact text; v_gmsg text; v_gerr text;
  v_grp jsonb := '{}'; v_has_err boolean; v_first int;
begin
  if v_cid is null then raise exception 'Choose the channel these orders belong to'; end if;
  select name into v_cname from channels where channel_id = v_cid;
  if v_cname is null then raise exception 'Channel not found'; end if;
  if not has_channel_scope(v_cid) then raise exception 'You are not assigned to channel %', v_cname; end if;

  -- pass 1: check each row
  for i in 0 .. jsonb_array_length(p_rows) - 1 loop
    r := p_rows -> i; rn := coalesce(nullif(r ->> '_row', '')::int, i + 2);
    v_err := null; v_warn := null; v_pid := null; v_date := null; v_state := null; v_scode := null; v_gstin := null;
    v_oid := imp_txt(r, 'external_order_id'); v_sku := upper(imp_txt(r, 'sku'));
    v_qty := null; v_price := 0; v_disc := 0; v_tax := 0;
    if v_oid is null then v_err := 'Order id is required';
    elsif v_oid ~* '^[0-9.]+e\+?[0-9]+$' then v_err := 'Order id ' || v_oid || ' was turned into a short number by Excel. Format the column as Text and download the report again';
    elsif v_sku is null then v_err := 'SKU is required';
    else
      select product_id into v_pid from products where sku = v_sku;
      if v_pid is null then v_err := 'SKU ' || v_sku || ' not found. Add it in Admin > Products or upload the SKU master first (the channel listing map can also be used)'; end if;
    end if;
    if v_err is null then
      v_qty := coalesce(imp_num(imp_txt(r, 'quantity')), case when imp_txt(r, 'quantity') is null then 1 end);
      if v_qty is null or v_qty <= 0 then v_err := 'Quantity must be a number above zero';
      elsif v_qty <> trunc(v_qty) then v_err := 'Quantity must be a whole number';
      end if;
    end if;
    if v_err is null then
      if imp_txt(r, 'unit_price') is not null then v_price := imp_num(imp_txt(r, 'unit_price')); end if;
      if imp_txt(r, 'discount') is not null then v_disc := imp_num(imp_txt(r, 'discount')); end if;
      if imp_txt(r, 'tax') is not null then v_tax := imp_num(imp_txt(r, 'tax')); end if;
      if v_price is null or v_disc is null or v_tax is null or v_price < 0 or v_disc < 0 or v_tax < 0 then
        v_err := 'Unit price, discount and tax must be numbers, zero or more';
      end if;
    end if;
    if v_err is null then
      v_raw := imp_txt(r, 'order_date');
      if v_raw is null then v_date := now(); v_warn := 'No order date: today is used';
      else begin v_date := v_raw::timestamptz; exception when others then v_err := 'Order date "' || v_raw || '" is not a date. Use DD-MM-YYYY or YYYY-MM-DD'; end;
      end if;
    end if;
    if v_err is null then
      v_state := imp_txt(r, 'ship_to_state');
      if v_state is not null then
        v_scode := gst_state_code(v_state);
        if v_scode is null then
          if v_tax > 0 then v_err := 'Ship-to state "' || v_state || '" is not a state name. Fix the spelling; the GST split depends on it'; else v_warn := imp_join(v_warn, 'Ship-to state "' || v_state || '" is not recognised'); end if;
        else v_state := (select name from gst_states where code = v_scode); end if;
      elsif v_tax > 0 then v_err := 'Ship-to state is missing. It is needed to split the GST into CGST+SGST or IGST';
      else v_warn := imp_join(v_warn, 'No ship-to state'); end if;
    end if;
    if v_err is null then
      v_gstin := upper(imp_txt(r, 'customer_gstin'));
      if v_gstin is not null and not gstin_valid(v_gstin) then v_err := 'Customer GSTIN ' || v_gstin || ' is not valid'; end if;
    end if;
    v_pt := lower(imp_txt(r, 'payment_type')); v_fs := coalesce(lower(imp_txt(r, 'fulfilment_status')), 'pending'); v_ps := coalesce(lower(imp_txt(r, 'payment_status')), 'pending');
    if v_err is null and v_pt is not null and v_pt not in ('prepaid', 'cod') then v_err := 'Payment type "' || v_pt || '" must be prepaid or cod'; end if;
    if v_err is null and v_fs not in ('pending', 'processing', 'shipped', 'delivered', 'cancelled', 'rto') then v_err := 'Fulfilment status "' || v_fs || '" must be pending, processing, shipped, delivered, cancelled or rto'; end if;
    if v_err is null and v_ps not in ('pending', 'paid', 'partially_paid', 'refunded', 'failed') then v_err := 'Payment status "' || v_ps || '" must be pending, paid, partially_paid, refunded or failed'; end if;
    v_p := v_p || jsonb_build_object('rno', rn, 'oid', v_oid, 'err', v_err, 'warn', v_warn, 'pid', v_pid, 'qty', v_qty, 'price', v_price, 'disc', v_disc,
        'tax', v_tax, 'odate', v_date, 'state', v_state, 'scode', v_scode, 'gstin', v_gstin, 'ref', imp_txt(r, 'customer_ref'), 'pt', v_pt, 'fs', v_fs, 'ps', v_ps);
  end loop;

  -- pass 2: one decision per order (all its lines are in or all are out)
  for g in select x.oid, bool_or(x.err is not null) as has_err, min(x.rno) as first_row,
                  (array_agg(x.rno order by x.rno) filter (where x.err is not null))[1] as err_row
             from jsonb_to_recordset(v_p) as x(oid text, rno int, err text) where x.oid is not null group by x.oid loop
    v_gact := null; v_gmsg := null; v_gerr := null;
    if g.has_err then
      v_gerr := 'Order ' || g.oid || ' not imported because row ' || g.err_row || ' has an error';
    else
      select * into v_exist from orders where channel_id = v_cid and external_order_id = g.oid;
      if v_exist.order_id is not null then
        -- an existing order is never rewritten; a missing state / GSTIN is filled in so that GST can be worked out
        select q2.state, q2.gstin into q from (select (array_agg(x.state) filter (where x.state is not null))[1] state, (array_agg(x.gstin) filter (where x.gstin is not null))[1] gstin
              from jsonb_to_recordset(v_p) as x(oid text, state text, gstin text) where x.oid = g.oid) q2;
        if (v_exist.ship_to_state is null and q.state is not null) or (v_exist.customer_gstin is null and q.gstin is not null) then
          v_gact := 'update'; v_gmsg := 'Order already exists. Lines are left as they are; the missing state / GSTIN was filled in';
          if p_apply then update orders set ship_to_state = coalesce(ship_to_state, q.state), customer_gstin = coalesce(customer_gstin, q.gstin) where order_id = v_exist.order_id; end if;
        else v_gact := 'unchanged'; v_gmsg := 'Order already imported. Skipped, nothing changes'; end if;
      else
        v_gact := 'add';
        if p_apply then
          begin
            select min(x.odate), sum(x.qty * x.price), sum(x.disc), sum(x.tax) into v_date, v_gross, v_dtot, v_ttot
              from jsonb_to_recordset(v_p) as x(oid text, odate timestamptz, qty numeric, price numeric, disc numeric, tax numeric) where x.oid = g.oid;
            select (array_agg(x.state) filter (where x.state is not null))[1], (array_agg(x.gstin) filter (where x.gstin is not null))[1],
                   (array_agg(x.ref) filter (where x.ref is not null))[1], (array_agg(x.pt) filter (where x.pt is not null))[1], (array_agg(x.fs))[1], (array_agg(x.ps))[1]
              into v_state, v_gstin, v_ref, v_pt, v_fs, v_ps
              from jsonb_to_recordset(v_p) as x(oid text, state text, gstin text, ref text, pt text, fs text, ps text) where x.oid = g.oid;
            insert into orders (channel_id, external_order_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount,
                                fulfilment_status, payment_status, ship_to_state, customer_gstin)
            values (v_cid, g.oid, v_date, v_ref, v_pt, v_gross, v_dtot, v_ttot, v_gross - v_dtot + v_ttot, v_fs, v_ps, v_state, v_gstin)
            returning order_id into v_order;
            -- the same SKU twice in one order becomes one line
            insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)
            select v_order, x.pid, sum(x.qty), (array_agg(x.price order by x.rno desc))[1], sum(x.disc), sum(x.tax)
              from jsonb_to_recordset(v_p) as x(oid text, rno int, pid uuid, qty numeric, price numeric, disc numeric, tax numeric) where x.oid = g.oid group by x.pid;
          exception when others then v_gerr := 'Order ' || g.oid || ': ' || sqlerrm; v_gact := null;
          end;
        end if;
      end if;
    end if;
    v_grp := v_grp || jsonb_build_object(g.oid, jsonb_build_object('act', v_gact, 'msg', v_gmsg, 'err', v_gerr));
  end loop;

  -- results, row by row
  for i in 0 .. jsonb_array_length(v_p) - 1 loop
    v_o := v_p -> i;
    if v_o ->> 'err' is not null then v_out := v_out || imp_res((v_o ->> 'rno')::int, v_o ->> 'err', null, null);
    elsif v_o ->> 'oid' is null then null;
    else
      v_out := v_out || imp_res((v_o ->> 'rno')::int, (v_grp -> (v_o ->> 'oid')) ->> 'err',
                                imp_join(v_o ->> 'warn', (v_grp -> (v_o ->> 'oid')) ->> 'msg'),
                                (v_grp -> (v_o ->> 'oid')) ->> 'act');
    end if;
  end loop;
  return jsonb_build_object('rows', v_out);
end $$;

-- ---------------------------------------------------------------- the entry point: preview (p_apply false) or import (p_apply true)
create or replace function import_run(p_kind text, p_rows jsonb, p_apply boolean default false, p_options jsonb default '{}'::jsonb,
                                      p_file_name text default null, p_file_path text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_run uuid; v_res jsonb; v_rows jsonb; v_ferr text; v_opt jsonb := coalesce(p_options, '{}'::jsonb);
  v_add int; v_upd int; v_same int; v_warn int; v_rej int; v_total int;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not import_can(p_kind) then raise exception 'Your role cannot upload this kind of file'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'No rows received'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'A file can have up to 5000 rows. Split it and upload in parts'; end if;
  if p_file_path is not null and p_file_path not like auth.uid()::text || '/%' then raise exception 'File path is not in your folder'; end if;

  if p_apply then
    insert into import_runs (kind, file_name, file_path, options) values (p_kind, left(p_file_name, 200), p_file_path, v_opt) returning run_id into v_run;
    v_opt := v_opt || jsonb_build_object('run_id', v_run);
  end if;

  v_res := case p_kind
    when 'products'       then imp_products(p_rows, p_apply, v_opt)
    when 'opening_stock'  then imp_stock(p_rows, p_apply, v_opt, 'opening')
    when 'stock_count'    then imp_stock(p_rows, p_apply, v_opt, 'count')
    when 'listing_map'    then imp_listing_map(p_rows, p_apply, v_opt)
    when 'ledger_opening' then imp_ledger_opening(p_rows, p_apply, v_opt)
    when 'orders'         then imp_orders(p_rows, p_apply, v_opt)
    else null end;
  if v_res is null then raise exception 'Unknown upload type'; end if;
  v_rows := v_res -> 'rows'; v_ferr := v_res ->> 'file_error';

  select count(*) filter (where e ->> 'action' = 'add'), count(*) filter (where e ->> 'action' = 'update'), count(*) filter (where e ->> 'action' = 'unchanged'),
         count(*) filter (where e ->> 'status' = 'warning' and (e ->> 'row')::int > 0), count(*) filter (where e ->> 'status' = 'error' and (e ->> 'row')::int > 0), count(*) filter (where (e ->> 'row')::int > 0)
    into v_add, v_upd, v_same, v_warn, v_rej, v_total from jsonb_array_elements(v_rows) e;

  if p_apply then
    -- a file-level problem (for example opening balances that do not balance) means nothing was saved
    if v_ferr is not null then v_add := 0; v_upd := 0; v_same := 0; end if;
    update import_runs set total_rows = v_total, added = v_add, updated = v_upd, unchanged = v_same, warnings = v_warn,
           rejected = case when v_ferr is not null then v_total else v_rej end where run_id = v_run;
    insert into import_run_rows (run_id, row_no, status, action, message)
    select v_run, (e ->> 'row')::int, e ->> 'status', e ->> 'action', e ->> 'message' from jsonb_array_elements(v_rows) e
     where e ->> 'status' <> 'ok' or e ->> 'action' is not null on conflict do nothing;
  end if;
  return jsonb_build_object('run_id', v_run, 'applied', p_apply and v_ferr is null, 'file_error', v_ferr, 'rows', v_rows,
    'summary', jsonb_build_object('total', v_total, 'added', v_add, 'updated', v_upd, 'unchanged', v_same, 'warnings', v_warn, 'errors', v_rej));
end $$;

-- ---------------------------------------------------------------- create the financial year (gap: periods were only ever seeded)
create or replace function create_financial_year(p_start_year int) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_fy text; m int; v_start date; v_end date; v_made int := 0; v_name text;
begin
  if not has_accounting_write() then raise exception 'Only a Super Admin, Finance Manager or Accountant can create accounting periods'; end if;
  if p_start_year is null or p_start_year < 2020 or p_start_year > 2100 then raise exception 'Enter a year such as 2026 for FY 2026-27'; end if;
  v_fy := 'FY' || p_start_year || '-' || lpad(((p_start_year + 1) % 100)::text, 2, '0');
  for m in 0 .. 11 loop
    v_start := (make_date(p_start_year, 4, 1) + (m || ' months')::interval)::date;
    v_end := (v_start + interval '1 month - 1 day')::date;
    v_name := to_char(v_start, 'Mon YYYY');
    -- a month that already has a period (whatever it is called) is left alone
    if exists (select 1 from accounting_periods where start_date = v_start) then continue; end if;
    insert into accounting_periods (financial_year_id, period_name, start_date, end_date, status) values (v_fy, v_name, v_start, v_end, 'open');
    v_made := v_made + 1;
  end loop;
  return jsonb_build_object('financial_year', v_fy, 'created', v_made, 'already_there', 12 - v_made);
end $$;

-- ---------------------------------------------------------------- the left menu follows the same rules as the data
-- One call returns which parts of the app the signed-in person (or the role being previewed) may use. Each flag is computed from the very same
-- helper functions the row-level security uses, so a menu item can never show for a screen that would come up empty, or hide for one that works.
create or replace function my_nav_access() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'all', true,
    'accounting_view', has_accounting_view(),
    'accounting_write', has_accounting_write(),
    'bankcod_view', has_bankcod_view(),
    'settlements_view', has_settlements_view(),
    'returns_view', has_returns_view(),
    'claims_view', has_claims_view(),
    'tax_view', has_tax_view(),
    'gst_view', has_gst_view(),
    'inventory_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Claims Manager',
                                                          'Marketplace Manager', 'Auditor', 'Warehouse Manager'), false),
    'users_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner'), false),
    'roles_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Auditor'), false),
    'audit_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Auditor'), false),
    'integrations_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager'), false),
    'channels_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Marketplace Manager', 'Auditor'), false),
    'warehouses_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager', 'Warehouse Manager', 'Auditor'), false),
    'uploads', import_can('products') or import_can('opening_stock') or import_can('listing_map') or import_can('ledger_opening') or import_can('orders')
  )
$$;
revoke execute on function my_nav_access() from public, anon;
grant execute on function my_nav_access() to authenticated;

-- ---------------------------------------------------------------- the private bucket that keeps the original files
do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise notice 'storage schema not present - skipping bucket setup';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('imports', 'imports', false, 10485760,
          array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'text/csv', 'application/vnd.ms-excel', 'application/csv', 'text/plain'])
  on conflict (id) do update set public = false, file_size_limit = 10485760,
    allowed_mime_types = array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'text/csv', 'application/vnd.ms-excel', 'application/csv', 'text/plain'];
  execute 'drop policy if exists "imports upload" on storage.objects';
  execute 'drop policy if exists "imports read" on storage.objects';
  execute $p$create policy "imports upload" on storage.objects for insert to authenticated
    with check (bucket_id = 'imports' and (storage.foldername(name))[1] = auth.uid()::text
                and (public.import_can('products') or public.import_can('opening_stock') or public.import_can('listing_map')
                     or public.import_can('ledger_opening') or public.import_can('orders')))$p$;
  execute $p$create policy "imports read" on storage.objects for select to authenticated
    using (bucket_id = 'imports' and ((storage.foldername(name))[1] = auth.uid()::text
           or public.current_role_name() in ('Super Admin', 'CEO/Owner', 'Auditor')))$p$;
end $$;

-- ---------------------------------------------------------------- who can call what
revoke execute on function imp_txt(jsonb, text), imp_num(text), imp_res(int, text, text, text), imp_join(text, text),
  imp_products(jsonb, boolean, jsonb), imp_stock(jsonb, boolean, jsonb, text), imp_listing_map(jsonb, boolean, jsonb),
  imp_ledger_opening(jsonb, boolean, jsonb), imp_orders(jsonb, boolean, jsonb), import_run(text, jsonb, boolean, jsonb, text, text),
  create_financial_year(int), import_can(text), has_warehouse_scope(uuid) from public, anon, authenticated;
grant execute on function import_run(text, jsonb, boolean, jsonb, text, text), create_financial_year(int), import_can(text), has_warehouse_scope(uuid) to authenticated;
