-- 0070: Connection centre. One place where the Super Admin plugs in each client's own keys (marketplaces, courier, GST/e-invoice, WhatsApp, bank).
--
--   * connector_catalog: the providers we support and the fields each one needs (marked secret or not). Adding a provider = adding a row here
--     and, for live use, one adapter file in the app. The app never needs changing for a new client: they just fill in their keys.
--   * connector_instances: one connection per client account (e.g. "Amazon - Main"). Mode is DUMMY (sample data, no outside call, clearly marked)
--     or LIVE (real keys). Starts in DUMMY.
--   * connector_secrets: the keys. Nobody can read this table through the app; only the Super Admin functions below (and the server) can.
--     The screen only ever shows the last 4 characters.
--   * shipments, message_outbox, einvoice_records: where courier bookings, WhatsApp messages and e-invoice numbers are recorded, tagged dummy/live.
--   * Dummy data is always labelled (DUMMY- order ids, DUMMY-IRN-, mode = dummy) and can be wiped in one click before going live.

create table if not exists connector_catalog (
  code        text primary key,
  category    text not null check (category in ('marketplace', 'courier', 'gst', 'whatsapp', 'bank')),
  label       text not null,
  description text not null,
  fields      jsonb not null,            -- [{key,label,secret,required,help}]
  docs_url    text,
  sort        int not null default 100
);

create table if not exists connector_instances (
  instance_id    uuid primary key default gen_random_uuid(),
  connector_code text not null references connector_catalog(code),
  label          text not null,
  channel_id     uuid references channels(channel_id) on delete set null,   -- marketplace connections feed this channel
  mode           text not null default 'dummy' check (mode in ('dummy', 'live')),
  enabled        boolean not null default true,
  config         jsonb not null default '{}'::jsonb,                          -- non-secret settings (region, pickup pincode, ...)
  status         text not null default 'dummy' check (status in ('dummy', 'not_configured', 'ready', 'error')),
  last_sync_at   timestamptz,
  last_message   text,
  created_at     timestamptz not null default now(),
  created_by     uuid
);
create table if not exists connector_secrets (
  instance_id uuid not null references connector_instances(instance_id) on delete cascade,
  key         text not null,
  value       text not null,
  updated_at  timestamptz not null default now(),
  primary key (instance_id, key)
);
create table if not exists connector_log (
  log_id      uuid primary key default gen_random_uuid(),
  instance_id uuid references connector_instances(instance_id) on delete cascade,
  at          timestamptz not null default now(),
  kind        text not null,
  ok          boolean not null,
  message     text,
  by_user     uuid
);
create index if not exists connector_log_recent on connector_log (instance_id, at desc);

create table if not exists shipments (
  shipment_id  uuid primary key default gen_random_uuid(),
  order_id     uuid not null references orders(order_id) on delete cascade,
  instance_id  uuid references connector_instances(instance_id) on delete set null,
  mode         text not null check (mode in ('dummy', 'live')),
  courier      text,
  awb          text not null,
  status       text not null default 'booked',
  charge       numeric(12,2),
  events       jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (awb)
);
create table if not exists message_outbox (
  message_id   uuid primary key default gen_random_uuid(),
  instance_id  uuid references connector_instances(instance_id) on delete set null,
  mode         text not null check (mode in ('dummy', 'live')),
  to_phone     text not null,
  template     text not null,
  vars         jsonb not null default '{}'::jsonb,
  related_type text,
  related_id   uuid,
  status       text not null default 'queued' check (status in ('queued', 'sent', 'failed')),
  provider_ref text,
  error        text,
  created_at   timestamptz not null default now(),
  sent_at      timestamptz
);
create table if not exists einvoice_records (
  invoice_id   uuid primary key references invoices(invoice_id) on delete cascade,
  instance_id  uuid references connector_instances(instance_id) on delete set null,
  mode         text not null check (mode in ('dummy', 'live')),
  irn          text not null,
  ack_no       text,
  ack_date     timestamptz,
  qr_text      text,
  ewb_no       text,
  created_at   timestamptz not null default now()
);

