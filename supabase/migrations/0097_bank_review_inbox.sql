-- 0097: "For review" inbox for bank lines (QuickBooks-style).
--   * every open bank line gets a suggested account (and vendor for payments) from payee rules
--   * accepting a line books it (through the existing br_book_txn) and, if asked, remembers the choice as a payee rule
--   * rules can also be added by hand; nothing is booked without a person pressing Accept
-- No change to how reconciliation, rules (0054) or the Rule Book (0050) work.

alter table bank_transactions
  add column if not exists supplier_id         uuid references suppliers(supplier_id),
  add column if not exists suggest_ledger_id   uuid references ledgers(ledger_id),
  add column if not exists suggest_supplier_id uuid references suppliers(supplier_id),
  add column if not exists suggest_source      text,
  add column if not exists suggest_confidence  int,
  add column if not exists reviewed_by         uuid,
  add column if not exists reviewed_at         timestamptz;

create table if not exists bank_payee_rules (
  payee_rule_id uuid primary key default gen_random_uuid(),
  keyword       text not null check (keyword = upper(keyword) and length(keyword) >= 4),
  direction     text not null default 'any' check (direction in ('any','credit','debit')),
  supplier_id   uuid references suppliers(supplier_id) on delete set null,
  ledger_id     uuid not null references ledgers(ledger_id),
  source        text not null default 'manual' check (source in ('manual','learned')),
  hits          int  not null default 0,
  status        text not null default 'active' check (status in ('active','inactive')),
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (keyword, direction)
);
alter table bank_payee_rules enable row level security;
drop policy if exists "payee view" on bank_payee_rules;
create policy "payee view" on bank_payee_rules for select to authenticated using (has_bankcod_view());
revoke all on bank_payee_rules from anon;
revoke insert, update, delete on bank_payee_rules from authenticated;

