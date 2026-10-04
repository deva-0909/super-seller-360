-- 0055: Cash settlement control.
--
-- When money moves from the bank into cash (an ATM / cheque cash withdrawal, or any entry that debits Cash in Hand and
-- credits a bank account) somebody has to account for where that cash went. This migration:
--   * adds the "Cash in Hand" ledger and two Rule Book rules that book bank-statement cash withdrawals / deposits;
--   * detects every cash withdrawal (cash_movements) and keeps it OPEN until cash spending is recorded against it
--     (first-in-first-out against credits to Cash in Hand) or a settlement report is submitted;
--   * lets a finance user submit a settlement report (spent / returned to bank / kept in hand / recorded elsewhere).
--     "Spent" lines post the journal entry (Dr expense, Cr Cash in Hand) in the same step;
--   * feeds the on-screen reminder (cash_open_summary) and the owner's e-mail queue (cash_mail_queue).
-- Also adds acc_post_journal(), the one place a manual / recurring journal entry gets written (used again by 0056).

-- ---------------------------------------------------------------- 1. ledger
insert into account_groups (parent_group_id, name, nature, is_primary, status)
select (select account_group_id from account_groups where name = 'Assets' and is_primary), 'Cash-in-Hand', 'asset', false, 'active'
where not exists (select 1 from account_groups where name = 'Cash-in-Hand');

insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = 'Cash-in-Hand'), 'Cash in Hand', 'asset', 0, 'debit', false, false, 'active'
where not exists (select 1 from ledgers where name = 'Cash in Hand');

-- ---------------------------------------------------------------- 2. one place that writes a journal voucher
create or replace function acc_post_journal(p_date date, p_narration text, p_lines jsonb,
                                            p_source_type text default 'manual', p_source_id uuid default null,
                                            p_status text default 'posted', p_user uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ln jsonb; v_period uuid; v_vt uuid; v_prefix text; v_no text; v_vid uuid;
  v_dr numeric := 0; v_cr numeric := 0; d numeric; c numeric; n int := 0;
begin
  if p_date is null then raise exception 'Entry date is required'; end if;
  if p_status not in ('draft', 'posted') then raise exception 'Status must be draft or posted'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then raise exception 'Entry lines are required'; end if;
  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    d := round(coalesce(nullif(ln ->> 'debit', '')::numeric, 0), 2);
    c := round(coalesce(nullif(ln ->> 'credit', '')::numeric, 0), 2);
    if nullif(ln ->> 'ledger_id', '') is null then raise exception 'Line % has no ledger', n; end if;
    if not exists (select 1 from ledgers where ledger_id = (ln ->> 'ledger_id')::uuid and status = 'active') then
      raise exception 'Line % uses a ledger that does not exist or is inactive', n;
    end if;
    if d < 0 or c < 0 then raise exception 'Line %: amounts cannot be negative', n; end if;
    if (d > 0) = (c > 0) then raise exception 'Line %: enter either a debit or a credit amount (not both, not neither)', n; end if;
    v_dr := v_dr + d; v_cr := v_cr + c;
  end loop;
  if n < 2 then raise exception 'A journal entry needs at least two lines'; end if;
  if v_dr <> v_cr then raise exception 'Entry does not balance: debits % vs credits %', v_dr, v_cr; end if;

  select accounting_period_id into v_period from accounting_periods where p_date between start_date and end_date and status = 'open' limit 1;
  if v_period is null then raise exception 'No open accounting period covers %', p_date; end if;
  select voucher_type_id, numbering_prefix into v_vt, v_prefix from voucher_types where code = 'JOURNAL';
  v_no := v_prefix || '-' || to_char(p_date, 'YYMM') || '-' || lpad(nextval('journal_voucher_seq')::text, 6, '0');

  insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, source_type, source_id, narration, total_debit, total_credit, created_by)
  values (v_vt, v_no, p_date, v_period, 'draft', p_source_type, p_source_id, nullif(btrim(p_narration), ''), v_dr, v_cr, coalesce(p_user, auth.uid()))
  returning voucher_id into v_vid;
  for ln in select * from jsonb_array_elements(p_lines) loop
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id, narration)
    values (v_vid, (ln ->> 'ledger_id')::uuid, round(coalesce(nullif(ln ->> 'debit', '')::numeric, 0), 2),
            round(coalesce(nullif(ln ->> 'credit', '')::numeric, 0), 2), p_source_type, p_source_id, nullif(btrim(coalesce(ln ->> 'narration', '')), ''));
  end loop;
  if p_status = 'posted' then update vouchers set status = 'posted' where voucher_id = v_vid; end if;
  return jsonb_build_object('voucher_id', v_vid, 'voucher_no', v_no, 'total', v_dr);
