-- 0050: Rule-driven journal entries (the "rule book").
--
-- Idea (same mental model as QuickBooks "bank rules", extended to every business event):
--   * the app raises an EVENT (return accepted, RTO received, COD remitted, bank line imported ...)
--   * the engine hands the event's facts ("context") to the active RULES in priority order
--   * a rule = conditions (field / operator / value) + a journal template (debit and credit lines)
--   * first matching rule wins (or keeps going, if the rule says "stop on match = no")
--   * the rule either posts the voucher or leaves it as a DRAFT for a human to approve (review queue)
-- A 10-year CA's defaults ship as system rules (0051); admins can edit, disable, clone or add rules.
-- Posted vouchers stay immutable - editing a rule only changes FUTURE entries.

create sequence if not exists journal_voucher_seq;

create or replace function has_rulebook_edit() returns boolean
language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin','Finance Manager'), false)
$$;

-- The original journal_rules table was an empty skeleton (text columns, never read by the app).
drop table if exists journal_rules cascade;

create table journal_event_types (
  event_type   text primary key,
  label        text not null,
  description  text,
  trigger_text text,
  source_type  text not null,
  pack         text not null default 'core',
  sample_ctx   jsonb not null default '{}'::jsonb,
  sort_order   int not null default 100
);

create table journal_event_fields (
  event_type  text not null references journal_event_types(event_type) on delete cascade,
  field       text not null,
  label       text not null,
  data_type   text not null check (data_type in ('text','number','boolean','date')),
  description text,
  primary key (event_type, field)
);

