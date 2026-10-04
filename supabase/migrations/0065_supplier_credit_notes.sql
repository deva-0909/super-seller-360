-- 0065: Supplier credit notes (purchase returns).
--
-- A supplier credit note reduces what you owe on one of their bills (goods returned, rate difference, discount after the sale). It is
-- entered against a bill and follows the usual maker-checker; approval posts
--   Dr Sundry Creditors (note total less any TDS taken back), Dr TDS Payable (the TDS on the returned value),
--   Cr Purchase Returns (value), Cr Input CGST/SGST/IGST (only if credit was claimed on the original bill).
-- Effects elsewhere:
--   * the bill's outstanding amount and creditors ageing fall by the note
--   * GSTR-3B workings show the credit reversed in the month of the note (section 4(B)(2)-style reversal; confirm with your CA)
--   * the TDS register for the bill's month falls by the TDS taken back (a deposit already made then shows as "deposited more than deducted")
--   * the GSTR-2B check matches the supplier's credit notes to the notes recorded here
-- A note cannot exceed the value of the bill, nor what is still owed on it. If the bill is already paid, the supplier owes you a
-- refund, which is not recorded here.

insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = 'Expenses' limit 1), 'Purchase Returns', 'expense', 0, 'debit', false, false, 'active'
where not exists (select 1 from ledgers where name = 'Purchase Returns');

create sequence if not exists supplier_credit_note_seq;

create table if not exists supplier_credit_notes (
  note_id             uuid primary key default gen_random_uuid(),
  note_no             text not null unique,
  supplier_id         uuid not null references suppliers(supplier_id),
  bill_id             uuid not null references purchase_bills(bill_id),
  supplier_note_no    text not null check (btrim(supplier_note_no) <> ''),
  note_date           date not null,
  reason              text not null check (reason in ('return', 'rate_difference', 'discount', 'other')),
  lines               jsonb not null,
  taxable_value       numeric(14,2) not null check (taxable_value > 0),
  cgst                numeric(14,2) not null default 0,
  sgst                numeric(14,2) not null default 0,
  igst                numeric(14,2) not null default 0,
  total               numeric(14,2) not null,
  itc_reversal        boolean not null,
  tds_adj             numeric(14,2) not null default 0,
  tds_period          text,
  tds_section         text,
  payable_reduction   numeric(14,2),
  notes               text,
  status              text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  voucher_id          uuid references vouchers(voucher_id),
  reversal_voucher_id uuid references vouchers(voucher_id),
  decision_note       text,
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  decided_by          uuid,
  decided_at          timestamptz
);
create unique index if not exists scn_supplier_no_uq on supplier_credit_notes (supplier_id, lower(btrim(supplier_note_no))) where status in ('pending', 'approved');
create index if not exists scn_bill on supplier_credit_notes (bill_id, status);
create index if not exists scn_date on supplier_credit_notes (note_date) where status = 'approved';

alter table supplier_credit_notes enable row level security;
drop policy if exists "scn read" on supplier_credit_notes;
create policy "scn read" on supplier_credit_notes for select to authenticated using (has_accounting_view());
grant select on supplier_credit_notes to authenticated;

