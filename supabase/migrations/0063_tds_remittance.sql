-- 0063: TDS remittance (paying the tax you deducted from suppliers to the government) and the deduction register.
--
-- TDS is deducted when a purchase bill is approved (0059) and sits in the "TDS Payable" ledger. This migration adds:
--   * a register by month and section: deducted, deposited, waiting for approval, still to pay, due date and status
--   * challans: each deposit is recorded with its BSR code, challan serial number and date (together the CIN), the bank used, and the proof
--   * the same maker-checker as supplier payments: one person records the challan, another approves it, and only then is it posted
--     (Dr TDS Payable, Dr TDS Interest, Dr TDS Late Fee, Cr Bank). A posted challan is undone only by a reversal voucher.
--   * deductions listing by date range with supplier, PAN, base, rate and challan numbers: the working papers for the quarterly return (26Q)
-- Interest and late fee are entered by hand from what the portal or your CA shows; they are not worked out here.
-- Due dates (7th of the next month, 30 April for March) are working rules to confirm with your CA.

insert into ledgers (account_group_id, name, nature, opening_balance, opening_balance_type, gst_applicable, reconciliation_required, status)
select (select account_group_id from account_groups where name = 'Expenses' limit 1), v.name, 'expense', 0, 'debit', false, false, 'active'
from (values ('TDS Interest'), ('TDS Late Fee')) as v(name)
where not exists (select 1 from ledgers l where l.name = v.name);

create sequence if not exists tds_challan_seq;

