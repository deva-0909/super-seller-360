-- 0077: Journal entry guard rails.
--
-- Problem: an operator picks the wrong ledger or amount, nobody notices, and the books drift.
-- Design for 500-1,000 vouchers a day: most are posted by the system (orders, settlements) from tested rules, so the
-- people-chosen ones (manual journals, bank-matched entries, expense claims) get three layers instead of a manager
-- reading everything:
--   1. WHILE ENTERING  journal_precheck() reads the entry back in plain words and raises warnings (control account,
--      back-dated, duplicate, first-time ledger pair, unusual size, weak narration, missing proof ...). A warning needs a
--      written reason, enforced on the server, not just in the screen.
--   2. HOLD  an entry above the approval limit is saved but not posted until a different manager approves it.
--   3. AFTER POSTING  every people-chosen voucher gets a risk score. High-risk entries must be reviewed; a controlled
--      sample of the rest is reviewed (capped per day so the manager's queue stays workable); new operators and
--      operators with a high error rate are sampled more. The manager marks each OK or Wrong (wrong can reverse the
--      entry in one click) and the operator-quality table shows who needs coaching.
-- Rules are stored in one editable policy row.

-- ---------------------------------------------------------------- helpers and policy
create or replace function has_journal_review() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Finance Manager', 'CEO/Owner', 'Auditor'), false)
$$;

create index if not exists voucher_lines_ledger_ix on voucher_lines (ledger_id, voucher_id);
alter table ledgers add column if not exists is_control boolean not null default false;

create table if not exists journal_policy (
  id                   int primary key default 1 check (id = 1),
  review_amount        numeric(14,2) not null default 50000,    -- an entry this large is always reviewed afterwards
  approval_amount      numeric(14,2) not null default 200000,   -- an entry this large is held until a manager approves it
  proof_amount         numeric(14,2) not null default 10000,    -- from this amount a bill or receipt should be attached
  backdate_days        int not null default 7,
  dup_days             int not null default 7,
  must_review_score    int not null default 40,
  sample_pct           int not null default 10 check (sample_pct between 0 and 100),
  daily_review_cap     int not null default 60,                 -- most reviews the manager is asked for per day (sample ones stop at the cap)
  sla_days             int not null default 2,
  new_operator_entries int not null default 20,                 -- an operator with fewer entries than this is treated as new
  error_rate_pct       int not null default 5,
  odd_from_hour        int not null default 22,
  odd_to_hour          int not null default 6,
  weak_words           text[] not null default '{adjustment,adjust,entry,test,misc,other,na,n/a,journal,correction,temp,xxx,asdf}',
  control_groups       text[] not null default '{"Bank Accounts","Sundry Debtors","Sundry Creditors","Duties & Taxes","Stock-in-Trade","Fixed Assets","Equity"}',
  review_sources       text[] not null default '{manual,recurring,bank_txn,expense_claim}',
  updated_by           uuid,
  updated_at           timestamptz not null default now()
);
insert into journal_policy (id) values (1) on conflict do nothing;
alter table journal_policy enable row level security;
drop policy if exists "jp read" on journal_policy; create policy "jp read" on journal_policy for select to authenticated using (has_accounting_view());
grant select on journal_policy to authenticated;

-- statutory payables raised by payroll are control accounts too
update ledgers set is_control = true where name in ('Salary Payable', 'PF Payable', 'ESI Payable', 'Professional Tax Payable', 'TDS on Salary Payable', 'Labour Welfare Fund Payable', 'Employee Advances');

create table if not exists journal_review (
  voucher_id        uuid primary key references vouchers(voucher_id),
  voucher_no        text,
  entry_date        date not null,
  amount            numeric(14,2) not null default 0,
  source_type       text,
  created_by        uuid,
  created_by_name   text,
  narration         text,
  created_at        timestamptz not null default now(),
  score             int not null default 0,
  flags             jsonb not null default '[]'::jsonb,
  review_class      text not null check (review_class in ('held', 'must', 'sample', 'none')),
  status            text not null check (status in ('held', 'pending', 'auto', 'ok', 'wrong', 'corrected', 'approved', 'rejected')),
  ack_reason        text,
  reviewed_by       uuid,
  reviewed_at       timestamptz,
  review_note       text,
  due_on            date,
  correction_voucher_id uuid references vouchers(voucher_id)
);
create index if not exists journal_review_queue_ix on journal_review (status, review_class, created_at);
create index if not exists journal_review_user_ix on journal_review (created_by, created_at);
alter table journal_review enable row level security;
drop policy if exists "jr read" on journal_review;
create policy "jr read" on journal_review for select to authenticated using (has_journal_review() or created_by = auth.uid());
grant select on journal_review to authenticated;

-- ---------------------------------------------------------------- the checker (used while entering and again when posted)
create or replace function jr_flag(p_code text, p_sev text, p_pts int, p_msg text) returns jsonb language sql immutable as $$
  select jsonb_build_object('code', p_code, 'severity', p_sev, 'points', p_pts, 'message', p_msg)
$$;

create or replace function journal_assess(p_date date, p_narration text, p_lines jsonb, p_user uuid, p_has_proof boolean,
                                          p_source text default 'manual', p_exclude uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  pol journal_policy%rowtype; ln jsonb; flags jsonb := '[]'::jsonb; summ jsonb := '[]'::jsonb; amt numeric := 0; score int; v_hold boolean := false;
  d numeric; c numeric; lid uuid; lname text; lnat text; v_ctl boolean; ctl text[] := '{}'; drs uuid[] := '{}'; crs uuid[] := '{}'; v_manual boolean := (p_source = 'manual');
  mx numeric; cnt int; v_unusual text; pr record; v_pair text; v_hist int; dup text; n_ops int; n_rev int; n_wrong int; v_hr int; v_txt text; v_nl int := 0;
begin
  select * into pol from journal_policy where id = 1;
  if jsonb_typeof(p_lines) is distinct from 'array' then return jsonb_build_object('score', 0, 'amount', 0, 'flags', '[]'::jsonb, 'summary', '[]'::jsonb, 'hold', false, 'needs_reason', false); end if;

  for ln in select * from jsonb_array_elements(p_lines) loop
    lid := nullif(ln ->> 'ledger_id', '')::uuid;
    d := coalesce(nullif(ln ->> 'debit', '')::numeric, 0); c := coalesce(nullif(ln ->> 'credit', '')::numeric, 0);
    continue when lid is null or (d = 0 and c = 0);
    select l.name, l.nature, (l.is_control or g.name = any (pol.control_groups)) into lname, lnat, v_ctl from ledgers l join account_groups g on g.account_group_id = l.account_group_id where l.ledger_id = lid;
    continue when lname is null;
    v_nl := v_nl + 1;
    amt := amt + d;
    if d > 0 then drs := drs || lid; else crs := crs || lid; end if;
    v_txt := case
      when lnat = 'asset'     and d > 0 then 'Increases what you own: ' || lname
      when lnat = 'asset'     and c > 0 then 'Reduces what you own: ' || lname
      when lnat = 'liability' and c > 0 then 'Increases what you owe: ' || lname
      when lnat = 'liability' and d > 0 then 'Reduces what you owe: ' || lname
      when lnat = 'income'    and c > 0 then 'Records income: ' || lname
      when lnat = 'income'    and d > 0 then 'Reduces income: ' || lname
      when lnat = 'expense'   and d > 0 then 'Records an expense: ' || lname
      when lnat = 'expense'   and c > 0 then 'Reduces an expense: ' || lname
      when lnat = 'equity'    and c > 0 then 'Increases owner capital or reserves: ' || lname
      else 'Reduces owner capital or reserves: ' || lname end;
    summ := summ || jsonb_build_object('text', v_txt, 'amount', d + c, 'side', case when d > 0 then 'debit' else 'credit' end);
    if v_manual and v_ctl and not (lname = any (ctl)) then ctl := ctl || lname; end if;
    if (lnat = 'income' and d > 0) or (lnat = 'expense' and c > 0) then
      flags := flags || jr_flag('REDUCES', 'info', 5, lname || ' is being reduced. This is correct for a refund or a correction; check it is what you meant.');
    end if;
    -- far bigger than anything seen on this ledger in the last 90 days
    if v_unusual is null and (d + c) >= 10000 then
      select max(greatest(vl.debit, vl.credit)), count(*) into mx, cnt from voucher_lines vl join vouchers v on v.voucher_id = vl.voucher_id
       where vl.ledger_id = lid and v.status = 'posted' and v.voucher_date > current_date - 90 and v.voucher_id is distinct from p_exclude;
      if cnt >= 5 and (d + c) > 5 * mx then v_unusual := lname; end if;
    end if;
  end loop;
  if v_nl = 0 then return jsonb_build_object('score', 0, 'amount', 0, 'flags', '[]'::jsonb, 'summary', '[]'::jsonb, 'hold', false, 'needs_reason', false); end if;

  if amt >= pol.approval_amount and v_manual then
    v_hold := true;
    flags := flags || jr_flag('HOLD', 'warn', 40, 'This entry is ₹' || to_char(amt, 'FM99,99,99,999') || ' or more. It will be saved but NOT posted until a different manager approves it.');
  elsif amt >= pol.review_amount then
    flags := flags || jr_flag('LARGE', 'info', 25, 'Large entry (₹' || to_char(amt, 'FM99,99,99,999') || '). A manager will check it after it is posted.');
  end if;
  if v_unusual is not null then flags := flags || jr_flag('UNUSUAL_SIZE', 'warn', 20, 'This amount is much larger than anything posted to ' || v_unusual || ' in the last 3 months. Check for an extra zero or a wrong ledger.'); end if;

  if v_manual then
    if p_date < current_date - pol.backdate_days then flags := flags || jr_flag('BACKDATED', 'warn', 20, 'The date is more than ' || pol.backdate_days || ' days in the past. Back-dated entries change reports that were already read.'); end if;
    if p_date > current_date then flags := flags || jr_flag('FUTURE', 'warn', 15, 'The date is in the future.'); end if;
    if array_length(ctl, 1) > 0 then flags := flags || jr_flag('CONTROL', 'warn', 20, 'The system normally updates ' || array_to_string(ctl, ', ') || ' (bank, cash, customers, suppliers, tax, stock or statutory dues). A hand entry here can break its reconciliation. Use the proper screen if there is one.'); end if;
    if exists (select 1 from unnest(drs) x where x = any (crs)) then flags := flags || jr_flag('SAME_LEDGER', 'warn', 15, 'The same ledger is on both the debit and the credit side.'); end if;
    if length(btrim(coalesce(p_narration, ''))) < 8 or lower(btrim(coalesce(p_narration, ''))) = any (pol.weak_words) then
      flags := flags || jr_flag('WEAK_NARRATION', 'warn', 10, 'The narration is too short to tell a reviewer why this entry was made. Say what it is for.');
    end if;
    if p_has_proof is false and amt >= pol.proof_amount then flags := flags || jr_flag('NO_PROOF', 'warn', 15, 'No bill or receipt is attached. Attach one for entries of ₹' || to_char(pol.proof_amount, 'FM99,99,999') || ' or more.'); end if;
    select v.voucher_no into dup from vouchers v
     where v.status in ('posted', 'draft') and v.source_type = 'manual' and v.total_debit = amt and v.voucher_id is distinct from p_exclude
       and v.voucher_date between p_date - pol.dup_days and p_date + pol.dup_days
       and exists (select 1 from voucher_lines vl where vl.voucher_id = v.voucher_id and vl.ledger_id = any (drs || crs)) limit 1;
    if dup is not null then flags := flags || jr_flag('DUPLICATE', 'warn', 30, 'Looks like a duplicate of ' || dup || ' (same amount, same ledger, nearby date).'); end if;
  end if;

  -- a debit/credit pairing nobody has used in the last year is the classic wrong-ledger signature
  select count(*) into v_hist from vouchers where status = 'posted' and voucher_date > current_date - 365;
  if v_hist >= 30 then
    for pr in select dl, cl from unnest(drs) dl, unnest(crs) cl limit 6 loop
      if not exists (select 1 from voucher_lines a join voucher_lines b on b.voucher_id = a.voucher_id and b.ledger_id = pr.cl and b.credit > 0
                      join vouchers v on v.voucher_id = a.voucher_id
                      where a.ledger_id = pr.dl and a.debit > 0 and v.status = 'posted' and v.voucher_date > current_date - 365 and v.voucher_id is distinct from p_exclude) then
        select (select name from ledgers where ledger_id = pr.dl) || ' and ' || (select name from ledgers where ledger_id = pr.cl) into v_pair; exit;
      end if;
    end loop;
    if v_pair is not null then flags := flags || jr_flag('NEW_PAIR', 'info', 10, 'First time in a year that ' || v_pair || ' are used together. Check you picked the right ledgers.'); end if;
  end if;

  v_hr := extract(hour from now() at time zone 'Asia/Kolkata');
  if (pol.odd_from_hour > pol.odd_to_hour and (v_hr >= pol.odd_from_hour or v_hr < pol.odd_to_hour)) or (pol.odd_from_hour < pol.odd_to_hour and v_hr >= pol.odd_from_hour and v_hr < pol.odd_to_hour) then
    flags := flags || jr_flag('ODD_HOURS', 'info', 10, 'Posted outside normal working hours.');
  end if;
  if p_user is not null then
    select count(*) into n_ops from journal_review where created_by = p_user and voucher_id is distinct from p_exclude;
    if n_ops < pol.new_operator_entries then flags := flags || jr_flag('NEW_OPERATOR', 'info', 15, 'Few entries so far by this person; their first entries get extra checking.'); end if;
    select count(*) filter (where status in ('ok', 'wrong', 'corrected')), count(*) filter (where status in ('wrong', 'corrected')) into n_rev, n_wrong
      from journal_review where created_by = p_user and created_at > now() - interval '60 days';
    if n_rev >= 5 and n_wrong * 100 >= pol.error_rate_pct * n_rev then flags := flags || jr_flag('ERROR_RATE', 'info', 15, 'Recent entries by this person needed correction, so they get extra checking.'); end if;
  end if;

  select least(100, coalesce(sum((f ->> 'points')::int), 0)) into score from jsonb_array_elements(flags) f;
  return jsonb_build_object('score', score, 'amount', amt, 'flags', flags, 'summary', summ, 'hold', v_hold,
                            'needs_reason', exists (select 1 from jsonb_array_elements(flags) f where f ->> 'severity' = 'warn'));
end $$;

create or replace function journal_precheck(p_date date, p_narration text, p_lines jsonb, p_has_proof boolean default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can post a journal entry'; end if;
  return journal_assess(p_date, p_narration, p_lines, auth.uid(), p_has_proof, 'manual', null);
end $$;

-- ---------------------------------------------------------------- capture after posting
create or replace function journal_review_capture(p_voucher uuid, p_hold boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v vouchers%rowtype; pol journal_policy%rowtype; a jsonb; v_lines jsonb; v_cls text; v_st text; v_proof boolean; v_today int; v_score int;
begin
  select * into v from vouchers where voucher_id = p_voucher;
  if not found or exists (select 1 from journal_review where voucher_id = p_voucher) then return; end if;
  select * into pol from journal_policy where id = 1;
  if v.source_type is null or not (v.source_type = any (pol.review_sources)) then return; end if;
  select jsonb_agg(jsonb_build_object('ledger_id', ledger_id, 'debit', debit, 'credit', credit)) into v_lines from voucher_lines where voucher_id = p_voucher;
  v_proof := case when v.source_type = 'manual' then nullif(current_setting('app.jr_proof', true), '')::boolean else null end;
  a := journal_assess(v.voucher_date, v.narration, v_lines, v.created_by, v_proof, v.source_type, p_voucher);
  v_score := (a ->> 'score')::int;
  select count(*) into v_today from journal_review where created_at::date = current_date and review_class in ('must', 'sample');
  if p_hold then v_cls := 'held'; v_st := 'held';
  elsif v.source_type = 'recurring' and exists (select 1 from journal_review where source_type = 'recurring' and voucher_id in (select voucher_id from vouchers where source_id = v.source_id and voucher_id <> p_voucher)) then v_cls := 'none'; v_st := 'auto';
  elsif v_score >= pol.must_review_score then v_cls := 'must'; v_st := 'pending';
  elsif v_today < pol.daily_review_cap and (abs(hashtext(p_voucher::text)) % 100) < least(100, pol.sample_pct * case when exists (select 1 from jsonb_array_elements(a -> 'flags') f where f ->> 'code' in ('NEW_OPERATOR', 'ERROR_RATE')) then 3 else 1 end) then v_cls := 'sample'; v_st := 'pending';
  else v_cls := 'none'; v_st := 'auto'; end if;
  insert into journal_review (voucher_id, voucher_no, entry_date, amount, source_type, created_by, created_by_name, narration, score, flags, review_class, status, ack_reason, due_on)
  values (p_voucher, v.voucher_no, v.voucher_date, (a ->> 'amount')::numeric, v.source_type, v.created_by, (select name from user_profiles where user_id = v.created_by), v.narration, v_score, a -> 'flags', v_cls, v_st,
          nullif(btrim(coalesce(current_setting('app.jr_reason', true), '')), ''), case when v_st in ('held', 'pending') then current_date + pol.sla_days end);
end $$;

create or replace function jr_after_post() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin perform journal_review_capture(new.voucher_id, false);
  exception when others then raise warning 'journal review capture failed for %: %', new.voucher_no, sqlerrm; end;
  return new;
end $$;
drop trigger if exists trg_journal_review on vouchers;
create trigger trg_journal_review after update of status on vouchers for each row when (old.status = 'draft' and new.status = 'posted') execute function jr_after_post();

-- ---------------------------------------------------------------- manual journal: server-side enforcement
drop function if exists post_manual_journal(date, text, jsonb, jsonb);
create or replace function post_manual_journal(p_date date, p_narration text, p_lines jsonb, p_recurring jsonb default null, p_has_proof boolean default null, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_freq text; v_end date; v_rid uuid; v_res jsonb; v_name text; a jsonb;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can post a journal entry'; end if;
  a := journal_assess(p_date, p_narration, p_lines, auth.uid(), p_has_proof, 'manual', null);
  if (a ->> 'needs_reason')::boolean and length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'Please read the warnings and give a reason (at least 5 letters) before posting';
  end if;
  perform set_config('app.jr_reason', coalesce(btrim(p_reason), ''), true);
  perform set_config('app.jr_proof', coalesce(p_has_proof::text, ''), true);
  if (a ->> 'hold')::boolean then
    if p_recurring is not null and coalesce(p_recurring ->> 'frequency', '') <> '' then raise exception 'An entry this large cannot be set to repeat. Post it once and have it approved.'; end if;
    v_res := acc_post_journal(p_date, p_narration, p_lines, 'manual', null, 'draft', auth.uid());
    perform journal_review_capture((v_res ->> 'voucher_id')::uuid, true);
    return v_res || jsonb_build_object('held', true);
  end if;
  if p_recurring is not null and coalesce(p_recurring ->> 'frequency', '') <> '' then
    v_freq := p_recurring ->> 'frequency';
    if v_freq not in ('weekly', 'fortnightly', 'monthly', 'quarterly', 'half_yearly', 'annual') then
      raise exception 'Repeat must be weekly, fortnightly, monthly, quarterly, half-yearly or annual';
    end if;
    v_end := nullif(p_recurring ->> 'end_date', '')::date;
    if v_end is not null and v_end < p_date then raise exception 'The repeat end date is before the entry date'; end if;
    v_name := coalesce(nullif(btrim(p_recurring ->> 'name'), ''), nullif(btrim(p_narration), ''), 'Recurring journal');
    insert into recurring_journals (name, narration, frequency, start_date, end_date, lines, runs, next_run_date, last_run_date, created_by)
    values (v_name, nullif(btrim(p_narration), ''), v_freq, p_date, v_end, p_lines, 0, p_date, null, auth.uid())
    returning recurring_id into v_rid;
    v_res := acc_post_journal(p_date, p_narration, p_lines, 'recurring', v_rid, 'posted', auth.uid());
    insert into recurring_journal_runs (recurring_id, run_date, voucher_id, voucher_no)
    values (v_rid, p_date, (v_res ->> 'voucher_id')::uuid, v_res ->> 'voucher_no');
    update recurring_journals set runs = 1, last_run_date = p_date, next_run_date = rj_occurrence(p_date, v_freq, 1),
           status = case when v_end is not null and rj_occurrence(p_date, v_freq, 1) > v_end then 'ended' else 'active' end
     where recurring_id = v_rid;
    return v_res || jsonb_build_object('recurring_id', v_rid,
             'next_run_date', (select next_run_date from recurring_journals where recurring_id = v_rid));
  end if;
  return acc_post_journal(p_date, p_narration, p_lines, 'manual', null, 'posted', auth.uid());
end $$;

-- ---------------------------------------------------------------- reviewer actions
create or replace function jr_reviewer_check(p_creator uuid) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can review journal entries'; end if;
  if not pur_self_ok(p_creator) then raise exception 'A different person must review this entry (you posted it)'; end if;
end $$;

create or replace function journal_review_set(p_voucher uuid, p_outcome text, p_note text default null, p_reverse boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r journal_review%rowtype; v_rev uuid;
begin
  select * into r from journal_review where voucher_id = p_voucher for update;
  if not found then raise exception 'This entry is not in the review list'; end if;
  perform jr_reviewer_check(r.created_by);
  if r.status not in ('pending', 'auto') then raise exception 'This entry has already been dealt with'; end if;
  if p_outcome = 'ok' then
    update journal_review set status = 'ok', reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(btrim(coalesce(p_note, '')), '') where voucher_id = p_voucher;
    return jsonb_build_object('status', 'ok');
  elsif p_outcome = 'wrong' then
    if length(btrim(coalesce(p_note, ''))) < 5 then raise exception 'Say what was wrong (at least 5 letters) so the operator can learn from it'; end if;
    if p_reverse then
      if r.source_type not in ('manual', 'recurring') then raise exception 'Only a hand-written journal can be reversed here. Correct this one from the screen that created it.'; end if;
      v_rev := br_reverse_voucher(p_voucher, 'review: ' || btrim(p_note));
      update journal_review set status = 'corrected', reviewed_by = auth.uid(), reviewed_at = now(), review_note = btrim(p_note), correction_voucher_id = v_rev where voucher_id = p_voucher;
      return jsonb_build_object('status', 'corrected', 'reversal_voucher_id', v_rev);
    end if;
    update journal_review set status = 'wrong', reviewed_by = auth.uid(), reviewed_at = now(), review_note = btrim(p_note) where voucher_id = p_voucher;
    return jsonb_build_object('status', 'wrong');
  end if;
  raise exception 'Choose OK or Wrong';
end $$;

create or replace function journal_review_bulk_ok(p_vouchers uuid[]) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can review journal entries'; end if;
  for r in select voucher_id, created_by from journal_review where voucher_id = any (p_vouchers) and status = 'pending' and review_class = 'sample' for update loop
    if pur_self_ok(r.created_by) then
      update journal_review set status = 'ok', reviewed_by = auth.uid(), reviewed_at = now(), review_note = 'bulk OK' where voucher_id = r.voucher_id; n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function journal_hold_decide(p_voucher uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r journal_review%rowtype; v vouchers%rowtype;
begin
  select * into r from journal_review where voucher_id = p_voucher for update;
  if not found or r.status <> 'held' then raise exception 'This entry is not waiting for approval'; end if;
  perform jr_reviewer_check(r.created_by);
  select * into v from vouchers where voucher_id = p_voucher for update;
  if p_approve then
    if not exists (select 1 from accounting_periods where v.voucher_date between start_date and end_date and status = 'open') then raise exception 'The accounting period for % is closed', v.voucher_date; end if;
    update vouchers set status = 'posted', approved_by = auth.uid() where voucher_id = p_voucher;
    update journal_review set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(btrim(coalesce(p_note, '')), '') where voucher_id = p_voucher;
  else
    if length(btrim(coalesce(p_note, ''))) < 5 then raise exception 'Say why it is rejected (at least 5 letters)'; end if;
    update vouchers set status = 'cancelled' where voucher_id = p_voucher;
    update journal_review set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_note = btrim(p_note) where voucher_id = p_voucher;
  end if;
end $$;

create or replace function journal_policy_save(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare k text; v numeric;
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can change the review rules'; end if;
  for k in select jsonb_object_keys(p) loop
    if k in ('review_amount', 'approval_amount', 'proof_amount', 'backdate_days', 'dup_days', 'must_review_score', 'sample_pct', 'daily_review_cap', 'sla_days', 'new_operator_entries', 'error_rate_pct', 'odd_from_hour', 'odd_to_hour') then
      v := (p ->> k)::numeric; if v is null or v < 0 then raise exception '% cannot be negative', k; end if;
      if k = 'sample_pct' and v > 100 then raise exception 'Sample percentage cannot be above 100'; end if;
      if k in ('odd_from_hour', 'odd_to_hour') and v > 23 then raise exception 'Hours run from 0 to 23'; end if;
      execute format('update journal_policy set %I = $1, updated_by = auth.uid(), updated_at = now() where id = 1', k) using v;
    elsif k in ('weak_words', 'control_groups', 'review_sources') then
      if jsonb_typeof(p -> k) <> 'array' then raise exception '% must be a list', k; end if;
      execute format('update journal_policy set %I = $1, updated_by = auth.uid(), updated_at = now() where id = 1', k) using (select coalesce(array_agg(x), '{}') from jsonb_array_elements_text(p -> k) x);
    else raise exception 'Unknown setting %', k; end if;
  end loop;
  if (select approval_amount from journal_policy where id = 1) < (select review_amount from journal_policy where id = 1) then raise exception 'The approval limit cannot be below the review amount'; end if;
end $$;

create or replace function ledger_set_control(p_ledger uuid, p_control boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can change this'; end if;
  update ledgers set is_control = p_control where ledger_id = p_ledger;
end $$;

-- ---------------------------------------------------------------- how each person is doing
create or replace function journal_control_summary(p_from date, p_to date) returns table
  (user_id uuid, name text, entries bigint, value numeric, flagged bigint, held bigint, pending bigint, reviewed bigint, wrong bigint, error_pct numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_journal_review() then return; end if;
  return query
  select j.created_by, coalesce(u.name, 'Unknown'), count(*), coalesce(sum(j.amount), 0), count(*) filter (where j.score >= 20), count(*) filter (where j.status = 'held'),
         count(*) filter (where j.status = 'pending'), count(*) filter (where j.status in ('ok', 'wrong', 'corrected')), count(*) filter (where j.status in ('wrong', 'corrected')),
         round(100.0 * count(*) filter (where j.status in ('wrong', 'corrected')) / nullif(count(*) filter (where j.status in ('ok', 'wrong', 'corrected')), 0), 1)
    from journal_review j left join user_profiles u on u.user_id = j.created_by
   where j.entry_date between p_from and p_to group by j.created_by, u.name order by 2;
end $$;

-- ---------------------------------------------------------------- navigation access
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
    'purchasing_view', has_po_view(),
    'payroll_view', has_payroll_view(),
    'journal_review', has_journal_review(),
    'automation_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager'), false),
    'uploads', import_can('products') or import_can('opening_stock') or import_can('listing_map') or import_can('ledger_opening') or import_can('orders') or import_can('settlement')
  )
$$;

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
from journal_review where status = 'pending' and review_class = 'must' having count(*) > 0 and has_purchase_approve();

-- ---------------------------------------------------------------- permissions
revoke execute on function has_journal_review(), jr_flag(text, text, int, text), journal_assess(date, text, jsonb, uuid, boolean, text, uuid), journal_precheck(date, text, jsonb, boolean),
  journal_review_capture(uuid, boolean), jr_after_post(), post_manual_journal(date, text, jsonb, jsonb, boolean, text), jr_reviewer_check(uuid), journal_review_set(uuid, text, text, boolean),
  journal_review_bulk_ok(uuid[]), journal_hold_decide(uuid, boolean, text), journal_policy_save(jsonb), ledger_set_control(uuid, boolean), journal_control_summary(date, date), my_nav_access() from public, anon, authenticated;
grant execute on function has_journal_review(), journal_precheck(date, text, jsonb, boolean), post_manual_journal(date, text, jsonb, jsonb, boolean, text), journal_review_set(uuid, text, text, boolean),
  journal_review_bulk_ok(uuid[]), journal_hold_decide(uuid, boolean, text), journal_policy_save(jsonb), ledger_set_control(uuid, boolean), journal_control_summary(date, date), my_nav_access() to authenticated;