alter table connector_catalog   enable row level security;
alter table connector_instances enable row level security;
alter table connector_secrets   enable row level security;
alter table connector_log       enable row level security;
alter table shipments           enable row level security;
alter table message_outbox      enable row level security;
alter table einvoice_records    enable row level security;

create or replace function is_super_admin() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() = 'Super Admin', false)
$$;
create or replace function connector_can_use(p_category text) returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Operations Manager', 'Marketplace Manager')
                  or (p_category in ('gst', 'bank') and current_role_name() in ('Finance Manager', 'Accountant')), false)
$$;

drop policy if exists "catalog read" on connector_catalog;   create policy "catalog read"   on connector_catalog   for select to authenticated using (auth.uid() is not null);
drop policy if exists "inst read" on connector_instances;    create policy "inst read"      on connector_instances for select to authenticated using (is_super_admin() or connector_can_use((select category from connector_catalog c where c.code = connector_code)));
drop policy if exists "clog read" on connector_log;          create policy "clog read"      on connector_log       for select to authenticated using (is_super_admin() or current_role_name() in ('Operations Manager', 'Finance Manager', 'CEO/Owner', 'Auditor'));
drop policy if exists "ship read" on shipments;              create policy "ship read"      on shipments           for select to authenticated using (has_orders_write() or current_role_name() in ('Warehouse Manager', 'CEO/Owner', 'Auditor', 'Finance Manager'));
drop policy if exists "outbox read" on message_outbox;       create policy "outbox read"    on message_outbox      for select to authenticated using (has_orders_write() or current_role_name() in ('CEO/Owner', 'Auditor', 'Finance Manager'));
drop policy if exists "einv read" on einvoice_records;       create policy "einv read"      on einvoice_records    for select to authenticated using (has_accounting_view());
-- connector_secrets: no policy and no grant = unreadable from the app
revoke all on connector_secrets from anon, authenticated;
grant select on connector_catalog, connector_instances, connector_log, shipments, message_outbox, einvoice_records to authenticated;

-- ---------------------------------------------------------------- the providers we know
insert into connector_catalog (code, category, label, description, sort, fields) values
('amazon_sp', 'marketplace', 'Amazon Seller Central (SP-API)', 'Pulls orders and settlement data from Amazon.', 10,
  '[{"key":"seller_id","label":"Seller ID","secret":false,"required":true},{"key":"marketplace_id","label":"Marketplace ID (India: A21TJRUUN4KGV)","secret":false,"required":true},
    {"key":"lwa_client_id","label":"LWA client ID","secret":false,"required":true},{"key":"lwa_client_secret","label":"LWA client secret","secret":true,"required":true},
    {"key":"refresh_token","label":"Refresh token","secret":true,"required":true}]'),
('flipkart', 'marketplace', 'Flipkart Seller Hub', 'Pulls orders and settlements from Flipkart.', 20,
  '[{"key":"application_id","label":"Application ID","secret":false,"required":true},{"key":"application_secret","label":"Application secret","secret":true,"required":true}]'),
('myntra', 'marketplace', 'Myntra Partner Portal', 'Pulls orders from Myntra.', 30,
  '[{"key":"partner_id","label":"Partner ID","secret":false,"required":true},{"key":"api_key","label":"API key","secret":true,"required":true}]'),
('meesho', 'marketplace', 'Meesho Supplier Panel', 'Pulls orders from Meesho.', 40,
  '[{"key":"supplier_id","label":"Supplier ID","secret":false,"required":true},{"key":"api_key","label":"API key","secret":true,"required":true}]'),
