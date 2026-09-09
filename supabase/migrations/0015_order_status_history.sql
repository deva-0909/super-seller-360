-- ============================================================================
-- Super Seller 360 — Order status history (ORD-014 Order Timeline)
-- Automatically logs every fulfilment/payment status change so the Order
-- Detail page can show a real timeline, not just the current snapshot.
-- ============================================================================

create table order_status_history (
  history_id          uuid primary key default gen_random_uuid(),
  order_id            uuid not null references orders(order_id) on delete cascade,
  fulfilment_status   text,
  payment_status      text,
  changed_at          timestamptz not null default now(),
  changed_by          uuid references user_profiles(user_id)
);

alter table order_status_history enable row level security;
create policy "order_status_history readable by authenticated"
  on order_status_history for select using (auth.uid() is not null);
-- No direct writes — only the trigger below inserts here.

create or replace function log_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if TG_OP = 'INSERT'
     or new.fulfilment_status is distinct from old.fulfilment_status
     or new.payment_status is distinct from old.payment_status then
    insert into order_status_history (order_id, fulfilment_status, payment_status, changed_by)
    values (new.order_id, new.fulfilment_status, new.payment_status, auth.uid());
  end if;
  return new;
end;
$$;

create trigger trg_log_order_status_change
  after insert or update on orders
  for each row execute function log_order_status_change();

-- Backfill one history row for every order that already exists, so the
-- timeline isn't empty for orders created before this migration.
insert into order_status_history (order_id, fulfilment_status, payment_status, changed_at)
select order_id, fulfilment_status, payment_status, created_at from orders
where not exists (
  select 1 from order_status_history where order_status_history.order_id = orders.order_id
);