create table if not exists tds_challans (
  challan_id          uuid primary key default gen_random_uuid(),
  challan_no          text not null unique,
  period              text not null check (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),   -- the month the tax was deducted
  section             text not null references tds_sections(section),
  tax                 numeric(14,2) not null check (tax > 0),
  interest            numeric(14,2) not null default 0 check (interest >= 0),
  late_fee            numeric(14,2) not null default 0 check (late_fee >= 0),
  total               numeric(14,2) generated always as (tax + interest + late_fee) stored,
  deposit_date        date not null,
  bank_account_id     uuid not null references bank_accounts(bank_account_id),
  bsr_code            text not null check (bsr_code ~ '^[0-9]{7}$'),
  challan_serial      text not null check (challan_serial ~ '^[0-9]{5}$'),
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
-- the same bank challan (BSR code + serial + date) cannot be entered twice
create unique index if not exists tds_challans_cin_uq on tds_challans (bsr_code, challan_serial, deposit_date) where status in ('pending', 'approved');
create index if not exists tds_challans_period on tds_challans (period, section);

alter table tds_challans enable row level security;
drop policy if exists "tdsc read" on tds_challans;
create policy "tdsc read" on tds_challans for select to authenticated using (has_accounting_view());
grant select on tds_challans to authenticated;

-- ---------------------------------------------------------------- due date
create or replace function tds_due_date(p_period text) returns date
language sql immutable as $$
  select case when right(p_period, 2) = '03' then make_date(left(p_period, 4)::int, 4, 30)
              else ((p_period || '-01')::date + interval '1 month' + interval '6 days')::date end
$$;

-- ---------------------------------------------------------------- amounts for one month and section
create or replace function tds_position(p_period text, p_section text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'deducted', coalesce((select sum(tds_amount) from purchase_bills where status = 'approved' and tds_amount > 0 and tds_section = p_section
                           and to_char(bill_date, 'YYYY-MM') = p_period), 0),
    'paid',     coalesce((select sum(tax) from tds_challans where status = 'approved' and period = p_period and section = p_section), 0),
    'pending',  coalesce((select sum(tax) from tds_challans where status = 'pending'  and period = p_period and section = p_section), 0))
$$;

-- ---------------------------------------------------------------- register for a financial year (p_fy_start = 1 April)
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
  c as (
    select k.period as per, k.section as sec,
           coalesce(sum(k.tax) filter (where k.status = 'approved'), 0) as pd, coalesce(sum(k.tax) filter (where k.status = 'pending'), 0) as pn
      from tds_challans k where k.period between to_char(v_from, 'YYYY-MM') and to_char(v_to, 'YYYY-MM') group by 1, 2)
  select d.per, d.sec, d.ded, d.n, coalesce(c.pd, 0), coalesce(c.pn, 0), greatest(d.ded - coalesce(c.pd, 0) - coalesce(c.pn, 0), 0), tds_due_date(d.per),
         case when coalesce(c.pd, 0) > d.ded then 'excess'
              when d.ded - coalesce(c.pd, 0) <= 0 then 'paid'
              when d.ded - coalesce(c.pd, 0) - coalesce(c.pn, 0) <= 0 then 'awaiting_approval'
              when tds_due_date(d.per) < current_date then 'overdue'
              else 'due' end
    from d left join c on c.per = d.per and c.sec = d.sec
   order by d.per, d.sec;
end $$;

-- ---------------------------------------------------------------- record, approve, reject, cancel a challan
create or replace function create_tds_challan(p_period text, p_section text, p_tax numeric, p_interest numeric, p_late_fee numeric,
                                              p_date date, p_bank uuid, p_bsr text, p_serial text, p_notes text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_pos jsonb; v_left numeric; v_id uuid;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can record a TDS challan'; end if;
  if p_period is null or p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Choose the month the tax was deducted'; end if;
  if not exists (select 1 from tds_sections where section = p_section) then raise exception 'Choose the TDS section'; end if;
  if p_tax is null or p_tax <= 0 then raise exception 'Enter the tax deposited'; end if;
  if coalesce(p_interest, 0) < 0 or coalesce(p_late_fee, 0) < 0 then raise exception 'Interest and late fee cannot be negative'; end if;
  if p_date is null or p_date > current_date then raise exception 'The deposit date cannot be empty or in the future'; end if;
  if p_bank is null or not exists (select 1 from bank_accounts where bank_account_id = p_bank) then raise exception 'Choose the bank account the tax was paid from'; end if;
  if p_bsr is null or btrim(p_bsr) !~ '^[0-9]{7}$' then raise exception 'The BSR code is 7 digits'; end if;
  if p_serial is null or btrim(p_serial) !~ '^[0-9]{5}$' then raise exception 'The challan serial number is 5 digits'; end if;
  v_pos := tds_position(p_period, p_section);
  v_left := (v_pos ->> 'deducted')::numeric - (v_pos ->> 'paid')::numeric - (v_pos ->> 'pending')::numeric;
  if round(p_tax, 2) > v_left then
    raise exception 'Only % of TDS under % is left to deposit for % (deducted % less deposited and waiting for approval)', v_left, p_section, p_period, (v_pos ->> 'deducted');
  end if;
  begin
    insert into tds_challans (challan_no, period, section, tax, interest, late_fee, deposit_date, bank_account_id, bsr_code, challan_serial, notes)
    values ('TDS-' || to_char(p_date, 'YYMM') || '-' || lpad(nextval('tds_challan_seq')::text, 5, '0'), p_period, p_section, round(p_tax, 2),
            round(coalesce(p_interest, 0), 2), round(coalesce(p_late_fee, 0), 2), p_date, p_bank, btrim(p_bsr), btrim(p_serial), nullif(btrim(coalesce(p_notes, '')), ''))
    returning challan_id into v_id;
  exception when unique_violation then raise exception 'A challan with this BSR code, serial number and date is already recorded';
  end;
  return v_id;
end $$;

create or replace function approve_tds_challan(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c tds_challans%rowtype; v_pos jsonb; v_left numeric; v_tds uuid; v_int uuid; v_fee uuid; v_bank uuid; v_lines jsonb; v_res jsonb;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve a TDS challan'; end if;
  select * into c from tds_challans where challan_id = p_id for update;
  if not found then raise exception 'Challan not found'; end if;
  if c.status <> 'pending' then raise exception 'This challan is already %', c.status; end if;
  if not pur_self_ok(c.created_by) then raise exception 'A different person must approve this challan (you entered it)'; end if;
  v_pos := tds_position(c.period, c.section);
  v_left := (v_pos ->> 'deducted')::numeric - (v_pos ->> 'paid')::numeric;
  if c.tax > v_left then raise exception 'The TDS deducted for % under % is now only % more than already deposited. Check the bills.', c.period, c.section, v_left; end if;
  select ledger_id into v_tds from ledgers where name = 'TDS Payable';
  select ledger_id into v_int from ledgers where name = 'TDS Interest';
  select ledger_id into v_fee from ledgers where name = 'TDS Late Fee';
  select ledger_id into v_bank from bank_accounts where bank_account_id = c.bank_account_id;
  if v_tds is null or v_int is null or v_fee is null or v_bank is null then raise exception 'The TDS or bank ledger is missing'; end if;
  v_lines := jsonb_build_array(jsonb_build_object('ledger_id', v_tds, 'debit', c.tax, 'credit', 0, 'narration', 'TDS ' || c.section || ' ' || c.period));
  if c.interest > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', v_int, 'debit', c.interest, 'credit', 0, 'narration', 'Interest on late TDS'); end if;
  if c.late_fee > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', v_fee, 'debit', c.late_fee, 'credit', 0, 'narration', 'Late fee on TDS return'); end if;
  v_lines := v_lines || jsonb_build_object('ledger_id', v_bank, 'debit', 0, 'credit', c.total, 'narration', 'BSR ' || c.bsr_code || ' / ' || c.challan_serial);
  v_res := acc_post_journal(c.deposit_date, 'TDS deposited ' || c.challan_no || ' (' || c.section || ', ' || c.period || ') BSR ' || c.bsr_code || ' serial ' || c.challan_serial,
                            v_lines, 'tds_challan', c.challan_id, 'posted', auth.uid());
  update tds_challans set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, decided_by = auth.uid(), decided_at = now() where challan_id = p_id;
  return v_res;
end $$;

create or replace function reject_tds_challan(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can reject a TDS challan'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  update tds_challans set status = 'rejected', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where challan_id = p_id and status = 'pending';
  if not found then raise exception 'Only a pending challan can be rejected'; end if;
end $$;

create or replace function cancel_tds_challan(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c tds_challans%rowtype; v_rev uuid;
begin
  select * into c from tds_challans where challan_id = p_id for update;
  if not found then raise exception 'Challan not found'; end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then raise exception 'Give a reason'; end if;
  if c.status = 'pending' then
    if not (c.created_by = auth.uid() or has_purchase_approve()) then raise exception 'Only the person who entered it, or an approver, can withdraw this challan'; end if;
    update tds_challans set status = 'cancelled', decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where challan_id = p_id;
  elsif c.status = 'approved' then
    if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can cancel an approved challan'; end if;
    v_rev := br_reverse_voucher(c.voucher_id, 'TDS challan ' || c.challan_no || ' cancelled: ' || btrim(p_reason));
    update tds_challans set status = 'cancelled', reversal_voucher_id = v_rev, decision_note = btrim(p_reason), decided_by = auth.uid(), decided_at = now() where challan_id = p_id;
  else raise exception 'This challan is already %', c.status; end if;
end $$;

-- ---------------------------------------------------------------- deductions listing (working papers for the quarterly return)
create or replace function tds_deductions(p_from date, p_to date) returns table (
  bill_id uuid, bill_no text, bill_date date, supplier text, pan text, gstin text, section text, base numeric, rate numeric, tds numeric,
  invoice_no text, challans text, no_pan boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  if not has_accounting_view() then raise exception 'Not authorized'; end if;
  return query
  select b.bill_id, b.bill_no, b.bill_date, s.name, s.pan, s.gstin, b.tds_section, b.tds_base, b.tds_rate, b.tds_amount, b.supplier_invoice_no,
         (select string_agg(k.bsr_code || '/' || k.challan_serial || ' ' || to_char(k.deposit_date, 'DD-MM-YYYY'), '; ' order by k.deposit_date)
            from tds_challans k where k.status = 'approved' and k.period = to_char(b.bill_date, 'YYYY-MM') and k.section = b.tds_section),
         s.pan is null
    from purchase_bills b join suppliers s on s.supplier_id = b.supplier_id
   where b.status = 'approved' and b.tds_amount > 0 and b.bill_date between p_from and p_to
   order by b.bill_date, b.bill_no;
end $$;

-- ---------------------------------------------------------------- proofs on challans
alter table attachments drop constraint if exists attachments_entity_type_check;
alter table attachments add constraint attachments_entity_type_check check (entity_type in
  ('voucher', 'cash_settlement_report', 'bank_transaction', 'cod_collection', 'settlement', 'claim', 'return', 'rto', 'tax_transaction',
   'supplier_bill', 'supplier_payment', 'expense_claim', 'tds_challan'));

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
    else false end)
  and attachment_parent_visible(p_type, p_id)
$$;

-- ---------------------------------------------------------------- grants
revoke execute on function tds_due_date(text), tds_position(text, text), tds_register(date), create_tds_challan(text, text, numeric, numeric, numeric, date, uuid, text, text, text),
  approve_tds_challan(uuid), reject_tds_challan(uuid, text), cancel_tds_challan(uuid, text), tds_deductions(date, date) from public, anon, authenticated;
grant execute on function tds_due_date(text), tds_register(date), create_tds_challan(text, text, numeric, numeric, numeric, date, uuid, text, text, text),
  approve_tds_challan(uuid), reject_tds_challan(uuid, text), cancel_tds_challan(uuid, text), tds_deductions(date, date) to authenticated;