-- ---------------------------------------------------------------- helpers
-- the first meaningful word of a bank narration (skips UPI / NEFT / IMPS style noise)
create or replace function bank_payee_keyword(p_ref text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select upper(w) from regexp_split_to_table(coalesce(p_ref, ''), '[^A-Za-z]+') with ordinality t(w, i)
   where length(w) >= 4
     and upper(w) <> all (array['UPIIN','UPIOUT','NEFT','IMPS','RTGS','PAYMENT','PAYMENTS','TRANSFER','FROM','CHEQUE','CHQ','BANK','REF','TXN','TRANSACTION','CREDIT','DEBIT','INWARD','OUTWARD','CHARGES','ONLINE','MOBILE','BANKING','THROUGH','AXIS','HDFC','ICICI','SBIN','KOTAK'])
   order by i limit 1
$$;

create or replace function bank_review_suggest(p_ref text, p_type text)
returns table (s_ledger uuid, s_supplier uuid, s_source text, s_conf int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_norm text := br_norm(p_ref); r record; n int; m int; sid uuid;
begin
  if length(v_norm) < 4 then return; end if;
  select pr.ledger_id as lid, pr.supplier_id as sup, pr.source as src, pr.hits as h into r
    from bank_payee_rules pr
   where pr.status = 'active' and (pr.direction = 'any' or pr.direction = p_type) and v_norm like '%' || br_norm(pr.keyword) || '%'
   order by length(pr.keyword) desc, pr.hits desc limit 1;
  if found then
    return query select r.lid, r.sup, 'rule:' || r.src, case when r.src = 'manual' then 95 else least(70 + r.h * 3, 92) end;
    return;
  end if;
  if p_type = 'debit' then
    -- vendor named on the statement: the supplier whose name has the most words in the narration, if one clearly wins
    with sc as (
      select s.supplier_id, (select count(*) from regexp_split_to_table(s.name, '[^A-Za-z]+') w
                              where length(w) >= 5 and upper(w) <> all (array['PRIVATE','LIMITED','SHREE','COMPANY','INDUSTRIES','SERVICES','ENTERPRISE','ENTERPRISES','TRADERS','TRADING','ASSOCIATES'])
                                and v_norm like '%' || upper(w) || '%') as hit
        from suppliers s)
    select (select max(hit) from sc), (select count(*) from sc where hit = (select max(hit) from sc)),
           (select supplier_id from sc where hit = (select max(hit) from sc) limit 1) into n, m, sid;
    if n > 0 and m = 1 then return query select null::uuid, sid, 'vendor_name'::text, 50; end if;
  end if;
end $$;

create or replace function trg_bank_txn_suggest() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    select s_ledger, s_supplier, s_source, s_conf into new.suggest_ledger_id, new.suggest_supplier_id, new.suggest_source, new.suggest_confidence
      from bank_review_suggest(new.reference, new.type);
  exception when others then null;   -- a suggestion must never block a statement import
  end;
  return new;
end $$;
drop trigger if exists trg_bank_txn_suggest on bank_transactions;
create trigger trg_bank_txn_suggest before insert on bank_transactions for each row execute function trg_bank_txn_suggest();

-- ---------------------------------------------------------------- screens
create or replace function bank_review_refresh(p_bank_account_id uuid default null) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if not has_bankcod_write() then raise exception 'Not authorized'; end if;
  with s as (
    select b.bank_txn_id, (bank_review_suggest(b.reference, b.type)).*
      from bank_transactions b
     where b.recon_status in ('unreconciled','suggested') and (p_bank_account_id is null or b.bank_account_id = p_bank_account_id))
  update bank_transactions b set suggest_ledger_id = s.s_ledger, suggest_supplier_id = s.s_supplier, suggest_source = s.s_source, suggest_confidence = s.s_conf
    from s where b.bank_txn_id = s.bank_txn_id;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function bank_review_list(p_bank_account_id uuid, p_limit int default 300)
returns table (bank_txn_id uuid, txn_date date, description text, amount numeric, type text, recon_status text,
               suggest_ledger_id uuid, suggest_ledger_name text, suggest_supplier_id uuid, suggest_supplier_name text,
               suggest_source text, suggest_confidence int, has_match_suggestion boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_bankcod_view() then raise exception 'Not authorized'; end if;
  return query
  select b.bank_txn_id, b.txn_date, b.reference, b.amount, b.type, b.recon_status,
         b.suggest_ledger_id, l.name, b.suggest_supplier_id, s.name, b.suggest_source, b.suggest_confidence,
         exists (select 1 from bank_recon_suggestions q where q.bank_txn_id = b.bank_txn_id and q.status = 'pending')
    from bank_transactions b
    left join ledgers l on l.ledger_id = b.suggest_ledger_id
    left join suppliers s on s.supplier_id = b.suggest_supplier_id
   where b.bank_account_id = p_bank_account_id and b.recon_status in ('unreconciled','suggested')
   order by b.txn_date desc, b.created_at desc
   limit least(coalesce(p_limit, 300), 1000);
end $$;

create or replace function bank_review_accept(p_txn uuid, p_ledger uuid, p_supplier uuid default null, p_remember boolean default true, p_narration text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare t bank_transactions%rowtype; v jsonb; kw text;
begin
  if not has_accounting_write() then raise exception 'Not authorized to post vouchers'; end if;
  select * into t from bank_transactions where bank_txn_id = p_txn for update;
  if not found then raise exception 'Statement line not found'; end if;
  if t.recon_status not in ('unreconciled','suggested') then raise exception 'This line is no longer waiting for review'; end if;
  v := br_book_txn(p_txn, p_ledger, p_narration);
  update bank_transactions set supplier_id = p_supplier, reviewed_by = auth.uid(), reviewed_at = now() where bank_txn_id = p_txn;
  if p_remember then
    kw := bank_payee_keyword(t.reference);
    if kw is not null then
      insert into bank_payee_rules (keyword, direction, supplier_id, ledger_id, source, hits) values (kw, t.type, p_supplier, p_ledger, 'learned', 1)
      on conflict (keyword, direction) do update set
        hits       = case when bank_payee_rules.ledger_id = excluded.ledger_id then bank_payee_rules.hits + 1 else 1 end,
        ledger_id  = case when bank_payee_rules.source = 'manual' then bank_payee_rules.ledger_id else excluded.ledger_id end,
        supplier_id = coalesce(excluded.supplier_id, bank_payee_rules.supplier_id),
        updated_at = now();
    end if;
  end if;
  return v;
end $$;

-- Accept every selected line that has a confident suggestion (70+); the rest are left for a person.
create or replace function bank_review_bulk_accept(p_txns uuid[]) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; ok int := 0; skipped int := 0; errs jsonb := '[]'::jsonb;
begin
  if not has_accounting_write() then raise exception 'Not authorized to post vouchers'; end if;
  for r in select bank_txn_id, suggest_ledger_id, suggest_supplier_id, suggest_confidence, reference from bank_transactions
            where bank_txn_id = any (p_txns) and recon_status in ('unreconciled','suggested') order by txn_date loop
    if r.suggest_ledger_id is null or coalesce(r.suggest_confidence, 0) < 70 then skipped := skipped + 1; continue; end if;
    begin
      perform bank_review_accept(r.bank_txn_id, r.suggest_ledger_id, r.suggest_supplier_id, true, null);
      ok := ok + 1;
    exception when others then
      errs := errs || jsonb_build_object('line', left(coalesce(r.reference, ''), 40), 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('accepted', ok, 'skipped', skipped, 'errors', errs);
end $$;

create or replace function bank_payee_rule_save(p_keyword text, p_direction text, p_supplier uuid, p_ledger uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare k text := upper(regexp_replace(coalesce(p_keyword, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if not has_accounting_write() then raise exception 'Not authorized'; end if;
  if length(k) < 4 then raise exception 'Enter at least 4 letters or digits of the name as it appears on the bank statement'; end if;
  if p_direction not in ('any','credit','debit') then raise exception 'Choose money in, money out or both'; end if;
  if not exists (select 1 from ledgers where ledger_id = p_ledger and status = 'active') then raise exception 'Choose an active account'; end if;
  insert into bank_payee_rules (keyword, direction, supplier_id, ledger_id, source, hits) values (k, p_direction, p_supplier, p_ledger, 'manual', 0)
  on conflict (keyword, direction) do update set supplier_id = excluded.supplier_id, ledger_id = excluded.ledger_id, source = 'manual', status = 'active', updated_at = now();
  perform bank_review_refresh(null);
end $$;

create or replace function bank_payee_rule_delete(p_rule uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Not authorized'; end if;
  delete from bank_payee_rules where payee_rule_id = p_rule;
  perform bank_review_refresh(null);
end $$;

revoke execute on function bank_payee_keyword(text), bank_review_suggest(text, text), trg_bank_txn_suggest(),
  bank_review_refresh(uuid), bank_review_list(uuid, int), bank_review_accept(uuid, uuid, uuid, boolean, text),
  bank_review_bulk_accept(uuid[]), bank_payee_rule_save(text, text, uuid, uuid), bank_payee_rule_delete(uuid) from public, anon;
revoke execute on function bank_payee_keyword(text), bank_review_suggest(text, text), trg_bank_txn_suggest() from authenticated;
grant execute on function bank_review_refresh(uuid), bank_review_list(uuid, int), bank_review_accept(uuid, uuid, uuid, boolean, text),
  bank_review_bulk_accept(uuid[]), bank_payee_rule_save(text, text, uuid, uuid), bank_payee_rule_delete(uuid) to authenticated;
