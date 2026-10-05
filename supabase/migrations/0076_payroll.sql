-- 0076: Statutory compliance, part 2: payroll for a Gujarat employer.
--
-- Covers: employees and salary structure; the monthly payroll run (pro-rated for joining, leaving and loss of pay); provident fund (employee 12%,
-- employer 8.33% pension + 3.67% EPF, EDLI 0.5%, admin 0.5% with the Rs 500 minimum); ESI (0.75% + 3.25% up to Rs 21,000, with the rule that cover
-- continues to the end of the six-month contribution period); Gujarat professional tax (Rs 200 a month above Rs 12,000); Gujarat labour welfare fund
-- (June and December); salary TDS by the annual projection method for both tax regimes with rebate, surcharge and cess (section 392 of the
-- Income-tax Act 2025); the accounting entries; salary payment and remittance of every statutory dues head; and the data for the PF ECR file, the ESI
-- file, professional tax, Form 138 and Form 130.
--
-- Every rate is held in Payroll settings and slab tables so a change in law is a data edit, not a code change. All are flagged for your CA to confirm.
-- Not covered yet: bonus, gratuity, leave encashment and full-and-final settlement.

-- ---------------------------------------------------------------- who can see and run payroll
create or replace function has_payroll_view() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Finance Manager', 'Accountant'), false)
$$;
create or replace function has_payroll_write() returns boolean language sql stable set search_path = public, pg_temp as $$
  select coalesce(current_role_name() in ('Super Admin', 'Finance Manager', 'Accountant'), false)
$$;

-- ---------------------------------------------------------------- settings (one row)
create table if not exists payroll_settings (
  id                 int primary key default 1 check (id = 1),
  pf_wage_ceiling    numeric(10,2) not null default 15000,
  pf_emp_pct         numeric(5,2) not null default 12,
  pf_eps_pct         numeric(5,2) not null default 8.33,
  pf_er_total_pct    numeric(5,2) not null default 12,
  edli_pct           numeric(5,2) not null default 0.5,
  edli_cap           numeric(10,2) not null default 15000,
  pf_admin_pct       numeric(5,2) not null default 0.5,
  pf_admin_min       numeric(10,2) not null default 500,
  esi_ceiling        numeric(10,2) not null default 21000,
  esi_emp_pct        numeric(5,2) not null default 0.75,
  esi_er_pct         numeric(5,2) not null default 3.25,
  esi_daily_exempt   numeric(10,2) not null default 176,
  pt_threshold       numeric(10,2) not null default 12000,
  pt_amount          numeric(10,2) not null default 200,
  lwf_emp            numeric(10,2) not null default 6,
  lwf_er             numeric(10,2) not null default 12,
  lwf_months         int[] not null default '{6,12}',
  use_code_on_wages  boolean not null default true,       -- PF wage is at least 50% of fixed pay (Code on Wages, in force from 21 Nov 2025)
  std_deduction_new  numeric(10,2) not null default 75000,
  std_deduction_old  numeric(10,2) not null default 50000,
  rebate_new_limit   numeric(12,2) not null default 1200000,
  rebate_old_limit   numeric(12,2) not null default 500000,
  rebate_old_max     numeric(10,2) not null default 12500,
  cess_pct           numeric(5,2) not null default 4,
  cap_80c            numeric(10,2) not null default 150000,
  cap_home_loan      numeric(10,2) not null default 200000,
  updated_by         uuid,
  updated_at         timestamptz not null default now()
);
insert into payroll_settings (id) values (1) on conflict do nothing;

create table if not exists payroll_tax_slabs (
  slab_id   uuid primary key default gen_random_uuid(),
  regime    text not null check (regime in ('new', 'old')),
  fy_from   int not null,                                -- applies from the financial year starting in this year
  age_band  text not null default 'all' check (age_band in ('all', 'below60', 'senior', 'super')),
  from_amt  numeric(14,2) not null,
  to_amt    numeric(14,2),
  rate      numeric(5,2) not null
);
insert into payroll_tax_slabs (regime, fy_from, age_band, from_amt, to_amt, rate)
select * from (values
  ('new', 2025, 'all', 0, 400000, 0), ('new', 2025, 'all', 400000, 800000, 5), ('new', 2025, 'all', 800000, 1200000, 10), ('new', 2025, 'all', 1200000, 1600000, 15),
  ('new', 2025, 'all', 1600000, 2000000, 20), ('new', 2025, 'all', 2000000, 2400000, 25), ('new', 2025, 'all', 2400000, null, 30),
  ('old', 2025, 'below60', 0, 250000, 0), ('old', 2025, 'below60', 250000, 500000, 5), ('old', 2025, 'below60', 500000, 1000000, 20), ('old', 2025, 'below60', 1000000, null, 30),
  ('old', 2025, 'senior', 0, 300000, 0), ('old', 2025, 'senior', 300000, 500000, 5), ('old', 2025, 'senior', 500000, 1000000, 20), ('old', 2025, 'senior', 1000000, null, 30),
  ('old', 2025, 'super', 0, 500000, 0), ('old', 2025, 'super', 500000, 1000000, 20), ('old', 2025, 'super', 1000000, null, 30)
) as v(regime, fy_from, age_band, from_amt, to_amt, rate)
where not exists (select 1 from payroll_tax_slabs);

alter table payroll_settings enable row level security; alter table payroll_tax_slabs enable row level security;
drop policy if exists "pset read" on payroll_settings; create policy "pset read" on payroll_settings for select to authenticated using (has_payroll_view());
drop policy if exists "pslab read" on payroll_tax_slabs; create policy "pslab read" on payroll_tax_slabs for select to authenticated using (has_payroll_view());
grant select on payroll_settings, payroll_tax_slabs to authenticated;

create or replace function payroll_settings_save(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare k text; v numeric;
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can change payroll settings'; end if;
  for k in select jsonb_object_keys(p) loop
    if k not in ('pf_wage_ceiling','pf_emp_pct','pf_eps_pct','pf_er_total_pct','edli_pct','edli_cap','pf_admin_pct','pf_admin_min','esi_ceiling','esi_emp_pct','esi_er_pct','esi_daily_exempt',
                 'pt_threshold','pt_amount','lwf_emp','lwf_er','std_deduction_new','std_deduction_old','rebate_new_limit','rebate_old_limit','rebate_old_max','cess_pct','cap_80c','cap_home_loan',
                 'use_code_on_wages') then raise exception 'Unknown setting %', k; end if;
    if k <> 'use_code_on_wages' then
      v := (p ->> k)::numeric;
      if v is null or v < 0 then raise exception '% cannot be negative', k; end if;
    end if;
  end loop;
  execute (select 'update payroll_settings set ' || string_agg(format('%I = %s', k2, case when k2 = 'use_code_on_wages' then format('%L::boolean', p ->> k2) else format('%L::numeric', p ->> k2) end), ', ')
                  || ', updated_by = auth.uid(), updated_at = now() where id = 1' from jsonb_object_keys(p) k2);
end $$;

-- ---------------------------------------------------------------- ledgers
insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = v.grp limit 1), v.name, v.nature, 0, v.ob, false, false, 'active'
from (values
  ('Indirect Expenses',   'Employer PF Contribution',          'expense',   'debit'),
  ('Indirect Expenses',   'PF Admin and EDLI Charges',         'expense',   'debit'),
  ('Indirect Expenses',   'Employer ESI Contribution',         'expense',   'debit'),
  ('Indirect Expenses',   'Labour Welfare Fund Expense',       'expense',   'debit'),
  ('Current Liabilities', 'Salary Payable',                    'liability', 'credit'),
  ('Current Liabilities', 'PF Payable',                        'liability', 'credit'),
  ('Current Liabilities', 'ESI Payable',                       'liability', 'credit'),
  ('Current Liabilities', 'Professional Tax Payable',          'liability', 'credit'),
  ('Current Liabilities', 'TDS on Salary Payable',             'liability', 'credit'),
  ('Current Liabilities', 'Labour Welfare Fund Payable',       'liability', 'credit'),
  ('Current Assets',      'Employee Advances',                 'asset',     'debit')
) as v(grp, name, nature, ob)
where not exists (select 1 from ledgers l where l.name = v.name);
update ledgers set status = 'active' where name = 'Salaries & Wages' and status <> 'active';