('shopify', 'marketplace', 'Shopify store', 'Orders arrive by webhook; this stores the store keys.', 50,
  '[{"key":"shop_domain","label":"Store domain (xyz.myshopify.com)","secret":false,"required":true},{"key":"access_token","label":"Admin API access token","secret":true,"required":true},{"key":"webhook_secret","label":"Webhook signing secret","secret":true,"required":true}]'),
('shiprocket', 'courier', 'Shiprocket', 'Courier rates, booking and tracking through one aggregator.', 10,
  '[{"key":"email","label":"Account email","secret":false,"required":true},{"key":"password","label":"API password","secret":true,"required":true}]'),
('delhivery', 'courier', 'Delhivery', 'Direct Delhivery booking and tracking.', 20,
  '[{"key":"api_token","label":"API token","secret":true,"required":true},{"key":"pickup_name","label":"Registered pickup name","secret":false,"required":true}]'),
('cleartax_einv', 'gst', 'ClearTax (e-invoice and e-way bill)', 'Generates the IRN, QR code and e-way bill.', 10,
  '[{"key":"gstin","label":"Seller GSTIN","secret":false,"required":true},{"key":"client_id","label":"Client ID","secret":false,"required":true},{"key":"client_secret","label":"Client secret","secret":true,"required":true},
    {"key":"portal_user","label":"GST portal API user","secret":false,"required":true},{"key":"portal_password","label":"GST portal API password","secret":true,"required":true}]'),
('mastergst', 'gst', 'MasterGST', 'Alternative provider for e-invoice and e-way bill.', 20,
  '[{"key":"gstin","label":"Seller GSTIN","secret":false,"required":true},{"key":"client_id","label":"Client ID","secret":false,"required":true},{"key":"client_secret","label":"Client secret","secret":true,"required":true},{"key":"email","label":"Registered email","secret":false,"required":true}]'),
('whatsapp_cloud', 'whatsapp', 'WhatsApp Business (Meta Cloud API)', 'Sends order, delivery and reminder messages.', 10,
  '[{"key":"phone_number_id","label":"Phone number ID","secret":false,"required":true},{"key":"waba_id","label":"Business account ID","secret":false,"required":true},{"key":"access_token","label":"Permanent access token","secret":true,"required":true}]'),
('bank_aa', 'bank', 'Bank statement feed (Account Aggregator)', 'Brings bank lines in daily for reconciliation.', 10,
  '[{"key":"client_id","label":"Client ID","secret":false,"required":true},{"key":"client_secret","label":"Client secret","secret":true,"required":true},{"key":"account_ref","label":"Account reference","secret":false,"required":false}]')
on conflict (code) do update set label = excluded.label, description = excluded.description, fields = excluded.fields, sort = excluded.sort;

