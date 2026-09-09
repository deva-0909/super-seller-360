-- ============================================================================
-- Super Seller 360 — Phase 5: Claims, Tax
-- ============================================================================

create table claims (
  claim_id          uuid primary key default gen_random_uuid(),
  order_id          uuid not null references orders(order_id),
  claim_type        text check (claim_type in ('lost_shipment','damaged_return','incorrect_deduction','excess_deduction','other')),
  potential_amount  numeric(14,2) not null default 0,
  claimed_amount    numeric(14,2),
  approved_amount   numeric(14,2),
  recovered_amount  numeric(14,2) not null default 0,
  deadline          date,
  owner             uuid references user_profiles(user_id),
  status            text not null default 'potential'
                      check (status in ('potential','claimed','approved','rejected','recovered')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table tax_transactions (
  tax_txn_id      uuid primary key default gen_random_uuid(),
  tax_type        text not null check (tax_type in ('GST','TDS','TCS')),
  period          text not null,  -- e.g. 'Sep 2026'
  source          text,           -- free-text description of where this came from
  document_ref    text,
  taxable_value   numeric(14,2) not null default 0,
  tax_amount      numeric(14,2) not null default 0,
  matched_status  text not null default 'unmatched' check (matched_status in ('matched','unmatched','disputed')),
  reference_type  text,
  reference_id    uuid,
  created_at      timestamptz not null default now()
);

create trigger trg_claims_updated_at before update on claims
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- advance_claim — the controlled path for status transitions that matter:
-- approving sets approved_amount, recovering adds to recovered_amount.
-- Kept as a single function so the amount fields and status always move
-- together (an "approved" claim always has an approved_amount, etc.)
-- ---------------------------------------------------------------------------
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
    update claims
      set status = 'recovered', recovered_amount = v_claim.recovered_amount + coalesce(p_amount, 0)
      where claim_id = p_claim_id;
  else
    raise exception 'Invalid claim status: %', p_status;
  end if;
end;
$$;

revoke execute on function advance_claim(uuid,text,numeric) from anon, public;
grant execute on function advance_claim(uuid,text,numeric) to authenticated;