-- ---------------------------------------------------------------- employees
create sequence if not exists employee_seq;
create table if not exists employees (
  emp_id          uuid primary key default gen_random_uuid(),
  emp_code        text not null unique,
  name            text not null check (btrim(name) <> ''),
  gender          text check (gender in ('male', 'female', 'other')),
  date_of_birth   date,
  date_of_joining date not null,
  date_of_leaving date,
  pan             text check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  uan             text check (uan is null or uan ~ '^[0-9]{12}$'),
  esic_no         text check (esic_no is null or esic_no ~ '^[0-9]{10,17}$'),
  designation     text,
  department      text,
  email           text,
  phone           text,
  pf_applicable   boolean not null default true,
  pf_on_actual    boolean not null default false,       -- contribute on full basic instead of the Rs 15,000 ceiling (employer and employee agree)
  esi_applicable  boolean not null default true,        -- ESI still applies only while wages are within the ceiling
  pt_applicable   boolean not null default true,
  lwf_applicable  boolean not null default true,
  status          text not null default 'active' check (status in ('active', 'exited')),
  created_by      uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  check (date_of_leaving is null or date_of_leaving >= date_of_joining)
);
create table if not exists employee_salary (
  salary_id        uuid primary key default gen_random_uuid(),
  emp_id           uuid not null references employees(emp_id) on delete cascade,
  effective_from   date not null,
  basic            numeric(12,2) not null check (basic >= 0),
  da               numeric(12,2) not null default 0 check (da >= 0),
  hra              numeric(12,2) not null default 0 check (hra >= 0),
  other_allowance  numeric(12,2) not null default 0 check (other_allowance >= 0),
  total            numeric(12,2) generated always as (basic + da + hra + other_allowance) stored,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  unique (emp_id, effective_from)
);
create table if not exists employee_bank (
  emp_id          uuid primary key references employees(emp_id) on delete cascade,
  bank_name       text not null,
  ifsc            text not null check (ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  account_number  text not null check (account_number ~ '^[0-9]{6,20}$'),
  account_holder  text not null
);
create table if not exists employee_declarations (
  emp_id             uuid not null references employees(emp_id) on delete cascade,
  fy                 int not null,
  regime             text not null default 'new' check (regime in ('new', 'old')),
  ded_80c            numeric(12,2) not null default 0 check (ded_80c >= 0),
  ded_80d            numeric(12,2) not null default 0 check (ded_80d >= 0),
  hra_exempt         numeric(12,2) not null default 0 check (hra_exempt >= 0),
  home_loan_interest numeric(12,2) not null default 0 check (home_loan_interest >= 0),
  other_deductions   numeric(12,2) not null default 0 check (other_deductions >= 0),
  prev_income        numeric(14,2) not null default 0 check (prev_income >= 0),   -- salary from a previous employer this year
  prev_tds           numeric(14,2) not null default 0 check (prev_tds >= 0),
  primary key (emp_id, fy)
);
alter table employees enable row level security; alter table employee_salary enable row level security; alter table employee_bank enable row level security; alter table employee_declarations enable row level security;
drop policy if exists "emp read" on employees; create policy "emp read" on employees for select to authenticated using (has_payroll_view());
drop policy if exists "empsal read" on employee_salary; create policy "empsal read" on employee_salary for select to authenticated using (has_payroll_view());
drop policy if exists "empbank read" on employee_bank; create policy "empbank read" on employee_bank for select to authenticated using (has_payroll_write());
drop policy if exists "empdecl read" on employee_declarations; create policy "empdecl read" on employee_declarations for select to authenticated using (has_payroll_view());
grant select on employees, employee_salary, employee_bank, employee_declarations to authenticated;

create or replace function employee_save(p_id uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid := p_id; v_pan text := nullif(upper(btrim(coalesce(p ->> 'pan', ''))), ''); v_uan text := nullif(btrim(coalesce(p ->> 'uan', '')), ''); v_esic text := nullif(btrim(coalesce(p ->> 'esic_no', '')), '');
        v_doj date := nullif(p ->> 'date_of_joining', '')::date; v_dob date := nullif(p ->> 'date_of_birth', '')::date;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can save an employee'; end if;
  if nullif(btrim(coalesce(p ->> 'name', '')), '') is null then raise exception 'Enter the employee''s name'; end if;
  if v_doj is null then raise exception 'Enter the date of joining'; end if;
  if v_pan is not null and v_pan !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' then raise exception 'PAN must look like ABCDE1234F'; end if;
  if v_uan is not null and v_uan !~ '^[0-9]{12}$' then raise exception 'UAN is 12 digits'; end if;
  if v_esic is not null and v_esic !~ '^[0-9]{10,17}$' then raise exception 'ESIC number is 10 to 17 digits'; end if;
  if v_dob is not null and v_dob > v_doj - interval '14 years' then raise exception 'The employee must be at least 14 years old at joining'; end if;
  if v_id is null then
    insert into employees (emp_code, name, gender, date_of_birth, date_of_joining, pan, uan, esic_no, designation, department, email, phone, pf_applicable, pf_on_actual, esi_applicable, pt_applicable, lwf_applicable)
    values ('E' || lpad(nextval('employee_seq')::text, 4, '0'), btrim(p ->> 'name'), nullif(p ->> 'gender', ''), v_dob, v_doj, v_pan, v_uan, v_esic,
            nullif(btrim(coalesce(p ->> 'designation', '')), ''), nullif(btrim(coalesce(p ->> 'department', '')), ''), nullif(btrim(coalesce(p ->> 'email', '')), ''), nullif(btrim(coalesce(p ->> 'phone', '')), ''),
            coalesce((p ->> 'pf_applicable')::boolean, true), coalesce((p ->> 'pf_on_actual')::boolean, false), coalesce((p ->> 'esi_applicable')::boolean, true),
            coalesce((p ->> 'pt_applicable')::boolean, true), coalesce((p ->> 'lwf_applicable')::boolean, true))
    returning emp_id into v_id;
  else
    update employees set name = btrim(p ->> 'name'), gender = nullif(p ->> 'gender', ''), date_of_birth = v_dob, date_of_joining = v_doj, pan = v_pan, uan = v_uan, esic_no = v_esic,
           designation = nullif(btrim(coalesce(p ->> 'designation', '')), ''), department = nullif(btrim(coalesce(p ->> 'department', '')), ''),
           email = nullif(btrim(coalesce(p ->> 'email', '')), ''), phone = nullif(btrim(coalesce(p ->> 'phone', '')), ''),
           pf_applicable = coalesce((p ->> 'pf_applicable')::boolean, pf_applicable), pf_on_actual = coalesce((p ->> 'pf_on_actual')::boolean, pf_on_actual),
           esi_applicable = coalesce((p ->> 'esi_applicable')::boolean, esi_applicable), pt_applicable = coalesce((p ->> 'pt_applicable')::boolean, pt_applicable),
           lwf_applicable = coalesce((p ->> 'lwf_applicable')::boolean, lwf_applicable)
     where emp_id = v_id;
    if not found then raise exception 'Employee not found'; end if;
  end if;
  return v_id;
end $$;

create or replace function employee_set_salary(p_emp uuid, p_from date, p_basic numeric, p_da numeric, p_hra numeric, p_other numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can change a salary'; end if;
  if not exists (select 1 from employees where emp_id = p_emp) then raise exception 'Employee not found'; end if;
  if p_from is null then raise exception 'Choose the date the salary applies from'; end if;
  if coalesce(p_basic, 0) <= 0 then raise exception 'Enter the basic salary'; end if;
  if exists (select 1 from payroll_lines l join payroll_runs r on r.run_id = l.run_id where l.emp_id = p_emp and r.status in ('approved', 'paid') and r.month >= date_trunc('month', p_from)::date) then
    raise exception 'A payroll run that covers this date is already approved. Apply the change from the next month instead.';
  end if;
  insert into employee_salary (emp_id, effective_from, basic, da, hra, other_allowance) values (p_emp, p_from, round(p_basic, 2), round(coalesce(p_da, 0), 2), round(coalesce(p_hra, 0), 2), round(coalesce(p_other, 0), 2))
  on conflict (emp_id, effective_from) do update set basic = excluded.basic, da = excluded.da, hra = excluded.hra, other_allowance = excluded.other_allowance, created_by = auth.uid();
end $$;

create or replace function employee_set_bank(p_emp uuid, p_bank text, p_ifsc text, p_account text, p_holder text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can save bank details'; end if;
  if not exists (select 1 from employees where emp_id = p_emp) then raise exception 'Employee not found'; end if;
  if nullif(btrim(coalesce(p_bank, '')), '') is null then raise exception 'Enter the bank name'; end if;
  if upper(btrim(coalesce(p_ifsc, ''))) !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'IFSC looks like SBIN0001234'; end if;
  if btrim(coalesce(p_account, '')) !~ '^[0-9]{6,20}$' then raise exception 'Account number is 6 to 20 digits'; end if;
  insert into employee_bank (emp_id, bank_name, ifsc, account_number, account_holder) values (p_emp, btrim(p_bank), upper(btrim(p_ifsc)), btrim(p_account), coalesce(nullif(btrim(coalesce(p_holder, '')), ''), (select name from employees where emp_id = p_emp)))
  on conflict (emp_id) do update set bank_name = excluded.bank_name, ifsc = excluded.ifsc, account_number = excluded.account_number, account_holder = excluded.account_holder;
end $$;

create or replace function employee_set_declaration(p_emp uuid, p_fy int, p_regime text, p_80c numeric, p_80d numeric, p_hra numeric, p_home numeric, p_other numeric, p_prev_income numeric, p_prev_tds numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can save a tax declaration'; end if;
  if p_regime not in ('new', 'old') then raise exception 'Regime must be new or old'; end if;
  if not exists (select 1 from employees where emp_id = p_emp) then raise exception 'Employee not found'; end if;
  insert into employee_declarations (emp_id, fy, regime, ded_80c, ded_80d, hra_exempt, home_loan_interest, other_deductions, prev_income, prev_tds)
  values (p_emp, p_fy, p_regime, coalesce(p_80c, 0), coalesce(p_80d, 0), coalesce(p_hra, 0), coalesce(p_home, 0), coalesce(p_other, 0), coalesce(p_prev_income, 0), coalesce(p_prev_tds, 0))
  on conflict (emp_id, fy) do update set regime = excluded.regime, ded_80c = excluded.ded_80c, ded_80d = excluded.ded_80d, hra_exempt = excluded.hra_exempt,
    home_loan_interest = excluded.home_loan_interest, other_deductions = excluded.other_deductions, prev_income = excluded.prev_income, prev_tds = excluded.prev_tds;
end $$;

create or replace function employee_exit(p_emp uuid, p_date date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can record a resignation'; end if;
  if p_date is null then raise exception 'Enter the last working day'; end if;
  update employees set date_of_leaving = p_date, status = case when p_date <= current_date then 'exited' else status end where emp_id = p_emp and date_of_joining <= p_date;
  if not found then raise exception 'Employee not found, or the last day is before the joining date'; end if;
end $$;

-- ---------------------------------------------------------------- runs and lines
create sequence if not exists payroll_run_seq;
create table if not exists payroll_runs (
  run_id           uuid primary key default gen_random_uuid(),
  run_no           text not null unique,
  month            date not null check (month = date_trunc('month', month)::date),
  status           text not null default 'draft' check (status in ('draft', 'approved', 'paid', 'cancelled')),
  pf_admin_topup   numeric(12,2) not null default 0,
  voucher_id       uuid references vouchers(voucher_id),
  paid_voucher_id  uuid references vouchers(voucher_id),
  paid_on          date,
  pay_reference    text,
  reversal_voucher_id uuid references vouchers(voucher_id),
  note             text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  approved_by      uuid,
  approved_at      timestamptz
);
create unique index if not exists payroll_runs_month_uq on payroll_runs (month) where status <> 'cancelled';
create table if not exists payroll_lines (
  line_id        uuid primary key default gen_random_uuid(),
  run_id         uuid not null references payroll_runs(run_id) on delete cascade,
  emp_id         uuid not null references employees(emp_id),
  days_in_month  int not null,
  paid_days      numeric(5,2) not null,
  lop_days       numeric(5,2) not null default 0,
  basic          numeric(12,2) not null default 0,
  da             numeric(12,2) not null default 0,
  hra            numeric(12,2) not null default 0,
  other_allowance numeric(12,2) not null default 0,
  extra_earning  numeric(12,2) not null default 0,
  extra_is_wage  boolean not null default false,
  extra_note     text,
  gross          numeric(12,2) not null default 0,
  pf_wage        numeric(12,2) not null default 0,
  pf_ee          numeric(12,2) not null default 0,
  pf_eps         numeric(12,2) not null default 0,
  pf_epf         numeric(12,2) not null default 0,
  edli           numeric(12,2) not null default 0,
  pf_admin       numeric(12,2) not null default 0,
  esi_wage       numeric(12,2) not null default 0,
  esi_covered    boolean not null default false,
  esi_ee         numeric(12,2) not null default 0,
  esi_er         numeric(12,2) not null default 0,
  pt             numeric(12,2) not null default 0,
  lwf_ee         numeric(12,2) not null default 0,
  lwf_er         numeric(12,2) not null default 0,
  tds            numeric(12,2) not null default 0,
  other_ded      numeric(12,2) not null default 0,
  ded_note       text,
  net_pay        numeric(12,2) not null default 0,
  tds_detail     jsonb,
  unique (run_id, emp_id)
);
alter table payroll_runs enable row level security; alter table payroll_lines enable row level security;
drop policy if exists "prun read" on payroll_runs; create policy "prun read" on payroll_runs for select to authenticated using (has_payroll_view());
drop policy if exists "pline read" on payroll_lines; create policy "pline read" on payroll_lines for select to authenticated using (has_payroll_view());
grant select on payroll_runs, payroll_lines to authenticated;

create table if not exists payroll_remittances (
  rem_id        uuid primary key default gen_random_uuid(),
  head          text not null check (head in ('pf', 'esi', 'pt', 'tds', 'lwf')),
  month         date not null,
  amount        numeric(14,2) not null check (amount > 0),
  remit_date    date not null,
  bank_account_id uuid not null references bank_accounts(bank_account_id),
  reference     text,
  voucher_id    uuid references vouchers(voucher_id),
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now()
);
alter table payroll_remittances enable row level security;
drop policy if exists "prem read" on payroll_remittances; create policy "prem read" on payroll_remittances for select to authenticated using (has_payroll_view());
grant select on payroll_remittances to authenticated;

-- ---------------------------------------------------------------- tax calculation
create or replace function payroll_slab_tax(p_regime text, p_fy int, p_income numeric, p_band text) returns numeric
language sql stable set search_path = public, pg_temp as $$
  with pick as (select max(fy_from) as f from payroll_tax_slabs where regime = p_regime and fy_from <= p_fy),
       s as (select * from payroll_tax_slabs, pick where regime = p_regime and fy_from = pick.f and age_band = case when p_regime = 'new' then 'all' else p_band end)
  select coalesce(sum(greatest(least(p_income, coalesce(to_amt, p_income)) - from_amt, 0) * rate / 100), 0) from s
$$;

-- full tax for the year on a taxable income: slabs, rebate, surcharge, cess; income and tax rounded to the nearest Rs 10 (sections 288A and 288B of the old Act, kept in the new one)
create or replace function payroll_annual_tax(p_regime text, p_fy int, p_taxable numeric, p_band text) returns numeric
language plpgsql stable set search_path = public, pg_temp as $$
declare s payroll_settings%rowtype; v_inc numeric := round(greatest(p_taxable, 0) / 10) * 10; v_tax numeric; v_sur numeric := 0;
begin
  select * into s from payroll_settings where id = 1;
  v_tax := payroll_slab_tax(p_regime, p_fy, v_inc, p_band);
  if p_regime = 'new' then
    if v_inc <= s.rebate_new_limit then v_tax := 0; else v_tax := least(v_tax, v_inc - s.rebate_new_limit); end if;
  else
    if v_inc <= s.rebate_old_limit then v_tax := greatest(v_tax - s.rebate_old_max, 0); end if;
  end if;
  v_sur := case when v_inc > 50000000 and p_regime = 'old' then 0.37 when v_inc > 20000000 then 0.25 when v_inc > 10000000 then 0.15 when v_inc > 5000000 then 0.10 else 0 end;
  v_tax := v_tax * (1 + v_sur);
  v_tax := v_tax * (1 + s.cess_pct / 100);
  return round(v_tax / 10) * 10;
end $$;

-- ---------------------------------------------------------------- one employee, one month
create or replace function payroll_compute_line(p_emp uuid, p_month date, p_lop numeric, p_extra numeric, p_extra_wage boolean, p_other_ded numeric) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  e employees%rowtype; sal employee_salary%rowtype; s payroll_settings%rowtype; d employee_declarations%rowtype;
  m date := date_trunc('month', p_month)::date; m_end date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date; v_days int := extract(day from (date_trunc('month', p_month) + interval '1 month - 1 day'))::int;
  v_from date; v_to date; v_elig int; v_paid numeric; v_ratio numeric;
  v_basic numeric; v_da numeric; v_hra numeric; v_other numeric; v_fixed numeric; v_gross numeric; v_extra numeric := round(coalesce(p_extra, 0), 2);
  v_pfbase numeric; v_pfbase_full numeric; v_pfwage numeric := 0; v_pf_ee numeric := 0; v_eps numeric := 0; v_epf numeric := 0; v_edli numeric := 0; v_admin numeric := 0;
  v_esi_wage numeric := 0; v_esi_cov boolean := false; v_esi_ee numeric := 0; v_esi_er numeric := 0; v_pt numeric := 0; v_lwf_ee numeric := 0; v_lwf_er numeric := 0;
  v_per_start date; v_fy int; v_fy_start date; v_regime text := 'new'; v_band text := 'below60'; v_age int;
  v_ytd_gross numeric; v_ytd_tds numeric; v_ytd_pt numeric; v_ytd_pf numeric; v_future int; v_div int; v_annual numeric; v_ded numeric := 0; v_taxable numeric; v_tax numeric; v_tds numeric := 0; v_pt_full numeric;
  v_c80 numeric; v_net numeric; v_other_ded numeric := round(coalesce(p_other_ded, 0), 2);
begin
  select * into e from employees where emp_id = p_emp;
  select * into s from payroll_settings where id = 1;
  select * into sal from employee_salary where emp_id = p_emp and effective_from <= m_end order by effective_from desc limit 1;
  if sal.salary_id is null then raise exception 'No salary is set for % (%)', e.name, e.emp_code; end if;
  v_from := greatest(e.date_of_joining, m); v_to := least(coalesce(e.date_of_leaving, m_end), m_end);
  v_elig := greatest(v_to - v_from + 1, 0);
  if coalesce(p_lop, 0) < 0 or coalesce(p_lop, 0) > v_elig then raise exception 'Loss-of-pay days for % must be between 0 and %', e.name, v_elig; end if;
  v_paid := v_elig - coalesce(p_lop, 0); v_ratio := v_paid / v_days;
  v_basic := round(sal.basic * v_ratio); v_da := round(sal.da * v_ratio); v_hra := round(sal.hra * v_ratio); v_other := round(sal.other_allowance * v_ratio);
  v_fixed := v_basic + v_da + v_hra + v_other; v_gross := v_fixed + v_extra;

  -- provident fund
  if e.pf_applicable and v_paid > 0 then
    v_pfbase := v_basic + v_da; v_pfbase_full := sal.basic + sal.da;
    if s.use_code_on_wages then v_pfbase := greatest(v_pfbase, round(0.5 * v_fixed)); v_pfbase_full := greatest(v_pfbase_full, round(0.5 * sal.total)); end if;
    v_pfbase := v_pfbase + case when p_extra_wage then v_extra else 0 end;
    v_pfwage := case when e.pf_on_actual then v_pfbase else least(v_pfbase, s.pf_wage_ceiling) end;
    v_pf_ee := round(v_pfwage * s.pf_emp_pct / 100);
    v_eps := round(least(v_pfwage, s.pf_wage_ceiling) * s.pf_eps_pct / 100);
    v_epf := round(v_pfwage * s.pf_er_total_pct / 100) - v_eps;
    v_edli := round(least(v_pfwage, s.edli_cap) * s.edli_pct / 100);
    v_admin := round(v_pfwage * s.pf_admin_pct / 100);
  end if;

  -- ESI: covered while the monthly pay is within the ceiling; once covered, cover runs to the end of the six-month contribution period
  v_per_start := case when extract(month from m) between 4 and 9 then make_date(extract(year from m)::int, 4, 1)
                      when extract(month from m) >= 10 then make_date(extract(year from m)::int, 10, 1) else make_date(extract(year from m)::int - 1, 10, 1) end;
  if e.esi_applicable and v_paid > 0 then
    v_esi_cov := sal.total <= s.esi_ceiling
                 or exists (select 1 from payroll_lines l join payroll_runs r on r.run_id = l.run_id where l.emp_id = p_emp and r.status in ('approved', 'paid') and r.month >= v_per_start and r.month < m and l.esi_covered);
    if v_esi_cov then
      v_esi_wage := v_fixed + case when p_extra_wage then v_extra else 0 end;
      v_esi_er := ceil(v_esi_wage * s.esi_er_pct / 100);
      v_esi_ee := case when v_paid > 0 and v_esi_wage / v_paid <= s.esi_daily_exempt then 0 else ceil(v_esi_wage * s.esi_emp_pct / 100) end;
    end if;
  end if;

  -- Gujarat professional tax and labour welfare fund
  if e.pt_applicable and v_gross > s.pt_threshold then v_pt := s.pt_amount; end if;
  if e.lwf_applicable and v_paid > 0 and extract(month from m)::int = any (s.lwf_months) then v_lwf_ee := s.lwf_emp; v_lwf_er := s.lwf_er; end if;

  -- salary TDS by annual projection
  v_fy := case when extract(month from m) >= 4 then extract(year from m)::int else extract(year from m)::int - 1 end; v_fy_start := make_date(v_fy, 4, 1);
  select * into d from employee_declarations where emp_id = p_emp and fy = v_fy;
  v_regime := coalesce(d.regime, 'new');
  v_age := extract(year from age(make_date(v_fy + 1, 3, 31), coalesce(e.date_of_birth, make_date(1990, 1, 1))))::int;
  v_band := case when v_age >= 80 then 'super' when v_age >= 60 then 'senior' else 'below60' end;
  select coalesce(sum(l.gross), 0), coalesce(sum(l.tds), 0), coalesce(sum(l.pt), 0), coalesce(sum(l.pf_ee), 0) into v_ytd_gross, v_ytd_tds, v_ytd_pt, v_ytd_pf
    from payroll_lines l join payroll_runs r on r.run_id = l.run_id where l.emp_id = p_emp and r.status in ('approved', 'paid') and r.month >= v_fy_start and r.month < m;
  v_future := 12 - ((extract(year from m)::int * 12 + extract(month from m)::int) - (v_fy * 12 + 4)) - 1;
  if e.date_of_leaving is not null and e.date_of_leaving < make_date(v_fy + 1, 3, 31) then
    v_future := least(v_future, greatest((extract(year from e.date_of_leaving)::int * 12 + extract(month from e.date_of_leaving)::int) - (extract(year from m)::int * 12 + extract(month from m)::int), 0));
  end if;
  v_future := greatest(v_future, 0); v_div := v_future + 1;
  v_pt_full := case when sal.total > s.pt_threshold and e.pt_applicable then s.pt_amount else 0 end;
  v_annual := v_ytd_gross + v_gross + sal.total * v_future + coalesce(d.prev_income, 0);
  if v_regime = 'new' then
    v_ded := s.std_deduction_new;
  else
    v_c80 := least(s.cap_80c, coalesce(d.ded_80c, 0) + v_ytd_pf + v_pf_ee + case when e.pf_applicable then round(least(coalesce(v_pfbase_full, 0), case when e.pf_on_actual then coalesce(v_pfbase_full, 0) else s.pf_wage_ceiling end) * s.pf_emp_pct / 100) * v_future else 0 end);
    v_ded := s.std_deduction_old + v_ytd_pt + v_pt + v_pt_full * v_future + v_c80 + coalesce(d.ded_80d, 0) + coalesce(d.hra_exempt, 0) + least(coalesce(d.home_loan_interest, 0), s.cap_home_loan) + coalesce(d.other_deductions, 0);
  end if;
  v_taxable := greatest(v_annual - v_ded, 0);
  v_tax := payroll_annual_tax(v_regime, v_fy, v_taxable, v_band);
  if v_paid > 0 then v_tds := greatest(round((v_tax - v_ytd_tds - coalesce(d.prev_tds, 0)) / v_div), 0); end if;
  v_net := v_gross - v_pf_ee - v_esi_ee - v_pt - v_lwf_ee - v_tds - v_other_ded;
  return jsonb_build_object('days_in_month', v_days, 'paid_days', v_paid, 'lop_days', coalesce(p_lop, 0), 'basic', v_basic, 'da', v_da, 'hra', v_hra, 'other_allowance', v_other,
    'extra_earning', v_extra, 'extra_is_wage', coalesce(p_extra_wage, false), 'gross', v_gross, 'pf_wage', v_pfwage, 'pf_ee', v_pf_ee, 'pf_eps', v_eps, 'pf_epf', v_epf, 'edli', v_edli, 'pf_admin', v_admin,
    'esi_wage', v_esi_wage, 'esi_covered', v_esi_cov, 'esi_ee', v_esi_ee, 'esi_er', v_esi_er, 'pt', v_pt, 'lwf_ee', v_lwf_ee, 'lwf_er', v_lwf_er, 'tds', v_tds, 'other_ded', v_other_ded, 'net_pay', v_net,
    'tds_detail', jsonb_build_object('regime', v_regime, 'fy', v_fy, 'annual_income', v_annual, 'deductions', v_ded, 'taxable', v_taxable, 'annual_tax', v_tax, 'tds_so_far', v_ytd_tds + coalesce(d.prev_tds, 0), 'months_left', v_div));
end $$;

create or replace function payroll_line_write(p_run uuid, p_emp uuid, c jsonb, p_extra_note text, p_ded_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into payroll_lines (run_id, emp_id, days_in_month, paid_days, lop_days, basic, da, hra, other_allowance, extra_earning, extra_is_wage, extra_note, gross, pf_wage, pf_ee, pf_eps, pf_epf, edli, pf_admin,
                             esi_wage, esi_covered, esi_ee, esi_er, pt, lwf_ee, lwf_er, tds, other_ded, ded_note, net_pay, tds_detail)
  values (p_run, p_emp, (c ->> 'days_in_month')::int, (c ->> 'paid_days')::numeric, (c ->> 'lop_days')::numeric, (c ->> 'basic')::numeric, (c ->> 'da')::numeric, (c ->> 'hra')::numeric, (c ->> 'other_allowance')::numeric,
          (c ->> 'extra_earning')::numeric, (c ->> 'extra_is_wage')::boolean, nullif(btrim(coalesce(p_extra_note, '')), ''), (c ->> 'gross')::numeric, (c ->> 'pf_wage')::numeric, (c ->> 'pf_ee')::numeric, (c ->> 'pf_eps')::numeric,
          (c ->> 'pf_epf')::numeric, (c ->> 'edli')::numeric, (c ->> 'pf_admin')::numeric, (c ->> 'esi_wage')::numeric, (c ->> 'esi_covered')::boolean, (c ->> 'esi_ee')::numeric, (c ->> 'esi_er')::numeric, (c ->> 'pt')::numeric,
          (c ->> 'lwf_ee')::numeric, (c ->> 'lwf_er')::numeric, (c ->> 'tds')::numeric, (c ->> 'other_ded')::numeric, nullif(btrim(coalesce(p_ded_note, '')), ''), (c ->> 'net_pay')::numeric, c -> 'tds_detail')
  on conflict (run_id, emp_id) do update set days_in_month = excluded.days_in_month, paid_days = excluded.paid_days, lop_days = excluded.lop_days, basic = excluded.basic, da = excluded.da, hra = excluded.hra,
    other_allowance = excluded.other_allowance, extra_earning = excluded.extra_earning, extra_is_wage = excluded.extra_is_wage, extra_note = excluded.extra_note, gross = excluded.gross, pf_wage = excluded.pf_wage,
    pf_ee = excluded.pf_ee, pf_eps = excluded.pf_eps, pf_epf = excluded.pf_epf, edli = excluded.edli, pf_admin = excluded.pf_admin, esi_wage = excluded.esi_wage, esi_covered = excluded.esi_covered, esi_ee = excluded.esi_ee,
    esi_er = excluded.esi_er, pt = excluded.pt, lwf_ee = excluded.lwf_ee, lwf_er = excluded.lwf_er, tds = excluded.tds, other_ded = excluded.other_ded, ded_note = excluded.ded_note, net_pay = excluded.net_pay, tds_detail = excluded.tds_detail;
end $$;

create or replace function payroll_run_create(p_month date) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare m date := date_trunc('month', p_month)::date; m_end date; v_id uuid; e record; v_n int := 0; v_prev date;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can start a payroll run'; end if;
  if m is null or m > date_trunc('month', current_date)::date then raise exception 'Choose a month up to the current month'; end if;
  m_end := (m + interval '1 month - 1 day')::date;
  if exists (select 1 from payroll_runs where month = m and status <> 'cancelled') then raise exception 'A payroll run for % already exists', to_char(m, 'Mon YYYY'); end if;
  select max(month) into v_prev from payroll_runs where status in ('approved', 'paid') and month < m;
  if exists (select 1 from payroll_runs where status = 'draft' and month < m) then raise exception 'Finish or cancel the earlier draft payroll run first'; end if;
  insert into payroll_runs (run_no, month) values ('PAY-' || to_char(m, 'YYMM') || '-' || lpad(nextval('payroll_run_seq')::text, 4, '0'), m) returning run_id into v_id;
  for e in select emp_id from employees where date_of_joining <= m_end and (date_of_leaving is null or date_of_leaving >= m) order by emp_code loop
    perform payroll_line_write(v_id, e.emp_id, payroll_compute_line(e.emp_id, m, 0, 0, false, 0), null, null);
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'No employees to pay for %', to_char(m, 'Mon YYYY'); end if;
  return v_id;
end $$;

create or replace function payroll_line_adjust(p_line uuid, p_lop numeric, p_extra numeric, p_extra_wage boolean, p_extra_note text, p_other_ded numeric, p_ded_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l payroll_lines%rowtype; r payroll_runs%rowtype;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can change a payroll line'; end if;
  select * into l from payroll_lines where line_id = p_line;
  if not found then raise exception 'Line not found'; end if;
  select * into r from payroll_runs where run_id = l.run_id;
  if r.status <> 'draft' then raise exception 'Only a draft run can be changed'; end if;
  if coalesce(p_extra, 0) < 0 or coalesce(p_other_ded, 0) < 0 then raise exception 'Amounts cannot be negative'; end if;
  perform payroll_line_write(l.run_id, l.emp_id, payroll_compute_line(l.emp_id, r.month, coalesce(p_lop, 0), coalesce(p_extra, 0), coalesce(p_extra_wage, false), coalesce(p_other_ded, 0)), p_extra_note, p_ded_note);
end $$;

create or replace function payroll_run_recalculate(p_run uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r payroll_runs%rowtype; l record;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can recalculate'; end if;
  select * into r from payroll_runs where run_id = p_run;
  if not found or r.status <> 'draft' then raise exception 'Only a draft run can be recalculated'; end if;
  for l in select * from payroll_lines where run_id = p_run loop
    perform payroll_line_write(p_run, l.emp_id, payroll_compute_line(l.emp_id, r.month, l.lop_days, l.extra_earning, l.extra_is_wage, l.other_ded), l.extra_note, l.ded_note);
  end loop;
end $$;

create or replace function payroll_run_cancel(p_run uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r payroll_runs%rowtype; v_rev uuid;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can cancel a run'; end if;
  select * into r from payroll_runs where run_id = p_run;
  if not found then raise exception 'Run not found'; end if;
  if r.status = 'cancelled' then raise exception 'Already cancelled'; end if;
  if r.status = 'paid' then raise exception 'Salary has been paid for this run. It cannot be cancelled.'; end if;
  if exists (select 1 from payroll_remittances where month = r.month) then raise exception 'Statutory dues for this month have been paid. It cannot be cancelled.'; end if;
  if r.status = 'approved' then
    if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can cancel an approved run'; end if;
    v_rev := br_reverse_voucher(r.voucher_id, 'payroll ' || r.run_no || ' cancelled');
    update payroll_runs set reversal_voucher_id = v_rev where run_id = p_run;
  end if;
  update payroll_runs set status = 'cancelled' where run_id = p_run;
end $$;

-- ---------------------------------------------------------------- approve: posts the accrual
create or replace function payroll_run_approve(p_run uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r payroll_runs%rowtype; t record; v_topup numeric := 0; v_admin numeric; v_lines jsonb := '[]'::jsonb; v_res jsonb; v_date date; v_bad text;
        l_sal uuid; l_erpf uuid; l_adm uuid; l_eresi uuid; l_lwfx uuid; l_pay uuid; l_pf uuid; l_esi uuid; l_pt uuid; l_tds uuid; l_lwf uuid; l_adv uuid; v_pf_tot numeric; v_esi_tot numeric;
begin
  if not has_purchase_approve() then raise exception 'Only a Finance Manager or Super Admin can approve payroll'; end if;
  select * into r from payroll_runs where run_id = p_run for update;
  if not found or r.status <> 'draft' then raise exception 'Only a draft run can be approved'; end if;
  if not pur_self_ok(r.created_by) then raise exception 'A different person must approve this payroll (you started it)'; end if;
  select string_agg(e.name, ', ') into v_bad from payroll_lines l join employees e on e.emp_id = l.emp_id where l.run_id = p_run and l.net_pay < 0;
  if v_bad is not null then raise exception 'Deductions are more than pay for: %. Reduce the recovery or loss-of-pay and try again.', v_bad; end if;
  select coalesce(sum(gross), 0) g, coalesce(sum(pf_ee), 0) pfe, coalesce(sum(pf_eps + pf_epf), 0) pfer, coalesce(sum(edli), 0) edli, coalesce(sum(pf_admin), 0) adm, coalesce(sum(esi_ee), 0) esie, coalesce(sum(esi_er), 0) esir,
         coalesce(sum(pt), 0) pt, coalesce(sum(lwf_ee), 0) lwfe, coalesce(sum(lwf_er), 0) lwfr, coalesce(sum(tds), 0) tds, coalesce(sum(other_ded), 0) od, coalesce(sum(net_pay), 0) net into t from payroll_lines where run_id = p_run;
  if t.g <= 0 then raise exception 'This run has no pay in it'; end if;
  select pf_admin_min into v_admin from payroll_settings where id = 1;
  if t.adm > 0 and t.adm < v_admin then v_topup := v_admin - t.adm; end if;
  v_pf_tot := t.pfe + t.pfer + t.edli + t.adm + v_topup; v_esi_tot := t.esie + t.esir;
  select ledger_id into l_sal from ledgers where name = 'Salaries & Wages'; select ledger_id into l_erpf from ledgers where name = 'Employer PF Contribution'; select ledger_id into l_adm from ledgers where name = 'PF Admin and EDLI Charges';
  select ledger_id into l_eresi from ledgers where name = 'Employer ESI Contribution'; select ledger_id into l_lwfx from ledgers where name = 'Labour Welfare Fund Expense'; select ledger_id into l_pay from ledgers where name = 'Salary Payable';
  select ledger_id into l_pf from ledgers where name = 'PF Payable'; select ledger_id into l_esi from ledgers where name = 'ESI Payable'; select ledger_id into l_pt from ledgers where name = 'Professional Tax Payable';
  select ledger_id into l_tds from ledgers where name = 'TDS on Salary Payable'; select ledger_id into l_lwf from ledgers where name = 'Labour Welfare Fund Payable'; select ledger_id into l_adv from ledgers where name = 'Employee Advances';
  if l_sal is null or l_erpf is null or l_adm is null or l_eresi is null or l_lwfx is null or l_pay is null or l_pf is null or l_esi is null or l_pt is null or l_tds is null or l_lwf is null or l_adv is null then
    raise exception 'A payroll ledger is missing. Check Accounting > Ledgers for the salary and statutory payable ledgers.';
  end if;
  v_date := (r.month + interval '1 month - 1 day')::date;
  v_lines := jsonb_build_array(jsonb_build_object('ledger_id', l_sal, 'debit', t.g, 'credit', 0));
  if t.pfer > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_erpf, 'debit', t.pfer, 'credit', 0); end if;
  if t.edli + t.adm + v_topup > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_adm, 'debit', t.edli + t.adm + v_topup, 'credit', 0); end if;
  if t.esir > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_eresi, 'debit', t.esir, 'credit', 0); end if;
  if t.lwfr > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_lwfx, 'debit', t.lwfr, 'credit', 0); end if;
  if t.net > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_pay, 'debit', 0, 'credit', t.net); end if;
  if v_pf_tot > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_pf, 'debit', 0, 'credit', v_pf_tot); end if;
  if v_esi_tot > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_esi, 'debit', 0, 'credit', v_esi_tot); end if;
  if t.pt > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_pt, 'debit', 0, 'credit', t.pt); end if;
  if t.tds > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tds, 'debit', 0, 'credit', t.tds); end if;
  if t.lwfe + t.lwfr > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_lwf, 'debit', 0, 'credit', t.lwfe + t.lwfr); end if;
  if t.od > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_adv, 'debit', 0, 'credit', t.od); end if;
  v_res := acc_post_journal(v_date, 'Payroll for ' || to_char(r.month, 'Mon YYYY') || ' (' || r.run_no || ')', v_lines, 'payroll', p_run, 'posted', auth.uid());
  update payroll_runs set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, pf_admin_topup = v_topup, approved_by = auth.uid(), approved_at = now() where run_id = p_run;
  return jsonb_build_object('voucher_no', v_res ->> 'voucher_no', 'gross', t.g, 'net', t.net, 'pf', v_pf_tot, 'esi', v_esi_tot, 'pt', t.pt, 'tds', t.tds, 'lwf', t.lwfe + t.lwfr);
