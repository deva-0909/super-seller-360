-- 0093: business rules found in the audit.
--  1. Gujarat professional tax by slab (not a flat Rs 200), with women's exemption. Rates are editable. CONFIRM WITH YOUR CA before relying on them.
--  2. MSME suppliers paid after the 45-day limit (Section 43B(h): such payments are not deductible in the year, and interest is due to the supplier).
--  3. RTO shipments stuck on the way back for more than 15 days.

-- ------------------------------------------------------------------ 1. professional tax
create table if not exists pt_slabs (
  from_amt numeric(12,2) primary key check (from_amt >= 0),
  amount   numeric(10,2) not null check (amount >= 0),
  note     text
);
insert into pt_slabs (from_amt, amount, note) values
  (6000, 80, 'Gujarat slab: Rs 6,000 to 8,999 a month. Confirm with your CA.'),
  (9000, 150, 'Gujarat slab: Rs 9,000 to 11,999 a month. Confirm with your CA.'),
  (12000, 200, 'Gujarat slab: Rs 12,000 and above. Confirm with your CA.')
on conflict (from_amt) do nothing;
alter table payroll_settings add column if not exists pt_women_exempt_below numeric(10,2) not null default 12000;
comment on column payroll_settings.pt_women_exempt_below is 'Women earning below this a month pay no professional tax (Gujarat). Confirm with your CA.';

alter table pt_slabs enable row level security;
drop policy if exists "pt slabs read" on pt_slabs;
create policy "pt slabs read" on pt_slabs for select to authenticated using (has_payroll_view());
grant select on pt_slabs to authenticated;

create or replace function pt_for(p_wage numeric, p_gender text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_gender = 'female' and p_wage < coalesce((select pt_women_exempt_below from payroll_settings where id = 1), 0) then 0
    else coalesce((select amount from pt_slabs where from_amt <= p_wage order by from_amt desc limit 1), 0)
  end
$$;

create or replace function pt_slab_save(p_from numeric, p_amount numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not (is_super_admin() or has_payroll_write()) then raise exception 'Only a Super Admin or payroll user can change professional tax slabs'; end if;
  if p_from is null or p_from < 0 or p_amount is null or p_amount < 0 then raise exception 'Enter the salary from which the slab starts and the tax amount'; end if;
  insert into pt_slabs (from_amt, amount) values (p_from, p_amount) on conflict (from_amt) do update set amount = excluded.amount;
end $$;
create or replace function pt_slab_delete(p_from numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not (is_super_admin() or has_payroll_write()) then raise exception 'Only a Super Admin or payroll user can change professional tax slabs'; end if;
  delete from pt_slabs where from_amt = p_from;
end $$;
revoke execute on function pt_slab_save(numeric, numeric), pt_slab_delete(numeric) from public, anon;
grant execute on function pt_slab_save(numeric, numeric), pt_slab_delete(numeric), pt_for(numeric, text) to authenticated;

do $do$
declare d text;
begin
  d := pg_get_functiondef('payroll_compute_line(uuid,date,numeric,numeric,boolean,numeric)'::regprocedure);
  d := replace(d, 'if e.pt_applicable and v_gross > s.pt_threshold then v_pt := s.pt_amount; end if;', 'if e.pt_applicable then v_pt := pt_for(v_gross, e.gender); end if;');
  d := replace(d, 'v_pt_full := case when sal.total > s.pt_threshold and e.pt_applicable then s.pt_amount else 0 end;', 'v_pt_full := case when e.pt_applicable then pt_for(sal.total, e.gender) else 0 end;');
  if d not like '%pt_for(v_gross%' or d not like '%pt_for(sal.total%' then raise exception 'payroll_compute_line: professional tax lines not found'; end if;
  execute d;
end $do$;

-- ------------------------------------------------------------------ 2. MSME bills paid late
create or replace view msme_paid_late with (security_invoker = true) as
select b.bill_id, b.bill_no, s.supplier_id, s.name as supplier_name, b.supplier_invoice_no, b.supplier_invoice_date,
       (b.supplier_invoice_date + least(s.payment_terms_days, coalesce((select msme_limit_days from purchase_settings where id = 1), 45))) as limit_date,
       p.payment_no, p.payment_date, a.amount as paid_amount,
       p.payment_date - (b.supplier_invoice_date + least(s.payment_terms_days, coalesce((select msme_limit_days from purchase_settings where id = 1), 45))) as days_late
  from payment_allocations a
  join supplier_payments p on p.payment_id = a.payment_id and p.status = 'approved'
  join purchase_bills b on b.bill_id = a.bill_id and b.status = 'approved'
  join suppliers s on s.supplier_id = b.supplier_id and s.is_msme
 where p.payment_date > (b.supplier_invoice_date + least(s.payment_terms_days, coalesce((select msme_limit_days from purchase_settings where id = 1), 45)));
grant select on msme_paid_late to authenticated;

-- ------------------------------------------------------------------ 3. RTOs stuck on the way back
create or replace view rto_stuck with (security_invoker = true) as
select r.rto_id, r.order_id, o.external_order_id, o.net_amount, r.awb, r.status, r.created_at::date as raised_on,
       (current_date - r.created_at::date) as days_open
  from rtos r join orders o on o.order_id = r.order_id
 where r.status in ('initiated', 'in_transit') and r.created_at < now() - interval '15 days';
grant select on rto_stuck to authenticated;
