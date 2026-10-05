-- 0094: four items from the audit, built with suggested defaults. CONFIRM WITH YOUR CA.
--  1. Bonus for a leaver, worked out from the pay runs (statutory bonus, pro rata for the months worked).
--  2. Marketplace COD orders delivered but not yet in any settlement, with the fee we expect.
--  3. A register of sales credit notes that shows the credit-note number beside the voucher number.
--  4. Bills dated in one month but entered in a later month (month-end cut-off).
-- Nothing here posts to the books.

-- ------------------------------------------------------------------ 1. leaver's bonus
create or replace function fnf_bonus_suggest(p_emp uuid, p_last date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s payroll_exit_settings%rowtype; v_fy int; v_from date; v_to date; r record; v_amt numeric := 0; v_elig boolean; v_reason text; v_in_run boolean;
begin
  if not has_payroll_view() then raise exception 'Not allowed'; end if;
  select * into s from payroll_exit_settings where id = 1;
  v_fy := case when extract(month from p_last) >= 4 then extract(year from p_last)::int else extract(year from p_last)::int - 1 end;
  v_from := make_date(v_fy, 4, 1); v_to := date_trunc('month', p_last)::date;
  select coalesce(sum(l.paid_days), 0) as days, count(*) as n, coalesce(sum(least(l.basic + l.da, s.bonus_calc_cap)), 0) as wage, coalesce(max(l.basic + l.da), 0) as top_wage
    into r
    from payroll_lines l join payroll_runs pr on pr.run_id = l.run_id and pr.status in ('approved', 'paid') and pr.month between v_from and v_to
   where l.emp_id = p_emp;
  select exists (select 1 from bonus_runs b join bonus_lines bl on bl.bonus_id = b.bonus_id where b.fy = v_fy and b.status in ('approved', 'paid') and bl.emp_id = p_emp and bl.amount > 0) into v_in_run;
  v_elig := r.days >= s.bonus_min_days and r.top_wage <= s.bonus_eligible_wage;
  if v_in_run then v_reason := 'Already paid in this year''s bonus run';
  elsif r.n = 0 then v_reason := 'No approved pay runs for this person in the year';
  elsif r.days < s.bonus_min_days then v_reason := 'Worked fewer than ' || s.bonus_min_days || ' days';
  elsif r.top_wage > s.bonus_eligible_wage then v_reason := 'Monthly basic + DA is above the eligibility limit';
  end if;
  if v_elig and not v_in_run then v_amt := round(r.wage * (select pct from (select s2.bonus_pct as pct from payroll_exit_settings s2 where s2.id = 1) q) / 100, 2); end if;
  return jsonb_build_object('amount', v_amt, 'fy', v_fy, 'months', r.n, 'days', r.days, 'wage', round(r.wage, 2), 'pct', s.bonus_pct, 'reason', v_reason);
end $$;
revoke execute on function fnf_bonus_suggest(uuid, date) from public, anon;
grant execute on function fnf_bonus_suggest(uuid, date) to authenticated;

-- ------------------------------------------------------------------ 2. marketplace COD orders awaiting settlement
create or replace view cod_awaiting_settlement with (security_invoker = true) as
select o.order_id, o.external_order_id, c.channel_id, c.name as channel_name, o.order_date::date as order_date,
       (current_date - o.order_date::date) as days_old, o.net_amount,
       round(coalesce((select sum(o.net_amount * f.percent / 100 + f.fixed) from channel_fee_rules f where f.channel_id = o.channel_id), 0), 2) as expected_fees
  from orders o join channels c on c.channel_id = o.channel_id
 where o.payment_type = 'cod' and c.type = 'marketplace' and o.fulfilment_status = 'delivered'
   and not exists (select 1 from settlement_lines l where l.order_id = o.order_id and l.fee_type = 'order_value');
grant select on cod_awaiting_settlement to authenticated;

-- ------------------------------------------------------------------ 3. sales credit-note register
create or replace view sales_credit_note_register with (security_invoker = true) as
select cn.credit_note_id, cn.note_number, cn.date, i.invoice_number, o.external_order_id, cn.amount, cn.tax_amount, cn.status,
       v.voucher_no,
       case when abs(cn.amount - i.total) < 0.01 then 'Full' else 'Partial' end as note_kind
  from credit_notes cn join invoices i on i.invoice_id = cn.invoice_id join orders o on o.order_id = i.order_id
  left join vouchers v on v.voucher_id = cn.voucher_id;
grant select on sales_credit_note_register to authenticated;

-- ------------------------------------------------------------------ 4. month-end cut-off
create or replace view bills_booked_late with (security_invoker = true) as
select b.bill_id, b.bill_no, s.name as supplier_name, b.supplier_invoice_no, b.supplier_invoice_date, b.bill_date, b.total,
       (date_trunc('month', b.bill_date)::date - date_trunc('month', b.supplier_invoice_date)::date) as months_late
  from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
 where b.status = 'approved' and date_trunc('month', b.bill_date) > date_trunc('month', b.supplier_invoice_date);
grant select on bills_booked_late to authenticated;
