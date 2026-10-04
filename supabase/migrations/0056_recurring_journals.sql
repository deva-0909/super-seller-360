-- 0056: Manual journal entries, optionally recurring.
--
-- post_manual_journal() posts a hand-written journal entry. If the entry is marked recurring (weekly, fortnightly, monthly,
-- quarterly, half-yearly or annual) a schedule is saved and run_recurring_journals() posts each later occurrence when it falls
-- due. The first occurrence is the entry itself. A run is idempotent (one voucher per schedule per date), catches up on missed
-- dates, and never skips: if a period is closed the schedule waits and shows the reason until it can post.

create table if not exists recurring_journals (
  recurring_id   uuid primary key default gen_random_uuid(),
  name           text not null,
  narration      text,
  frequency      text not null check (frequency in ('weekly', 'fortnightly', 'monthly', 'quarterly', 'half_yearly', 'annual')),
  start_date     date not null,
  end_date       date check (end_date is null or end_date >= start_date),
  lines          jsonb not null,
  runs           int not null default 0,              -- vouchers posted so far, the first entry included
  next_run_date  date not null,
  last_run_date  date,
  last_error     text,
  status         text not null default 'active' check (status in ('active', 'paused', 'ended')),
  created_by     uuid,
  created_at     timestamptz not null default now()
);
create index if not exists recurring_journals_due on recurring_journals (status, next_run_date);

create table if not exists recurring_journal_runs (
  run_id        uuid primary key default gen_random_uuid(),
  recurring_id  uuid not null references recurring_journals(recurring_id) on delete cascade,
  run_date      date not null,
  voucher_id    uuid references vouchers(voucher_id),
  voucher_no    text,
  created_at    timestamptz not null default now(),
  unique (recurring_id, run_date)
);

alter table recurring_journals     enable row level security;
alter table recurring_journal_runs enable row level security;
drop policy if exists "rj view" on recurring_journals;     create policy "rj view" on recurring_journals     for select to authenticated using (has_accounting_view());
drop policy if exists "rj view" on recurring_journal_runs; create policy "rj view" on recurring_journal_runs for select to authenticated using (has_accounting_view());

-- the n-th occurrence counted from the start date (computed from the start so month-ends never drift: 31 Jan, 28 Feb, 31 Mar ...)
create or replace function rj_occurrence(p_start date, p_freq text, p_n int) returns date
language sql immutable as $$
  select (case p_freq
    when 'weekly'      then p_start + p_n * 7
    when 'fortnightly' then p_start + p_n * 14
    when 'monthly'     then (p_start + make_interval(months => p_n))::date
    when 'quarterly'   then (p_start + make_interval(months => 3 * p_n))::date
    when 'half_yearly' then (p_start + make_interval(months => 6 * p_n))::date
    when 'annual'      then (p_start + make_interval(months => 12 * p_n))::date
  end)::date
$$;

create or replace function post_manual_journal(p_date date, p_narration text, p_lines jsonb, p_recurring jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_freq text; v_end date; v_rid uuid; v_res jsonb; v_name text;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can post a journal entry'; end if;
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

-- Posts every occurrence that has fallen due. Safe to call at any time and from any session: it only posts what an
-- accountant already scheduled, once per date.
create or replace function run_recurring_journals(p_upto date default current_date) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; v_posted int := 0; v_guard int; v_res jsonb; v_next date;
begin
  for r in select * from recurring_journals where status = 'active' and next_run_date <= p_upto order by next_run_date for update skip locked loop
    v_guard := 0;
    while r.next_run_date <= p_upto and v_guard < 24 loop
      v_guard := v_guard + 1;
      if r.end_date is not null and r.next_run_date > r.end_date then
        update recurring_journals set status = 'ended', last_error = null where recurring_id = r.recurring_id;
        exit;
      end if;
      begin
        if exists (select 1 from recurring_journal_runs where recurring_id = r.recurring_id and run_date = r.next_run_date) then
          null;  -- already posted for this date
        else
          v_res := acc_post_journal(r.next_run_date, r.narration, r.lines, 'recurring', r.recurring_id, 'posted', r.created_by);
          insert into recurring_journal_runs (recurring_id, run_date, voucher_id, voucher_no)
          values (r.recurring_id, r.next_run_date, (v_res ->> 'voucher_id')::uuid, v_res ->> 'voucher_no');
          v_posted := v_posted + 1;
        end if;
        r.runs := r.runs + 1;
        v_next := rj_occurrence(r.start_date, r.frequency, r.runs);
        update recurring_journals set runs = r.runs, last_run_date = r.next_run_date, next_run_date = v_next, last_error = null,
               status = case when end_date is not null and v_next > end_date then 'ended' else 'active' end
         where recurring_id = r.recurring_id;
        r.next_run_date := v_next;
      exception when others then
        update recurring_journals set last_error = left(sqlerrm, 300) where recurring_id = r.recurring_id;
        exit;   -- wait here until the problem (e.g. a closed period) is fixed; nothing is skipped
      end;
    end loop;
  end loop;
  return jsonb_build_object('posted', v_posted);
end $$;

create or replace function set_recurring_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can change a recurring entry'; end if;
  if p_status not in ('active', 'paused', 'ended') then raise exception 'Unknown status'; end if;
  update recurring_journals set status = p_status, last_error = case when p_status = 'active' then last_error else null end where recurring_id = p_id;
  if not found then raise exception 'Recurring entry not found'; end if;
end $$;

revoke execute on function rj_occurrence(date, text, int), post_manual_journal(date, text, jsonb, jsonb), run_recurring_journals(date),
  set_recurring_status(uuid, text) from public, anon, authenticated;
grant execute on function rj_occurrence(date, text, int), post_manual_journal(date, text, jsonb, jsonb), run_recurring_journals(date),
  set_recurring_status(uuid, text) to authenticated;
grant execute on function run_recurring_journals(date) to service_role;
