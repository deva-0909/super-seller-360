-- ============================================================================
-- Super Seller 360 — Fix: advance_claim enforced no state-transition rules
--
-- Found during senior-QA testing: advance_claim() let any status jump to
-- any other status in any order. Confirmed live: a terminal 'rejected'
-- claim was silently reopened and "approved" for a fabricated ₹5,000 with
-- zero error.
--
-- First fix attempt was too strict and broke a legitimate pattern: it
-- required status to be exactly 'approved' to record a recovery, which
-- blocked the multi-installment recovery flow (recording several partial
-- recoveries in sequence) that was built and tested earlier in this
-- project. Caught before shipping by re-testing that exact flow — a
-- second partial recovery call failed with "must be approved". Corrected
-- to allow recovered -> recovered (another installment) alongside
-- approved -> recovered (the first one); the existing amount check still
-- prevents over-recovery regardless of how many installments it takes.
--
-- Valid transitions: potential -> claimed -> approved/rejected ->
-- recovered (any number of times, capped by the approved amount).
-- rejected and a fully-settled recovered claim are otherwise terminal.
-- ============================================================================
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

  if p_status = 'claimed' and v_claim.status <> 'potential' then
    raise exception 'Cannot file a claim from status % — must be potential', v_claim.status;
  elsif p_status in ('approved', 'rejected') and v_claim.status <> 'claimed' then
    raise exception 'Cannot % a claim from status % — must be claimed', p_status, v_claim.status;
  elsif p_status = 'recovered' and v_claim.status not in ('approved', 'recovered') then
    raise exception 'Cannot record a recovery from status % — must be approved (or already recovering in installments)', v_claim.status;
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