-- ---------------------------------------------------------------- create
-- p_lines: [{description, taxable, gst_rate}]
create or replace function create_supplier_credit_note(p_bill uuid, p_note_no text, p_date date, p_reason text, p_lines jsonb, p_notes text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b purchase_bills%rowtype; s suppliers%rowtype; ln jsonb; n int := 0; tx numeric; rt numeric; tax numeric; c numeric; sg numeric; ig numeric;
  t_tx numeric := 0; t_c numeric := 0; t_s numeric := 0; t_i numeric := 0; v_prior numeric; v_id uuid; v_out jsonb := '[]'::jsonb;
  v_rates numeric[] := array[0, 0.25, 3, 5, 12, 18, 28, 40];
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can record a supplier credit note'; end if;
  select * into b from purchase_bills where bill_id = p_bill;
  if not found or b.status <> 'approved' then raise exception 'Choose an approved bill'; end if;
  if b.is_opening then raise exception 'This is an opening-balance bill, which has no tax detail. Record the supplier''s credit note by correcting the opening balance.'; end if;
  select * into s from suppliers where supplier_id = b.supplier_id;
  if nullif(btrim(coalesce(p_note_no, '')), '') is null then raise exception 'Enter the supplier''s credit note number'; end if;
  if p_date is null or p_date > current_date then raise exception 'The note date cannot be empty or in the future'; end if;
  if p_date < b.supplier_invoice_date then raise exception 'The note date is before the invoice date'; end if;
  if p_reason not in ('return', 'rate_difference', 'discount', 'other') then raise exception 'Choose the reason'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Add at least one line'; end if;
  for ln in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    tx := round(coalesce(nullif(ln ->> 'taxable', '')::numeric, 0), 2);
    rt := coalesce(nullif(ln ->> 'gst_rate', '')::numeric, 0);
    if tx <= 0 then raise exception 'Line %: enter the value before GST', n; end if;
    if not (rt = any (v_rates)) then raise exception 'Line %: GST rate % is not one of 0, 0.25, 3, 5, 12, 18, 28, 40', n, rt; end if;
    tax := round(tx * rt / 100, 2);
    if b.is_intra_state then c := floor(tax * 100 / 2) / 100; sg := tax - c; ig := 0; else c := 0; sg := 0; ig := tax; end if;
    t_tx := t_tx + tx; t_c := t_c + c; t_s := t_s + sg; t_i := t_i + ig;
    v_out := v_out || jsonb_build_object('line_no', n, 'description', nullif(btrim(coalesce(ln ->> 'description', '')), ''), 'taxable', tx, 'gst_rate', rt, 'cgst', c, 'sgst', sg, 'igst', ig);
  end loop;
  if s.gstin is null and (t_c + t_s + t_i) > 0 then raise exception 'This supplier has no GSTIN, so a credit note cannot carry GST. Set the rate to 0.'; end if;
  select coalesce(sum(taxable_value), 0) into v_prior from supplier_credit_notes where bill_id = p_bill and status in ('pending', 'approved');
  if t_tx + v_prior > b.taxable_value then
    raise exception 'Credit notes on this bill would total % before GST, more than the bill''s % (earlier notes: %)', t_tx + v_prior, b.taxable_value, v_prior;
  end if;
  begin
    insert into supplier_credit_notes (note_no, supplier_id, bill_id, supplier_note_no, note_date, reason, lines, taxable_value, cgst, sgst, igst, total, itc_reversal, notes)
    values ('SCN-' || to_char(p_date, 'YYMM') || '-' || lpad(nextval('supplier_credit_note_seq')::text, 5, '0'), b.supplier_id, p_bill, btrim(p_note_no), p_date, p_reason, v_out,
            t_tx, t_c, t_s, t_i, t_tx + t_c + t_s + t_i, b.itc_eligible, nullif(btrim(coalesce(p_notes, '')), ''))
    returning note_id into v_id;
  exception when unique_violation then raise exception 'A credit note numbered % from this supplier is already entered', btrim(p_note_no);
  end;
  return v_id;
end $$;

-- ---------------------------------------------------------------- what is still owed on a bill (payments and credit notes taken off)
create or replace function bill_outstanding(p_bill uuid, p_as_of date default null, p_include_pending boolean default false) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select b.net_payable
         - coalesce((select sum(a.amount) from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id
                      where a.bill_id = b.bill_id
                        and (p.status = 'approved' or (p_include_pending and p.status = 'pending'))
                        and (p_as_of is null or p.payment_date <= p_as_of)), 0)
         - coalesce((select sum(n.payable_reduction) from supplier_credit_notes n
                      where n.bill_id = b.bill_id and n.status = 'approved' and (p_as_of is null or n.note_date <= p_as_of)), 0)
    from purchase_bills b where b.bill_id = p_bill and b.status = 'approved'
$$;

create or replace function approve_supplier_credit_note(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  n supplier_credit_notes%rowtype; b purchase_bills%rowtype; s suppliers%rowtype; v_tds_adj numeric := 0; v_prior_adj numeric; v_red numeric; v_out numeric;
  l_cr uuid; l_ret uuid; l_tds uuid; l_cgst uuid; l_sgst uuid; l_igst uuid; v_lines jsonb := '[]'::jsonb; v_ret_amt numeric; v_res jsonb;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve a supplier credit note'; end if;
  select * into n from supplier_credit_notes where note_id = p_id for update;
  if not found then raise exception 'Credit note not found'; end if;
  if n.status <> 'pending' then raise exception 'This credit note is already %', n.status; end if;
  if not pur_self_ok(n.created_by) then raise exception 'A different person must approve this credit note (you entered it)'; end if;
  select * into b from purchase_bills where bill_id = n.bill_id for update;
  if b.status <> 'approved' then raise exception 'The bill is %, so the credit note cannot be approved', b.status; end if;
  select * into s from suppliers where supplier_id = n.supplier_id;
  if b.tds_amount > 0 and b.taxable_value > 0 then
    select coalesce(sum(tds_adj), 0) into v_prior_adj from supplier_credit_notes where bill_id = b.bill_id and status = 'approved';
    v_tds_adj := least(round(n.taxable_value / b.taxable_value * b.tds_amount, 2), b.tds_amount - v_prior_adj);
  end if;
  v_red := n.total - v_tds_adj;
  v_out := bill_outstanding(b.bill_id, null, true);
  if v_red > v_out then
    raise exception 'Only % is still owed on bill % (after payments, including those waiting for approval). The bill is largely paid, so ask the supplier for a refund instead.', v_out, b.bill_no;
  end if;
  select ledger_id into l_cr  from ledgers where name = 'Sundry Creditors';
  select ledger_id into l_ret from ledgers where name = 'Purchase Returns';
  select ledger_id into l_tds from ledgers where name = 'TDS Payable';
  select ledger_id into l_cgst from ledgers where name = 'Input CGST';
  select ledger_id into l_sgst from ledgers where name = 'Input SGST';
  select ledger_id into l_igst from ledgers where name = 'Input IGST';
  if l_cr is null or l_ret is null or l_tds is null or l_cgst is null or l_sgst is null or l_igst is null then raise exception 'A purchase ledger is missing'; end if;
  v_ret_amt := n.taxable_value + case when n.itc_reversal then 0 else n.cgst + n.sgst + n.igst end;
  v_lines := jsonb_build_array(jsonb_build_object('ledger_id', l_cr, 'debit', v_red, 'credit', 0, 'narration', s.name || ' credit note ' || n.supplier_note_no));
  if v_tds_adj > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tds, 'debit', v_tds_adj, 'credit', 0, 'narration', 'TDS taken back ' || coalesce(b.tds_section, '')); end if;
  v_lines := v_lines || jsonb_build_object('ledger_id', l_ret, 'debit', 0, 'credit', v_ret_amt, 'narration', 'Purchase return ' || b.supplier_invoice_no);
  if n.itc_reversal then
    if n.cgst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_cgst, 'debit', 0, 'credit', n.cgst, 'narration', 'Input CGST reversed'); end if;
    if n.sgst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_sgst, 'debit', 0, 'credit', n.sgst, 'narration', 'Input SGST reversed'); end if;
    if n.igst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_igst, 'debit', 0, 'credit', n.igst, 'narration', 'Input IGST reversed'); end if;
  end if;
  v_res := acc_post_journal(n.note_date, 'Supplier credit note ' || n.note_no || ' - ' || s.name || ' ' || n.supplier_note_no || ' against ' || b.bill_no, v_lines, 'supplier_credit_note', n.note_id, 'posted', auth.uid());
  update supplier_credit_notes set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, decided_by = auth.uid(), decided_at = now(),
         tds_adj = v_tds_adj, tds_period = case when v_tds_adj > 0 then to_char(b.bill_date, 'YYYY-MM') end, tds_section = case when v_tds_adj > 0 then b.tds_section end,
         payable_reduction = v_red where note_id = p_id;
  return v_res || jsonb_build_object('tds_adj', v_tds_adj, 'payable_reduction', v_red);
