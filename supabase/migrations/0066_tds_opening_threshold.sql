-- 0066: TDS annual threshold and opening-balance bills.
--
-- Opening-balance bills (0064) still count towards a supplier's financial-year total when testing the annual TDS threshold, but the TDS
-- "catch-up" no longer re-deducts tax on them: those invoices were booked in your old books, where any TDS was dealt with (or is for your
-- CA to adjust). Before this change, entering an opening balance could make the next bill deduct TDS on the whole opening amount.

create or replace function pb_tds(p_supplier uuid, p_bill_date date, p_taxable numeric, p_exclude uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s suppliers%rowtype; t tds_sections%rowtype; v_rate numeric; v_prior numeric; v_prior_base numeric; v_cum numeric; v_base numeric := 0; v_fy date; v_open numeric;
begin
  select * into s from suppliers where supplier_id = p_supplier;
  if s.tds_section is null then return jsonb_build_object('section', null, 'base', 0, 'rate', 0, 'amount', 0); end if;
  select * into t from tds_sections where section = s.tds_section;
  v_rate := coalesce(s.tds_rate_override, t.rate);
  if s.pan is null then v_rate := greatest(v_rate, 20); end if;   -- no PAN: higher rate applies
  v_fy := pur_fy_start(p_bill_date);
  select coalesce(sum(taxable_value), 0), coalesce(sum(tds_base), 0), coalesce(sum(taxable_value) filter (where is_opening), 0) into v_prior, v_prior_base, v_open
    from purchase_bills where supplier_id = p_supplier and status = 'approved' and bill_id is distinct from p_exclude
     and bill_date >= v_fy and bill_date < v_fy + interval '1 year';
  v_cum := v_prior + p_taxable;
  if t.annual_threshold is not null and v_cum >= t.annual_threshold then v_base := v_cum - v_prior_base - v_open;
  elsif t.single_threshold is not null and p_taxable >= t.single_threshold then v_base := p_taxable;
  elsif t.single_threshold is null and t.annual_threshold is null then v_base := p_taxable; end if;
  return jsonb_build_object('section', s.tds_section, 'base', v_base, 'rate', v_rate, 'amount', round(v_base * v_rate / 100, 0));
end $$;
revoke execute on function pb_tds(uuid, date, numeric, uuid) from public, anon, authenticated;
grant execute on function pb_tds(uuid, date, numeric, uuid) to authenticated;

-- housekeeping: the attachment permission helpers are only needed by signed-in users (anonymous visitors cannot see any record through them anyway)
revoke execute on function attachment_parent_visible(text, uuid), can_attach(text, uuid), can_view_attachment(text, uuid), pur_fy_start(date) from public, anon;
grant execute on function attachment_parent_visible(text, uuid), can_attach(text, uuid), can_view_attachment(text, uuid), pur_fy_start(date) to authenticated;
