-- 0100: book one bank line across several accounts (for example amount + GST, or one payment covering rent and maintenance).
-- Same rules as br_book_txn (0054): open period, other side must be active ledgers, posts straight away and links to the bank line.
create or replace function bank_review_accept_split(p_txn uuid, p_splits jsonb, p_supplier uuid default null, p_narration text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  t bank_transactions%rowtype; v_bank uuid; v_period uuid; v_vt uuid; v_prefix text; v_no text; v_vid uuid; s jsonb; v_sum numeric := 0; v_amt numeric; v_led uuid; v_n int := 0;
begin
  if not has_accounting_write() then raise exception 'Not authorized to post vouchers'; end if;
  select * into t from bank_transactions where bank_txn_id = p_txn for update;
  if not found then raise exception 'Statement line not found'; end if;
  if t.recon_status not in ('unreconciled','suggested') then raise exception 'This line is no longer waiting for review'; end if;
  if jsonb_typeof(p_splits) is distinct from 'array' or jsonb_array_length(p_splits) < 2 then raise exception 'Split the line across at least two accounts'; end if;
  if jsonb_array_length(p_splits) > 20 then raise exception 'A split can have at most 20 lines'; end if;
  v_bank := br_bank_ledger_of(t.bank_account_id);
  if v_bank is null then raise exception 'This bank account has no ledger'; end if;
  for s in select * from jsonb_array_elements(p_splits) loop
    v_led := (s ->> 'ledger_id')::uuid; v_amt := round((s ->> 'amount')::numeric, 2);
    if v_amt is null or v_amt <= 0 then raise exception 'Every split line needs an amount above zero'; end if;
    if v_led = v_bank then raise exception 'Choose the other side of the entry, not the bank itself'; end if;
    if not exists (select 1 from ledgers where ledger_id = v_led and status = 'active') then raise exception 'Choose an active account on every split line'; end if;
    v_sum := v_sum + v_amt;
  end loop;
  if abs(v_sum - t.amount) >= 0.005 then raise exception 'The split adds up to % but the bank line is %', v_sum, t.amount; end if;
  select accounting_period_id into v_period from accounting_periods where t.txn_date between start_date and end_date and status = 'open' limit 1;
  if v_period is null then raise exception 'No open accounting period covers %', t.txn_date; end if;
  select voucher_type_id, numbering_prefix into v_vt, v_prefix from voucher_types where code = case when t.type = 'credit' then 'RECEIPT' else 'PAYMENT' end;
  v_no := v_prefix || '-' || to_char(t.txn_date, 'YYMM') || '-' || lpad(nextval('journal_voucher_seq')::text, 6, '0');

  perform br_cancel_rule_draft(p_txn);
  perform br_unlink(p_txn);
  update bank_recon_suggestions set status = 'withdrawn' where bank_txn_id = p_txn and status = 'pending';

  insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, source_type, source_id, narration, total_debit, total_credit, created_by)
  values (v_vt, v_no, t.txn_date, v_period, 'draft', 'bank_txn', t.bank_txn_id, coalesce(nullif(p_narration, ''), t.reference, 'Bank entry (split)'), t.amount, t.amount, auth.uid())
  returning voucher_id into v_vid;
  insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id, narration)
  values (v_vid, v_bank, case when t.type = 'credit' then t.amount else 0 end, case when t.type = 'credit' then 0 else t.amount end, 'bank_txn', t.bank_txn_id, t.reference);
  for s in select * from jsonb_array_elements(p_splits) loop
    v_amt := round((s ->> 'amount')::numeric, 2);
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id, narration)
    values (v_vid, (s ->> 'ledger_id')::uuid, case when t.type = 'credit' then 0 else v_amt end, case when t.type = 'credit' then v_amt else 0 end, 'bank_txn', t.bank_txn_id,
            coalesce(nullif(s ->> 'narration', ''), t.reference));
    v_n := v_n + 1;
  end loop;
  update vouchers set status = 'posted', approved_by = auth.uid() where voucher_id = v_vid;
  update bank_transactions set matched_entity = 'journal_rule', matched_reference_id = v_vid, match_status = 'matched',
         supplier_id = p_supplier, reviewed_by = auth.uid(), reviewed_at = now() where bank_txn_id = p_txn;
  perform br_link_rule_voucher(p_txn, v_vid);
  return jsonb_build_object('voucher_id', v_vid, 'voucher_no', v_no, 'lines', v_n);
end $$;
revoke execute on function bank_review_accept_split(uuid, jsonb, uuid, text) from public, anon;
grant execute on function bank_review_accept_split(uuid, jsonb, uuid, text) to authenticated;
