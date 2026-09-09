-- ============================================================================
-- Super Seller 360 — Fix: null product_id crash in disposition functions
--
-- Bug found during audit: dispositioning a return/RTO as "restocked" for an
-- order with an unmapped SKU (order_lines.product_id null) crashed with a
-- raw Postgres NOT NULL constraint error instead of completing gracefully.
-- Confirmed live the crash rolled back cleanly (no partial/corrupted state
-- left behind — a single function call is atomic) but the UX was broken.
--
-- Fix: skip unmapped lines, still restock the mapped ones, and raise a
-- NOTICE reporting how many were skipped so the person knows to map the
-- SKU and restock manually rather than silently losing that line's stock.
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
