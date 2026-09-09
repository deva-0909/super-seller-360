-- ============================================================================
-- Super Seller 360 — Fix: disposition_return/disposition_rto bypassed the
-- warehouse-scope RLS fix entirely (SECURITY DEFINER)
--
-- Direct follow-up to 0025's RLS fix. Found during senior-QA testing:
-- disposition_return() and disposition_rto() are SECURITY DEFINER,
-- meaning their internal UPDATE statements bypass RLS entirely —
-- including the warehouse-scope policy just fixed there. Confirmed live:
-- Kavita (Warehouse Manager, scoped to Surat only) successfully
-- dispositioned and restocked a return against MUMBAI's warehouse with
-- zero error, crediting real stock to a warehouse she has no authority
-- over — the exact same class of bug as 0025, just reachable through a
-- different door. A SECURITY DEFINER function deliberately runs with
-- elevated privilege, so it needs its own explicit check; RLS alone can
-- never be sufficient for it.
--
-- Re-verified after the fix: the same attack is blocked, her legitimate
-- Surat-scoped disposition still works with no regression, and inventory
-- balances came back to exactly the original correct seed state.
-- ============================================================================

create or replace function disposition_return(
  p_return_id uuid, p_inspection_result text, p_disposition text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_return returns%rowtype;
  v_line record;
  v_skipped_count int := 0;
begin
  if not (has_returns_write()) then
    raise exception 'Not authorized to disposition returns';
  end if;
  if p_disposition not in ('restocked','quarantined','claimed') then
    raise exception 'Invalid disposition: %', p_disposition;
  end if;

  select * into v_return from returns where return_id = p_return_id;
  if not found then
    raise exception 'Return % not found', p_return_id;
  end if;

  if current_role_name() = 'Warehouse Manager' and v_return.warehouse_id is not null
     and not exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = v_return.warehouse_id) then
    raise exception 'Not authorized to disposition a return for a warehouse outside your assignment';
  end if;

  if v_return.status not in ('received','inspected') then
    raise exception 'Return must be received before it can be dispositioned (current status: %)', v_return.status;
  end if;
  if p_disposition = 'restocked' and v_return.warehouse_id is null then
    raise exception 'A destination warehouse must be set before restocking';
  end if;

  update returns
    set inspection_result = p_inspection_result,
        status = p_disposition,
        restock_status = p_disposition
    where return_id = p_return_id;

  if p_disposition = 'restocked' and p_inspection_result = 'good' then
    for v_line in select product_id, quantity from order_lines where order_id = v_return.order_id loop
      if v_line.product_id is null then
        v_skipped_count := v_skipped_count + 1;
        continue;
      end if;
      perform record_inventory_movement(
        v_line.product_id, v_return.warehouse_id, 'return_restock',
        v_line.quantity, 'return', p_return_id
      );
    end loop;
    if v_skipped_count > 0 then
      raise notice '% line item(s) had no mapped product and were not restocked — map the SKU and restock manually.', v_skipped_count;
    end if;
  end if;
end;
$$;

create or replace function disposition_rto(
  p_rto_id uuid, p_inspection_result text, p_disposition text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rto rtos%rowtype;
  v_line record;
  v_skipped_count int := 0;
begin
  if not (has_returns_write()) then
    raise exception 'Not authorized to disposition RTOs';
  end if;
  if p_disposition not in ('restocked','quarantined','claimed') then
    raise exception 'Invalid disposition: %', p_disposition;
  end if;

  select * into v_rto from rtos where rto_id = p_rto_id;
  if not found then
    raise exception 'RTO % not found', p_rto_id;
  end if;

  if current_role_name() = 'Warehouse Manager' and v_rto.warehouse_id is not null
     and not exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = v_rto.warehouse_id) then
    raise exception 'Not authorized to disposition an RTO for a warehouse outside your assignment';
  end if;

  if v_rto.status not in ('received','inspected') then
    raise exception 'RTO must be received before it can be dispositioned (current status: %)', v_rto.status;
  end if;
  if p_disposition = 'restocked' and v_rto.warehouse_id is null then
    raise exception 'A destination warehouse must be set before restocking';
  end if;

  update rtos
    set inspection_result = p_inspection_result,
        status = p_disposition
    where rto_id = p_rto_id;

  if p_disposition = 'restocked' and p_inspection_result = 'good' then
    for v_line in select product_id, quantity from order_lines where order_id = v_rto.order_id loop
      if v_line.product_id is null then
        v_skipped_count := v_skipped_count + 1;
        continue;
      end if;
      perform record_inventory_movement(
        v_line.product_id, v_rto.warehouse_id, 'rto_restock',
        v_line.quantity, 'rto', p_rto_id
      );
    end loop;
    if v_skipped_count > 0 then
      raise notice '% line item(s) had no mapped product and were not restocked — map the SKU and restock manually.', v_skipped_count;
    end if;
  end if;
end;
$$;