create table journal_rules (
  journal_rule_id    uuid primary key default gen_random_uuid(),
  rule_code          text not null unique,
  name               text not null,
  description        text,
  notes              text,                       -- the CA's reasoning, shown in the editor
  rule_group         text not null,
  pack               text not null default 'core' check (pack in ('core','inventory_cogs','custom')),
  event_type         text not null references journal_event_types(event_type),
  action             text not null default 'post' check (action in ('post','ignore')),
  voucher_type_code  text not null default 'JOURNAL',
  match_mode         text not null default 'all' check (match_mode in ('all','any')),
  priority           int  not null default 100,
  stop_on_match      boolean not null default true,
  auto_post          boolean not null default true,
  gst_rate_pct       numeric(5,2) check (gst_rate_pct is null or (gst_rate_pct >= 0 and gst_rate_pct <= 100)),
  narration_template text,
  effective_from     date not null default date '2000-01-01',
  effective_to       date,
  status             text not null default 'active' check (status in ('active','inactive')),
  is_system          boolean not null default false,
  default_definition jsonb,
  version            int not null default 1,
  created_by         uuid,
  updated_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index on journal_rules (event_type, status, priority);

create table journal_rule_conditions (
  condition_id    uuid primary key default gen_random_uuid(),
  journal_rule_id uuid not null references journal_rules(journal_rule_id) on delete cascade,
  sort_order      int not null default 0,
  field           text not null,
  operator        text not null check (operator in
    ('equals','not_equals','contains','not_contains','contains_any','starts_with','ends_with',
     'in','not_in','regex','gt','gte','lt','lte','between','is_empty','is_not_empty')),
  value           text
);
create index on journal_rule_conditions (journal_rule_id);

create table journal_rule_lines (
  line_id         uuid primary key default gen_random_uuid(),
  journal_rule_id uuid not null references journal_rules(journal_rule_id) on delete cascade,
  sort_order      int not null default 0,
  side            text not null check (side in ('debit','credit')),
  ledger_id       uuid references ledgers(ledger_id),
  ledger_role     text check (ledger_role in ('bank')),
  amount_source   text not null default 'amount',
  percent         numeric(7,3) not null default 100 check (percent >= 0),
  fixed_amount    numeric(14,2) check (fixed_amount is null or fixed_amount >= 0),
  narration       text,
  check (ledger_id is not null or ledger_role is not null)
);
create index on journal_rule_lines (journal_rule_id);

create table journal_rule_log (
  log_id          uuid primary key default gen_random_uuid(),
  journal_rule_id uuid references journal_rules(journal_rule_id) on delete set null,
  rule_code       text,
  event_type      text not null,
  source_type     text,
  source_id       uuid,
  dedupe_key      text,
  status          text not null check (status in ('posted','draft','ignored','skipped','error','discarded')),
  voucher_id      uuid references vouchers(voucher_id) on delete set null,
  message         text,
  context         jsonb,
  created_by      uuid,
  created_at      timestamptz not null default now()
);
create index on journal_rule_log (created_at desc);
create index on journal_rule_log (status);
create index on journal_rule_log (voucher_id);
create index on journal_rule_log (rule_code, dedupe_key);

create table journal_rule_history (
  history_id      uuid primary key default gen_random_uuid(),
  journal_rule_id uuid not null references journal_rules(journal_rule_id) on delete cascade,
  version         int not null,
  snapshot        jsonb not null,
  change_note     text,
  changed_by      uuid,
  changed_at      timestamptz not null default now()
);
create index on journal_rule_history (journal_rule_id, version desc);

-- ---------------------------------------------------------------- RLS
alter table journal_event_types      enable row level security;
alter table journal_event_fields     enable row level security;
alter table journal_rules            enable row level security;
alter table journal_rule_conditions  enable row level security;
alter table journal_rule_lines       enable row level security;
alter table journal_rule_log         enable row level security;
alter table journal_rule_history     enable row level security;

create policy "rulebook view" on journal_event_types     for select to authenticated using (has_accounting_view());
create policy "rulebook view" on journal_event_fields    for select to authenticated using (has_accounting_view());
create policy "rulebook view" on journal_rules           for select to authenticated using (has_accounting_view());
create policy "rulebook view" on journal_rule_conditions for select to authenticated using (has_accounting_view());
create policy "rulebook view" on journal_rule_lines      for select to authenticated using (has_accounting_view());
create policy "rulebook view" on journal_rule_log        for select to authenticated using (has_accounting_view());
create policy "rulebook view" on journal_rule_history    for select to authenticated using (has_accounting_view());
-- All writes to rules go through save_journal_rule() / helpers below (SECURITY DEFINER, role-checked),
-- so no direct write policies are granted.

revoke all on journal_event_types, journal_event_fields, journal_rules, journal_rule_conditions,
              journal_rule_lines, journal_rule_log, journal_rule_history from anon;
revoke insert, update, delete on journal_event_types, journal_event_fields, journal_rules, journal_rule_conditions,
              journal_rule_lines, journal_rule_log, journal_rule_history from authenticated;

-- bank lines posted through the rule engine are tracked as their own match type
alter table bank_transactions drop constraint if exists bank_transactions_matched_entity_check;
alter table bank_transactions add constraint bank_transactions_matched_entity_check
  check (matched_entity is null or matched_entity = any (array['settlement','cod','order','journal_rule']));

-- ---------------------------------------------------------------- small helpers
create or replace function jr_num(p_ctx jsonb, p_field text) returns numeric
language plpgsql immutable set search_path = public, pg_temp as $$
begin
  return coalesce((p_ctx ->> p_field)::numeric, 0);
exception when others then
  return 0;
end $$;

create or replace function jr_render(p_template text, p_ctx jsonb) returns text
language plpgsql immutable set search_path = public, pg_temp as $$
declare v_out text := coalesce(p_template, ''); k text; v text;
begin
  for k, v in select key, value from jsonb_each_text(coalesce(p_ctx, '{}'::jsonb)) loop
    v_out := replace(v_out, '{' || k || '}', coalesce(v, ''));
  end loop;
  return v_out;
end $$;

create or replace function jr_cond_ok(p_ctx jsonb, p_field text, p_op text, p_val text) returns boolean
language plpgsql immutable set search_path = public, pg_temp as $$
declare
  v text := p_ctx ->> p_field;
  lv text := lower(coalesce(p_ctx ->> p_field, ''));
  lval text := lower(coalesce(p_val, ''));
  a numeric; b numeric;
begin
  if p_op = 'is_empty'     then return v is null or btrim(v) = ''; end if;
  if p_op = 'is_not_empty' then return v is not null and btrim(v) <> ''; end if;
  if p_op = 'equals'       then return lv = lval; end if;
  if p_op = 'not_equals'   then return lv <> lval; end if;
  if p_op = 'contains'     then return lval <> '' and position(lval in lv) > 0; end if;
  if p_op = 'not_contains' then return lval = '' or position(lval in lv) = 0; end if;
  if p_op = 'starts_with'  then return left(lv, length(lval)) = lval; end if;
  if p_op = 'ends_with'    then return right(lv, length(lval)) = lval; end if;
  if p_op = 'contains_any' then
    return exists (select 1 from unnest(string_to_array(lval, '|')) t
                   where btrim(t) <> '' and position(btrim(t) in lv) > 0);
  end if;
  if p_op = 'in'     then return exists (select 1 from unnest(string_to_array(lval, '|')) t where btrim(t) = lv); end if;
  if p_op = 'not_in' then return not exists (select 1 from unnest(string_to_array(lval, '|')) t where btrim(t) = lv); end if;
  if p_op = 'regex'  then
    begin
      return coalesce(v, '') ~* coalesce(p_val, '');
    exception when others then
      return false;
    end;
  end if;
  begin
    a := v::numeric;
    if p_op = 'gt'  then return a >  p_val::numeric; end if;
    if p_op = 'gte' then return a >= p_val::numeric; end if;
    if p_op = 'lt'  then return a <  p_val::numeric; end if;
    if p_op = 'lte' then return a <= p_val::numeric; end if;
    if p_op = 'between' then
      a := v::numeric;
      b := split_part(p_val, '|', 1)::numeric;
      return a >= b and a <= split_part(p_val, '|', 2)::numeric;
    end if;
  exception when others then
    return false;
  end;
  return false;
end $$;

create or replace function jr_bank_ledger(p_ctx jsonb) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  begin
    select ledger_id into v_id from bank_accounts where bank_account_id = (p_ctx ->> 'bank_account_id')::uuid;
  exception when others then v_id := null;
  end;
  if v_id is null then
    select ledger_id into v_id from bank_accounts where status = 'active' and ledger_id is not null order by created_at limit 1;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------- context builders (facts the rules can test)
create or replace function jr_order_ctx(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  o orders%rowtype; v_ch channels%rowtype; v_inv invoices%rowtype;
  v_state text; v_amount numeric; v_tax numeric; v_inter boolean; v_cg numeric; v_sg numeric; v_ig numeric;
begin
  select * into o from orders where order_id = p_order_id;
  if not found then return '{}'::jsonb; end if;
  select * into v_ch from channels where channel_id = o.channel_id;
  select * into v_inv from invoices where order_id = p_order_id limit 1;
  select state into v_state from companies limit 1;
  v_amount := coalesce(v_inv.total, o.net_amount);
  v_tax    := coalesce(v_inv.gst_amount, o.tax_amount);
  v_inter  := v_tax > 0 and o.ship_to_state is distinct from v_state;
  v_cg := case when v_tax = 0 or v_inter then 0 else round(v_tax / 2, 2) end;
  v_sg := case when v_tax = 0 or v_inter then 0 else v_tax - v_cg end;
  v_ig := case when v_inter then v_tax else 0 end;
  return jsonb_build_object(
    'order_id', o.order_id, 'order_ref', o.external_order_id,
    'channel', v_ch.name, 'channel_type', v_ch.type, 'payment_type', o.payment_type,
    'ship_state', o.ship_to_state, 'interstate', v_inter,
    'amount', v_amount, 'taxable', v_amount - v_tax, 'tax', v_tax, 'cgst', v_cg, 'sgst', v_sg, 'igst', v_ig,
    'has_invoice', v_inv.invoice_id is not null, 'invoice_id', v_inv.invoice_id,
    'already_credited', exists (select 1 from credit_notes cn join invoices ii using (invoice_id)
                                where ii.order_id = p_order_id and cn.status <> 'cancelled')
  );
end $$;

create or replace function jr_order_cogs(p_order_id uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(ol.quantity * coalesce(p.cost_price, 0)), 0)
  from order_lines ol left join products p on p.product_id = ol.product_id
  where ol.order_id = p_order_id
$$;

-- ---------------------------------------------------------------- evaluation (no side effects)
create or replace function jr_evaluate(p_event text, p_ctx jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  r journal_rules%rowtype;
  l record;
  v_date date := coalesce(nullif(p_ctx ->> 'date', '')::date, current_date);
  v_ctx jsonb; v_matched boolean; v_has_cond boolean;
  v_out jsonb := '[]'::jsonb; v_lines jsonb; v_amt numeric; v_d numeric; v_c numeric;
  v_ledger uuid; v_rem_side text; v_rem_ledger uuid; v_rem_narr text; v_err text;
  v_base numeric; v_amount numeric;
begin
  for r in select * from journal_rules
           where event_type = p_event and status = 'active'
             and effective_from <= v_date and (effective_to is null or effective_to >= v_date)
           order by priority, created_at loop

    select count(*) > 0 into v_has_cond from journal_rule_conditions where journal_rule_id = r.journal_rule_id;
    if not v_has_cond then
      v_matched := true;
    elsif r.match_mode = 'all' then
      v_matched := not exists (select 1 from journal_rule_conditions c where c.journal_rule_id = r.journal_rule_id
                               and not jr_cond_ok(p_ctx, c.field, c.operator, c.value));
    else
      v_matched := exists (select 1 from journal_rule_conditions c where c.journal_rule_id = r.journal_rule_id
                           and jr_cond_ok(p_ctx, c.field, c.operator, c.value));
    end if;
    continue when not v_matched;

    -- GST-inclusive split for bank rules (base + tax), e.g. a 18% courier bill
    v_ctx := p_ctx;
    if p_ctx ? 'amount' then
      v_amount := jr_num(p_ctx, 'amount');
      if coalesce(r.gst_rate_pct, 0) > 0 then
        v_base := round(v_amount * 100 / (100 + r.gst_rate_pct), 2);
        v_ctx := v_ctx || jsonb_build_object('base', v_base, 'tax', v_amount - v_base,
                  'cgst', round((v_amount - v_base) / 2, 2), 'sgst', (v_amount - v_base) - round((v_amount - v_base) / 2, 2));
      elsif not (p_ctx ? 'base') then
        v_ctx := v_ctx || jsonb_build_object('base', v_amount);
      end if;
    end if;

    v_lines := '[]'::jsonb; v_d := 0; v_c := 0; v_rem_side := null; v_err := null;
    if r.action = 'post' then
      for l in select * from journal_rule_lines where journal_rule_id = r.journal_rule_id order by sort_order, line_id loop
        v_ledger := coalesce(l.ledger_id, case when l.ledger_role = 'bank' then jr_bank_ledger(v_ctx) end);
        if v_ledger is null then v_err := 'A line has no ledger (no bank account is set up)'; continue; end if;
        if l.amount_source = 'remainder' then
          v_rem_side := l.side; v_rem_ledger := v_ledger; v_rem_narr := l.narration; continue;
        end if;
        v_amt := case when l.amount_source = 'fixed' then coalesce(l.fixed_amount, 0)
                      else round(jr_num(v_ctx, l.amount_source) * l.percent / 100, 2) end;
        if v_amt < 0.005 then continue; end if;
        v_lines := v_lines || jsonb_build_object('side', l.side, 'ledger_id', v_ledger,
                     'ledger_name', (select name from ledgers where ledger_id = v_ledger),
                     'amount', v_amt, 'narration', jr_render(l.narration, v_ctx));
        if l.side = 'debit' then v_d := v_d + v_amt; else v_c := v_c + v_amt; end if;
      end loop;
      if v_rem_side is not null then
        v_amt := case when v_rem_side = 'debit' then v_c - v_d else v_d - v_c end;
        if v_amt >= 0.005 then
          v_lines := v_lines || jsonb_build_object('side', v_rem_side, 'ledger_id', v_rem_ledger,
                       'ledger_name', (select name from ledgers where ledger_id = v_rem_ledger),
                       'amount', v_amt, 'narration', jr_render(v_rem_narr, v_ctx));
          if v_rem_side = 'debit' then v_d := v_d + v_amt; else v_c := v_c + v_amt; end if;
        end if;
      end if;
      -- a rule whose amounts all come to zero is not a real match - let a later rule try
      continue when jsonb_array_length(v_lines) = 0 and v_err is null;
    end if;

    v_out := v_out || jsonb_build_object(
      'journal_rule_id', r.journal_rule_id, 'rule_code', r.rule_code, 'name', r.name,
      'action', r.action, 'voucher_type_code', r.voucher_type_code, 'auto_post', r.auto_post,
      'balanced', abs(v_d - v_c) < 0.005, 'total', greatest(v_d, v_c), 'lines', v_lines, 'error', v_err,
      'narration', jr_render(coalesce(r.narration_template, r.name), v_ctx), 'stop', r.stop_on_match);
    exit when r.stop_on_match;
  end loop;
  return v_out;
end $$;

-- ---------------------------------------------------------------- posting
create or replace function post_journal_event(
  p_event text, p_source_type text, p_source_id uuid, p_ctx jsonb, p_dedupe text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_results jsonb; res jsonb; ln jsonb;
  v_date date := coalesce(nullif(p_ctx ->> 'date', '')::date, current_date);
  v_period uuid; v_vt uuid; v_prefix text; v_vid uuid; v_status text; v_no text; v_rule uuid;
  v_out jsonb := '[]'::jsonb; v_tot numeric;
begin
  if not exists (select 1 from journal_rules where event_type = p_event and status = 'active') then
    return jsonb_build_object('skipped', 'no active rule for this event');
  end if;

  -- credit-note style events: nothing to do if already credited / never invoiced
  if p_event in ('return.accepted', 'rto.received', 'order.cancelled') then
    if p_ctx ->> 'already_credited' = 'true' then
      return jsonb_build_object('skipped', 'a credit note already exists for this invoice');
    end if;
    if p_ctx ->> 'has_invoice' = 'false' then
      insert into journal_rule_log (event_type, source_type, source_id, dedupe_key, status, message, context, created_by)
      values (p_event, p_source_type, p_source_id, p_dedupe, 'skipped', 'The order was never invoiced, so there is no sale to reverse.', p_ctx, auth.uid());
      return jsonb_build_object('skipped', 'order never invoiced');
    end if;
  end if;

  v_results := jr_evaluate(p_event, p_ctx);
  if jsonb_array_length(v_results) = 0 then
    insert into journal_rule_log (event_type, source_type, source_id, dedupe_key, status, message, context, created_by)
    values (p_event, p_source_type, p_source_id, p_dedupe, 'skipped',
            'No active rule matched this event - nothing was posted. Add or adjust a rule in the Rule Book.', p_ctx, auth.uid());
    return jsonb_build_object('skipped', 'no rule matched');
  end if;

  for res in select * from jsonb_array_elements(v_results) loop
    v_rule := (res ->> 'journal_rule_id')::uuid;

    if exists (select 1 from journal_rule_log
               where rule_code = res ->> 'rule_code' and dedupe_key = p_dedupe and status in ('posted','draft','ignored')) then
      continue;  -- this exact event was already handled by this rule
    end if;

    if res ->> 'action' = 'ignore' then
      insert into journal_rule_log (journal_rule_id, rule_code, event_type, source_type, source_id, dedupe_key, status, message, context, created_by)
      values (v_rule, res ->> 'rule_code', p_event, p_source_type, p_source_id, p_dedupe, 'ignored',
              'Ignored by rule: ' || (res ->> 'name'), p_ctx, auth.uid());
      continue;
    end if;

    if res ->> 'error' is not null then
      raise exception 'Rule % cannot post: %', res ->> 'rule_code', res ->> 'error';
    end if;
    if not (res ->> 'balanced')::boolean then
      raise exception 'Rule % does not balance (debits <> credits) for this event - fix the rule''s amounts', res ->> 'rule_code';
    end if;

    select accounting_period_id into v_period from accounting_periods
      where v_date between start_date and end_date and status = 'open' limit 1;
    if v_period is null then
      raise exception 'No open accounting period covers %', v_date;
    end if;
    select voucher_type_id, numbering_prefix into v_vt, v_prefix from voucher_types where code = res ->> 'voucher_type_code';
    if v_vt is null then raise exception 'Voucher type % does not exist', res ->> 'voucher_type_code'; end if;

    v_tot := (res ->> 'total')::numeric;
    v_no := v_prefix || '-' || to_char(v_date, 'YYMM') || '-' || lpad(nextval('journal_voucher_seq')::text, 6, '0');
    v_status := case when (res ->> 'auto_post')::boolean then 'posted' else 'draft' end;

    insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, source_type, source_id,
                          narration, total_debit, total_credit, created_by)
    values (v_vt, v_no, v_date, v_period, 'draft', p_source_type, p_source_id, res ->> 'narration', v_tot, v_tot, auth.uid())
    returning voucher_id into v_vid;

    for ln in select * from jsonb_array_elements(res -> 'lines') loop
      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id, narration)
      values (v_vid, (ln ->> 'ledger_id')::uuid,
              case when ln ->> 'side' = 'debit'  then (ln ->> 'amount')::numeric else 0 end,
              case when ln ->> 'side' = 'credit' then (ln ->> 'amount')::numeric else 0 end,
              p_source_type, p_source_id, nullif(ln ->> 'narration', ''));
    end loop;

    -- credit-note events also create the GST credit-note document (feeds the GST summary)
    if res ->> 'voucher_type_code' = 'CREDIT_NOTE' and p_ctx ->> 'invoice_id' is not null
       and p_event in ('return.accepted', 'rto.received', 'order.cancelled')
       and not exists (select 1 from credit_notes cn where cn.invoice_id = (p_ctx ->> 'invoice_id')::uuid and cn.status <> 'cancelled') then
      insert into credit_notes (invoice_id, return_id, amount, tax_amount, date, status, voucher_id)
      values ((p_ctx ->> 'invoice_id')::uuid, nullif(p_ctx ->> 'return_id', '')::uuid,
              jr_num(p_ctx, 'amount'), jr_num(p_ctx, 'tax'), v_date,
              case when v_status = 'posted' then 'posted' else 'draft' end, v_vid);
    end if;

    if v_status = 'posted' then
      update vouchers set status = 'posted' where voucher_id = v_vid;
    end if;

    insert into journal_rule_log (journal_rule_id, rule_code, event_type, source_type, source_id, dedupe_key, status, voucher_id, message, context, created_by)
    values (v_rule, res ->> 'rule_code', p_event, p_source_type, p_source_id, p_dedupe, v_status, v_vid,
            v_no || ' - ' || (res ->> 'name'), p_ctx, auth.uid());
    v_out := v_out || jsonb_build_object('rule_code', res ->> 'rule_code', 'status', v_status, 'voucher_id', v_vid, 'voucher_no', v_no);
  end loop;
  return jsonb_build_object('results', v_out);
end $$;

-- Safe wrapper used by every trigger: a bookkeeping problem must NEVER block a warehouse / courier / bank action.
create or replace function jr_fire(p_event text, p_source_type text, p_source_id uuid, p_ctx jsonb, p_dedupe text)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return post_journal_event(p_event, p_source_type, p_source_id, p_ctx, p_dedupe);
exception when others then
  insert into journal_rule_log (event_type, source_type, source_id, dedupe_key, status, message, context, created_by)
  values (p_event, p_source_type, p_source_id, p_dedupe, 'error', sqlerrm, p_ctx, auth.uid());
  return jsonb_build_object('error', sqlerrm);
end $$;

-- Bank line -> rules (used by the insert trigger, the "apply rules" button and backfill)
create or replace function jr_process_bank_txn(p_txn_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  t bank_transactions%rowtype; v_ctx jsonb; v_res jsonb; v_item jsonb;
begin
  select * into t from bank_transactions where bank_txn_id = p_txn_id;
  if not found or t.match_status <> 'unmatched' then return jsonb_build_object('skipped', 'not an unmatched line'); end if;
  v_ctx := jsonb_build_object(
    'description', coalesce(t.reference, ''), 'amount', t.amount, 'direction', t.type, 'date', t.txn_date,
    'bank_account_id', t.bank_account_id,
    'bank_account', (select bank_name from bank_accounts where bank_account_id = t.bank_account_id));
  v_res := jr_fire('bank.' || t.type, 'bank_txn', t.bank_txn_id, v_ctx, 'bank:' || t.bank_txn_id);
  for v_item in select * from jsonb_array_elements(coalesce(v_res -> 'results', '[]'::jsonb)) loop
    update bank_transactions
       set matched_entity = 'journal_rule', matched_reference_id = (v_item ->> 'voucher_id')::uuid,
           match_status = case when v_item ->> 'status' = 'posted' then 'matched' else 'partial' end
     where bank_txn_id = p_txn_id;
  end loop;
  return v_res;
end $$;

-- ---------------------------------------------------------------- admin-facing functions
create or replace function jr_rule_definition(p_rule_id uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'journal_rule_id', r.journal_rule_id, 'rule_code', r.rule_code, 'name', r.name, 'description', r.description,
    'notes', r.notes, 'rule_group', r.rule_group, 'pack', r.pack, 'event_type', r.event_type, 'action', r.action,
    'voucher_type_code', r.voucher_type_code, 'match_mode', r.match_mode, 'priority', r.priority,
    'stop_on_match', r.stop_on_match, 'auto_post', r.auto_post, 'gst_rate_pct', r.gst_rate_pct,
    'narration_template', r.narration_template, 'effective_from', r.effective_from, 'effective_to', r.effective_to,
    'status', r.status, 'is_system', r.is_system, 'version', r.version,
    'conditions', coalesce((select jsonb_agg(jsonb_build_object('field', c.field, 'operator', c.operator, 'value', c.value) order by c.sort_order, c.condition_id)
                            from journal_rule_conditions c where c.journal_rule_id = r.journal_rule_id), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('side', l.side, 'ledger_id', l.ledger_id, 'ledger_role', l.ledger_role,
                         'amount_source', l.amount_source, 'percent', l.percent, 'fixed_amount', l.fixed_amount, 'narration', l.narration)
                         order by l.sort_order, l.line_id)
                       from journal_rule_lines l where l.journal_rule_id = r.journal_rule_id), '[]'::jsonb))
  from journal_rules r where r.journal_rule_id = p_rule_id
$$;

create or replace function save_journal_rule(p_rule jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id uuid := nullif(p_rule ->> 'journal_rule_id', '')::uuid;
  v_event text := p_rule ->> 'event_type';
  v_action text := coalesce(p_rule ->> 'action', 'post');
  c jsonb; l jsonb; i int := 0; v_fields text[]; v_deb int := 0; v_cred int := 0; v_rem int := 0;
  v_old jsonb; v_ver int; v_code text; v_gst numeric := nullif(p_rule ->> 'gst_rate_pct', '')::numeric;
begin
  if not has_rulebook_edit() then raise exception 'Only a Super Admin or Finance Manager can change the rule book'; end if;
  if coalesce(btrim(p_rule ->> 'name'), '') = '' then raise exception 'Rule name is required'; end if;
  if not exists (select 1 from journal_event_types where event_type = v_event) then raise exception 'Unknown event type %', v_event; end if;
  if v_action not in ('post','ignore') then raise exception 'Action must be post or ignore'; end if;
  if not exists (select 1 from voucher_types where code = coalesce(p_rule ->> 'voucher_type_code', 'JOURNAL')) then
    raise exception 'Unknown voucher type %', p_rule ->> 'voucher_type_code';
  end if;

  select array_agg(field) into v_fields from journal_event_fields where event_type = v_event;
  v_fields := coalesce(v_fields, '{}') || array['base','tax','cgst','sgst','date'];

  for c in select * from jsonb_array_elements(coalesce(p_rule -> 'conditions', '[]'::jsonb)) loop
    if not ((c ->> 'field') = any (v_fields)) then raise exception 'Condition field "%" is not available for event %', c ->> 'field', v_event; end if;
  end loop;

  if v_action = 'post' then
    for l in select * from jsonb_array_elements(coalesce(p_rule -> 'lines', '[]'::jsonb)) loop
      if l ->> 'side' = 'debit' then v_deb := v_deb + 1; elsif l ->> 'side' = 'credit' then v_cred := v_cred + 1;
      else raise exception 'Every line must be debit or credit'; end if;
      if nullif(l ->> 'ledger_id', '') is null and coalesce(l ->> 'ledger_role', '') <> 'bank' then
        raise exception 'Every line needs a ledger';
      end if;
      if coalesce(l ->> 'amount_source', 'amount') = 'remainder' then v_rem := v_rem + 1;
      elsif coalesce(l ->> 'amount_source', 'amount') <> 'fixed' and not ((l ->> 'amount_source') = any (v_fields)) then
        raise exception 'Amount source "%" is not available for event %', l ->> 'amount_source', v_event;
      end if;
    end loop;
    if v_deb < 1 or v_cred < 1 then raise exception 'A posting rule needs at least one debit line and one credit line'; end if;
    if v_rem > 1 then raise exception 'Only one line can use the balancing figure (remainder)'; end if;
  end if;

  if v_id is not null then
    select jr_rule_definition(v_id), version into v_old, v_ver from journal_rules where journal_rule_id = v_id;
    if v_old is null then raise exception 'Rule not found'; end if;
    insert into journal_rule_history (journal_rule_id, version, snapshot, change_note, changed_by)
    values (v_id, v_ver, v_old, p_rule ->> 'change_note', auth.uid());
    update journal_rules set
      name = btrim(p_rule ->> 'name'), description = p_rule ->> 'description', notes = p_rule ->> 'notes',
      rule_group = coalesce(p_rule ->> 'rule_group', rule_group), event_type = v_event, action = v_action,
      voucher_type_code = coalesce(p_rule ->> 'voucher_type_code', 'JOURNAL'),
      match_mode = coalesce(p_rule ->> 'match_mode', 'all'), priority = coalesce((p_rule ->> 'priority')::int, 100),
      stop_on_match = coalesce((p_rule ->> 'stop_on_match')::boolean, true),
      auto_post = coalesce((p_rule ->> 'auto_post')::boolean, true), gst_rate_pct = v_gst,
      narration_template = p_rule ->> 'narration_template',
      effective_from = coalesce(nullif(p_rule ->> 'effective_from', '')::date, effective_from),
      effective_to = nullif(p_rule ->> 'effective_to', '')::date,
      status = coalesce(p_rule ->> 'status', status), version = version + 1, updated_by = auth.uid(), updated_at = now()
    where journal_rule_id = v_id;
    delete from journal_rule_conditions where journal_rule_id = v_id;
    delete from journal_rule_lines where journal_rule_id = v_id;
  else
    v_code := coalesce(nullif(p_rule ->> 'rule_code', ''), 'CUSTOM-' || lpad(nextval('journal_voucher_seq')::text, 4, '0'));
    insert into journal_rules (rule_code, name, description, notes, rule_group, pack, event_type, action, voucher_type_code,
                               match_mode, priority, stop_on_match, auto_post, gst_rate_pct, narration_template,
                               effective_from, effective_to, status, is_system, created_by, updated_by)
    values (v_code, btrim(p_rule ->> 'name'), p_rule ->> 'description', p_rule ->> 'notes',
            coalesce(p_rule ->> 'rule_group', 'Custom rules'), coalesce(p_rule ->> 'pack', 'custom'), v_event, v_action,
            coalesce(p_rule ->> 'voucher_type_code', 'JOURNAL'), coalesce(p_rule ->> 'match_mode', 'all'),
            coalesce((p_rule ->> 'priority')::int, 100), coalesce((p_rule ->> 'stop_on_match')::boolean, true),
            coalesce((p_rule ->> 'auto_post')::boolean, true), v_gst, p_rule ->> 'narration_template',
            coalesce(nullif(p_rule ->> 'effective_from', '')::date, current_date), nullif(p_rule ->> 'effective_to', '')::date,
            coalesce(p_rule ->> 'status', 'active'), false, auth.uid(), auth.uid())
    returning journal_rule_id into v_id;
  end if;

  i := 0;
  for c in select * from jsonb_array_elements(coalesce(p_rule -> 'conditions', '[]'::jsonb)) loop
    i := i + 1;
    insert into journal_rule_conditions (journal_rule_id, sort_order, field, operator, value)
    values (v_id, i, c ->> 'field', c ->> 'operator', c ->> 'value');
  end loop;
  i := 0;
  for l in select * from jsonb_array_elements(coalesce(p_rule -> 'lines', '[]'::jsonb)) loop
    i := i + 1;
    insert into journal_rule_lines (journal_rule_id, sort_order, side, ledger_id, ledger_role, amount_source, percent, fixed_amount, narration)
    values (v_id, i, l ->> 'side', nullif(l ->> 'ledger_id', '')::uuid, nullif(l ->> 'ledger_role', ''),
            coalesce(l ->> 'amount_source', 'amount'), coalesce(nullif(l ->> 'percent', '')::numeric, 100),
            nullif(l ->> 'fixed_amount', '')::numeric, nullif(l ->> 'narration', ''));
  end loop;
  return v_id;
end $$;

create or replace function jr_snapshot_default(p_rule_id uuid) returns void
language sql security definer set search_path = public, pg_temp as $$
  update journal_rules set default_definition = jr_rule_definition(p_rule_id) where journal_rule_id = p_rule_id
$$;

create or replace function reset_journal_rule_to_default(p_rule_id uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_def jsonb;
begin
  if not has_rulebook_edit() then raise exception 'Only a Super Admin or Finance Manager can change the rule book'; end if;
  select default_definition into v_def from journal_rules where journal_rule_id = p_rule_id;
  if v_def is null then raise exception 'This rule has no shipped default to restore'; end if;
  return save_journal_rule(v_def || jsonb_build_object('journal_rule_id', p_rule_id, 'change_note', 'Restored CA default'));
end $$;

create or replace function duplicate_journal_rule(p_rule_id uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_def jsonb;
begin
  if not has_rulebook_edit() then raise exception 'Only a Super Admin or Finance Manager can change the rule book'; end if;
  v_def := jr_rule_definition(p_rule_id);
  if v_def is null then raise exception 'Rule not found'; end if;
  return save_journal_rule((v_def - 'journal_rule_id' - 'rule_code') ||
    jsonb_build_object('name', (v_def ->> 'name') || ' (copy)', 'status', 'inactive', 'pack', 'custom', 'rule_group', v_def ->> 'rule_group'));
end $$;

create or replace function delete_journal_rule(p_rule_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_rulebook_edit() then raise exception 'Only a Super Admin or Finance Manager can change the rule book'; end if;
  if exists (select 1 from journal_rules where journal_rule_id = p_rule_id and is_system) then
    raise exception 'Shipped CA rules cannot be deleted - switch them off instead (you can always restore the default)';
  end if;
  delete from journal_rules where journal_rule_id = p_rule_id;
end $$;

create or replace function simulate_journal_rules(p_event text, p_ctx jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_view() then raise exception 'Not authorized'; end if;
  return jr_evaluate(p_event, p_ctx);
end $$;

create or replace function approve_rule_voucher(p_voucher_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Not authorized to approve vouchers'; end if;
  if not exists (select 1 from vouchers where voucher_id = p_voucher_id and status = 'draft') then
    raise exception 'Only a draft voucher can be approved';
  end if;
  update vouchers set status = 'posted', approved_by = auth.uid() where voucher_id = p_voucher_id;
  update journal_rule_log set status = 'posted' where voucher_id = p_voucher_id and status = 'draft';
  update credit_notes set status = 'posted' where voucher_id = p_voucher_id and status = 'draft';
  update bank_transactions set match_status = 'matched'
   where matched_entity = 'journal_rule' and matched_reference_id = p_voucher_id;
end $$;

create or replace function discard_rule_voucher(p_voucher_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Not authorized to discard vouchers'; end if;
  if not exists (select 1 from vouchers where voucher_id = p_voucher_id and status = 'draft') then
    raise exception 'Only a draft voucher can be discarded';
  end if;
  update vouchers set status = 'cancelled' where voucher_id = p_voucher_id;
  update journal_rule_log set status = 'discarded' where voucher_id = p_voucher_id and status = 'draft';
  update credit_notes set status = 'cancelled' where voucher_id = p_voucher_id and status = 'draft';
  update bank_transactions set match_status = 'unmatched', matched_entity = null, matched_reference_id = null
   where matched_entity = 'journal_rule' and matched_reference_id = p_voucher_id;
end $$;

create or replace function apply_bank_rules(p_txn_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare t record; v_n int := 0; v_posted int := 0; v_review int := 0; v_res jsonb; v_item jsonb;
begin
  if not (has_bankcod_write() or has_accounting_write()) then raise exception 'Not authorized to apply bank rules'; end if;
  for t in select bank_txn_id from bank_transactions
           where match_status = 'unmatched' and (p_txn_ids is null or bank_txn_id = any (p_txn_ids)) order by txn_date loop
    v_n := v_n + 1;
    v_res := jr_process_bank_txn(t.bank_txn_id);
    for v_item in select * from jsonb_array_elements(coalesce(v_res -> 'results', '[]'::jsonb)) loop
      if v_item ->> 'status' = 'posted' then v_posted := v_posted + 1; else v_review := v_review + 1; end if;
    end loop;
  end loop;
  return jsonb_build_object('checked', v_n, 'posted', v_posted, 'sent_for_review', v_review);
end $$;

create or replace function set_journal_rule_status(p_rule_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old jsonb; v_ver int;
begin
  if not has_rulebook_edit() then raise exception 'Only a Super Admin or Finance Manager can change the rule book'; end if;
  if p_status not in ('active','inactive') then raise exception 'Status must be active or inactive'; end if;
  select jr_rule_definition(p_rule_id), version into v_old, v_ver from journal_rules where journal_rule_id = p_rule_id;
  if v_old is null then raise exception 'Rule not found'; end if;
  insert into journal_rule_history (journal_rule_id, version, snapshot, change_note, changed_by)
  values (p_rule_id, v_ver, v_old, 'Status set to ' || p_status, auth.uid());
  update journal_rules set status = p_status, version = version + 1, updated_by = auth.uid(), updated_at = now()
   where journal_rule_id = p_rule_id;
end $$;

create or replace function set_journal_pack_status(p_pack text, p_status text) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  if not has_rulebook_edit() then raise exception 'Only a Super Admin or Finance Manager can change the rule book'; end if;
  for r in select journal_rule_id from journal_rules where pack = p_pack and status <> p_status loop
    perform set_journal_rule_status(r.journal_rule_id, p_status);
    n := n + 1;
  end loop;
  return n;
end $$;

-- lock down: engine internals are only reachable through triggers and the role-checked wrappers above
revoke execute on function post_journal_event(text, text, uuid, jsonb, text) from public, anon, authenticated;
revoke execute on function jr_fire(text, text, uuid, jsonb, text) from public, anon, authenticated;
revoke execute on function jr_process_bank_txn(uuid) from public, anon, authenticated;
revoke execute on function jr_evaluate(text, jsonb) from public, anon, authenticated;
revoke execute on function jr_order_ctx(uuid) from public, anon, authenticated;
revoke execute on function jr_order_cogs(uuid) from public, anon, authenticated;
revoke execute on function jr_bank_ledger(jsonb) from public, anon, authenticated;
revoke execute on function jr_snapshot_default(uuid) from public, anon, authenticated;
revoke execute on function save_journal_rule(jsonb) from public, anon;
revoke execute on function reset_journal_rule_to_default(uuid) from public, anon;
revoke execute on function duplicate_journal_rule(uuid) from public, anon;
revoke execute on function delete_journal_rule(uuid) from public, anon;
revoke execute on function simulate_journal_rules(text, jsonb) from public, anon;
revoke execute on function approve_rule_voucher(uuid) from public, anon;
revoke execute on function discard_rule_voucher(uuid) from public, anon;
revoke execute on function apply_bank_rules(uuid[]) from public, anon;
revoke execute on function jr_rule_definition(uuid) from public, anon;
revoke execute on function set_journal_rule_status(uuid, text), set_journal_pack_status(text, text) from public, anon;
grant execute on function save_journal_rule(jsonb), reset_journal_rule_to_default(uuid), duplicate_journal_rule(uuid),
  delete_journal_rule(uuid), simulate_journal_rules(text, jsonb), approve_rule_voucher(uuid), discard_rule_voucher(uuid),
  apply_bank_rules(uuid[]), jr_rule_definition(uuid), set_journal_rule_status(uuid, text), set_journal_pack_status(text, text) to authenticated;