end $$;

-- ---------------------------------------------------------------- 3. tables
create table if not exists cash_settings (
  id                 int primary key default 1 check (id = 1),
  remind_minutes     int not null default 30 check (remind_minutes between 5 and 720),
  mail_repeat_hours  int not null default 24 check (mail_repeat_hours between 1 and 168),
  tolerance          numeric(10,2) not null default 1 check (tolerance >= 0),
  extra_recipients   text,                       -- comma separated e-mail addresses besides the Super Admin(s)
  updated_at         timestamptz not null default now(),
  updated_by         uuid
);
insert into cash_settings (id) values (1) on conflict do nothing;

create table if not exists cash_movements (
  movement_id      uuid primary key default gen_random_uuid(),
  voucher_id       uuid not null references vouchers(voucher_id),
  voucher_line_id  uuid not null unique references voucher_lines(voucher_line_id),
  voucher_no       text,
  movement_date    date not null,
  amount           numeric(14,2) not null check (amount > 0),
  cash_ledger_id   uuid not null references ledgers(ledger_id),
  narration        text,
  accounted        numeric(14,2) not null default 0,   -- cash spending already booked against it (first-in-first-out)
  declared         numeric(14,2) not null default 0,   -- covered by a submitted settlement report without a cash entry
  status           text not null default 'open' check (status in ('open', 'settled', 'void')),
  settle_method    text check (settle_method in ('auto', 'report')),
  settled_at       timestamptz,
  detected_at      timestamptz not null default now(),
  mail_count       int not null default 0,
  last_mailed_at   timestamptz
);
create index if not exists cash_movements_status on cash_movements (status, movement_date);

create table if not exists cash_settlement_reports (
  report_id     uuid primary key default gen_random_uuid(),
  movement_id   uuid not null references cash_movements(movement_id),
  total         numeric(14,2) not null,
  note          text,
  voucher_id    uuid references vouchers(voucher_id),
  submitted_by  uuid,
  submitted_at  timestamptz not null default now()
);
create table if not exists cash_settlement_report_lines (
  line_id    uuid primary key default gen_random_uuid(),
  report_id  uuid not null references cash_settlement_reports(report_id) on delete cascade,
  kind       text not null check (kind in ('spent', 'returned_to_bank', 'kept_in_hand', 'other_recorded')),
  amount     numeric(14,2) not null check (amount > 0),
  ledger_id  uuid references ledgers(ledger_id),
  narration  text,
  reference  text
);

alter table cash_settings               enable row level security;
alter table cash_movements              enable row level security;
alter table cash_settlement_reports     enable row level security;
alter table cash_settlement_report_lines enable row level security;
drop policy if exists "cash view" on cash_settings;               create policy "cash view" on cash_settings               for select to authenticated using (has_bankcod_view());
drop policy if exists "cash view" on cash_movements;              create policy "cash view" on cash_movements              for select to authenticated using (has_bankcod_view());
drop policy if exists "cash view" on cash_settlement_reports;     create policy "cash view" on cash_settlement_reports     for select to authenticated using (has_bankcod_view());
drop policy if exists "cash view" on cash_settlement_report_lines; create policy "cash view" on cash_settlement_report_lines for select to authenticated using (has_bankcod_view());

-- ---------------------------------------------------------------- 4. detection
create or replace function cash_ledger_ids() returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(l.ledger_id), '{}') from ledgers l join account_groups g on g.account_group_id = l.account_group_id
   where g.name = 'Cash-in-Hand' and l.status = 'active'
$$;

