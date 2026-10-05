-- Payroll part 2: payslips for employees, leave, statutory bonus, gratuity, full-and-final settlement.
-- Every rate is editable and should be confirmed with your CA / labour consultant.

-- ---------------------------------------------------------------- settings
create table if not exists payroll_exit_settings (
  id                 int primary key default 1 check (id = 1),
  bonus_pct          numeric(5,2) not null default 8.33 check (bonus_pct between 0 and 40),     -- 8.33% minimum, up to 20% of wage
  bonus_eligible_wage numeric(10,2) not null default 21000,                                      -- employees earning (basic + DA) above this a month get no statutory bonus
  bonus_calc_cap     numeric(10,2) not null default 7000,                                        -- bonus is worked out on wage up to this a month (or the state minimum wage if higher: enter that here)
  bonus_min_days     int not null default 30,                                                    -- must have worked at least this many days in the year
  gratuity_days      numeric(5,2) not null default 15,
  gratuity_divisor   numeric(5,2) not null default 26,
  gratuity_min_years int not null default 5,                                                     -- 5 years of service (1 year for fixed-term staff under the Code on Social Security: set 1 if all your staff are fixed-term)
  gratuity_cap       numeric(12,2) not null default 2000000,
  leave_per_month    numeric(5,2) not null default 1.5,                                          -- earned leave added each month
  leave_divisor      numeric(5,2) not null default 26,                                           -- days used to turn monthly pay into a day's pay
  leave_encash_cap   numeric(8,2) not null default 30,                                           -- most days paid out at exit
  updated_by         uuid,
  updated_at         timestamptz not null default now()
);
insert into payroll_exit_settings (id) values (1) on conflict do nothing;
alter table payroll_exit_settings enable row level security;
drop policy if exists "pes read" on payroll_exit_settings; create policy "pes read" on payroll_exit_settings for select to authenticated using (has_payroll_view());
grant select on payroll_exit_settings to authenticated;

create or replace function payroll_exit_settings_save(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can change these rates'; end if;
  update payroll_exit_settings set
    bonus_pct = coalesce(nullif(p ->> 'bonus_pct', '')::numeric, bonus_pct), bonus_eligible_wage = coalesce(nullif(p ->> 'bonus_eligible_wage', '')::numeric, bonus_eligible_wage),
    bonus_calc_cap = coalesce(nullif(p ->> 'bonus_calc_cap', '')::numeric, bonus_calc_cap), bonus_min_days = coalesce(nullif(p ->> 'bonus_min_days', '')::int, bonus_min_days),
    gratuity_days = coalesce(nullif(p ->> 'gratuity_days', '')::numeric, gratuity_days), gratuity_divisor = coalesce(nullif(p ->> 'gratuity_divisor', '')::numeric, gratuity_divisor),
    gratuity_min_years = coalesce(nullif(p ->> 'gratuity_min_years', '')::int, gratuity_min_years), gratuity_cap = coalesce(nullif(p ->> 'gratuity_cap', '')::numeric, gratuity_cap),
    leave_per_month = coalesce(nullif(p ->> 'leave_per_month', '')::numeric, leave_per_month), leave_divisor = coalesce(nullif(p ->> 'leave_divisor', '')::numeric, leave_divisor),
    leave_encash_cap = coalesce(nullif(p ->> 'leave_encash_cap', '')::numeric, leave_encash_cap), updated_by = auth.uid(), updated_at = now() where id = 1;
exception when check_violation then raise exception 'One of the values is outside its allowed range';
end $$;

-- ---------------------------------------------------------------- ledgers
insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = v.grp limit 1), v.name, v.nature, 0, v.ob, false, false, 'active'
from (values
  ('Indirect Expenses',   'Bonus Expense',                 'expense',   'debit'),
  ('Indirect Expenses',   'Gratuity Expense',              'expense',   'debit'),
  ('Indirect Expenses',   'Leave Encashment Expense',      'expense',   'debit'),
  ('Current Liabilities', 'Bonus Payable',                 'liability', 'credit'),
  ('Current Liabilities', 'Full and Final Payable',        'liability', 'credit')
) as v(grp, name, nature, ob)
where not exists (select 1 from ledgers l where l.name = v.name);

