-- ============================================================================
-- Super Seller 360 — Fix: RPCs accepted invalid amounts with zero server-side check
--
-- Bug found during audit: reconcile_settlement, record_cod_remittance, and
-- advance_claim only validated amounts in the React forms — the RPCs
-- themselves had no checks at all. Confirmed live: calling
-- reconcile_settlement directly with -100 as the amount succeeded,
-- silently saving a negative "money received" value. Client-side
-- validation is UX, not security — any direct API call bypasses it
-- entirely. Added the same checks inside the functions, plus two new
-- business-logic guards found worth adding while in here: a COD
-- remittance can no longer exceed the total COD amount owed, and a claim
-- recovery can no longer exceed what was actually approved.
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
  v_status text;
begin
  if not has_settlements_reconcile() then
    raise exception 'Not authorized to reconcile settlements';
  end if;
  if p_actual_amount < 0 then
    raise exception 'Actual amount cannot be negative';
  end if;

  select expected_amount into v_expected from settlements where settlement_id = p_settlement_id;
  if not found then
    raise exception 'Settlement % not found', p_settlement_id;
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

create or replace function record_cod_remittance(
  p_cod_id uuid, p_remitted_amount numeric, p_bank_txn_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cod cod_collections%rowtype;
  v_new_total numeric;
  v_status text;
begin
  if not has_bankcod_write() then
    raise exception 'Not authorized to record COD remittances';
  end if;
  if p_remitted_amount <= 0 then
    raise exception 'Remitted amount must be greater than zero';
  end if;

  select * into v_cod from cod_collections where cod_id = p_cod_id;
  if not found then
    raise exception 'COD collection % not found', p_cod_id;
  end if;

  v_new_total := v_cod.remitted_amount + p_remitted_amount;
  if v_new_total > v_cod.cod_amount then
    raise exception 'Remitted amount (%) would exceed the total COD amount (%)', v_new_total, v_cod.cod_amount;
  end if;

  v_status := case
    when v_new_total >= v_cod.cod_amount then 'remitted'
    else 'short_remit'
  end;

  update cod_collections
    set remitted_amount = v_new_total, status = v_status, remitted_date = current_date
    where cod_id = p_cod_id;

  if p_bank_txn_id is not null then
    update bank_transactions
      set matched_entity = 'cod', matched_reference_id = p_cod_id, match_status = 'matched'
      where bank_txn_id = p_bank_txn_id;
  end if;
end;
$$;

create or replace function advance_claim(
  p_claim_id uuid, p_status text, p_amount numeric default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_claim claims%rowtype;
begin
  if not has_claims_manage() then
    raise exception 'Not authorized to update claim status';
  end if;
  if p_amount is not null and p_amount < 0 then
    raise exception 'Amount cannot be negative';
  end if;

  select * into v_claim from claims where claim_id = p_claim_id;
  if not found then
    raise exception 'Claim % not found', p_claim_id;
  end if;

  if p_status = 'claimed' then
    update claims set status = 'claimed', claimed_amount = coalesce(p_amount, v_claim.potential_amount)
      where claim_id = p_claim_id;
  elsif p_status = 'approved' then
    update claims set status = 'approved', approved_amount = coalesce(p_amount, v_claim.claimed_amount)
      where claim_id = p_claim_id;
  elsif p_status = 'rejected' then
    update claims set status = 'rejected' where claim_id = p_claim_id;
  elsif p_status = 'recovered' then
    if v_claim.recovered_amount + coalesce(p_amount, 0) > coalesce(v_claim.approved_amount, v_claim.potential_amount) then
      raise exception 'Recovered amount would exceed the approved amount';
    end if;
    update claims
      set status = 'recovered', recovered_amount = v_claim.recovered_amount + coalesce(p_amount, 0)
      where claim_id = p_claim_id;
  else
    raise exception 'Invalid claim status: %', p_status;
  end if;
end;
$$;
