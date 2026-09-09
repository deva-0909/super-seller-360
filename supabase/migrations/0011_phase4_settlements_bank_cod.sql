-- ============================================================================
-- Super Seller 360 — Phase 4: Settlements, Bank/COD reconciliation
--
-- Addresses pain point #2 (verifying portal/gateway payments after
-- deductions) and #4 (COD collection tracking) from the original brief.
-- ============================================================================

create table bank_accounts (
  bank_account_id       uuid primary key default gen_random_uuid(),
  company_id            uuid not null references companies(company_id),
  bank_name             text not null,
  account_name          text not null,
  account_number_last4  text,
  ifsc                  text,
  status                text not null default 'active' check (status in ('active','inactive')),
  created_at            timestamptz not null default now()
);

create table settlements (
  settlement_id            uuid primary key default gen_random_uuid(),
  channel_id               uuid not null references channels(channel_id),
  external_settlement_id   text not null,
  period_start             date,
  period_end               date,
  gross                    numeric(14,2) not null default 0,
  deductions               numeric(14,2) not null default 0,
  expected_amount          numeric(14,2) not null default 0,
  actual_amount            numeric(14,2),
  status                   text not null default 'pending'
                             check (status in ('pending','reconciled','short_pay','excess')),
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  unique (channel_id, external_settlement_id)
);

create table settlement_lines (
  settlement_line_id  uuid primary key default gen_random_uuid(),
  settlement_id       uuid not null references settlements(settlement_id) on delete cascade,
  order_id            uuid references orders(order_id),
  fee_type            text check (fee_type in ('order_value','commission','shipping','gateway_fee','tax','refund','other')),
  amount              numeric(14,2) not null default 0,
  tax_amount          numeric(14,2) not null default 0
);

create table bank_transactions (
  bank_txn_id            uuid primary key default gen_random_uuid(),
  bank_account_id        uuid not null references bank_accounts(bank_account_id),
  txn_date               date not null,
  reference              text,
  amount                 numeric(14,2) not null,
  type                   text not null check (type in ('credit','debit')),
  matched_entity         text check (matched_entity in ('settlement','cod','order')),
  matched_reference_id   uuid,
  match_status           text not null default 'unmatched' check (match_status in ('unmatched','matched','partial')),
  created_at             timestamptz not null default now()
);

create table cod_collections (
  cod_id             uuid primary key default gen_random_uuid(),
  order_id           uuid not null references orders(order_id),
  courier_name       text,
  cod_amount         numeric(14,2) not null default 0,
  collected_amount   numeric(14,2) not null default 0,
  remitted_amount    numeric(14,2) not null default 0,
  status             text not null default 'pending'
                       check (status in ('pending','collected','remitted','short_remit')),
  collected_date     date,
  remitted_date      date,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create trigger trg_settlements_updated_at before update on settlements
  for each row execute function set_updated_at();
create trigger trg_cod_collections_updated_at before update on cod_collections
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- reconcile_settlement — the controlled path that records what was actually
-- received against a settlement and computes short-pay/excess/reconciled
-- status from the comparison. Optionally links the matching bank transaction
-- in the same call so "money received" and "money explained" move together.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- record_cod_remittance — records a courier remitting COD cash collected on
-- delivery. status reflects whether the full cod_amount has been remitted.
-- ---------------------------------------------------------------------------
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

  select * into v_cod from cod_collections where cod_id = p_cod_id;
  if not found then
    raise exception 'COD collection % not found', p_cod_id;
  end if;

  v_new_total := v_cod.remitted_amount + p_remitted_amount;
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

revoke execute on function reconcile_settlement(uuid,numeric,uuid) from anon, public;
grant execute on function reconcile_settlement(uuid,numeric,uuid) to authenticated;
revoke execute on function record_cod_remittance(uuid,numeric,uuid) from anon, public;
grant execute on function record_cod_remittance(uuid,numeric,uuid) to authenticated;
