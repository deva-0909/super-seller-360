-- 0052: wire the rule engine into the app. Every hook is a trigger that raises an EVENT and never blocks the
-- action itself (jr_fire swallows and logs errors). Plus a one-time backfill for data that predates the engine.

create or replace function jr_return_ctx(r public.returns, p_date date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jr_order_ctx(r.order_id) || jsonb_build_object(
    'return_id', r.return_id, 'reason', r.return_reason, 'inspection_result', r.inspection_result,
    'disposition', r.status, 'cogs', jr_order_cogs(r.order_id), 'date', p_date)
$$;

create or replace function jr_rto_ctx(r public.rtos, p_date date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jr_order_ctx(r.order_id) || jsonb_build_object(
    'rto_id', r.rto_id, 'awb', r.awb, 'reason', r.reason, 'inspection_result', r.inspection_result,
    'disposition', r.status, 'cogs', jr_order_cogs(r.order_id), 'date', p_date)
$$;

create or replace function jr_log_hook_error(p_event text, p_source_type text, p_source_id uuid, p_msg text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into journal_rule_log (event_type, source_type, source_id, status, message)
  values (p_event, p_source_type, p_source_id, 'error', 'Hook failed: ' || p_msg)
$$;

-- ---------------------------------------------------------------- returns
create or replace function trg_returns_journal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_post text[] := array['received','inspected','restocked','quarantined','claimed'];
  v_old_status text := null; v_old_refund text := null;
begin
  if tg_op = 'UPDATE' then v_old_status := old.status; v_old_refund := old.refund_status; end if;
  begin
    if new.status = any (v_post) and (v_old_status is null or not (v_old_status = any (v_post))) then
      perform jr_fire('return.accepted', 'return', new.return_id, jr_return_ctx(new, current_date), 'return.accepted:' || new.return_id);
    end if;
    if new.refund_status = 'refunded' and v_old_refund is distinct from 'refunded' then
      perform jr_fire('return.refund_paid', 'return', new.return_id, jr_return_ctx(new, current_date), 'return.refund_paid:' || new.return_id);
    end if;
    if new.status in ('claimed', 'quarantined') and v_old_status is distinct from new.status then
      perform jr_fire('return.writeoff', 'return', new.return_id, jr_return_ctx(new, current_date), 'return.writeoff:' || new.return_id || ':' || new.status);
    end if;
  exception when others then
    perform jr_log_hook_error('return', 'return', new.return_id, sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_returns_journal on returns;
create trigger trg_returns_journal after insert or update of status, refund_status on returns
  for each row execute function trg_returns_journal();

-- ---------------------------------------------------------------- RTO
create or replace function trg_rtos_journal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_post text[] := array['received','inspected','restocked','quarantined','claimed'];
  v_old_status text := null;
begin
  if tg_op = 'UPDATE' then v_old_status := old.status; end if;
  begin
    if new.status = any (v_post) and (v_old_status is null or not (v_old_status = any (v_post))) then
      perform jr_fire('rto.received', 'rto', new.rto_id, jr_rto_ctx(new, current_date), 'rto.received:' || new.rto_id);
    end if;
    if new.status in ('claimed', 'quarantined') and v_old_status is distinct from new.status then
      perform jr_fire('rto.writeoff', 'rto', new.rto_id, jr_rto_ctx(new, current_date), 'rto.writeoff:' || new.rto_id || ':' || new.status);
    end if;
  exception when others then
    perform jr_log_hook_error('rto', 'rto', new.rto_id, sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_rtos_journal on rtos;
create trigger trg_rtos_journal after insert or update of status on rtos
  for each row execute function trg_rtos_journal();

-- ---------------------------------------------------------------- invoiced order cancelled
create or replace function trg_orders_journal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if new.fulfilment_status = 'cancelled' and old.fulfilment_status is distinct from 'cancelled'
       and exists (select 1 from invoices where order_id = new.order_id) then
      perform jr_fire('order.cancelled', 'order', new.order_id,
                      jr_order_ctx(new.order_id) || jsonb_build_object('date', current_date), 'order.cancelled:' || new.order_id);
    end if;
  exception when others then
    perform jr_log_hook_error('order.cancelled', 'order', new.order_id, sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_orders_journal on orders;
create trigger trg_orders_journal after update of fulfilment_status on orders
  for each row execute function trg_orders_journal();

-- ---------------------------------------------------------------- COD
create or replace function jr_cod_ctx(c cod_collections, p_amount numeric, p_date date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('courier', c.courier_name, 'order_ref', (select external_order_id from orders where order_id = c.order_id),
    'amount', p_amount, 'cod_amount', c.cod_amount, 'total_remitted', c.remitted_amount,
    'short', greatest(c.cod_amount - c.remitted_amount, 0), 'date', p_date)
$$;

create or replace function trg_cod_journal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old_col numeric := 0; v_old_rem numeric := 0;
begin
  begin
    if tg_op = 'UPDATE' then v_old_col := old.collected_amount; v_old_rem := old.remitted_amount; end if;
    if new.collected_amount > v_old_col then
      perform jr_fire('cod.collected', 'cod', new.cod_id, jr_cod_ctx(new, new.collected_amount - v_old_col, current_date),
                      'cod.collected:' || new.cod_id || ':' || new.collected_amount);
    end if;
    if new.remitted_amount > v_old_rem then
      perform jr_fire('cod.remitted', 'cod', new.cod_id, jr_cod_ctx(new, new.remitted_amount - v_old_rem, current_date),
                      'cod.remitted:' || new.cod_id || ':' || new.remitted_amount);
    end if;
  exception when others then
    perform jr_log_hook_error('cod', 'cod', new.cod_id, sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_cod_journal on cod_collections;
create trigger trg_cod_journal after insert or update of collected_amount, remitted_amount on cod_collections
  for each row execute function trg_cod_journal();

-- ---------------------------------------------------------------- settlements
create or replace function jr_settlement_ctx(s settlements, p_date date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('channel', c.name, 'channel_type', c.type, 'settlement_ref', s.external_settlement_id,
    'gross', s.gross, 'deductions', s.deductions, 'expected', s.expected_amount, 'actual', coalesce(s.actual_amount, 0),
    'short', greatest(s.expected_amount - coalesce(s.actual_amount, 0), 0),
    'excess', greatest(coalesce(s.actual_amount, 0) - s.expected_amount, 0), 'status', s.status, 'date', p_date)
  from channels c where c.channel_id = s.channel_id
$$;

create or replace function trg_settlements_journal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if old.status = 'pending' and new.status in ('reconciled', 'short_pay', 'excess') then
      perform jr_fire('settlement.reconciled', 'settlement', new.settlement_id, jr_settlement_ctx(new, current_date),
                      'settlement.reconciled:' || new.settlement_id);
    end if;
  exception when others then
    perform jr_log_hook_error('settlement', 'settlement', new.settlement_id, sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_settlements_journal on settlements;
create trigger trg_settlements_journal after update of status on settlements
  for each row execute function trg_settlements_journal();

-- ---------------------------------------------------------------- claims
create or replace function jr_claim_ctx(c claims, p_amount numeric, p_date date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('claim_type', c.claim_type, 'order_ref', o.external_order_id, 'channel', ch.name,
    'amount', p_amount, 'total_recovered', c.recovered_amount, 'date', p_date)
  from (select 1) x left join orders o on o.order_id = c.order_id left join channels ch on ch.channel_id = o.channel_id
$$;

create or replace function trg_claims_journal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    if new.status = 'approved' and old.status is distinct from 'approved' then
      perform jr_fire('claim.approved', 'claim', new.claim_id,
                      jr_claim_ctx(new, coalesce(new.approved_amount, new.claimed_amount, new.potential_amount, 0), current_date),
                      'claim.approved:' || new.claim_id);
    end if;
    if new.recovered_amount > old.recovered_amount then
      perform jr_fire('claim.recovered', 'claim', new.claim_id, jr_claim_ctx(new, new.recovered_amount - old.recovered_amount, current_date),
                      'claim.recovered:' || new.claim_id || ':' || new.recovered_amount);
    end if;
    if new.status = 'rejected' and old.status is distinct from 'rejected' then
      perform jr_fire('claim.rejected', 'claim', new.claim_id, jr_claim_ctx(new, coalesce(new.claimed_amount, new.potential_amount, 0), current_date),
                      'claim.rejected:' || new.claim_id);
    end if;
  exception when others then
    perform jr_log_hook_error('claim', 'claim', new.claim_id, sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_claims_journal on claims;
create trigger trg_claims_journal after update of status, recovered_amount on claims
  for each row execute function trg_claims_journal();

-- ---------------------------------------------------------------- inventory movements (perpetual-inventory pack)
create or replace function trg_inventory_journal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_event text := 'inventory.' || new.movement_type; v_cost numeric; v_sku text; v_name text; v_wh text;
begin
  begin
    if exists (select 1 from journal_rules where event_type = v_event and status = 'active') then
      select sku, name, coalesce(cost_price, 0) into v_sku, v_name, v_cost from products where product_id = new.product_id;
      select name into v_wh from warehouses where warehouse_id = new.warehouse_id;
      perform jr_fire(v_event, 'inventory', new.inventory_txn_id,
        jsonb_build_object('movement_type', new.movement_type, 'sku', v_sku, 'product', v_name, 'warehouse', v_wh,
                           'quantity', new.quantity, 'qty', abs(new.quantity), 'unit_cost', v_cost, 'cogs', round(abs(new.quantity) * v_cost, 2), 'date', current_date),
        'inventory:' || new.inventory_txn_id);
    end if;
  exception when others then
    perform jr_log_hook_error(v_event, 'inventory', new.inventory_txn_id, sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_inventory_journal on inventory_transactions;
create trigger trg_inventory_journal after insert on inventory_transactions
  for each row execute function trg_inventory_journal();

-- ---------------------------------------------------------------- bank lines
create or replace function trg_bank_txn_journal() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin
    perform jr_process_bank_txn(new.bank_txn_id);
  exception when others then
    perform jr_log_hook_error('bank.' || new.type, 'bank_txn', new.bank_txn_id, sqlerrm);
  end;
  return new;
end $$;
drop trigger if exists trg_bank_txn_journal on bank_transactions;
create trigger trg_bank_txn_journal after insert on bank_transactions
  for each row execute function trg_bank_txn_journal();

revoke execute on function jr_return_ctx(public.returns, date), jr_rto_ctx(public.rtos, date), jr_cod_ctx(cod_collections, numeric, date),
  jr_settlement_ctx(settlements, date), jr_claim_ctx(claims, numeric, date), jr_log_hook_error(text, text, uuid, text),
  trg_returns_journal(), trg_rtos_journal(), trg_orders_journal(), trg_cod_journal(), trg_settlements_journal(),
  trg_claims_journal(), trg_inventory_journal(), trg_bank_txn_journal() from public, anon, authenticated;

-- ---------------------------------------------------------------- backfill (data that predates the engine)
-- Replays events for existing records using the date each thing actually happened. Safe to run twice: every event carries a
-- dedupe key, so nothing is posted twice. Dates in a closed accounting period are logged as errors and left alone.
create or replace function jr_backfill() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ret public.returns; rt public.rtos; cod public.cod_collections; st public.settlements; cl public.claims; bt record;
  v_before int; v_after int; v_post text[] := array['received','inspected','restocked','quarantined','claimed'];
  v_date date;
begin
  select count(*) into v_before from journal_rule_log;

  for ret in select * from public.returns where status = any (v_post) order by created_at loop
    perform jr_fire('return.accepted', 'return', ret.return_id, jr_return_ctx(ret, coalesce(ret.received_date, ret.created_at::date)), 'return.accepted:' || ret.return_id);
  end loop;
  for ret in select * from public.returns where refund_status = 'refunded' order by created_at loop
    perform jr_fire('return.refund_paid', 'return', ret.return_id, jr_return_ctx(ret, coalesce(ret.received_date, ret.created_at::date)), 'return.refund_paid:' || ret.return_id);
  end loop;
  for rt in select * from public.rtos where status = any (v_post) order by created_at loop
    perform jr_fire('rto.received', 'rto', rt.rto_id, jr_rto_ctx(rt, coalesce(rt.received_date, rt.created_at::date)), 'rto.received:' || rt.rto_id);
  end loop;
  for cod in select * from public.cod_collections order by created_at loop
    if cod.collected_amount > 0 then
      perform jr_fire('cod.collected', 'cod', cod.cod_id, jr_cod_ctx(cod, cod.collected_amount, coalesce(cod.collected_date, cod.created_at::date)),
                      'cod.collected:' || cod.cod_id || ':' || cod.collected_amount);
    end if;
    if cod.remitted_amount > 0 then
      perform jr_fire('cod.remitted', 'cod', cod.cod_id, jr_cod_ctx(cod, cod.remitted_amount, coalesce(cod.remitted_date, cod.created_at::date)),
                      'cod.remitted:' || cod.cod_id || ':' || cod.remitted_amount);
    end if;
  end loop;
  for st in select * from public.settlements where status in ('reconciled', 'short_pay', 'excess') order by period_end loop
    select txn_date into v_date from bank_transactions where matched_entity = 'settlement' and matched_reference_id = st.settlement_id limit 1;
    perform jr_fire('settlement.reconciled', 'settlement', st.settlement_id, jr_settlement_ctx(st, coalesce(v_date, st.period_end)),
                    'settlement.reconciled:' || st.settlement_id);
  end loop;
  for cl in select * from public.claims order by created_at loop
    if cl.status in ('approved', 'recovered') then
      perform jr_fire('claim.approved', 'claim', cl.claim_id,
                      jr_claim_ctx(cl, coalesce(cl.approved_amount, cl.claimed_amount, cl.potential_amount, 0), cl.updated_at::date), 'claim.approved:' || cl.claim_id);
    end if;
    if cl.recovered_amount > 0 then
      perform jr_fire('claim.recovered', 'claim', cl.claim_id, jr_claim_ctx(cl, cl.recovered_amount, cl.updated_at::date),
                      'claim.recovered:' || cl.claim_id || ':' || cl.recovered_amount);
    end if;
  end loop;
  for bt in select bank_txn_id from bank_transactions where match_status = 'unmatched' order by txn_date loop
    perform jr_process_bank_txn(bt.bank_txn_id);
  end loop;

  select count(*) into v_after from journal_rule_log;
  return jsonb_build_object('log_rows_added', v_after - v_before,
    'posted', (select count(*) from journal_rule_log where status = 'posted'),
    'in_review', (select count(*) from journal_rule_log where status = 'draft'),
    'errors', (select count(*) from journal_rule_log where status = 'error'));
end $$;
revoke execute on function jr_backfill() from public, anon, authenticated;

create or replace function run_journal_backfill() returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not has_rulebook_edit() then raise exception 'Only a Super Admin or Finance Manager can post pending entries'; end if;
  return jr_backfill();
end $$;
revoke execute on function run_journal_backfill() from public, anon;
grant execute on function run_journal_backfill() to authenticated;
