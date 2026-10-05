-- 0088: a marketplace settlement now books each kind of deduction where it belongs.
--
-- When a settlement is matched with the bank, the amount the marketplace held back was booked in one piece as "commission" plus
-- 18% GST credit. That is right for the marketplace fee and shipping fee, but a settlement also carries two taxes the marketplace deducts
-- for you (GST TCS and income-tax TDS 194-O). Those are not an expense: they are credits you recover later. Booking them as commission
-- overstated expenses and understated what is recoverable.
--
-- Now, when the settlement has its lines:
--   * fee lines (commission, shipping, gateway fee) with their GST   -> expense + GST input credit, as before
--   * GST TCS deducted                                                -> GST TCS Credit Receivable
--   * 194-O TDS deducted                                              -> TDS Receivable (Sec 194-O)
--   * a Shopify (own-store) payout fee goes to Payment Gateway Charges instead of Marketplace Commission
-- A settlement with no lines is booked exactly as before.

create or replace function reconcile_settlement(p_settlement_id uuid, p_actual_amount numeric, p_bank_txn_id uuid default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_expected numeric; v_deductions numeric; v_current_status text; v_status text; v_channel uuid; v_ctype text;
  v_voucher_type_id uuid; v_period_id uuid; v_voucher_id uuid;
  v_tcs numeric; v_tds numeric; v_fee numeric; v_fee_base numeric; v_fee_gst numeric;
  v_receivable_ledger uuid; v_commission_ledger uuid; v_itc_ledger uuid; v_tcs_ledger uuid; v_tds_ledger uuid;
begin
  if not has_settlements_reconcile() then
    raise exception 'Not authorized to reconcile settlements';
  end if;
  if p_actual_amount < 0 then
    raise exception 'Actual amount cannot be negative';
  end if;

  select expected_amount, status, deductions, channel_id into v_expected, v_current_status, v_deductions, v_channel
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
    select type into v_ctype from channels where channel_id = v_channel;
    select ledger_id into v_receivable_ledger from ledgers where name = 'Trade Receivables';
    select ledger_id into v_commission_ledger from ledgers where name = case when v_ctype = 'd2c' then 'Payment Gateway Charges' else 'Marketplace Commission Expense' end;
    select ledger_id into v_itc_ledger from ledgers where name = 'GST Input Tax Credit (ITC)';
    select ledger_id into v_tcs_ledger from ledgers where name = 'GST TCS Credit Receivable';
    select ledger_id into v_tds_ledger from ledgers where name = 'TDS Receivable (Sec 194-O)';
    select voucher_type_id into v_voucher_type_id from voucher_types where code = 'JOURNAL';
    select accounting_period_id into v_period_id from accounting_periods
      where app_today() between start_date and end_date and status = 'open' limit 1;

    -- what the settlement lines say was held back as tax; the rest of the deductions are fees (with 18% GST)
    select coalesce(sum(amount) filter (where fee_type = 'tcs'), 0), coalesce(sum(amount) filter (where fee_type = 'tds_194o'), 0)
      into v_tcs, v_tds from settlement_lines where settlement_id = p_settlement_id;
    if v_tcs < 0 or v_tds < 0 or v_tcs + v_tds > v_deductions or v_tcs_ledger is null or v_tds_ledger is null then v_tcs := 0; v_tds := 0; end if;
    v_fee := v_deductions - v_tcs - v_tds;
    v_fee_base := round(v_fee / 1.18, 2);
    v_fee_gst := v_fee - v_fee_base;

    if v_receivable_ledger is not null and v_commission_ledger is not null
       and v_itc_ledger is not null and v_period_id is not null then
      insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, source_type, source_id, narration, total_debit, total_credit)
      values (
        v_voucher_type_id,
        'CE-' || to_char(app_today(), 'YYYYMMDD') || '-' || upper(substr(p_settlement_id::text, 1, 8)),
        app_today(), v_period_id, 'draft', 'settlement', p_settlement_id,
        case when v_tcs + v_tds > 0 then 'Marketplace fees, GST input credit, GST TCS and 194-O TDS on settlement reconciliation'
             else 'Marketplace commission + ITC on settlement reconciliation' end,
        v_deductions, v_deductions
      ) returning voucher_id into v_voucher_id;

      if v_fee_base > 0 then
        insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
        values (v_voucher_id, v_commission_ledger, v_fee_base, 0, 'settlement', p_settlement_id);
      end if;
      if v_fee_gst > 0 then
        insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
        values (v_voucher_id, v_itc_ledger, v_fee_gst, 0, 'settlement', p_settlement_id);
      end if;
      if v_tcs > 0 then
        insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
        values (v_voucher_id, v_tcs_ledger, v_tcs, 0, 'settlement', p_settlement_id);
      end if;
      if v_tds > 0 then
        insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
        values (v_voucher_id, v_tds_ledger, v_tds, 0, 'settlement', p_settlement_id);
      end if;
      insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id)
      values (v_voucher_id, v_receivable_ledger, 0, v_deductions, 'settlement', p_settlement_id);

      update vouchers set status = 'posted' where voucher_id = v_voucher_id;
    end if;
  end if;
end;
$$;