end $$;

-- ---------------------------------------------------------------- pay the salaries
create or replace function payroll_run_pay(p_run uuid, p_bank uuid, p_date date, p_reference text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare r payroll_runs%rowtype; v_net numeric; v_bank uuid; l_pay uuid; v_res jsonb;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can record salary payment'; end if;
  select * into r from payroll_runs where run_id = p_run for update;
  if not found or r.status <> 'approved' then raise exception 'Only an approved run can be marked paid'; end if;
  if p_date is null or p_date > current_date or p_date < r.month then raise exception 'Choose the date the salaries were paid (not in the future)'; end if;
  v_bank := br_bank_ledger_of(p_bank);
  if v_bank is null then raise exception 'Choose the bank account the salaries were paid from'; end if;
  select coalesce(sum(net_pay), 0) into v_net from payroll_lines where run_id = p_run;
  select ledger_id into l_pay from ledgers where name = 'Salary Payable';
  v_res := acc_post_journal(p_date, 'Salaries paid for ' || to_char(r.month, 'Mon YYYY') || ' (' || r.run_no || ')',
    jsonb_build_array(jsonb_build_object('ledger_id', l_pay, 'debit', v_net, 'credit', 0), jsonb_build_object('ledger_id', v_bank, 'debit', 0, 'credit', v_net)), 'payroll_payment', p_run, 'posted', auth.uid());
  update payroll_runs set status = 'paid', paid_voucher_id = (v_res ->> 'voucher_id')::uuid, paid_on = p_date, pay_reference = nullif(btrim(coalesce(p_reference, '')), '') where run_id = p_run;
  return (v_res ->> 'voucher_id')::uuid;
end $$;

-- ---------------------------------------------------------------- statutory dues
create or replace view payroll_dues with (security_invoker = true) as
with a as (
  select r.month, 'pf'::text as head, sum(l.pf_ee + l.pf_eps + l.pf_epf + l.edli + l.pf_admin) + max(r.pf_admin_topup) as accrued
    from payroll_runs r join payroll_lines l on l.run_id = r.run_id where r.status in ('approved', 'paid') group by r.month
  union all select r.month, 'esi', sum(l.esi_ee + l.esi_er) from payroll_runs r join payroll_lines l on l.run_id = r.run_id where r.status in ('approved', 'paid') group by r.month
  union all select r.month, 'pt', sum(l.pt) from payroll_runs r join payroll_lines l on l.run_id = r.run_id where r.status in ('approved', 'paid') group by r.month
  union all select r.month, 'tds', sum(l.tds) from payroll_runs r join payroll_lines l on l.run_id = r.run_id where r.status in ('approved', 'paid') group by r.month
  union all select r.month, 'lwf', sum(l.lwf_ee + l.lwf_er) from payroll_runs r join payroll_lines l on l.run_id = r.run_id where r.status in ('approved', 'paid') group by r.month)
select a.month, a.head, a.accrued, coalesce((select sum(p.amount) from payroll_remittances p where p.month = a.month and p.head = a.head), 0) as remitted,
       a.accrued - coalesce((select sum(p.amount) from payroll_remittances p where p.month = a.month and p.head = a.head), 0) as balance,
       case a.head when 'tds' then case when extract(month from a.month) = 3 then make_date(extract(year from a.month)::int, 4, 30) else (a.month + interval '1 month' + interval '6 days')::date end
                   when 'lwf' then case when extract(month from a.month) = 6 then make_date(extract(year from a.month)::int, 7, 15) else make_date(extract(year from a.month)::int + 1, 1, 15) end
                   else (a.month + interval '1 month' + interval '14 days')::date end as due_date
  from a where a.accrued > 0;
grant select on payroll_dues to authenticated;

create or replace function payroll_remit(p_head text, p_month date, p_amount numeric, p_bank uuid, p_date date, p_reference text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare m date := date_trunc('month', p_month)::date; d record; v_bank uuid; l_pay uuid; v_res jsonb; v_id uuid; v_name text;
begin
  if not has_payroll_write() then raise exception 'Only a user with payroll access can record a statutory payment'; end if;
  if p_head not in ('pf', 'esi', 'pt', 'tds', 'lwf') then raise exception 'Choose PF, ESI, professional tax, TDS or labour welfare'; end if;
  select * into d from payroll_dues where month = m and head = p_head;
  if not found then raise exception 'There is nothing due under this head for %', to_char(m, 'Mon YYYY'); end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount paid'; end if;
  if round(p_amount, 2) > d.balance then raise exception 'Only % is left to pay for % %', d.balance, upper(p_head), to_char(m, 'Mon YYYY'); end if;
  if p_date is null or p_date > current_date or p_date < m then raise exception 'Choose the payment date (not in the future)'; end if;
  v_bank := br_bank_ledger_of(p_bank); if v_bank is null then raise exception 'Choose the bank account the payment was made from'; end if;
  v_name := case p_head when 'pf' then 'PF Payable' when 'esi' then 'ESI Payable' when 'pt' then 'Professional Tax Payable' when 'tds' then 'TDS on Salary Payable' else 'Labour Welfare Fund Payable' end;
  select ledger_id into l_pay from ledgers where name = v_name;
  v_res := acc_post_journal(p_date, upper(p_head) || ' paid for ' || to_char(m, 'Mon YYYY') || coalesce(' (' || nullif(btrim(coalesce(p_reference, '')), '') || ')', ''),
    jsonb_build_array(jsonb_build_object('ledger_id', l_pay, 'debit', round(p_amount, 2), 'credit', 0), jsonb_build_object('ledger_id', v_bank, 'debit', 0, 'credit', round(p_amount, 2))), 'payroll_remittance', null, 'posted', auth.uid());
  insert into payroll_remittances (head, month, amount, remit_date, bank_account_id, reference, voucher_id) values (p_head, m, round(p_amount, 2), p_date, p_bank, nullif(btrim(coalesce(p_reference, '')), ''), (v_res ->> 'voucher_id')::uuid) returning rem_id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------- return and certificate data
create or replace function payroll_ecr_rows(p_run uuid) returns table (uan text, member_name text, gross_wages numeric, epf_wages numeric, eps_wages numeric, edli_wages numeric, epf_ee numeric, eps_er numeric, epf_er_diff numeric, ncp_days numeric, refund numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_view() then return; end if;
  return query
  select e.uan, e.name, l.gross, l.pf_wage, least(l.pf_wage, (select pf_wage_ceiling from payroll_settings where id = 1)), least(l.pf_wage, (select edli_cap from payroll_settings where id = 1)),
         l.pf_ee, l.pf_eps, l.pf_epf, l.days_in_month - l.paid_days, 0::numeric
    from payroll_lines l join employees e on e.emp_id = l.emp_id where l.run_id = p_run and l.pf_wage > 0 order by e.emp_code;
end $$;

create or replace function payroll_tds_summary(p_fy int, p_q int) returns table (emp_code text, name text, pan text, month date, gross numeric, tds numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare qb record;
begin
  if not has_payroll_view() then return; end if;
  select * into qb from tds_quarter(p_fy, p_q);
  return query select e.emp_code, e.name, e.pan, r.month, l.gross, l.tds from payroll_lines l join payroll_runs r on r.run_id = l.run_id join employees e on e.emp_id = l.emp_id
   where r.status in ('approved', 'paid') and r.month between qb.q_from and qb.q_to and l.tds > 0 order by r.month, e.emp_code;
end $$;

create or replace function payroll_form130_rows(p_fy int) returns table (emp_code text, name text, pan text, gross numeric, pf numeric, pt numeric, tds numeric, regime text, taxable numeric, annual_tax numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_view() then return; end if;
  return query
  select e.emp_code, e.name, e.pan, sum(l.gross), sum(l.pf_ee), sum(l.pt), sum(l.tds), coalesce(max(d.regime), 'new'),
         (select (x.tds_detail ->> 'taxable')::numeric from payroll_lines x join payroll_runs rr on rr.run_id = x.run_id where x.emp_id = e.emp_id and rr.status in ('approved', 'paid') and rr.month between make_date(p_fy, 4, 1) and make_date(p_fy + 1, 3, 1) order by rr.month desc limit 1),
         (select (x.tds_detail ->> 'annual_tax')::numeric from payroll_lines x join payroll_runs rr on rr.run_id = x.run_id where x.emp_id = e.emp_id and rr.status in ('approved', 'paid') and rr.month between make_date(p_fy, 4, 1) and make_date(p_fy + 1, 3, 1) order by rr.month desc limit 1)
    from payroll_lines l join payroll_runs r on r.run_id = l.run_id join employees e on e.emp_id = l.emp_id
    left join employee_declarations d on d.emp_id = e.emp_id and d.fy = p_fy
   where r.status in ('approved', 'paid') and r.month between make_date(p_fy, 4, 1) and make_date(p_fy + 1, 3, 1)
   group by e.emp_id, e.emp_code, e.name, e.pan order by e.emp_code;
end $$;

create or replace function payroll_bank_file(p_run uuid) returns table (beneficiary text, account_number text, ifsc text, bank text, amount numeric, reference text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not has_payroll_write() then return; end if;
  return query select b.account_holder, b.account_number, b.ifsc, b.bank_name, l.net_pay, r.run_no || '-' || e.emp_code
    from payroll_lines l join payroll_runs r on r.run_id = l.run_id join employees e on e.emp_id = l.emp_id join employee_bank b on b.emp_id = e.emp_id where l.run_id = p_run and l.net_pay > 0 order by e.emp_code;
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
    'automation_view', coalesce(current_role_name() in ('Super Admin', 'CEO/Owner', 'Operations Manager', 'Finance Manager'), false),
    'uploads', import_can('products') or import_can('opening_stock') or import_can('listing_map') or import_can('ledger_opening') or import_can('orders') or import_can('settlement')
  )
$$;


-- ---------------------------------------------------------------- calendar: payroll items now come from real runs
create or replace function compliance_calendar(p_from date, p_to date) returns table (
  item_key text, kind text, title text, period text, due_date date, authority text, form text, note text,
  filed boolean, filed_on date, ack_no text, status text, days_left int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_emp boolean; v_ptf text;
begin
  if not has_accounting_view() then return; end if;
  select has_employees, pt_frequency into v_emp, v_ptf from statutory_settings where id = 1;
  return query
  with m as (select d::date as m_start from generate_series(date_trunc('month', p_from - interval '3 months'), date_trunc('month', p_to), interval '1 month') d),
  fy as (select y from generate_series(extract(year from p_from)::int - 1, extract(year from p_to)::int) y),
  q as (select fy.y as fy, n as qn, qq.q_from, qq.q_to, qq.return_due, qq.cert_due from fy cross join generate_series(1, 4) n cross join lateral tds_quarter(fy.y, n) qq),
  x as (
    -- TDS deposit, one per deduction month that actually had deductions
    select 'TDS-DEP:' || to_char(m.m_start, 'YYYY-MM') as item_key, 'TDS'::text as kind, 'TDS deposit for ' || to_char(m.m_start, 'Mon YYYY') as title, to_char(m.m_start, 'YYYY-MM') as period,
           tds_due_date(to_char(m.m_start, 'YYYY-MM')) as due_date, 'Income Tax Department (challan at your bank)'::text as authority, null::text as form,
           'Due on the 7th of the next month; 30 April for March.'::text as note,
           (coalesce((select sum(tds_amount) from purchase_bills where status = 'approved' and bill_date >= m.m_start and bill_date < m.m_start + interval '1 month'), 0)
            <= coalesce((select sum(tax) from tds_challans where status = 'approved' and period = to_char(m.m_start, 'YYYY-MM')), 0)) as auto_filed
      from m where exists (select 1 from purchase_bills where status = 'approved' and tds_amount > 0 and bill_date >= m.m_start and bill_date < m.m_start + interval '1 month')
    union all
    select 'TDS-140:' || q.fy || '-Q' || q.qn, 'TDS', 'TDS statement (Form 140) for ' || q.fy || '-' || right((q.fy + 1)::text, 2) || ' Q' || q.qn, q.fy || '-Q' || q.qn, q.return_due,
           'Income Tax Department (TRACES / e-filing)', 'Form 140 (was 26Q)', 'Late fee Rs 200 a day, up to the tax deducted.', null::boolean
      from q where exists (select 1 from purchase_bills where status = 'approved' and tds_amount > 0 and bill_date between q.q_from and q.q_to)
    union all
    select 'TDS-131:' || q.fy || '-Q' || q.qn, 'TDS', 'TDS certificates (Form 131) for ' || q.fy || '-' || right((q.fy + 1)::text, 2) || ' Q' || q.qn, q.fy || '-Q' || q.qn, q.cert_due,
           'Give to each supplier', 'Form 131 (was 16A)', 'Due 15 days after the statement due date.', null::boolean
      from q where exists (select 1 from purchase_bills where status = 'approved' and tds_amount > 0 and bill_date between q.q_from and q.q_to)
    union all
    select 'GSTR1:' || to_char(m.m_start, 'YYYY-MM'), 'GST', 'GSTR-1 for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '10 days')::date,
           'GST portal', 'GSTR-1', 'Monthly filer. A quarterly (QRMP) filer follows a different date.', gst_period_filed(to_char(m.m_start, 'YYYY-MM'), 'GSTR1')
      from m
    union all
    select 'GSTR3B:' || to_char(m.m_start, 'YYYY-MM'), 'GST', 'GSTR-3B for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '19 days')::date,
           'GST portal', 'GSTR-3B', 'Monthly filer. A quarterly (QRMP) filer follows a different date.', gst_period_filed(to_char(m.m_start, 'YYYY-MM'), 'GSTR3B')
      from m
    union all
    -- advance tax: 15 June, 15 September, 15 December, 15 March
    select 'ADVTAX:' || fy.y || '-' || a.n, 'Income tax', 'Advance tax instalment (' || a.pct || ') for ' || fy.y || '-' || right((fy.y + 1)::text, 2),
           fy.y || '-' || a.n, make_date(fy.y + a.yoff, a.mon, 15), 'Income Tax Department (challan at your bank)', null,
           'Cumulative: 15% by 15 June, 45% by 15 September, 75% by 15 December, 100% by 15 March. Needed only if the year''s tax will exceed Rs 10,000.', null::boolean
      from fy cross join (values (1, 6, 0, '15%'), (2, 9, 0, '45%'), (3, 12, 0, '75%'), (4, 3, 1, '100%')) as a(n, mon, yoff, pct)
    union all
    select 'PF:' || to_char(m.m_start, 'YYYY-MM'), 'Payroll', 'Provident fund (PF) for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '14 days')::date,
           'EPFO', 'ECR and challan', 'Due on the 15th of the next month. Pay and file the ECR together.',
           coalesce((select d.balance <= 0 from payroll_dues d where d.month = m.m_start and d.head = 'pf'), false)
      from m where exists (select 1 from payroll_dues d where d.month = m.m_start and d.head = 'pf')
    union all
    select 'ESI:' || to_char(m.m_start, 'YYYY-MM'), 'Payroll', 'Employees'' State Insurance (ESI) for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '14 days')::date,
           'ESIC', 'Monthly contribution', 'Due on the 15th of the next month.',
           coalesce((select d.balance <= 0 from payroll_dues d where d.month = m.m_start and d.head = 'esi'), false)
      from m where exists (select 1 from payroll_dues d where d.month = m.m_start and d.head = 'esi')
    union all
    select 'PT:' || to_char(m.m_start, 'YYYY-MM'), 'Payroll', 'Gujarat professional tax for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), (m.m_start + interval '1 month' + interval '14 days')::date,
           'Gujarat Commercial Tax Department', 'Form 5 (monthly)', 'Working rule: 15th of the next month. Confirm your due date on your certificate.',
           coalesce((select d.balance <= 0 from payroll_dues d where d.month = m.m_start and d.head = 'pt'), false)
      from m where v_ptf = 'monthly' and exists (select 1 from payroll_dues d where d.month = m.m_start and d.head = 'pt')
    union all
    select 'TDS-DEP-SAL:' || to_char(m.m_start, 'YYYY-MM'), 'TDS', 'Salary TDS deposit for ' || to_char(m.m_start, 'Mon YYYY'), to_char(m.m_start, 'YYYY-MM'), tds_due_date(to_char(m.m_start, 'YYYY-MM')),
           'Income Tax Department (challan at your bank)', null, 'Due on the 7th of the next month; 30 April for March.',
           coalesce((select d.balance <= 0 from payroll_dues d where d.month = m.m_start and d.head = 'tds'), false)
      from m where exists (select 1 from payroll_dues d where d.month = m.m_start and d.head = 'tds')
    union all
    select 'LWF:' || fy.y || '-' || h.n, 'Payroll', 'Gujarat labour welfare fund, ' || h.label || ' ' || fy.y, fy.y || '-' || h.n, make_date(fy.y + h.dyoff, h.dmon, 15),
           'Gujarat Labour Welfare Board', 'Half-yearly return', 'Contribution is deducted in June and December. Working rule: pay by 15 July and 15 January.',
           coalesce((select d.balance <= 0 from payroll_dues d where d.month = make_date(fy.y, h.dedmon, 1) and d.head = 'lwf'), false)
      from fy cross join (values (1, 'January to June', 0, 7, 6), (2, 'July to December', 1, 1, 12)) as h(n, label, dyoff, dmon, dedmon)
     where exists (select 1 from payroll_dues d where d.month = make_date(fy.y, h.dedmon, 1) and d.head = 'lwf')
    union all
    select 'TDS-138:' || q.fy || '-Q' || q.qn, 'Payroll', 'Salary TDS statement (Form 138) for ' || q.fy || '-' || right((q.fy + 1)::text, 2) || ' Q' || q.qn, q.fy || '-Q' || q.qn, q.return_due,
           'Income Tax Department (TRACES / e-filing)', 'Form 138 (was 24Q)', 'Late fee Rs 200 a day, up to the tax deducted.', null::boolean
      from q where exists (select 1 from payroll_dues d where d.head = 'tds' and d.month between q.q_from and q.q_to)
    union all
    select 'TDS-130:' || fy.y, 'Payroll', 'Salary TDS certificates (Form 130) for ' || fy.y || '-' || right((fy.y + 1)::text, 2), fy.y::text, make_date(fy.y + 1, 6, 15),
           'Give to each employee', 'Form 130 (was Form 16)', 'Due by 15 June after the year ends.', null::boolean
      from fy where exists (select 1 from payroll_dues d where d.head = 'tds' and d.month between make_date(fy.y, 4, 1) and make_date(fy.y + 1, 3, 1))
  )
  select x.item_key, x.kind, x.title, x.period, x.due_date::date, x.authority, x.form, x.note,
         coalesce(x.auto_filed, f.filing_key is not null) as filed, f.filed_on, f.ack_no,
         case when coalesce(x.auto_filed, f.filing_key is not null) then 'filed' when x.due_date < current_date then 'overdue' when x.due_date <= current_date + 7 then 'due_soon' else 'upcoming' end,
         (x.due_date::date - current_date)
    from x left join compliance_filings f on f.filing_key = x.item_key
   where x.due_date between p_from and p_to
   order by x.due_date, x.title;
end $$;


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
  and not exists (select 1 from payroll_runs where month = date_trunc('month', current_date)::date and status <> 'cancelled');

-- ---------------------------------------------------------------- permissions
revoke execute on function has_payroll_view(), has_payroll_write(), payroll_settings_save(jsonb), employee_save(uuid, jsonb), employee_set_salary(uuid, date, numeric, numeric, numeric, numeric),
  employee_set_bank(uuid, text, text, text, text), employee_set_declaration(uuid, int, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric), employee_exit(uuid, date),
  payroll_slab_tax(text, int, numeric, text), payroll_annual_tax(text, int, numeric, text), payroll_compute_line(uuid, date, numeric, numeric, boolean, numeric),
  payroll_line_write(uuid, uuid, jsonb, text, text), payroll_run_create(date), payroll_line_adjust(uuid, numeric, numeric, boolean, text, numeric, text), payroll_run_recalculate(uuid),
  payroll_run_cancel(uuid), payroll_run_approve(uuid), payroll_run_pay(uuid, uuid, date, text), payroll_remit(text, date, numeric, uuid, date, text), payroll_ecr_rows(uuid),
  payroll_tds_summary(int, int), payroll_form130_rows(int), payroll_bank_file(uuid), compliance_calendar(date, date), my_nav_access() from public, anon, authenticated;
grant execute on function has_payroll_view(), has_payroll_write(), payroll_settings_save(jsonb), employee_save(uuid, jsonb), employee_set_salary(uuid, date, numeric, numeric, numeric, numeric),
  employee_set_bank(uuid, text, text, text, text), employee_set_declaration(uuid, int, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric), employee_exit(uuid, date),
  payroll_slab_tax(text, int, numeric, text), payroll_annual_tax(text, int, numeric, text), payroll_run_create(date), payroll_line_adjust(uuid, numeric, numeric, boolean, text, numeric, text),
  payroll_run_recalculate(uuid), payroll_run_cancel(uuid), payroll_run_approve(uuid), payroll_run_pay(uuid, uuid, date, text), payroll_remit(text, date, numeric, uuid, date, text), payroll_ecr_rows(uuid),
  payroll_tds_summary(int, int), payroll_form130_rows(int), payroll_bank_file(uuid), compliance_calendar(date, date), my_nav_access() to authenticated;