end $$;

create or replace function reject_supplier_credit_note(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can reject a supplier credit note'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  update supplier_credit_notes set status = 'rejected', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where note_id = p_id and status = 'pending';
  if not found then raise exception 'Only a pending credit note can be rejected'; end if;
end $$;

create or replace function cancel_supplier_credit_note(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare n supplier_credit_notes%rowtype; v_rev uuid;
begin
  select * into n from supplier_credit_notes where note_id = p_id for update;
  if not found then raise exception 'Credit note not found'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  if n.status = 'pending' then
    if not (n.created_by = auth.uid() or has_purchase_approve()) then raise exception 'Only the person who entered it, or an approver, can withdraw this credit note'; end if;
    update supplier_credit_notes set status = 'cancelled', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where note_id = p_id;
  elsif n.status = 'approved' then
    if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can cancel an approved credit note'; end if;
    v_rev := br_reverse_voucher(n.voucher_id, 'supplier credit note ' || n.note_no || ' cancelled: ' || btrim(p_reason));
    update supplier_credit_notes set status = 'cancelled', reversal_voucher_id = v_rev, decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where note_id = p_id;
  else raise exception 'This credit note is already %', n.status; end if;
end $$;

-- a bill with credit notes cannot be cancelled until the notes are
create or replace function cancel_purchase_bill(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b purchase_bills%rowtype; v_rev uuid;
begin
  select * into b from purchase_bills where bill_id = p_id for update;
  if not found then raise exception 'Bill not found'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  if b.status = 'pending' then
    if not (b.created_by = auth.uid() or has_purchase_approve()) then raise exception 'Only the person who entered it, or an approver, can withdraw this bill'; end if;
    update purchase_bills set status = 'cancelled', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where bill_id = p_id;
  elsif b.status = 'approved' then
    if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can cancel an approved bill'; end if;
    if exists (select 1 from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id
                where a.bill_id = p_id and p.status in ('pending', 'approved')) then
      raise exception 'Payments are recorded against this bill. Cancel those payments first.';
    end if;
    if exists (select 1 from supplier_credit_notes where bill_id = p_id and status in ('pending', 'approved')) then
      raise exception 'Credit notes are recorded against this bill. Cancel those first.';
    end if;
    v_rev := br_reverse_voucher(b.voucher_id, 'purchase bill ' || b.bill_no || ' cancelled: ' || btrim(p_reason));
    update purchase_bills set status = 'cancelled', reversal_voucher_id = v_rev, decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where bill_id = p_id;
  else
    raise exception 'This bill is already %', b.status;
  end if;
end $$;

create or replace function supplier_ageing(p_as_of date default current_date)
returns table (bill_id uuid, bill_no text, supplier_id uuid, supplier_name text, is_msme boolean, supplier_invoice_no text, invoice_date date, bill_date date,
               due_date date, net_payable numeric, paid numeric, outstanding numeric, days_overdue int, bucket text, msme_due_date date, msme_breach boolean)
language sql stable set search_path = public, pg_temp as $$
  with x as (
    select b.bill_id, b.bill_no, b.supplier_id, s.name as supplier_name, s.is_msme, b.supplier_invoice_no, b.supplier_invoice_date as invoice_date, b.bill_date, b.due_date,
           b.net_payable,
           coalesce((select sum(a.amount) from payment_allocations a join supplier_payments p on p.payment_id = a.payment_id
                      where a.bill_id = b.bill_id and p.status = 'approved' and p.payment_date <= p_as_of), 0)
           + coalesce((select sum(n.payable_reduction) from supplier_credit_notes n where n.bill_id = b.bill_id and n.status = 'approved' and n.note_date <= p_as_of), 0) as paid,
           (b.supplier_invoice_date + least(s.payment_terms_days, coalesce((select msme_limit_days from purchase_settings where id = 1), 45))) as msme_due
      from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
     where b.status = 'approved' and b.bill_date <= p_as_of
  )
  select x.bill_id, x.bill_no, x.supplier_id, x.supplier_name, x.is_msme, x.supplier_invoice_no, x.invoice_date, x.bill_date, x.due_date, x.net_payable, x.paid,
         x.net_payable - x.paid, greatest(p_as_of - x.due_date, 0),
         case when p_as_of <= x.due_date then 'Not due' when p_as_of - x.due_date <= 30 then '1-30' when p_as_of - x.due_date <= 60 then '31-60'
              when p_as_of - x.due_date <= 90 then '61-90' else '90+' end,
         case when x.is_msme then x.msme_due end,
         x.is_msme and p_as_of > x.msme_due
    from x where x.net_payable - x.paid > 0
   order by x.due_date, x.supplier_name
$$;

create or replace function tds_position(p_period text, p_section text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'deducted', coalesce((select sum(tds_amount) from purchase_bills where status = 'approved' and tds_amount > 0 and tds_section = p_section
                           and to_char(bill_date, 'YYYY-MM') = p_period), 0)
              - coalesce((select sum(tds_adj) from supplier_credit_notes where status = 'approved' and tds_period = p_period and tds_section = p_section), 0),
    'paid',     coalesce((select sum(tax) from tds_challans where status = 'approved' and period = p_period and section = p_section), 0),
    'pending',  coalesce((select sum(tax) from tds_challans where status = 'pending'  and period = p_period and section = p_section), 0))
$$;

create or replace function tds_register(p_fy_start date) returns table (
  period text, section text, deducted numeric, bills int, paid numeric, pending numeric, to_pay numeric, due_date date, status text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare v_from date := pur_fy_start(p_fy_start); v_to date;
begin
  if not has_accounting_view() then raise exception 'Not authorized'; end if;
  v_to := (v_from + interval '1 year - 1 day')::date;
  return query
  with d as (
    select to_char(b.bill_date, 'YYYY-MM') as per, b.tds_section as sec, sum(b.tds_amount) as ded, count(*)::int as n
      from purchase_bills b where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between v_from and v_to group by 1, 2),
  a as (
    select n.tds_period as per, n.tds_section as sec, sum(n.tds_adj) as adj from supplier_credit_notes n
     where n.status = 'approved' and n.tds_period between to_char(v_from, 'YYYY-MM') and to_char(v_to, 'YYYY-MM') group by 1, 2),
  c as (
    select k.period as per, k.section as sec,
           coalesce(sum(k.tax) filter (where k.status = 'approved'), 0) as pd, coalesce(sum(k.tax) filter (where k.status = 'pending'), 0) as pn
      from tds_challans k where k.period between to_char(v_from, 'YYYY-MM') and to_char(v_to, 'YYYY-MM') group by 1, 2)
  select d.per, d.sec, (d.ded - coalesce(a.adj, 0)), d.n, coalesce(c.pd, 0), coalesce(c.pn, 0), greatest((d.ded - coalesce(a.adj, 0)) - coalesce(c.pd, 0) - coalesce(c.pn, 0), 0), tds_due_date(d.per),
         case when coalesce(c.pd, 0) > (d.ded - coalesce(a.adj, 0)) then 'excess'
              when (d.ded - coalesce(a.adj, 0)) - coalesce(c.pd, 0) <= 0 then 'paid'
              when (d.ded - coalesce(a.adj, 0)) - coalesce(c.pd, 0) - coalesce(c.pn, 0) <= 0 then 'awaiting_approval'
              when tds_due_date(d.per) < current_date then 'overdue'
              else 'due' end
    from d left join a on a.per = d.per and a.sec = d.sec left join c on c.per = d.per and c.sec = d.sec
   order by d.per, d.sec;
end $$;

create or replace function gstr3b_workings(p_month text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_from date; v_to date; o jsonb; i jsonb; inter jsonb; adj jsonb; v_lump numeric; v_tcs numeric; nt jsonb;
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  if p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Choose a month'; end if;
  v_from := (p_month || '-01')::date; v_to := (v_from + interval '1 month - 1 day')::date;

  with x as (
    select s.rate, s.taxable, s.igst, s.cgst, s.sgst from gst_sales_rows(v_from, v_to) s
    union all
    select c.rate, -c.taxable, -c.igst, -c.cgst, -c.sgst from gst_cn_rows(v_from, v_to) c
  )
  select jsonb_build_object(
    'taxable',  coalesce(sum(taxable) filter (where rate > 0), 0), 'igst', coalesce(sum(igst) filter (where rate > 0), 0),
    'cgst', coalesce(sum(cgst) filter (where rate > 0), 0), 'sgst', coalesce(sum(sgst) filter (where rate > 0), 0),
    'nil_taxable', coalesce(sum(taxable) filter (where rate = 0), 0))
    into o from x;

  -- 3.2: inter-state supplies to unregistered buyers, by place of supply
  select coalesce(jsonb_agg(jsonb_build_object('pos', pos_code, 'taxable', taxable, 'igst', igst) order by pos_code), '[]'::jsonb) into inter from (
    select y.pos_code, sum(y.taxable) as taxable, sum(y.igst) as igst from (
      select s.pos_code, s.taxable, s.igst from gst_sales_rows(v_from, v_to) s where s.is_inter and s.section <> 'B2B' and s.rate > 0
      union all
      select c.pos_code, -c.taxable, -c.igst from gst_cn_rows(v_from, v_to) c where c.is_inter and c.rate > 0 and c.section in ('B2CS', 'CDNUR')
    ) y group by y.pos_code having sum(y.taxable) <> 0 or sum(y.igst) <> 0) z;

  -- ITC from purchase bills booked in the month and claimed
  select jsonb_build_object(
    'igst', coalesce(sum(b.igst) filter (where b.itc_eligible), 0), 'cgst', coalesce(sum(b.cgst) filter (where b.itc_eligible), 0), 'sgst', coalesce(sum(b.sgst) filter (where b.itc_eligible), 0),
    'ineligible', coalesce(sum(b.igst + b.cgst + b.sgst) filter (where not b.itc_eligible), 0), 'bills', count(*))
    into i from purchase_bills b where b.status = 'approved' and b.bill_date between v_from and v_to;

  select jsonb_build_object(
    'other_igst', coalesce(sum(a.igst) filter (where a.kind = 'other_itc'), 0), 'other_cgst', coalesce(sum(a.cgst) filter (where a.kind = 'other_itc'), 0), 'other_sgst', coalesce(sum(a.sgst) filter (where a.kind = 'other_itc'), 0),
    'rev_igst', coalesce(sum(a.igst) filter (where a.kind = 'reversal'), 0), 'rev_cgst', coalesce(sum(a.cgst) filter (where a.kind = 'reversal'), 0), 'rev_sgst', coalesce(sum(a.sgst) filter (where a.kind = 'reversal'), 0))
    into adj from gst_itc_adjustments a where a.period = p_month and not a.voided;

  -- credit reversed on supplier credit notes dated in the month (only where credit was claimed on the original bill)
  select jsonb_build_object('igst', coalesce(sum(n.igst), 0), 'cgst', coalesce(sum(n.cgst), 0), 'sgst', coalesce(sum(n.sgst), 0), 'notes', count(*))
    into nt from supplier_credit_notes n where n.status = 'approved' and n.itc_reversal and n.note_date between v_from and v_to;

  -- reference only: what the books carry on the single ITC ledger (marketplace fees) and the TCS credit, for the month
  select coalesce(sum(vl.debit - vl.credit), 0) into v_lump from voucher_lines vl join vouchers v on v.voucher_id = vl.voucher_id join ledgers l on l.ledger_id = vl.ledger_id
   where l.name = 'GST Input Tax Credit (ITC)' and v.status = 'posted' and v.voucher_date between v_from and v_to;
  select coalesce(sum(vl.debit - vl.credit), 0) into v_tcs from voucher_lines vl join vouchers v on v.voucher_id = vl.voucher_id join ledgers l on l.ledger_id = vl.ledger_id
   where l.name = 'GST TCS Credit Receivable' and v.status = 'posted' and v.voucher_date between v_from and v_to;

  return jsonb_build_object('month', p_month, 'from', v_from, 'to', v_to, 'outward', o, 'inter_unreg', inter, 'itc_bills', i, 'itc_adj', adj, 'itc_notes', nt,
                            'books_marketplace_itc', v_lump, 'books_tcs_credit', v_tcs);
end $$;

create or replace function gstr2b_recon(p_period text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_up record; v_from date; v_to date; v_lines jsonb; v_books jsonb; v_sum jsonb; v_m jsonb;
begin
  if not has_gst_view() then raise exception 'Not authorized'; end if;
  if p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Choose a month'; end if;
  v_from := (p_period || '-01')::date; v_to := (v_from + interval '1 month - 1 day')::date;
  select * into v_up from gstr2b_uploads where period = p_period and not replaced order by uploaded_at desc limit 1;
  if not found then return jsonb_build_object('period', p_period, 'upload', null); end if;

  select coalesce(jsonb_agg(jsonb_build_object('line_id', q.line_id, 'bill_id', q.bill_id, 'note_id', q.note_id, 'status', q.status)), '[]'::jsonb) into v_m from (
  select l.line_id, b.bill_id, n.note_id,
    case
      when l.resolution = 'ignored'  then 'ignored'
      when l.doc_type = 'debit_note' then 'note'
      when l.doc_type = 'credit_note' then
        case when n.note_id is null then (case when l.resolution = 'accepted' then 'accepted' else 'not_in_books' end)
             when abs(n.taxable_value - l.taxable) <= 1 and abs(n.igst - l.igst) <= 1 and abs(n.cgst - l.cgst) <= 1 and abs(n.sgst - l.sgst) <= 1 then 'matched'
             when l.resolution = 'accepted' then 'accepted'
             else 'mismatch' end
      when l.reverse_charge          then 'rcm'
      when b.bill_id is null         then case when l.resolution = 'accepted' then 'accepted' else 'not_in_books' end
      when b.status = 'pending'      then 'bill_pending'
      when not l.itc_available and b.itc_eligible then 'blocked_in_2b'
      when abs(b.taxable_value - l.taxable) <= 1 and abs(b.igst - l.igst) <= 1 and abs(b.cgst - l.cgst) <= 1 and abs(b.sgst - l.sgst) <= 1 then 'matched'
      when l.resolution = 'accepted' then 'accepted'
      else 'mismatch' end as status
  from gstr2b_lines l
  left join lateral (
    select pb.* from purchase_bills pb join suppliers s on s.supplier_id = pb.supplier_id
     where s.gstin = l.supplier_gstin and gst_norm_doc(pb.supplier_invoice_no) = gst_norm_doc(l.doc_no) and pb.status in ('approved', 'pending')
     order by (pb.status = 'approved') desc limit 1) b on true
  left join lateral (
    select sn.* from supplier_credit_notes sn join suppliers s2 on s2.supplier_id = sn.supplier_id
     where l.doc_type = 'credit_note' and sn.status = 'approved' and s2.gstin = l.supplier_gstin and gst_norm_doc(sn.supplier_note_no) = gst_norm_doc(l.doc_no) limit 1) n on true
  where l.upload_id = v_up.upload_id) q;

  select coalesce(jsonb_agg(jsonb_build_object(
      'line_id', l.line_id, 'gstin', l.supplier_gstin, 'name', l.supplier_name, 'type', l.doc_type, 'doc_no', l.doc_no, 'doc_date', l.doc_date,
      'taxable', l.taxable, 'igst', l.igst, 'cgst', l.cgst, 'sgst', l.sgst, 'itc_available', l.itc_available, 'reverse_charge', l.reverse_charge,
      'status', x.status, 'resolution', l.resolution, 'resolution_note', l.resolution_note,
      'bill_id', b.bill_id, 'note_id', sn.note_id, 'bill_no', coalesce(b.bill_no, sn.note_no), 'bill_status', coalesce(b.status, sn.status), 'bill_taxable', coalesce(b.taxable_value, sn.taxable_value),
      'bill_igst', coalesce(b.igst, sn.igst), 'bill_cgst', coalesce(b.cgst, sn.cgst), 'bill_sgst', coalesce(b.sgst, sn.sgst),
      'bill_itc_eligible', b.itc_eligible)
    order by case x.status when 'mismatch' then 1 when 'not_in_books' then 2 when 'blocked_in_2b' then 3 when 'bill_pending' then 4 when 'rcm' then 5 when 'note' then 6 else 7 end,
             l.supplier_gstin, l.doc_no), '[]'::jsonb)
    into v_lines
  from gstr2b_lines l join jsonb_to_recordset(v_m) x(line_id uuid, bill_id uuid, note_id uuid, status text) using (line_id) left join purchase_bills b on b.bill_id = x.bill_id
  left join supplier_credit_notes sn on sn.note_id = x.note_id
  where l.upload_id = v_up.upload_id;

  -- bills booked this month with credit claimed, whose supplier is registered, that are not in this month's file
  select coalesce(jsonb_agg(jsonb_build_object('bill_id', b.bill_id, 'bill_no', b.bill_no, 'supplier', s.name, 'gstin', s.gstin,
      'invoice_no', b.supplier_invoice_no, 'invoice_date', b.supplier_invoice_date, 'taxable', b.taxable_value,
      'igst', b.igst, 'cgst', b.cgst, 'sgst', b.sgst) order by s.name, b.supplier_invoice_date), '[]'::jsonb)
    into v_books
  from purchase_bills b join suppliers s using (supplier_id)
  where b.status = 'approved' and b.itc_eligible and b.bill_date between v_from and v_to and s.gstin is not null and (b.igst + b.cgst + b.sgst) > 0
    and not exists (select 1 from jsonb_to_recordset(v_m) x(line_id uuid, bill_id uuid, status text) where x.bill_id = b.bill_id);

  select jsonb_build_object(
    'by_status', coalesce((select jsonb_object_agg(status, n) from (select x.status, count(*) n from jsonb_to_recordset(v_m) x(line_id uuid, bill_id uuid, status text) group by x.status) q), '{}'::jsonb),
    'in_2b', (select jsonb_build_object('igst', coalesce(sum(l.igst), 0), 'cgst', coalesce(sum(l.cgst), 0), 'sgst', coalesce(sum(l.sgst), 0))
                from gstr2b_lines l where l.upload_id = v_up.upload_id and l.doc_type = 'invoice' and l.itc_available and not l.reverse_charge),
    'not_in_books', (select jsonb_build_object('igst', coalesce(sum(l.igst), 0), 'cgst', coalesce(sum(l.cgst), 0), 'sgst', coalesce(sum(l.sgst), 0))
                from gstr2b_lines l join jsonb_to_recordset(v_m) x(line_id uuid, bill_id uuid, status text) using (line_id) where x.status = 'not_in_books' and l.doc_type = 'invoice'),
    'books_only', (select jsonb_build_object('igst', coalesce(sum((e ->> 'igst')::numeric), 0), 'cgst', coalesce(sum((e ->> 'cgst')::numeric), 0),
                'sgst', coalesce(sum((e ->> 'sgst')::numeric), 0)) from jsonb_array_elements(v_books) e),
    'notes', (select jsonb_build_object('credit_notes', coalesce(sum(case when l.doc_type = 'credit_note' then l.igst + l.cgst + l.sgst end), 0),
                'debit_notes', coalesce(sum(case when l.doc_type = 'debit_note' then l.igst + l.cgst + l.sgst end), 0))
                from gstr2b_lines l where l.upload_id = v_up.upload_id and l.doc_type <> 'invoice')
  ) into v_sum;

  return jsonb_build_object('period', p_period,
    'upload', jsonb_build_object('upload_id', v_up.upload_id, 'file_name', v_up.file_name, 'row_count', v_up.row_count, 'uploaded_at', v_up.uploaded_at),
    'lines', v_lines, 'books_only', v_books, 'summary', v_sum);
end $$;

-- ---------------------------------------------------------------- proofs on supplier credit notes
alter table attachments drop constraint if exists attachments_entity_type_check;
alter table attachments add constraint attachments_entity_type_check check (entity_type in
  ('voucher', 'cash_settlement_report', 'bank_transaction', 'cod_collection', 'settlement', 'claim', 'return', 'rto', 'tax_transaction',
   'supplier_bill', 'supplier_payment', 'expense_claim', 'tds_challan', 'supplier_credit_note'));

create or replace function attachment_parent_visible(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select case p_type
    when 'voucher'                then exists (select 1 from vouchers where voucher_id = p_id)
    when 'cash_settlement_report'  then exists (select 1 from cash_settlement_reports where report_id = p_id)
    when 'bank_transaction'        then exists (select 1 from bank_transactions where bank_txn_id = p_id)
    when 'cod_collection'          then exists (select 1 from cod_collections where cod_id = p_id)
    when 'settlement'              then exists (select 1 from settlements where settlement_id = p_id)
    when 'claim'                   then exists (select 1 from claims where claim_id = p_id)
    when 'return'                  then exists (select 1 from returns where return_id = p_id)
    when 'rto'                     then exists (select 1 from rtos where rto_id = p_id)
    when 'tax_transaction'         then exists (select 1 from tax_transactions where tax_txn_id = p_id)
    when 'supplier_bill'           then exists (select 1 from purchase_bills where bill_id = p_id)
    when 'supplier_payment'        then exists (select 1 from supplier_payments where payment_id = p_id)
    when 'expense_claim'           then exists (select 1 from expense_claims where claim_id = p_id)
    when 'tds_challan'            then exists (select 1 from tds_challans where challan_id = p_id)
    when 'supplier_credit_note'   then exists (select 1 from supplier_credit_notes where note_id = p_id)
    else false end
$$;

create or replace function can_attach(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select (case p_type
    when 'voucher'                then has_accounting_write()
    when 'cash_settlement_report'  then has_bankcod_write()
    when 'bank_transaction'        then has_bankcod_write()
    when 'cod_collection'          then has_bankcod_write()
    when 'settlement'              then has_settlements_reconcile()
    when 'claim'                   then has_claims_create() or has_claims_manage()
    when 'return'                  then has_returns_write()
    when 'rto'                     then has_returns_write()
    when 'tax_transaction'         then has_tax_write()
    when 'supplier_bill'           then has_accounting_write()
    when 'supplier_payment'        then has_accounting_write()
    when 'expense_claim'           then is_active_user() and (p_id is null
                                        or exists (select 1 from expense_claims c where c.claim_id = p_id and c.claimant_id = auth.uid() and c.status = 'draft')
                                        or has_accounting_write())
    when 'tds_challan'            then has_accounting_write()
    when 'supplier_credit_note'   then has_accounting_write()
    else false end)
  and (p_id is null or attachment_parent_visible(p_type, p_id))
$$;

create or replace function can_view_attachment(p_type text, p_id uuid) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select p_id is not null and (case p_type
    when 'voucher'                then has_accounting_view()
    when 'cash_settlement_report'  then has_bankcod_view()
    when 'bank_transaction'        then has_bankcod_view()
    when 'cod_collection'          then has_bankcod_view()
    when 'settlement'              then has_settlements_view()
    when 'claim'                   then has_claims_view()
    when 'return'                  then has_returns_view()
    when 'rto'                     then has_returns_view()
    when 'tax_transaction'         then has_tax_view()
    when 'supplier_bill'           then has_accounting_view()
    when 'supplier_payment'        then has_accounting_view()
    when 'expense_claim'           then true      -- the claim's own row-level security decides who can see it
    when 'tds_challan'            then has_accounting_view()
    when 'supplier_credit_note'   then has_accounting_view()
    else false end)
  and attachment_parent_visible(p_type, p_id)
$$;


revoke execute on function create_supplier_credit_note(uuid, text, date, text, jsonb, text), approve_supplier_credit_note(uuid), reject_supplier_credit_note(uuid, text),
  cancel_supplier_credit_note(uuid, text), cancel_purchase_bill(uuid, text), bill_outstanding(uuid, date, boolean), supplier_ageing(date), tds_position(text, text), tds_register(date),
  gstr3b_workings(text), gstr2b_recon(text) from public, anon, authenticated;
grant execute on function create_supplier_credit_note(uuid, text, date, text, jsonb, text), approve_supplier_credit_note(uuid), reject_supplier_credit_note(uuid, text),
  cancel_supplier_credit_note(uuid, text), cancel_purchase_bill(uuid, text), bill_outstanding(uuid, date, boolean), supplier_ageing(date), tds_register(date),
  gstr3b_workings(text), gstr2b_recon(text) to authenticated;
