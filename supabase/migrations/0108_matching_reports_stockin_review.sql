-- 0108: Matching reports and stock-in review (Round 24).
--   1. po_matching_status: per order line, what was received but not billed (value at the order price) and what was billed for more than was received.
--      This is a report for month-end; it posts nothing to the books.
--   2. Direct stock-ins (no purchase order) must be reviewed by a manager other than the person who entered them.

alter table stock_ins add column if not exists review_status text not null default 'pending' check (review_status in ('pending', 'reviewed'));
alter table stock_ins add column if not exists reviewed_by uuid;
alter table stock_ins add column if not exists reviewed_at timestamptz;
alter table stock_ins add column if not exists review_note text;

create or replace function stock_in_review(p_id uuid, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s stock_ins%rowtype; v_self boolean;
begin
  if not has_req_decide() then raise exception 'Only a manager can review a stock-in'; end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Write what you checked (for example the supplier bill number or who sent the goods)'; end if;
  select * into s from stock_ins where stock_in_id = p_id for update;
  if not found then raise exception 'Stock-in not found'; end if;
  if s.review_status = 'reviewed' then raise exception 'This stock-in is already reviewed'; end if;
  select allow_self_approval into v_self from purchase_settings where id = 1;
  if s.created_by = auth.uid() and not coalesce(v_self, false) then raise exception 'You entered this stock-in, so someone else has to review it'; end if;
  update stock_ins set review_status = 'reviewed', reviewed_by = auth.uid(), reviewed_at = now(), review_note = btrim(p_note) where stock_in_id = p_id;
end $$;
revoke execute on function stock_in_review(uuid, text) from public, anon;
grant execute on function stock_in_review(uuid, text) to authenticated;

create or replace view po_matching_status with (security_invoker = true) as
select s.po_line_id, s.po_id, p.po_no, p.supplier_id, p.status as po_status, s.line_no, s.product_id,
       s.quantity as ordered_qty, s.received_qty, s.billed_qty,
       greatest(s.received_qty - s.billed_qty, 0) as unbilled_qty,
       greatest(s.billed_qty - s.received_qty, 0) as over_billed_qty,
       round(greatest(s.received_qty - s.billed_qty, 0) * s.unit_price * (1 + s.gst_rate / 100), 2) as unbilled_value,
       (select min(g.received_on) from goods_receipts g where g.po_id = s.po_id) as first_received_on
from po_line_status s join purchase_orders p on p.po_id = s.po_id
where p.status in ('approved', 'part_received', 'received', 'closed');
grant select on po_matching_status to authenticated;