-- ---------------------------------------------------------------- payslips: an employee sees only their own, matched on e-mail
create or replace function my_payslips() returns table (
  month date, run_no text, status text, emp_code text, emp_name text, designation text, days_in_month int, paid_days numeric, lop_days numeric,
  basic numeric, da numeric, hra numeric, other_allowance numeric, extra_earning numeric, gross numeric, pf_ee numeric, esi_ee numeric, pt numeric, lwf_ee numeric, tds numeric, other_ded numeric, net_pay numeric, paid_on date)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_mail text := lower(btrim(coalesce(auth.jwt() ->> 'email', ''))); v_emp uuid; v_n int;
begin
  if v_mail = '' then return; end if;
  select count(*), min(emp_id::text)::uuid into v_n, v_emp from employees where lower(btrim(email)) = v_mail;
  if v_n <> 1 then return; end if;
  return query select r.month, r.run_no, r.status, e.emp_code, e.name, e.designation, l.days_in_month, l.paid_days, l.lop_days, l.basic, l.da, l.hra, l.other_allowance, l.extra_earning, l.gross,
                      l.pf_ee, l.esi_ee, l.pt, l.lwf_ee, l.tds, l.other_ded, l.net_pay, r.paid_on
                 from payroll_lines l join payroll_runs r on r.run_id = l.run_id join employees e on e.emp_id = l.emp_id
                where l.emp_id = v_emp and r.status in ('approved', 'paid') order by r.month desc;
end $$;

