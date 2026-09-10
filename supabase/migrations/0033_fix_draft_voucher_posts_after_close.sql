-- ============================================================================
-- Super Seller 360 — Fix: draft vouchers could be posted after period close
--
-- Bug found during senior-QA testing: prevent_voucher_in_closed_period only
-- fired on BEFORE INSERT, never BEFORE UPDATE. Confirmed live (using an
-- isolated test period, never touching real seed data): a draft voucher
-- created while a period was open could still be updated to 'posted'
-- status AFTER that period was closed, with zero error — completely
-- defeating the purpose of Period Close, since anyone could leave draft
-- vouchers sitting around and post them retroactively into supposedly
-- locked books.
--
-- Fixed by firing the same check on UPDATE too, not just INSERT.
-- Re-verified afterward: normal invoice posting (post_sales_voucher's own
-- draft -> posted transition, which happens while the period is still
-- open) still works correctly, the exploit is now blocked with the exact
-- error "Cannot post a voucher into a closed accounting period", and the
-- real books came back to their correct balanced state with the correct
-- 2 accounting periods intact.
-- ============================================================================
create or replace function prevent_voucher_in_closed_period()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_period_status text;
begin
  select status into v_period_status from accounting_periods where accounting_period_id = new.accounting_period_id;
  if v_period_status <> 'open' then
    raise exception 'Cannot post a voucher into a % accounting period', v_period_status;
  end if;
  return new;
end;
$$;

drop trigger trg_prevent_voucher_in_closed_period on vouchers;
create trigger trg_prevent_voucher_in_closed_period
  before insert or update on vouchers
  for each row execute function prevent_voucher_in_closed_period();
