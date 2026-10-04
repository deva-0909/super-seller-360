-- 0064: Supplier opening balances.
--
-- What you already owed suppliers on the day you started using the app is entered bill by bill (so ageing, payments and the MSME watch
-- work on them like any other bill). An opening bill has no GST and no TDS (those were dealt with in the period it was first booked) and is
-- posted as Dr Opening Balance Equity, Cr Sundry Creditors on the "balances as on" date. It follows the usual maker-checker: one person
-- enters, a Super Admin or Finance Manager approves, and only then is it posted. Cancelling an approved opening bill posts a reversal.
-- Amounts you paid in advance to a supplier (a debit balance) are not covered here.

alter table purchase_bills add column if not exists is_opening boolean not null default false;
create sequence if not exists opening_bill_seq;

create or replace function create_opening_bills(p_as_of date, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; s suppliers%rowtype; v_amt numeric; v_inv date; v_due date; v_no text; v_n int := 0; v_total numeric := 0; v_invno text;
begin
  if not has_accounting_write() then raise exception 'Only a user with accounting write access can enter opening balances'; end if;
  if p_as_of is null or p_as_of > current_date then raise exception 'Choose the date the balances are as on (not in the future)'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Add at least one bill'; end if;
  if jsonb_array_length(p_rows) > 1000 then raise exception 'Too many rows at once (limit 1,000)'; end if;
  for r in select e.value as j, e.ordinality as ord from jsonb_array_elements(p_rows) with ordinality e loop
    select * into s from suppliers where supplier_id = nullif(r.j ->> 'supplier_id', '')::uuid;
    if not found then raise exception 'Row %: choose the supplier', r.ord; end if;
    if s.status = 'blocked' then raise exception 'Row %: % is blocked', r.ord, s.name; end if;
    v_invno := btrim(coalesce(r.j ->> 'invoice_no', ''));
    if v_invno = '' then raise exception 'Row %: enter the supplier invoice number', r.ord; end if;
    v_amt := round(coalesce(nullif(r.j ->> 'amount', '')::numeric, 0), 2);
    if v_amt <= 0 then raise exception 'Row %: enter the amount still owed', r.ord; end if;
    v_inv := nullif(r.j ->> 'invoice_date', '')::date;
    if v_inv is null or v_inv > p_as_of then raise exception 'Row %: the invoice date must be on or before %', r.ord, p_as_of; end if;
    v_due := coalesce(nullif(r.j ->> 'due_date', '')::date, v_inv + s.payment_terms_days);
    if v_due < v_inv then raise exception 'Row %: the due date is before the invoice date', r.ord; end if;
    v_no := 'OB-' || lpad(nextval('opening_bill_seq')::text, 6, '0');
    begin
      insert into purchase_bills (bill_no, supplier_id, supplier_invoice_no, supplier_invoice_date, bill_date, due_date, is_intra_state, itc_eligible, itc_reason,
                                  taxable_value, cgst, sgst, igst, total, net_payable, notes, is_opening)
      values (v_no, s.supplier_id, v_invno, v_inv, p_as_of, v_due, true, false, 'Opening balance (tax dealt with when first booked)',
              v_amt, 0, 0, 0, v_amt, v_amt, nullif(btrim(coalesce(r.j ->> 'note', '')), ''), true);
    exception when unique_violation then raise exception 'Row %: invoice % of % is already entered', r.ord, v_invno, s.name;
    end;
    v_n := v_n + 1; v_total := v_total + v_amt;
  end loop;
  return jsonb_build_object('bills', v_n, 'total', v_total);
end $$;

create or replace function approve_opening_bill(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare b purchase_bills%rowtype; s suppliers%rowtype; l_cr uuid; l_ob uuid; v_res jsonb;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve an opening balance'; end if;
  select * into b from purchase_bills where bill_id = p_id for update;
  if not found or not b.is_opening then raise exception 'Opening bill not found'; end if;
  if b.status <> 'pending' then raise exception 'This bill is already %', b.status; end if;
  if not pur_self_ok(b.created_by) then raise exception 'A different person must approve this bill (you entered it)'; end if;
  select * into s from suppliers where supplier_id = b.supplier_id;
  if s.status <> 'active' then raise exception 'The supplier is %, so the bill cannot be approved', s.status; end if;
  select ledger_id into l_cr from ledgers where name = 'Sundry Creditors';
  select ledger_id into l_ob from ledgers where name = 'Opening Balance Equity';
  if l_cr is null or l_ob is null then raise exception 'The Sundry Creditors or Opening Balance Equity ledger is missing'; end if;
  v_res := acc_post_journal(b.bill_date, 'Opening balance: ' || s.name || ' invoice ' || b.supplier_invoice_no,
            jsonb_build_array(jsonb_build_object('ledger_id', l_ob, 'debit', b.total, 'credit', 0, 'narration', 'Opening balance'),
                              jsonb_build_object('ledger_id', l_cr, 'debit', 0, 'credit', b.total, 'narration', s.name || ' ' || b.supplier_invoice_no)),
            'purchase_bill', b.bill_id, 'posted', auth.uid());
  update purchase_bills set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, decided_by = auth.uid(), decided_at = now() where bill_id = p_id;
  return v_res || jsonb_build_object('tds', 0, 'net_payable', b.total);
end $$;

-- approving an opening bill from the ordinary bill screen goes through the opening-balance posting
create or replace function approve_purchase_bill(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b purchase_bills%rowtype; s suppliers%rowtype; t jsonb; v_lines jsonb := '[]'::jsonb; r record; v_res jsonb; v_cr numeric; v_tds numeric;
  l_creditors uuid; l_tds uuid; l_cgst uuid; l_sgst uuid; l_igst uuid;
begin
  if not has_purchase_approve() then raise exception 'Only a Super Admin or Finance Manager can approve a purchase bill'; end if;
  select * into b from purchase_bills where bill_id = p_id for update;
  if not found then raise exception 'Bill not found'; end if;
  if b.status <> 'pending' then raise exception 'This bill is already %', b.status; end if;
  if b.is_opening then return approve_opening_bill(p_id); end if;
  if not pur_self_ok(b.created_by) then raise exception 'A different person must approve this bill (you entered it)'; end if;
  select * into s from suppliers where supplier_id = b.supplier_id;
  if s.status <> 'active' then raise exception 'The supplier is %, so the bill cannot be approved', s.status; end if;
  select ledger_id into l_creditors from ledgers where name = 'Sundry Creditors';
  select ledger_id into l_tds from ledgers where name = 'TDS Payable';
  select ledger_id into l_cgst from ledgers where name = 'Input CGST';
  select ledger_id into l_sgst from ledgers where name = 'Input SGST';
  select ledger_id into l_igst from ledgers where name = 'Input IGST';
  if l_creditors is null or l_tds is null or l_cgst is null or l_sgst is null or l_igst is null then raise exception 'Purchase ledgers are missing (Sundry Creditors, TDS Payable, Input CGST/SGST/IGST)'; end if;

  t := pb_tds(b.supplier_id, b.bill_date, b.taxable_value, b.bill_id);
  v_tds := (t ->> 'amount')::numeric;
  v_cr := b.total - v_tds;

  -- debit side: each line's ledger (with its own tax added when the credit is not claimed)
  for r in select ledger_id, sum(taxable + case when b.itc_eligible then 0 else cgst + sgst + igst end) as amt
             from purchase_bill_lines where bill_id = p_id group by ledger_id order by ledger_id loop
    v_lines := v_lines || jsonb_build_object('ledger_id', r.ledger_id, 'debit', r.amt, 'credit', 0, 'narration', 'Purchase ' || b.supplier_invoice_no);
  end loop;
  if b.itc_eligible then
    if b.cgst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_cgst, 'debit', b.cgst, 'credit', 0, 'narration', 'Input CGST'); end if;
    if b.sgst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_sgst, 'debit', b.sgst, 'credit', 0, 'narration', 'Input SGST'); end if;
    if b.igst > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_igst, 'debit', b.igst, 'credit', 0, 'narration', 'Input IGST'); end if;
  end if;
  v_lines := v_lines || jsonb_build_object('ledger_id', l_creditors, 'debit', 0, 'credit', v_cr, 'narration', s.name);
  if v_tds > 0 then v_lines := v_lines || jsonb_build_object('ledger_id', l_tds, 'debit', 0, 'credit', v_tds, 'narration', 'TDS ' || (t ->> 'section')); end if;

  v_res := acc_post_journal(b.bill_date, 'Purchase bill ' || b.bill_no || ' - ' || s.name || ' inv ' || b.supplier_invoice_no, v_lines, 'purchase_bill', b.bill_id, 'posted', auth.uid());
  update purchase_bills set status = 'approved', voucher_id = (v_res ->> 'voucher_id')::uuid, decided_by = auth.uid(), decided_at = now(),
         tds_section = t ->> 'section', tds_base = (t ->> 'base')::numeric, tds_rate = (t ->> 'rate')::numeric, tds_amount = v_tds, net_payable = v_cr
   where bill_id = p_id;
  return v_res || jsonb_build_object('tds', v_tds, 'net_payable', v_cr);
end $$;

revoke execute on function create_opening_bills(date, jsonb), approve_opening_bill(uuid), approve_purchase_bill(uuid) from public, anon, authenticated;
grant execute on function create_opening_bills(date, jsonb), approve_opening_bill(uuid), approve_purchase_bill(uuid) to authenticated;