-- A posted voucher that debits Cash in Hand and credits a bank account is a cash withdrawal.
create or replace function cash_scan_voucher(p_voucher uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v vouchers%rowtype; ln record; v_bank numeric; v_n int := 0; v_cash uuid[];
begin
  select * into v from vouchers where voucher_id = p_voucher;
  if not found or v.status <> 'posted' or coalesce(v.source_type, '') = 'reversal' then return 0; end if;
  v_cash := cash_ledger_ids();
  select coalesce(sum(credit), 0) into v_bank from voucher_lines
   where voucher_id = p_voucher and credit > 0 and ledger_id in (select ledger_id from bank_accounts where ledger_id is not null);
  if v_bank <= 0 then return 0; end if;
  for ln in select voucher_line_id, ledger_id, debit, narration from voucher_lines
             where voucher_id = p_voucher and debit > 0 and ledger_id = any (v_cash) loop
    insert into cash_movements (voucher_id, voucher_line_id, voucher_no, movement_date, amount, cash_ledger_id, narration)
    values (p_voucher, ln.voucher_line_id, v.voucher_no, v.voucher_date, least(ln.debit, v_bank), ln.ledger_id, coalesce(ln.narration, v.narration))
    on conflict (voucher_line_id) do nothing;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Work out how much of each withdrawal has been accounted for: cash credits dated on / after the withdrawal are applied
-- oldest-first. A withdrawal is settled when (cash spending booked + amount declared in a report) covers it.
create or replace function cash_refresh() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m record; c record; v_tol numeric; v_acc numeric; v_take numeric; v_covered boolean;
begin
  select tolerance into v_tol from cash_settings where id = 1;
  v_tol := coalesce(v_tol, 1);

  -- a withdrawal whose entry was reversed (e.g. a bank line excluded) is no longer a movement
  update cash_movements cm set status = 'void', settled_at = null
   where status <> 'void' and exists (select 1 from vouchers rv where rv.source_type = 'reversal' and rv.source_id = cm.voucher_id and rv.status = 'posted');

  drop table if exists _cash_cr;
  create temp table _cash_cr (vl uuid, ledger uuid, d date, rem numeric) on commit drop;
  insert into _cash_cr
  select vl.voucher_line_id, vl.ledger_id, v.voucher_date, vl.credit
    from voucher_lines vl join vouchers v on v.voucher_id = vl.voucher_id
   where vl.credit > 0 and vl.ledger_id = any (cash_ledger_ids()) and v.status = 'posted' and coalesce(v.source_type, '') <> 'reversal'
     and not exists (select 1 from vouchers rv where rv.source_type = 'reversal' and rv.source_id = v.voucher_id and rv.status = 'posted');

  for m in select * from cash_movements where status <> 'void' order by movement_date, detected_at, movement_id loop
    v_acc := 0;
    for c in select * from _cash_cr where ledger = m.cash_ledger_id and d >= m.movement_date and rem > 0 order by d, vl loop
      exit when v_acc >= m.amount - m.declared;   -- what a report already explained does not need cash entries too
      v_take := least(c.rem, m.amount - m.declared - v_acc);
      v_acc := v_acc + v_take;
      update _cash_cr set rem = rem - v_take where vl = c.vl;
    end loop;
    v_covered := v_acc + m.declared >= m.amount - v_tol;
    update cash_movements
       set accounted = v_acc,
           status = case when v_covered then 'settled' else 'open' end,
           settle_method = case when v_covered then case when m.declared > 0 then 'report' else 'auto' end else null end,
           settled_at = case when v_covered then coalesce(m.settled_at, now()) else null end
     where movement_id = m.movement_id;
  end loop;
end $$;

create or replace function trg_voucher_cash() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if new.status = 'posted' and old.status is distinct from 'posted' then
      perform cash_scan_voucher(new.voucher_id);
      perform cash_refresh();
    end if;
  exception when others then
    null;  -- bookkeeping side-effects must never block a posting
  end;
  return new;
end $$;
drop trigger if exists trg_voucher_cash on vouchers;
create trigger trg_voucher_cash after update of status on vouchers for each row execute function trg_voucher_cash();

create or replace function cash_backfill() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v record; n int := 0;
begin
  if not has_bankcod_write() then raise exception 'Not authorized'; end if;
  for v in select voucher_id from vouchers where status = 'posted' and coalesce(source_type, '') <> 'reversal' loop
    n := n + cash_scan_voucher(v.voucher_id);
  end loop;
  perform cash_refresh();
  return jsonb_build_object('movements_found', n, 'open', (select count(*) from cash_movements where status = 'open'));
end $$;

-- ---------------------------------------------------------------- 5. what the screen asks
create or replace function cash_open_summary() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_set cash_settings%rowtype;
begin
  if not has_bankcod_write() then return jsonb_build_object('count', 0, 'remind_minutes', 30); end if;
  select * into v_set from cash_settings where id = 1;
  return jsonb_build_object(
    'remind_minutes', coalesce(v_set.remind_minutes, 30),
    'count', (select count(*) from cash_movements where status = 'open'),
    'total', coalesce((select sum(amount - accounted - declared) from cash_movements where status = 'open'), 0),
    'oldest', (select min(movement_date) from cash_movements where status = 'open'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', movement_id, 'date', movement_date, 'voucher_no', voucher_no,
                         'open_amount', amount - accounted - declared, 'narration', narration) order by movement_date)
                         from (select * from cash_movements where status = 'open' order by movement_date limit 5) x), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- 6. submitting the settlement report
