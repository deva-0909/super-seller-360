-- ============================================================================
-- Super Seller 360 — GST correctness audit, part 5: ITC on marketplace commission
--
-- Extends reconcile_settlement to recognize the Input Tax Credit embedded
-- in marketplace commission. Marketplaces charge 18% GST on their
-- commission/fees (a taxable service), which is legitimately claimable as
-- ITC against GST payable — not just a cost that reduces what's remitted.
-- Previously "deductions" only reduced actual_amount with no accounting
-- entry recognizing the expense or its embedded tax credit at all.
--
-- On each reconciliation with real deductions, posts a journal voucher:
-- Dr Marketplace Commission Expense (deductions ÷ 1.18, the base fee)
-- Dr GST Input Tax Credit (the embedded 18% GST — claimable)
-- Cr Trade Receivables (the full deduction)
--
-- Verified live on the real (previously pending) Flipkart September
-- settlement: ₹427.50 in deductions correctly split into ₹362.29 base
-- commission expense + ₹65.21 claimable ITC (362.29 × 1.18 = 427.50
-- exactly), and the trial balance remained exactly balanced afterward.
-- ============================================================================
create or replace function reconcile_settlement(
  p_settlement_id uuid, p_actual_amount numeric, p_bank_txn_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_expected numeric;
  v_deductions numeric;
  v_current_status text;
  v_status text;
  v_voucher_type_id uuid;
  v_period_id uuid;
  v_voucher_id uuid;
  v_commission_base numeric;
  v_commission_gst numeric;
  v_receivable_ledger uuid;
  v_commission_ledger uuid;
  v_itc_ledger uuid;
begin
  if not has_settlements_reconcile() then
    raise exception 'Not authorized to reconcile settlements';
  end if;
  if p_actual_amount < 0 then
    raise exception 'Actual amount cannot be negative';
  end if;

  select expected_amount, status, deductions into v_expected, v_current_status, v_deductions
    from settlements where settlement_id = p_settlement_id;
  if not found then
    raise exception 'Settlement % not found', p_settlement_id;
  end if;
  if v_current_status <> 'pending' then
    raise exception 'Settlement is already % — corrections require a separate reversal, not overwriting reconciled history', v_current_status;
  end if;

  v_status := case
    when p_actual_amount = v_expected then 'reconciled'
    when p_actual_amount < v_expected then 'short_pay'
    else 'excess'
  end;

  update settlements set actual_amount = p_actual_amount, status = v_status
    where settlement_id = p_settlement_id;

  if p_bank_txn_id is not null then
    update bank_transactions
      set matched_entity = 'settlement', matched_reference_id = p_settlement_id, match_status = 'matched'
      where bank_txn_id = p_bank_txn_id;
  end if;

  if v_deductions > 0 then
    select ledger_id into v_receivable_ledger from ledgers where name = 'Trade Receivables';
    select ledger_id into v_commission_ledger from ledgers where name = 'Marketplace Commission Expense';
    select ledger_id into v_itc_ledger from ledgers where name = 'GST Input Tax Credit (ITC)';
    select voucher_type_id into v_voucher_type_id from voucher_types where code = 'JOURNAL';
    select accounting_period_id into v_period_id from accounting_periods
      where current_date between start_date and end_date and status = 'open' limit 1;

    if v_receivable_ledger is not null and v_commission_ledger is not null
       and v_itc_ledger is not null and v_period_id is not null then
      v_commission_base := round(v_deductions / 1.18, 2);
      v_commission_gst := v_deductions - v_commission_base;

      insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, source_type, source_id, narration, total_debit, total_credit)
      values (
        v_voucher_type_id,
        'CE-' || to_char(now(), 'YYYYMMDD-HH24MISS'),
        current_date, v_period_id, 'draft', 'settlement', p_settlement_id,
        'Marketplace commission + ITC on settlement reconciliation',
        v_deductions, v_deductions
      ) returning voucher_id into v_voucher_id;

      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_commission_ledger, v_commission_base, 0, 'settlement', p_settlement_id);

      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_itc_ledger, v_commission_gst, 0, 'settlement', p_settlement_id);

      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_receivable_ledger, 0, v_deductions, 'settlement', p_settlement_id);

      update vouchers set status = 'posted' where voucher_id = v_voucher_id;
    end if;
  end if;
end;
$$;
