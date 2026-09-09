-- ============================================================================
-- Super Seller 360 — Fix: reconcile_settlement allowed silently overwriting
-- an already-reconciled settlement
--
-- Found during senior-QA testing: reconcile_settlement() had no check
-- against re-running on a settlement that was already reconciled/short_pay/
-- excess. Confirmed live: an already-reconciled settlement (real ₹5,270)
-- was silently overwritten to a fabricated ₹9,999 with zero error. The UI
-- hides the reconcile form once status isn't 'pending', but that's
-- cosmetic — the RPC itself enforced nothing.
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
  v_current_status text;
  v_status text;
begin
  if not has_settlements_reconcile() then
    raise exception 'Not authorized to reconcile settlements';
  end if;
  if p_actual_amount < 0 then
    raise exception 'Actual amount cannot be negative';
  end if;

  select expected_amount, status into v_expected, v_current_status
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
end;
$$;