-- p_lines: [{kind, amount, ledger_id?, narration, reference?}]. Together they must account for the whole open amount.
create or replace function submit_cash_settlement(p_movement uuid, p_lines jsonb, p_note text default null, p_date date default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  m cash_movements%rowtype; ln jsonb; v_tol numeric; v_open numeric; v_total numeric := 0; v_spent numeric := 0; v_decl numeric := 0;
  k text; a numeric; v_report uuid; v_voucher jsonb; v_vlines jsonb := '[]'::jsonb; v_cashl uuid[]; v_bankl uuid[]; n int := 0; v_date date;
begin
  if not has_bankcod_write() then raise exception 'Only Super Admin, Finance Manager or Accountant can submit a cash settlement report'; end if;
  perform cash_refresh();
  select * into m from cash_movements where movement_id = p_movement for update;
  if not found then raise exception 'Cash movement not found'; end if;
  if m.status <> 'open' then raise exception 'This cash movement is already %', m.status; end if;
  select tolerance into v_tol from cash_settings where id = 1; v_tol := coalesce(v_tol, 1);
  v_open := m.amount - m.accounted - m.declared;
  v_cashl := cash_ledger_ids();
  select coalesce(array_agg(ledger_id), '{}') into v_bankl from bank_accounts where ledger_id is not null;
  v_date := coalesce(p_date, current_date);
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one line to the report'; end if;

  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    k := ln ->> 'kind'; a := round(coalesce(nullif(ln ->> 'amount', '')::numeric, 0), 2);
    if k not in ('spent', 'returned_to_bank', 'kept_in_hand', 'other_recorded') then raise exception 'Line %: choose what happened to the cash', n; end if;
    if a <= 0 then raise exception 'Line %: amount must be more than zero', n; end if;
    if k = 'spent' then
      if nullif(ln ->> 'ledger_id', '') is null then raise exception 'Line %: choose the expense ledger the cash was spent on', n; end if;
      if (ln ->> 'ledger_id')::uuid = any (v_cashl) or (ln ->> 'ledger_id')::uuid = any (v_bankl) then
        raise exception 'Line %: choose an expense or other ledger - not a cash or bank ledger', n;
      end if;
      v_spent := v_spent + a;
      v_vlines := v_vlines || jsonb_build_object('ledger_id', ln ->> 'ledger_id', 'debit', a, 'credit', 0, 'narration', ln ->> 'narration');
    else
      if length(btrim(coalesce(ln ->> 'narration', '') || coalesce(ln ->> 'reference', ''))) < 3 then
        raise exception 'Line %: say where it is recorded or why (a few words)', n;
      end if;
      v_decl := v_decl + a;
    end if;
    v_total := v_total + a;
  end loop;
  if abs(v_total - v_open) > v_tol then
    raise exception 'The report accounts for % but % of the cash is still unexplained - the lines must add up to the open amount', v_total, v_open;
  end if;

  insert into cash_settlement_reports (movement_id, total, note, submitted_by) values (m.movement_id, v_total, nullif(btrim(p_note), ''), auth.uid())
  returning report_id into v_report;
  for ln in select * from jsonb_array_elements(p_lines) loop
    insert into cash_settlement_report_lines (report_id, kind, amount, ledger_id, narration, reference)
    values (v_report, ln ->> 'kind', round((ln ->> 'amount')::numeric, 2), nullif(ln ->> 'ledger_id', '')::uuid,
            nullif(btrim(coalesce(ln ->> 'narration', '')), ''), nullif(btrim(coalesce(ln ->> 'reference', '')), ''));
  end loop;

  if v_spent > 0 then
    v_voucher := acc_post_journal(v_date, 'Cash spent - settlement of withdrawal ' || coalesce(m.voucher_no, ''),
                   v_vlines || jsonb_build_object('ledger_id', m.cash_ledger_id, 'debit', 0, 'credit', v_spent, 'narration', 'Cash spent'),
                   'cash_settlement', v_report, 'posted', auth.uid());
    update cash_settlement_reports set voucher_id = (v_voucher ->> 'voucher_id')::uuid where report_id = v_report;
  end if;
  update cash_movements set declared = declared + v_decl where movement_id = m.movement_id;
  perform cash_refresh();
  -- a report that explains the cash always closes it, even if rounding left a tiny gap
  update cash_movements set status = 'settled', settle_method = coalesce(settle_method, 'report'), settled_at = coalesce(settled_at, now())
   where movement_id = m.movement_id and status = 'open';
  return jsonb_build_object('report_id', v_report, 'voucher', v_voucher, 'status', (select status from cash_movements where movement_id = m.movement_id));
end $$;

create or replace function save_cash_settings(p_remind_minutes int, p_mail_repeat_hours int, p_tolerance numeric, p_extra_recipients text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_rulebook_edit() then raise exception 'Only a Super Admin or Finance Manager can change these settings'; end if;
  update cash_settings set remind_minutes = p_remind_minutes, mail_repeat_hours = p_mail_repeat_hours, tolerance = coalesce(p_tolerance, 1),
         extra_recipients = nullif(btrim(coalesce(p_extra_recipients, '')), ''), updated_at = now(), updated_by = auth.uid() where id = 1;
end $$;

-- ---------------------------------------------------------------- 7. e-mail queue (called by the scheduled Edge Function only)
create or replace function cash_mail_queue() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_set cash_settings%rowtype; v_rcpt text[]; v_items jsonb;
begin
  perform cash_refresh();
  select * into v_set from cash_settings where id = 1;
  select coalesce(array_agg(distinct lower(btrim(e))), '{}') into v_rcpt from (
    select up.email as e from user_profiles up join roles r on r.role_id = up.role_id where r.name = 'Super Admin' and up.status = 'active'
    union all
    select unnest(string_to_array(coalesce(v_set.extra_recipients, ''), ','))
  ) q where coalesce(btrim(e), '') <> '';
  select coalesce(jsonb_agg(jsonb_build_object('id', movement_id, 'date', movement_date, 'voucher_no', voucher_no, 'amount', amount,
           'open_amount', amount - accounted - declared, 'narration', narration, 'times_mailed', mail_count) order by movement_date), '[]'::jsonb)
    into v_items
    from cash_movements
   where status = 'open' and (last_mailed_at is null or now() - last_mailed_at >= make_interval(hours => v_set.mail_repeat_hours));
  return jsonb_build_object('recipients', to_jsonb(v_rcpt), 'items', v_items,
                            'open_total', (select count(*) from cash_movements where status = 'open'));
end $$;

create or replace function cash_mail_mark(p_ids uuid[]) returns void
language sql security definer set search_path = public, pg_temp as $$
  update cash_movements set mail_count = mail_count + 1, last_mailed_at = now() where movement_id = any (p_ids)
$$;

-- ---------------------------------------------------------------- 8. Rule Book: book cash withdrawals / deposits seen on the bank statement
do $$
declare v uuid; v_cash uuid;
begin
  select ledger_id into v_cash from ledgers where name = 'Cash in Hand';

  if not exists (select 1 from journal_rules where rule_code = 'BNK-CASH-WITHDRAWAL') then
    insert into journal_rules (rule_code, name, notes, rule_group, pack, event_type, action, voucher_type_code, match_mode, priority,
                               stop_on_match, auto_post, gst_rate_pct, narration_template, effective_from, status, is_system)
    values ('BNK-CASH-WITHDRAWAL', 'Cash withdrawal (ATM / self cheque)',
            'Money taken out of the bank as cash. Posts Dr Cash in Hand, Cr Bank - and starts a cash-settlement reminder until the cash is accounted for.',
            'Bank rules - money out', 'core', 'bank.debit', 'post', 'JOURNAL', 'all', 8, true, true, null,
            'Cash withdrawn - {description}', date '2000-01-01', 'active', true)
    returning journal_rule_id into v;
    insert into journal_rule_conditions (journal_rule_id, sort_order, field, operator, value)
    values (v, 1, 'description', 'contains_any', 'ATM CASH|CASH WDL|CASH WITHDRAWAL|ATM WDL|NWD-|SELF CHQ|CHQ SELF|SELF CHEQUE|CASH PAID|CASH CHQ');
    insert into journal_rule_lines (journal_rule_id, sort_order, side, ledger_id, ledger_role, amount_source) values
      (v, 1, 'debit', v_cash, null, 'amount'), (v, 2, 'credit', null, 'bank', 'amount');
    perform jr_snapshot_default(v);
  end if;

  if not exists (select 1 from journal_rules where rule_code = 'BNK-CASH-DEPOSIT') then
    insert into journal_rules (rule_code, name, notes, rule_group, pack, event_type, action, voucher_type_code, match_mode, priority,
                               stop_on_match, auto_post, gst_rate_pct, narration_template, effective_from, status, is_system)
    values ('BNK-CASH-DEPOSIT', 'Cash deposited in the bank',
            'Cash taken to the bank (cash deposit machine / counter). Posts Dr Bank, Cr Cash in Hand, which also clears an open cash-settlement item.',
            'Bank rules - money in', 'core', 'bank.credit', 'post', 'JOURNAL', 'all', 8, true, true, null,
            'Cash deposited - {description}', date '2000-01-01', 'active', true)
    returning journal_rule_id into v;
    insert into journal_rule_conditions (journal_rule_id, sort_order, field, operator, value)
    values (v, 1, 'description', 'contains_any', 'CASH DEPOSIT|CASH DEP|BY CASH|CASH-DEP|CASH DEPOSITED');
    insert into journal_rule_lines (journal_rule_id, sort_order, side, ledger_id, ledger_role, amount_source) values
      (v, 1, 'debit', null, 'bank', 'amount'), (v, 2, 'credit', v_cash, null, 'amount');
    perform jr_snapshot_default(v);
  end if;
end $$;

-- pick up any withdrawal that was already booked
do $$
declare v record;
begin
  for v in select voucher_id from vouchers where status = 'posted' and coalesce(source_type, '') <> 'reversal' loop
    perform cash_scan_voucher(v.voucher_id);
  end loop;
  perform cash_refresh();
end $$;

-- ---------------------------------------------------------------- 9. grants
revoke execute on function acc_post_journal(date, text, jsonb, text, uuid, text, uuid), cash_ledger_ids(), cash_scan_voucher(uuid), cash_refresh(),
  trg_voucher_cash(), cash_backfill(), cash_open_summary(), submit_cash_settlement(uuid, jsonb, text, date), save_cash_settings(int, int, numeric, text),
  cash_mail_queue(), cash_mail_mark(uuid[]) from public, anon, authenticated;
grant execute on function cash_backfill(), cash_open_summary(), submit_cash_settlement(uuid, jsonb, text, date), save_cash_settings(int, int, numeric, text) to authenticated;
grant execute on function cash_mail_queue(), cash_mail_mark(uuid[]) to service_role;
