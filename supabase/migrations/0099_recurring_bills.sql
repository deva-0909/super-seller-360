-- 0099: recurring purchase bills (rent, internet, software, retainers).
-- A template makes a normal PENDING purchase bill on each due date; a second person still approves it, so nothing posts by itself.
create table if not exists recurring_bills (
  recurring_id   uuid primary key default gen_random_uuid(),
  name           text not null,
  supplier_id    uuid not null references suppliers(supplier_id),
  frequency      text not null check (frequency in ('monthly','quarterly','yearly')),
  anchor_day     int  not null check (anchor_day between 1 and 31),
  next_date      date not null,
  end_date       date,
  invoice_prefix text not null default 'REC' check (invoice_prefix ~ '^[A-Za-z0-9\-]{2,20}$'),
  lines          jsonb not null,
  itc            boolean not null default true,
  itc_reason     text,
  notes          text,
  status         text not null default 'active' check (status in ('active','paused','ended')),
  runs           int not null default 0,
  last_run_date  date,
  last_bill_id   uuid references purchase_bills(bill_id),
  last_error     text,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now()
);
alter table recurring_bills enable row level security;
drop policy if exists "recurring view" on recurring_bills;
create policy "recurring view" on recurring_bills for select to authenticated using (has_accounting_view());
revoke all on recurring_bills from anon;
revoke insert, update, delete on recurring_bills from authenticated;

-- the date of the n-th next occurrence, keeping the original day of month (31st becomes the last day of shorter months)
create or replace function rb_advance(p_from date, p_freq text, p_anchor int) returns date
language sql immutable set search_path = public, pg_temp as $$
  with m as (select (date_trunc('month', p_from) + (case p_freq when 'monthly' then interval '1 month' when 'quarterly' then interval '3 months' else interval '12 months' end))::date as first)
  select (m.first + (least(p_anchor, extract(day from (m.first + interval '1 month - 1 day'))::int) - 1))::date from m
$$;

create or replace function recurring_bill_save(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := p_id; s suppliers%rowtype; v_first date := (p ->> 'next_date')::date; v_end date := nullif(p ->> 'end_date', '')::date; v_freq text := p ->> 'frequency';
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can set up recurring bills'; end if;
  if nullif(btrim(coalesce(p ->> 'name', '')), '') is null then raise exception 'Give this recurring bill a name'; end if;
  select * into s from suppliers where supplier_id = (p ->> 'supplier_id')::uuid;
  if not found or s.status <> 'active' then raise exception 'Choose an approved supplier'; end if;
  if v_freq not in ('monthly','quarterly','yearly') then raise exception 'Choose how often it repeats'; end if;
  if v_first is null then raise exception 'Enter the first bill date'; end if;
  if v_end is not null and v_end < v_first then raise exception 'The end date is before the first bill date'; end if;
  perform pb_calc(s.supplier_id, p -> 'lines');   -- raises a clear message if the lines are wrong
  if v_id is null then
    insert into recurring_bills (name, supplier_id, frequency, anchor_day, next_date, end_date, invoice_prefix, lines, itc, itc_reason, notes)
    values (btrim(p ->> 'name'), s.supplier_id, v_freq, extract(day from v_first)::int, v_first, v_end, upper(coalesce(nullif(btrim(p ->> 'invoice_prefix'), ''), 'REC')),
            p -> 'lines', coalesce((p ->> 'itc')::boolean, true), nullif(btrim(coalesce(p ->> 'itc_reason', '')), ''), nullif(btrim(coalesce(p ->> 'notes', '')), ''))
    returning recurring_id into v_id;
  else
    update recurring_bills set name = btrim(p ->> 'name'), supplier_id = s.supplier_id, frequency = v_freq, end_date = v_end, lines = p -> 'lines',
           invoice_prefix = upper(coalesce(nullif(btrim(p ->> 'invoice_prefix'), ''), invoice_prefix)), itc = coalesce((p ->> 'itc')::boolean, true),
           itc_reason = nullif(btrim(coalesce(p ->> 'itc_reason', '')), ''), notes = nullif(btrim(coalesce(p ->> 'notes', '')), '')
     where recurring_id = v_id;
    if not found then raise exception 'Recurring bill not found'; end if;
  end if;
  return v_id;
end $$;

create or replace function recurring_bill_set_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_accounting_write() then raise exception 'Not authorized'; end if;
  if p_status not in ('active','paused') then raise exception 'Choose active or paused'; end if;
  update recurring_bills set status = p_status where recurring_id = p_id and status <> 'ended';
  if not found then raise exception 'Recurring bill not found or already ended'; end if;
end $$;

-- Makes the pending bills that are due (up to today). One call per template makes at most 3 catch-up bills.
create or replace function recurring_bill_create_due(p_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r recurring_bills%rowtype; v_made int := 0; v_fail jsonb := '[]'::jsonb; v_bill uuid; i int; v_inv text;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can create bills'; end if;
  for r in select * from recurring_bills where status = 'active' and next_date <= current_date and (p_id is null or recurring_id = p_id) order by next_date for update loop
    i := 0;
    while r.next_date <= current_date and i < 3 and r.status = 'active' loop
      i := i + 1;
      v_inv := r.invoice_prefix || '-' || to_char(r.next_date, 'YYYYMM');
      begin
        v_bill := create_purchase_bill(r.supplier_id, v_inv, r.next_date, r.next_date, r.lines, r.itc, r.itc_reason, coalesce(r.notes, 'Recurring: ' || r.name));
        v_made := v_made + 1;
        r.runs := r.runs + 1; r.last_bill_id := v_bill; r.last_error := null;
      exception when others then
        if sqlerrm like '%already entered%' then
          null;   -- this month's bill is already in; just move on
        else
          v_fail := v_fail || jsonb_build_object('name', r.name, 'error', sqlerrm);
          update recurring_bills set last_error = left(sqlerrm, 300) where recurring_id = r.recurring_id;
          exit;
        end if;
      end;
      r.last_run_date := r.next_date;
      r.next_date := rb_advance(r.next_date, r.frequency, r.anchor_day);
      if r.end_date is not null and r.next_date > r.end_date then r.status := 'ended'; end if;
      update recurring_bills set runs = r.runs, last_bill_id = r.last_bill_id, last_error = r.last_error, last_run_date = r.last_run_date, next_date = r.next_date, status = r.status where recurring_id = r.recurring_id;
    end loop;
  end loop;
  return jsonb_build_object('created', v_made, 'failed', v_fail);
end $$;

revoke execute on function rb_advance(date, text, int), recurring_bill_save(uuid, jsonb), recurring_bill_set_status(uuid, text), recurring_bill_create_due(uuid) from public, anon;
revoke execute on function rb_advance(date, text, int) from authenticated;
grant execute on function recurring_bill_save(uuid, jsonb), recurring_bill_set_status(uuid, text), recurring_bill_create_due(uuid) to authenticated;