-- ---------------------------------------------------------------- leave
create table if not exists leave_entries (
  entry_id    uuid primary key default gen_random_uuid(),
  emp_id      uuid not null references employees(emp_id),
  entry_date  date not null default current_date,
  kind        text not null check (kind in ('earned', 'taken', 'encashed', 'adjust')),
  days        numeric(6,2) not null check (days <> 0),      -- positive adds to the balance, negative uses it
  month       date,
  note        text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create unique index if not exists leave_earned_uq on leave_entries (emp_id, month) where kind = 'earned';
alter table leave_entries enable row level security;
drop policy if exists "leave read" on leave_entries; create policy "leave read" on leave_entries for select to authenticated using (has_payroll_view());
grant select on leave_entries to authenticated;

create or replace view leave_balances with (security_invoker = true) as
select e.emp_id, e.emp_code, e.name, e.status, coalesce(sum(l.days), 0) as balance,
       coalesce(sum(l.days) filter (where l.kind = 'earned'), 0) as earned, coalesce(-sum(l.days) filter (where l.kind = 'taken'), 0) as taken,
       coalesce(-sum(l.days) filter (where l.kind = 'encashed'), 0) as encashed
  from employees e left join leave_entries l on l.emp_id = e.emp_id group by e.emp_id, e.emp_code, e.name, e.status;
grant select on leave_balances to authenticated;

create or replace function leave_accrue(p_month date) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare m date := date_trunc('month', p_month)::date; n int; v numeric;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can add earned leave'; end if;
  if m > date_trunc('month', current_date)::date then raise exception 'You can add earned leave only up to the current month'; end if;
  select leave_per_month into v from payroll_exit_settings where id = 1;
  if v <= 0 then raise exception 'Earned leave per month is set to zero in the rates'; end if;
  insert into leave_entries (emp_id, entry_date, kind, days, month, note)
  select emp_id, current_date, 'earned', v, m, 'Earned leave for ' || to_char(m, 'Mon YYYY') from employees
   where date_of_joining <= (m + interval '1 month - 1 day')::date and (date_of_leaving is null or date_of_leaving >= m)
  on conflict do nothing;
  get diagnostics n = row_count; return n;
end $$;

create or replace function leave_record(p_emp uuid, p_kind text, p_days numeric, p_date date, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bal numeric;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can record leave'; end if;
  if p_kind not in ('taken', 'adjust') then raise exception 'Choose leave taken or a balance correction'; end if;
  if p_days is null or p_days = 0 then raise exception 'Enter the number of days'; end if;
  if p_kind = 'taken' then
    if p_days < 0 then raise exception 'Enter leave taken as a positive number of days'; end if;
    select coalesce(sum(days), 0) into v_bal from leave_entries where emp_id = p_emp;
    if p_days > v_bal then raise exception 'Only % days of leave are left for this person', trim_scale(v_bal); end if;
    p_days := -p_days;
  elsif btrim(coalesce(p_note, '')) = '' then raise exception 'Say why the balance is being corrected'; end if;
  if not exists (select 1 from employees where emp_id = p_emp) then raise exception 'Employee not found'; end if;
  insert into leave_entries (emp_id, entry_date, kind, days, note) values (p_emp, coalesce(p_date, current_date), p_kind, p_days, nullif(btrim(coalesce(p_note, '')), ''));
end $$;

-- ---------------------------------------------------------------- statutory bonus
create sequence if not exists bonus_run_seq;
create table if not exists bonus_runs (
  bonus_id    uuid primary key default gen_random_uuid(),
  bonus_no    text not null unique,
  fy          int not null,                                 -- 2025 means April 2025 to March 2026
  status      text not null default 'draft' check (status in ('draft', 'approved', 'paid', 'cancelled')),
  pct         numeric(5,2) not null,
  voucher_id  uuid references vouchers(voucher_id),
  paid_voucher_id uuid references vouchers(voucher_id),
  paid_on     date,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  approved_by uuid,
  approved_at timestamptz
);
create unique index if not exists bonus_runs_fy_uq on bonus_runs (fy) where status <> 'cancelled';
create table if not exists bonus_lines (
  line_id     uuid primary key default gen_random_uuid(),
  bonus_id    uuid not null references bonus_runs(bonus_id) on delete cascade,
  emp_id      uuid not null references employees(emp_id),
  days_worked numeric(6,2) not null default 0,
  months      int not null default 0,
  bonus_wage  numeric(12,2) not null default 0,             -- total wage the bonus is worked out on
  computed    numeric(12,2) not null default 0,
  amount      numeric(12,2) not null default 0,             -- what will be paid (you can change it)
  tds         numeric(12,2) not null default 0,
  note        text,
  eligible    boolean not null default true,
  reason      text,
  unique (bonus_id, emp_id)
);
alter table bonus_runs enable row level security; alter table bonus_lines enable row level security;
drop policy if exists "bonus read" on bonus_runs; create policy "bonus read" on bonus_runs for select to authenticated using (has_payroll_view());
drop policy if exists "bonusl read" on bonus_lines; create policy "bonusl read" on bonus_lines for select to authenticated using (has_payroll_view());
grant select on bonus_runs, bonus_lines to authenticated;

create or replace function bonus_fill(p_bonus uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b bonus_runs%rowtype; s payroll_exit_settings%rowtype; r record; v_from date; v_to date;
begin
  select * into b from bonus_runs where bonus_id = p_bonus; select * into s from payroll_exit_settings where id = 1;
  v_from := make_date(b.fy, 4, 1); v_to := make_date(b.fy + 1, 3, 1);
  delete from bonus_lines where bonus_id = p_bonus;
  for r in
    select e.emp_id, coalesce(sum(l.paid_days), 0) as days, count(*) as n, coalesce(sum(least(l.basic + l.da, s.bonus_calc_cap)), 0) as wage, coalesce(max(l.basic + l.da), 0) as top_wage
      from employees e join payroll_lines l on l.emp_id = e.emp_id join payroll_runs pr on pr.run_id = l.run_id and pr.status in ('approved', 'paid') and pr.month between v_from and v_to
     group by e.emp_id
  loop
    insert into bonus_lines (bonus_id, emp_id, days_worked, months, bonus_wage, computed, amount, eligible, reason)
    values (p_bonus, r.emp_id, r.days, r.n, round(r.wage, 2),
            case when r.days >= s.bonus_min_days and r.top_wage <= s.bonus_eligible_wage then round(r.wage * b.pct / 100, 2) else 0 end,
            case when r.days >= s.bonus_min_days and r.top_wage <= s.bonus_eligible_wage then round(r.wage * b.pct / 100, 2) else 0 end,
            r.days >= s.bonus_min_days and r.top_wage <= s.bonus_eligible_wage,
            case when r.days < s.bonus_min_days then 'Worked fewer than ' || s.bonus_min_days || ' days' when r.top_wage > s.bonus_eligible_wage then 'Monthly basic + DA is above the eligibility limit' end);
  end loop;
end $$;

create or replace function bonus_create(p_fy int) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; s payroll_exit_settings%rowtype;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can prepare the bonus'; end if;
  if p_fy is null or p_fy < 2015 or p_fy > extract(year from current_date)::int then raise exception 'Choose a financial year (2025 means April 2025 to March 2026)'; end if;
  if exists (select 1 from bonus_runs where fy = p_fy and status <> 'cancelled') then raise exception 'A bonus for this year already exists'; end if;
  select * into s from payroll_exit_settings where id = 1;
  insert into bonus_runs (bonus_no, fy, pct) values ('BN-' || p_fy || '-' || lpad(nextval('bonus_run_seq')::text, 3, '0'), p_fy, s.bonus_pct) returning bonus_id into v;
  perform bonus_fill(v);
  if not exists (select 1 from bonus_lines where bonus_id = v) then delete from bonus_runs where bonus_id = v; raise exception 'No approved pay runs found for that year'; end if;
  return v;
end $$;

create or replace function bonus_recalculate(p_bonus uuid, p_pct numeric default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b bonus_runs%rowtype;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can prepare the bonus'; end if;
  select * into b from bonus_runs where bonus_id = p_bonus for update;
  if not found or b.status <> 'draft' then raise exception 'Only a draft bonus can be recalculated'; end if;
  if p_pct is not null then
    if p_pct < 8.33 or p_pct > 20 then raise exception 'The Act allows 8.33%% to 20%% of wage'; end if;
    update bonus_runs set pct = p_pct where bonus_id = p_bonus;
  end if;
  perform bonus_fill(p_bonus);
end $$;

create or replace function bonus_line_set(p_line uuid, p_amount numeric, p_tds numeric, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b bonus_runs%rowtype;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can change the bonus'; end if;
  select r.* into b from bonus_runs r join bonus_lines l on l.bonus_id = r.bonus_id where l.line_id = p_line for update of r;
  if not found or b.status <> 'draft' then raise exception 'Only a draft bonus can be changed'; end if;
  if p_amount is null or p_amount < 0 or coalesce(p_tds, 0) < 0 then raise exception 'Amounts cannot be negative'; end if;
  if coalesce(p_tds, 0) > p_amount then raise exception 'Tax cannot be more than the bonus'; end if;
  if p_amount <> (select computed from bonus_lines where line_id = p_line) and btrim(coalesce(p_note, '')) = '' then raise exception 'Say why the amount differs from the calculated bonus'; end if;
  update bonus_lines set amount = round(p_amount, 2), tds = round(coalesce(p_tds, 0), 2), note = nullif(btrim(coalesce(p_note, '')), '') where line_id = p_line;
end $$;

create or replace function bonus_cancel(p_bonus uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can cancel the bonus'; end if;
  update bonus_runs set status = 'cancelled' where bonus_id = p_bonus and status = 'draft';
  if not found then raise exception 'Only a draft bonus can be cancelled'; end if;
end $$;

create or replace function bonus_approve(p_bonus uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b bonus_runs%rowtype; t record; l_exp uuid; l_pay uuid; l_tds uuid; v_lines jsonb; v_res jsonb;
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can approve the bonus'; end if;
  select * into b from bonus_runs where bonus_id = p_bonus for update;
  if not found or b.status <> 'draft' then raise exception 'Only a draft bonus can be approved'; end if;
  if not pur_self_ok(b.created_by) then raise exception 'A different person must approve this bonus (you prepared it)'; end if;
  select coalesce(sum(amount), 0) amt, coalesce(sum(tds), 0) tds into t from bonus_lines where bonus_id = p_bonus;
  if t.amt <= 0 then raise exception 'There is no bonus to pay'; end if;
  select ledger_id into l_exp from ledgers where name = 'Bonus Expense'; select ledger_id into l_pay from ledgers where name = 'Bonus Payable'; select ledger_id into l_tds from ledgers where name = 'TDS on Salary Payable';
  if l_exp is null or l_pay is null or l_tds is null then raise exception 'A bonus ledger is missing. Check Accounting > Ledgers.'; end if;
  v_lines := jsonb_build_array(jsonb_build_object('ledger_id', l_exp, 'debit', t.amt, 'credit', 0), jsonb_build_object('ledger_id', l_pay, 'debit', 0, 'credit', t.amt - t.tds));
  if t.tds > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tds, 'debit', 0, 'credit', t.tds); end if;
  v_res := acc_post_journal(make_date(b.fy + 1, 3, 31), 'Statutory bonus for FY ' || b.fy || '-' || right((b.fy + 1)::text, 2) || ' (' || b.bonus_no || ')', v_lines, 'bonus', p_bonus, 'posted', auth.uid());
  update bonus_runs set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, approved_by = auth.uid(), approved_at = now() where bonus_id = p_bonus;
  return jsonb_build_object('voucher_no', v_res ->> 'voucher_no', 'bonus', t.amt, 'tds', t.tds, 'net', t.amt - t.tds);
end $$;

create or replace function bonus_pay(p_bonus uuid, p_bank uuid, p_date date) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare b bonus_runs%rowtype; v_net numeric; v_bank uuid; l_pay uuid; v_res jsonb;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can record bonus payment'; end if;
  select * into b from bonus_runs where bonus_id = p_bonus for update;
  if not found or b.status <> 'approved' then raise exception 'Only an approved bonus can be marked paid'; end if;
  if p_date is null or p_date > current_date then raise exception 'Choose the date the bonus was paid (not in the future)'; end if;
  v_bank := br_bank_ledger_of(p_bank); if v_bank is null then raise exception 'Choose the bank account the bonus was paid from'; end if;
  select coalesce(sum(amount - tds), 0) into v_net from bonus_lines where bonus_id = p_bonus;
  select ledger_id into l_pay from ledgers where name = 'Bonus Payable';
  v_res := acc_post_journal(p_date, 'Bonus paid (' || b.bonus_no || ')', jsonb_build_array(jsonb_build_object('ledger_id', l_pay, 'debit', v_net, 'credit', 0), jsonb_build_object('ledger_id', v_bank, 'debit', 0, 'credit', v_net)), 'bonus_payment', p_bonus, 'posted', auth.uid());
  update bonus_runs set status = 'paid', paid_voucher_id = (v_res ->> 'voucher_id')::uuid, paid_on = p_date where bonus_id = p_bonus;
  return (v_res ->> 'voucher_id')::uuid;
end $$;

-- ---------------------------------------------------------------- gratuity
-- Years of service for gratuity: full years, and a remaining part of more than 6 months counts as one more year. Eligible after the minimum years of actual service.
create or replace function gratuity_calc(p_emp uuid, p_as_of date) returns table (years_actual int, years_counted int, last_wage numeric, eligible boolean, amount numeric, capped boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare e employees%rowtype; s payroll_exit_settings%rowtype; a interval; y int; mo int; d int; yc int; w numeric; amt numeric;
begin
  if not has_payroll_view() then return; end if;
  select * into e from employees where emp_id = p_emp; select * into s from payroll_exit_settings where id = 1;
  if not found then return; end if;
  a := age(p_as_of + 1, e.date_of_joining); y := extract(year from a)::int; mo := extract(month from a)::int; d := extract(day from a)::int;
  yc := y + case when mo > 6 or (mo = 6 and d > 0) then 1 else 0 end;
  select basic + da into w from employee_salary where emp_id = p_emp and effective_from <= p_as_of order by effective_from desc limit 1;
  w := coalesce(w, 0);
  amt := round(w * s.gratuity_days / s.gratuity_divisor * yc, 2);
  return query select y, yc, w, (y >= s.gratuity_min_years), case when y >= s.gratuity_min_years then least(amt, s.gratuity_cap) else 0 end, (y >= s.gratuity_min_years and amt > s.gratuity_cap);
end $$;

create or replace function gratuity_liability() returns table (emp_id uuid, emp_code text, name text, date_of_joining date, years_actual int, last_wage numeric, eligible boolean, amount_if_left_today numeric, months_to_eligible int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s payroll_exit_settings%rowtype;
begin
  if not has_payroll_view() then return; end if;
  select * into s from payroll_exit_settings where id = 1;
  return query select e.emp_id, e.emp_code, e.name, e.date_of_joining, g.years_actual, g.last_wage, g.eligible, g.amount,
                      case when g.eligible then 0 else greatest(0, ((e.date_of_joining + make_interval(years => s.gratuity_min_years))::date - current_date) / 30) end
                 from employees e, lateral gratuity_calc(e.emp_id, current_date) g where e.status = 'active' order by e.emp_code;
end $$;

-- ---------------------------------------------------------------- full and final settlement
create sequence if not exists fnf_seq;
create table if not exists fnf_settlements (
  fnf_id        uuid primary key default gen_random_uuid(),
  fnf_no        text not null unique,
  emp_id        uuid not null references employees(emp_id),
  last_day      date not null,
  status        text not null default 'draft' check (status in ('draft', 'approved', 'paid', 'cancelled')),
  salary_days   numeric(5,2) not null default 0,
  salary_amount numeric(12,2) not null default 0,
  leave_days    numeric(6,2) not null default 0,
  leave_amount  numeric(12,2) not null default 0,
  gratuity_amount numeric(12,2) not null default 0,
  bonus_amount  numeric(12,2) not null default 0,
  other_earning numeric(12,2) not null default 0,
  notice_recovery numeric(12,2) not null default 0,
  other_deduction numeric(12,2) not null default 0,
  tds           numeric(12,2) not null default 0,
  net           numeric(12,2) not null default 0,
  note          text,
  voucher_id    uuid references vouchers(voucher_id),
  paid_voucher_id uuid references vouchers(voucher_id),
  paid_on       date,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  approved_by   uuid,
  approved_at   timestamptz,
  check (salary_days >= 0 and leave_days >= 0 and gratuity_amount >= 0 and bonus_amount >= 0 and other_earning >= 0 and notice_recovery >= 0 and other_deduction >= 0 and tds >= 0)
);
create unique index if not exists fnf_emp_uq on fnf_settlements (emp_id) where status <> 'cancelled';
alter table fnf_settlements enable row level security;
drop policy if exists "fnf read" on fnf_settlements; create policy "fnf read" on fnf_settlements for select to authenticated using (has_payroll_view());
grant select on fnf_settlements to authenticated;

-- one place that works out the numbers, used by create and update
create or replace function fnf_figures(p_emp uuid, p_last date, p_salary_days numeric, p_leave_days numeric, p_gratuity_override numeric, p_bonus numeric, p_other_earn numeric, p_notice numeric, p_other_ded numeric, p_tds numeric)
returns table (salary_amount numeric, leave_days numeric, leave_amount numeric, gratuity_amount numeric, net numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare s payroll_exit_settings%rowtype; v_tot numeric; v_bd numeric; v_dim int; v_bal numeric; v_ld numeric; v_g numeric; v_sal numeric; v_la numeric;
begin
  select * into s from payroll_exit_settings where id = 1;
  select basic + da + hra + other_allowance, basic + da into v_tot, v_bd from employee_salary where emp_id = p_emp and effective_from <= p_last order by effective_from desc limit 1;
  v_tot := coalesce(v_tot, 0); v_bd := coalesce(v_bd, 0);
  v_dim := extract(day from (date_trunc('month', p_last) + interval '1 month - 1 day'))::int;
  v_sal := round(v_tot * coalesce(p_salary_days, 0) / v_dim, 2);
  select coalesce(sum(days), 0) into v_bal from leave_entries where emp_id = p_emp;
  v_ld := least(coalesce(p_leave_days, greatest(v_bal, 0)), greatest(v_bal, 0), s.leave_encash_cap);
  v_la := round(v_bd / s.leave_divisor * v_ld, 2);
  v_g := coalesce(p_gratuity_override, (select g.amount from gratuity_calc(p_emp, p_last) g), 0);
  return query select v_sal, v_ld, v_la, v_g, round(v_sal + v_la + v_g + coalesce(p_bonus, 0) + coalesce(p_other_earn, 0) - coalesce(p_notice, 0) - coalesce(p_other_ded, 0) - coalesce(p_tds, 0), 2);
end $$;

create or replace function fnf_save(p_fnf uuid, p_emp uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := p_fnf; f record; e employees%rowtype; v_last date := nullif(p ->> 'last_day', '')::date; v_sd numeric := coalesce(nullif(p ->> 'salary_days', '')::numeric, 0);
        v_ld numeric := nullif(p ->> 'leave_days', '')::numeric; v_go numeric := nullif(p ->> 'gratuity_override', '')::numeric; v_b numeric := coalesce(nullif(p ->> 'bonus_amount', '')::numeric, 0);
        v_oe numeric := coalesce(nullif(p ->> 'other_earning', '')::numeric, 0); v_nr numeric := coalesce(nullif(p ->> 'notice_recovery', '')::numeric, 0); v_od numeric := coalesce(nullif(p ->> 'other_deduction', '')::numeric, 0);
        v_t numeric := coalesce(nullif(p ->> 'tds', '')::numeric, 0); v_st text;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can prepare a final settlement'; end if;
  if v_id is not null then
    select emp_id, status into p_emp, v_st from fnf_settlements where fnf_id = v_id for update;
    if not found then raise exception 'Settlement not found'; end if;
    if v_st <> 'draft' then raise exception 'Only a draft settlement can be changed'; end if;
  end if;
  select * into e from employees where emp_id = p_emp;
  if not found then raise exception 'Choose an employee'; end if;
  if v_last is null or v_last < e.date_of_joining then raise exception 'Enter a last working day on or after the joining date'; end if;
  if least(v_sd, coalesce(v_ld, 0), coalesce(v_go, 0), v_b, v_oe, v_nr, v_od, v_t) < 0 then raise exception 'Amounts cannot be negative'; end if;
  if v_sd > 31 then raise exception 'Salary days cannot be more than 31'; end if;
  select * into f from fnf_figures(p_emp, v_last, v_sd, v_ld, v_go, v_b, v_oe, v_nr, v_od, v_t);
  if f.net < 0 then raise exception 'Deductions are more than what is payable. Reduce the recovery or tax.'; end if;
  if v_id is null then
    if exists (select 1 from fnf_settlements where emp_id = p_emp and status <> 'cancelled') then raise exception 'This person already has a final settlement'; end if;
    insert into fnf_settlements (fnf_no, emp_id, last_day, salary_days, salary_amount, leave_days, leave_amount, gratuity_amount, bonus_amount, other_earning, notice_recovery, other_deduction, tds, net, note)
    values ('FF-' || lpad(nextval('fnf_seq')::text, 4, '0'), p_emp, v_last, v_sd, f.salary_amount, f.leave_days, f.leave_amount, f.gratuity_amount, v_b, v_oe, v_nr, v_od, v_t, f.net, nullif(btrim(coalesce(p ->> 'note', '')), ''))
    returning fnf_id into v_id;
  else
    update fnf_settlements set last_day = v_last, salary_days = v_sd, salary_amount = f.salary_amount, leave_days = f.leave_days, leave_amount = f.leave_amount, gratuity_amount = f.gratuity_amount,
           bonus_amount = v_b, other_earning = v_oe, notice_recovery = v_nr, other_deduction = v_od, tds = v_t, net = f.net, note = nullif(btrim(coalesce(p ->> 'note', '')), '') where fnf_id = v_id;
  end if;
  return v_id;
end $$;

create or replace function fnf_cancel(p_fnf uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can cancel a settlement'; end if;
  update fnf_settlements set status = 'cancelled' where fnf_id = p_fnf and status = 'draft';
  if not found then raise exception 'Only a draft settlement can be cancelled'; end if;
end $$;

create or replace function fnf_approve(p_fnf uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare f fnf_settlements%rowtype; l_sal uuid; l_lv uuid; l_gr uuid; l_bn uuid; l_tds uuid; l_ff uuid; v_lines jsonb := '[]'::jsonb; v_res jsonb; v_sal_dr numeric; v_cr_sal numeric;
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can approve a final settlement'; end if;
  select * into f from fnf_settlements where fnf_id = p_fnf for update;
  if not found or f.status <> 'draft' then raise exception 'Only a draft settlement can be approved'; end if;
  if not pur_self_ok(f.created_by) then raise exception 'A different person must approve this settlement (you prepared it)'; end if;
  if f.net <= 0 then raise exception 'There is nothing payable in this settlement'; end if;
  select ledger_id into l_sal from ledgers where name = 'Salaries & Wages'; select ledger_id into l_lv from ledgers where name = 'Leave Encashment Expense'; select ledger_id into l_gr from ledgers where name = 'Gratuity Expense';
  select ledger_id into l_bn from ledgers where name = 'Bonus Expense'; select ledger_id into l_tds from ledgers where name = 'TDS on Salary Payable'; select ledger_id into l_ff from ledgers where name = 'Full and Final Payable';
  if l_sal is null or l_lv is null or l_gr is null or l_bn is null or l_tds is null or l_ff is null then raise exception 'A settlement ledger is missing. Check Accounting > Ledgers.'; end if;
  v_sal_dr := f.salary_amount + f.other_earning;
  if v_sal_dr > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_sal, 'debit', v_sal_dr, 'credit', 0); end if;
  if f.leave_amount > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_lv, 'debit', f.leave_amount, 'credit', 0); end if;
  if f.gratuity_amount > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_gr, 'debit', f.gratuity_amount, 'credit', 0); end if;
  if f.bonus_amount > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_bn, 'debit', f.bonus_amount, 'credit', 0); end if;
  v_cr_sal := f.notice_recovery + f.other_deduction;
  if v_cr_sal > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_sal, 'debit', 0, 'credit', v_cr_sal); end if;
  if f.tds > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tds, 'debit', 0, 'credit', f.tds); end if;
  v_lines := v_lines || jsonb_build_object('ledger_id', l_ff, 'debit', 0, 'credit', f.net);
  v_res := acc_post_journal(f.last_day, 'Full and final settlement (' || f.fnf_no || ')', v_lines, 'fnf', p_fnf, 'posted', auth.uid());
  update fnf_settlements set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, approved_by = auth.uid(), approved_at = now() where fnf_id = p_fnf;
  if f.leave_days > 0 then insert into leave_entries (emp_id, entry_date, kind, days, note) values (f.emp_id, f.last_day, 'encashed', -f.leave_days, 'Paid out in ' || f.fnf_no); end if;
  update employees set date_of_leaving = coalesce(date_of_leaving, f.last_day), status = case when f.last_day <= current_date then 'exited' else status end where emp_id = f.emp_id;
  return jsonb_build_object('voucher_no', v_res ->> 'voucher_no', 'net', f.net);
end $$;

create or replace function fnf_pay(p_fnf uuid, p_bank uuid, p_date date) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare f fnf_settlements%rowtype; v_bank uuid; l_ff uuid; v_res jsonb;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can record payment'; end if;
  select * into f from fnf_settlements where fnf_id = p_fnf for update;
  if not found or f.status <> 'approved' then raise exception 'Only an approved settlement can be marked paid'; end if;
  if p_date is null or p_date > current_date then raise exception 'Choose the date it was paid (not in the future)'; end if;
  v_bank := br_bank_ledger_of(p_bank); if v_bank is null then raise exception 'Choose the bank account it was paid from'; end if;
  select ledger_id into l_ff from ledgers where name = 'Full and Final Payable';
  v_res := acc_post_journal(p_date, 'Full and final paid (' || f.fnf_no || ')', jsonb_build_array(jsonb_build_object('ledger_id', l_ff, 'debit', f.net, 'credit', 0), jsonb_build_object('ledger_id', v_bank, 'debit', 0, 'credit', f.net)), 'fnf_payment', p_fnf, 'posted', auth.uid());
  update fnf_settlements set status = 'paid', paid_voucher_id = (v_res ->> 'voucher_id')::uuid, paid_on = p_date where fnf_id = p_fnf;
  return (v_res ->> 'voucher_id')::uuid;
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on function payroll_exit_settings_save(jsonb), my_payslips(), leave_accrue(date), leave_record(uuid, text, numeric, date, text), bonus_fill(uuid), bonus_create(int), bonus_recalculate(uuid, numeric),
  bonus_line_set(uuid, numeric, numeric, text), bonus_cancel(uuid), bonus_approve(uuid), bonus_pay(uuid, uuid, date), gratuity_calc(uuid, date), gratuity_liability(),
  fnf_figures(uuid, date, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric), fnf_save(uuid, uuid, jsonb), fnf_cancel(uuid), fnf_approve(uuid), fnf_pay(uuid, uuid, date) from public, anon, authenticated;
grant execute on function payroll_exit_settings_save(jsonb), my_payslips(), leave_accrue(date), leave_record(uuid, text, numeric, date, text), bonus_create(int), bonus_recalculate(uuid, numeric),
  bonus_line_set(uuid, numeric, numeric, text), bonus_cancel(uuid), bonus_approve(uuid), bonus_pay(uuid, uuid, date), gratuity_calc(uuid, date), gratuity_liability(),
  fnf_save(uuid, uuid, jsonb), fnf_cancel(uuid), fnf_approve(uuid), fnf_pay(uuid, uuid, date) to authenticated;