-- ---------------------------------------------------------------- helpers
create or replace function connector_refresh_status(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i connector_instances%rowtype; v_missing int;
begin
  select * into i from connector_instances where instance_id = p_id;
  if not found then return; end if;
  if i.mode = 'dummy' then update connector_instances set status = 'dummy' where instance_id = p_id; return; end if;
  select count(*) into v_missing from connector_catalog c, jsonb_array_elements(c.fields) f
   where c.code = i.connector_code and coalesce((f ->> 'required')::boolean, false)
     and not exists (select 1 from connector_secrets s where s.instance_id = p_id and s.key = f ->> 'key' and s.value <> '')
     and not exists (select 1 from jsonb_each_text(i.config) cc where cc.key = f ->> 'key' and cc.value <> '');
  update connector_instances set status = case when v_missing > 0 then 'not_configured' else 'ready' end where instance_id = p_id;
end $$;

create or replace function connector_create(p_code text, p_label text, p_channel uuid default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not is_super_admin() then raise exception 'Only a Super Admin can add or change a connection'; end if;
  if not exists (select 1 from connector_catalog where code = p_code) then raise exception 'Unknown provider'; end if;
  if nullif(btrim(coalesce(p_label, '')), '') is null then raise exception 'Give the connection a name'; end if;
  insert into connector_instances (connector_code, label, channel_id, created_by) values (p_code, btrim(p_label), p_channel, auth.uid()) returning instance_id into v_id;
  insert into connector_log (instance_id, kind, ok, message, by_user) values (v_id, 'created', true, 'Connection added in dummy mode', auth.uid());
  return v_id;
end $$;

create or replace function connector_update(p_id uuid, p_label text, p_channel uuid, p_mode text, p_enabled boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old text;
begin
  if not is_super_admin() then raise exception 'Only a Super Admin can add or change a connection'; end if;
  if p_mode not in ('dummy', 'live') then raise exception 'Mode must be dummy or live'; end if;
  select mode into v_old from connector_instances where instance_id = p_id;
  if v_old is null then raise exception 'Connection not found'; end if;
  update connector_instances set label = coalesce(nullif(btrim(p_label), ''), label), channel_id = p_channel, mode = p_mode, enabled = p_enabled where instance_id = p_id;
  perform connector_refresh_status(p_id);
  if v_old <> p_mode then insert into connector_log (instance_id, kind, ok, message, by_user) values (p_id, 'mode', true, 'Mode changed from ' || v_old || ' to ' || p_mode, auth.uid()); end if;
end $$;

-- save keys: blank values keep the old key, so a screen that shows "••••1234" can be saved without retyping
create or replace function connector_save_secrets(p_id uuid, p_values jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e record; v_code text; f jsonb; v_secret boolean;
begin
  if not is_super_admin() then raise exception 'Only a Super Admin can add or change a connection'; end if;
  select connector_code into v_code from connector_instances where instance_id = p_id;
  if v_code is null then raise exception 'Connection not found'; end if;
  for e in select key, value from jsonb_each_text(coalesce(p_values, '{}'::jsonb)) loop
    select x into f from (select jsonb_array_elements(fields) x from connector_catalog where code = v_code) q where x ->> 'key' = e.key;
    if f is null then raise exception 'Field % does not belong to this provider', e.key; end if;
    if btrim(e.value) = '' then continue; end if;
    v_secret := coalesce((f ->> 'secret')::boolean, false);
    if v_secret then
      insert into connector_secrets (instance_id, key, value) values (p_id, e.key, btrim(e.value))
        on conflict (instance_id, key) do update set value = excluded.value, updated_at = now();
    else
      update connector_instances set config = config || jsonb_build_object(e.key, btrim(e.value)) where instance_id = p_id;
    end if;
  end loop;
  perform connector_refresh_status(p_id);
  insert into connector_log (instance_id, kind, ok, message, by_user) values (p_id, 'keys', true, 'Keys updated', auth.uid());
end $$;

-- what is filled in, never the key itself
create or replace function connector_key_status(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_code text; v_cfg jsonb; v_out jsonb := '{}'::jsonb; f jsonb; v text;
begin
  if not is_super_admin() then raise exception 'Only a Super Admin can see connection keys'; end if;
  select connector_code, config into v_code, v_cfg from connector_instances where instance_id = p_id;
  if v_code is null then raise exception 'Connection not found'; end if;
  for f in select jsonb_array_elements(fields) from connector_catalog where code = v_code loop
    if coalesce((f ->> 'secret')::boolean, false) then
      select value into v from connector_secrets where instance_id = p_id and key = f ->> 'key';
      v_out := v_out || jsonb_build_object(f ->> 'key', case when v is null then jsonb_build_object('set', false) else jsonb_build_object('set', true, 'tail', right(v, 4)) end);
    else
      v := v_cfg ->> (f ->> 'key');
      v_out := v_out || jsonb_build_object(f ->> 'key', jsonb_build_object('set', v is not null, 'value', v));
    end if;
  end loop;
  return v_out;
end $$;

-- the real keys, for the server to call a provider in LIVE mode
create or replace function connector_get_keys(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cfg jsonb; v_s jsonb;
begin
  if not (is_super_admin() or coalesce(auth.jwt() ->> 'role', '') = 'service_role') then raise exception 'Only a Super Admin can read connection keys'; end if;
  select config into v_cfg from connector_instances where instance_id = p_id;
  if v_cfg is null then raise exception 'Connection not found'; end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_s from connector_secrets where instance_id = p_id;
  return v_cfg || v_s;
end $$;

create or replace function connector_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not is_super_admin() then raise exception 'Only a Super Admin can add or change a connection'; end if;
  delete from connector_instances where instance_id = p_id;
end $$;

create or replace function connector_log_event(p_id uuid, p_kind text, p_ok boolean, p_message text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cat text;
begin
  select c.category into v_cat from connector_instances i join connector_catalog c on c.code = i.connector_code where i.instance_id = p_id;
  if v_cat is null then raise exception 'Connection not found'; end if;
  if not connector_can_use(v_cat) then raise exception 'Not authorized'; end if;
  insert into connector_log (instance_id, kind, ok, message, by_user) values (p_id, p_kind, p_ok, left(p_message, 500), auth.uid());
  update connector_instances set last_sync_at = now(), last_message = left(p_message, 300),
         status = case when not p_ok and mode = 'live' then 'error' else status end where instance_id = p_id;
  if p_ok then perform connector_refresh_status(p_id); end if;
end $$;

-- ---------------------------------------------------------------- records written by the adapters
create or replace function shipment_save(p_order uuid, p_instance uuid, p_mode text, p_courier text, p_awb text, p_status text, p_charge numeric, p_events jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not has_orders_write() then raise exception 'Only Operations or Marketplace roles can book a shipment'; end if;
  if p_mode not in ('dummy', 'live') then raise exception 'Bad mode'; end if;
  if nullif(btrim(coalesce(p_awb, '')), '') is null then raise exception 'The courier did not return a tracking number'; end if;
  insert into shipments (order_id, instance_id, mode, courier, awb, status, charge, events)
    values (p_order, p_instance, p_mode, p_courier, btrim(p_awb), coalesce(p_status, 'booked'), p_charge, coalesce(p_events, '[]'::jsonb))
    on conflict (awb) do update set status = excluded.status, events = excluded.events, updated_at = now()
    returning shipment_id into v_id;
  return v_id;
end $$;

create or replace function outbox_add(p_instance uuid, p_mode text, p_to text, p_template text, p_vars jsonb, p_type text, p_related uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_phone text := regexp_replace(coalesce(p_to, ''), '[^0-9+]', '', 'g');
begin
  if not has_orders_write() then raise exception 'Not authorized to send messages'; end if;
  if length(regexp_replace(v_phone, '\D', '', 'g')) < 10 then raise exception 'That phone number is not valid'; end if;
  insert into message_outbox (instance_id, mode, to_phone, template, vars, related_type, related_id)
    values (p_instance, p_mode, v_phone, p_template, coalesce(p_vars, '{}'::jsonb), p_type, p_related) returning message_id into v_id;
  return v_id;
end $$;
create or replace function outbox_mark(p_id uuid, p_status text, p_ref text, p_error text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_orders_write() then raise exception 'Not authorized'; end if;
  if p_status not in ('sent', 'failed') then raise exception 'Bad status'; end if;
  update message_outbox set status = p_status, provider_ref = p_ref, error = left(p_error, 300), sent_at = case when p_status = 'sent' then now() end where message_id = p_id;
end $$;

create or replace function einvoice_save(p_invoice uuid, p_instance uuid, p_mode text, p_irn text, p_ack_no text, p_ack_date timestamptz, p_qr text, p_ewb text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can register an e-invoice'; end if;
  if p_mode not in ('dummy', 'live') then raise exception 'Bad mode'; end if;
  if nullif(btrim(coalesce(p_irn, '')), '') is null then raise exception 'No IRN returned'; end if;
  if p_mode = 'live' and exists (select 1 from einvoice_records where invoice_id = p_invoice and mode = 'live') then raise exception 'This invoice already has a live IRN'; end if;
  insert into einvoice_records (invoice_id, instance_id, mode, irn, ack_no, ack_date, qr_text, ewb_no)
    values (p_invoice, p_instance, p_mode, p_irn, p_ack_no, p_ack_date, p_qr, p_ewb)
    on conflict (invoice_id) do update set instance_id = excluded.instance_id, mode = excluded.mode, irn = excluded.irn, ack_no = excluded.ack_no,
         ack_date = excluded.ack_date, qr_text = excluded.qr_text, ewb_no = excluded.ewb_no;
end $$;

-- ---------------------------------------------------------------- wipe the sample data before going live
create or replace function connector_clear_dummy() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ship int; v_msg int; v_ei int; v_ord int; v_kept int; o record;
begin
  if not is_super_admin() then raise exception 'Only a Super Admin can clear sample data'; end if;
  delete from shipments where mode = 'dummy'; get diagnostics v_ship = row_count;
  delete from message_outbox where mode = 'dummy'; get diagnostics v_msg = row_count;
  delete from einvoice_records where mode = 'dummy'; get diagnostics v_ei = row_count;
  v_ord := 0; v_kept := 0;
  for o in select order_id from orders where external_order_id like 'DUMMY-%' loop
    if exists (select 1 from invoices where order_id = o.order_id) or exists (select 1 from order_dispatch where order_id = o.order_id) then v_kept := v_kept + 1; continue; end if;
    delete from order_lines where order_id = o.order_id;
    delete from orders where order_id = o.order_id;
    v_ord := v_ord + 1;
  end loop;
  insert into connector_log (instance_id, kind, ok, message, by_user) values (null, 'clear_dummy', true,
    format('Removed %s sample orders, %s shipments, %s messages, %s e-invoices; kept %s sample orders that already have an invoice or stock-out', v_ord, v_ship, v_msg, v_ei, v_kept), auth.uid());
  return jsonb_build_object('orders', v_ord, 'shipments', v_ship, 'messages', v_msg, 'einvoices', v_ei, 'kept_orders', v_kept);
end $$;

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
    'connectors_manage', coalesce(current_role_name() = 'Super Admin', false),
    'automation_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager'), false),
    'uploads', import_can('products') or import_can('opening_stock') or import_can('listing_map') or import_can('ledger_opening') or import_can('orders')
  )
$$;

revoke execute on function connector_refresh_status(uuid), connector_create(text, text, uuid), connector_update(uuid, text, uuid, text, boolean), connector_save_secrets(uuid, jsonb),
  connector_key_status(uuid), connector_get_keys(uuid), connector_delete(uuid), connector_log_event(uuid, text, boolean, text),
  shipment_save(uuid, uuid, text, text, text, text, numeric, jsonb), outbox_add(uuid, text, text, text, jsonb, text, uuid), outbox_mark(uuid, text, text, text),
  einvoice_save(uuid, uuid, text, text, text, timestamptz, text, text), connector_clear_dummy(), is_super_admin(), connector_can_use(text), my_nav_access() from public, anon, authenticated;
grant execute on function connector_create(text, text, uuid), connector_update(uuid, text, uuid, text, boolean), connector_save_secrets(uuid, jsonb), connector_key_status(uuid),
  connector_get_keys(uuid), connector_delete(uuid), connector_log_event(uuid, text, boolean, text),
  shipment_save(uuid, uuid, text, text, text, text, numeric, jsonb), outbox_add(uuid, text, text, text, jsonb, text, uuid), outbox_mark(uuid, text, text, text),
  einvoice_save(uuid, uuid, text, text, text, timestamptz, text, text), connector_clear_dummy(), is_super_admin(), connector_can_use(text), my_nav_access() to authenticated;
grant execute on function connector_get_keys(uuid) to service_role;
