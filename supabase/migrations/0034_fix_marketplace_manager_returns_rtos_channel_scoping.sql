-- ============================================================================
-- Super Seller 360 — Fix: returns/rtos channel-scoping gap for Marketplace Manager
--
-- Bug found during senior-QA testing: returns/rtos INSERT/UPDATE policies
-- had a warehouse-scope check for Warehouse Manager (0025) but no
-- channel-scope check for Marketplace Manager at all. Confirmed live:
-- Arjun (Marketplace Manager, scoped to Amazon + Flipkart) created a
-- return against a real SHOPIFY order by leaving warehouse_id null —
-- bypassing the *incidental* protection of him having zero warehouse
-- visibility (a separate, deliberate design choice, not real channel
-- scoping). Cleaned up immediately after confirming.
--
-- Fixed at BOTH layers this time, having already learned from the
-- warehouse-scoping case (0025 then 0029 as a follow-up) that fixing only
-- RLS leaves the SECURITY DEFINER disposition functions still exploitable:
-- added has_channel_scope() to the RLS policies AND directly inside
-- disposition_return/disposition_rto, checking the order's channel.
--
-- Re-verified after the fix: the same attack is blocked, his legitimate
-- return against his own Amazon order still works, Kavita's (Warehouse
-- Manager) legitimate Surat return has zero regression, and final counts
-- confirmed exactly clean — 3 returns, books balanced at ₹13,067.92.
-- ============================================================================

drop policy "returns write" on returns;
create policy "returns write" on returns for insert with check (
  has_returns_write()
  and (
    current_role_name() <> 'Warehouse Manager'
    or warehouse_id is null
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = returns.warehouse_id)
  )
  and has_channel_scope((select o.channel_id from orders o where o.order_id = returns.order_id))
);

drop policy "returns write update" on returns;
create policy "returns write update" on returns for update using (
  has_returns_write()
  and (
    current_role_name() <> 'Warehouse Manager'
    or warehouse_id is null
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = returns.warehouse_id)
  )
  and has_channel_scope((select o.channel_id from orders o where o.order_id = returns.order_id))
);

drop policy "rtos write" on rtos;
create policy "rtos write" on rtos for insert with check (
  has_returns_write()
  and (
    current_role_name() <> 'Warehouse Manager'
    or warehouse_id is null
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = rtos.warehouse_id)
  )
  and has_channel_scope((select o.channel_id from orders o where o.order_id = rtos.order_id))
);

drop policy "rtos write update" on rtos;
create policy "rtos write update" on rtos for update using (
  has_returns_write()
  and (
    current_role_name() <> 'Warehouse Manager'
    or warehouse_id is null
    or exists (select 1 from user_warehouse_scope uws where uws.user_id = auth.uid() and uws.warehouse_id = rtos.warehouse_id)
  )
  and has_channel_scope((select o.channel_id from orders o where o.order_id = rtos.order_id))
);

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
  v_order_channel_id uuid;
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

  select channel_id into v_order_channel_id from orders where order_id = v_return.order_id;
  if not has_channel_scope(v_order_channel_id) then
    raise exception 'Not authorized to disposition a return for a channel outside your assignment';
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
  v_order_channel_id uuid;
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

  select channel_id into v_order_channel_id from orders where order_id = v_rto.order_id;
  if not has_channel_scope(v_order_channel_id) then
    raise exception 'Not authorized to disposition an RTO for a channel outside your assignment';
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
