#!/usr/bin/env python3
"""Writes the demo SQL files into supabase/demo/ from the story in model.py."""
import os, datetime as dt, itertools
import model as m
from model import q_, events, orders, by_day, SUPPLIERS, OPENING, TODAY
from catalogue import PBY
from helpers_sql import HELPERS
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "demo")
SA = "2911a288-1727-4d24-869d-06ba96fc8ffa"

HEAD = """begin;
select set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, false);
select set_config('demo.self_ok', (select allow_self_approval::text from purchase_settings where id = 1), false);
update purchase_settings set allow_self_approval = true where id = 1;
select set_config('demo.t0', clock_timestamp()::text, false);
""" % SA
TAIL = """update purchase_settings set allow_self_approval = coalesce(nullif(current_setting('demo.self_ok', true), '')::boolean, false) where id = 1;
select set_config('app.today', '', false);
commit;
"""
def vals(rows): return ",\n".join(rows)

def orders_sql(lst):
    o_rows, l_rows, c_rows = [], [], []
    for o in lst:
        fs = {"rto": "shipped"}.get(o.status, o.status)
        ts = "%s %02d:%02d+05:30" % (o.date.isoformat(), o.hour, o.minute)
        o_rows.append("(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)" % (q_(o.ext), q_(m.CHANNELS[o.ch]), q_(ts), q_(o.cust), q_("cod" if o.cod else "prepaid"),
                      o.gross, o.disc, o.tax, o.net, q_(fs), q_(o.pay), q_(o.state), q_(o.wh)))
        for l in o.lines: l_rows.append("(%s,%s,%d,%s,%s,%s)" % (q_(o.ext), q_(l["sku"]), l["qty"], l["up"], l["disc"], l["tax"]))
        if o.cod and o.status in ("shipped", "delivered"): c_rows.append("(%s,%s)" % (q_(o.ext), q_(o.courier)))
    s = ["set constraints all deferred;",
         "insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state, warehouse_id, created_at)\n"
         "select v.ext, c.channel_id, v.od::timestamptz, v.cust, v.pt, v.g, v.d, v.t, v.n, v.fs, v.ps, v.st, w.warehouse_id, v.od::timestamptz from (values\n" + vals(o_rows) +
         "\n) v(ext, ch, od, cust, pt, g, d, t, n, fs, ps, st, wh) join channels c on c.name = v.ch join warehouses w on w.name = v.wh;",
         "insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)\nselect o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values\n" + vals(l_rows) +
         "\n) v(ext, sku, q, up, d, t) join orders o on o.external_order_id = v.ext join products p on p.sku = v.sku;",
         "set constraints all immediate;"]
    if c_rows:
        s.append("insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, created_at)\n"
                 "select o.order_id, v.cr, o.net_amount, 0, 0, 'pending', o.order_date from (values\n" + vals(c_rows) + "\n) v(ext, cr) join orders o on o.external_order_id = v.ext;")
    return "\n".join(s)

def month_files(limit=100_000):
    """One file per stretch of days, each small enough to run comfortably in the SQL editor."""
    days = sorted(set(events) | set(by_day))
    day_text = []
    for d in days:
        t = [f"\n-- {d:%a %d %b %Y}\nselect pg_temp.day('{d.isoformat()}');"]
        placed = False
        for prio, sql in sorted(events.get(d, []), key=lambda e: e[0]):
            if not placed and prio > m.P_ORDER and by_day.get(d):
                t.append(orders_sql(by_day[d])); placed = True
            t.append(sql)
        if not placed and by_day.get(d): t.append(orders_sql(by_day[d]))
        t.append("select pg_temp.retime();")
        day_text.append((d, "\n".join(t)))
    chunks, cur, size = [], [], 0
    for d, t in day_text:
        if cur and size + len(t) > limit: chunks.append(cur); cur, size = [], 0
        cur.append((d, t)); size += len(t)
    if cur: chunks.append(cur)
    files = []
    for ch in chunks:
        a, z = ch[0][0], ch[-1][0]
        name = f"{a:%b}{a.day:02d}-{z:%b}{z.day:02d}"
        head = (f"-- {a:%d %b} to {z:%d %b %Y}: orders, stock movements, purchases, collections, returns, settlements and payments, one day at a time.\n"
                f"-- Each day is posted as of that day (the books are dated by the event, not by when this file runs).")
        files.append((name, "\n".join([head, HEAD, HELPERS] + [t for _, t in ch] + [TAIL])))
    return files

# ------------------------------------------------------------------ reset
RESET_TABLES = """accounting_periods opening_balances vouchers voucher_lines journal_entries journal_review journal_rule_log invoices credit_notes einvoice_records
orders order_lines order_dispatch order_status_history shipments cod_collections returns rtos claims settlements settlement_lines settlement_fee_dismissals
bank_transactions bank_recon_matches bank_recon_suggestions bank_recon_book_exclusions inventory_transactions inventory_balances automation_issues marketplace_credit_entries
supplier_credit_notes supplier_payments payment_allocations payment_runs payment_run_items purchase_orders purchase_order_lines goods_receipts goods_receipt_lines
purchase_bills purchase_bill_lines tds_challans gst_filings gstr2b_uploads gstr2b_lines gst_itc_adjustments tax_transactions employees employee_bank employee_declarations employee_salary
payroll_runs payroll_lines payroll_remittances bonus_runs bonus_lines fnf_settlements leave_entries expense_claims expense_claim_lines fixed_assets asset_depreciation
recurring_journal_runs cash_movements cash_plan_items cash_settlement_reports cash_settlement_report_lines notifications message_outbox import_runs import_run_rows attachments
compliance_filings job_runs connector_log channel_sku_map rate_change_log role_preview""".split()

def reset_sql():
    return f"""-- 00_reset.sql - clears the demo TRANSACTIONS so the story can be loaded cleanly.
-- Keeps: users and roles, company, channels, warehouses, bank accounts, products, ledgers and account groups, the Rule Book, tax and statutory settings, connection settings.
-- Removes: orders, invoices, vouchers and journals, stock movements, returns, RTOs, COD, settlements, bank lines, purchases, payroll, assets, filings, accounting periods.
begin;
truncate table {", ".join(RESET_TABLES)} restart identity cascade;
-- suppliers are removed one by one (not truncated) so the product catalogue that points to a preferred supplier is kept
update products set preferred_supplier_id = null where preferred_supplier_id is not null;
delete from supplier_bank;
delete from suppliers;
update ledgers set opening_balance = 0, opening_balance_type = null;
-- document numbers start again from 1
do $$ declare s record; begin
  for s in select c.relname from pg_class c where c.relkind = 'S' and c.relnamespace = 'public'::regnamespace
            and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype in ('a', 'i')) loop
    execute format('alter sequence public.%I restart', s.relname);
  end loop;
end $$;
commit;
"""

# ------------------------------------------------------------------ opening position
CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
def gstin(state, pan):
    g = state + pan + "1Z"
    t = 0
    for i, c in enumerate(g, 1):
        pr = CHARS.index(c) * (1 if i % 2 else 2); t += pr // 36 + pr % 36
    return g + CHARS[(36 - t % 36) % 36]
SUP_INFO = {  # key: (PAN, city address, bank, IFSC, phone, msme)
 "SAT": ("AAKFS4418M", "Plot 41, Ring Road Textile Market, Surat, Gujarat 395002", "State Bank of India", "SBIN0060128", "9825011401", True),
 "TKF": ("AABCT7712K", "12/4 Kangeyam Road, Tiruppur, Tamil Nadu 641604", "Indian Bank", "IDIB000T045", "9443022133", False),
 "LWW": ("AAHFL2290P", "B-77 Focal Point Phase V, Ludhiana, Punjab 141010", "Punjab National Bank", "PUNB0412300", "9815066782", False),
 "KDW": ("AADFK5531R", "Unit 9, Narol Industrial Estate, Ahmedabad, Gujarat 382405", "Bank of Baroda", "BARB0NAROLX", "9825099410", True),
 "RSM": ("AAFCR8845E", "Gala 6, Dharavi Garment Hub, Mumbai, Maharashtra 400017", "HDFC Bank", "HDFC0000311", "9820012288", False),
 "LSG": ("AAJFL1176Q", "Shop 18, Sachin GIDC Road, Surat, Gujarat 394230", "Kotak Mahindra Bank", "KKBK0002451", "9712033655", True),
}
def opening_sql():
    out = ["-- 02_opening.sql - the financial year, supplier masters, the opening balance sheet and the opening stock, all as on 1 April 2026.", HEAD,
           "select set_config('app.today', '2026-04-01', false);",
           "select create_financial_year(2026);",
           "-- Shopify pays out weekly",
           "update channels set settlement_cycle = 'Weekly' where name like 'Shopify%';"]
    for i, (key, name, st, city, terms, styles) in enumerate(SUPPLIERS):
        pan, addr, bank, ifsc, phone, msme = SUP_INFO[key]
        acct = "%012d" % (40100000000 + i * 7919003)
        out.append("select supplier_decide(supplier_save(null, %s::jsonb), 'approve');" % q_(
            '{"name":"%s","gstin":"%s","state_code":"%s","payment_terms_days":%d,"is_msme":%s,"phone":"%s","email":"accounts@%s.example.com","address":"%s","bank_name":"%s","ifsc":"%s","account_number":"%s","account_holder":"%s"}'
            % (name, gstin(st, pan), st, terms, str(msme).lower(), phone, key.lower(), addr, bank, ifsc, acct, name)))
    out.append("""-- opening balance sheet: cash and bank, with the balancing figure in Retained Earnings (the opening stock is added to it below)
select import_run('ledger_opening', '[{"ledger":"Bank - ICICI Bank (7734)","debit":550000},{"ledger":"Bank - HDFC Bank (4821)","debit":250000},{"ledger":"Cash in Hand","debit":40000},{"ledger":"Retained Earnings","credit":840000}]'::jsonb, true,
  jsonb_build_object('financial_year', (select financial_year_id from accounting_periods order by start_date limit 1)), 'demo opening balances', null);""")
    rows = ["(%s,%s,%d)" % (q_(sku), q_(wh), qty) for (sku, wh), qty in sorted(OPENING.items())]
    out.append("-- opening stock by warehouse (the stock-keeping side)\nselect record_inventory_movement(p.product_id, w.warehouse_id, 'initial_stock', v.q, 'opening', null) from (values\n" + ",\n".join(rows) +
               "\n) v(sku, wh, q) join products p on p.sku = v.sku join warehouses w on w.name = v.wh;")
    out.append("""update inventory_transactions set created_at = '2026-04-01 09:00+05:30' where movement_type = 'initial_stock';
-- the accounting side of that stock: one entry at cost, against Retained Earnings. The stock rules switch on after this, so every later movement posts itself.
select acc_post_journal('2026-04-01', 'Opening stock at cost as on 1 April 2026', jsonb_build_array(
  jsonb_build_object('ledger_id', (select ledger_id from ledgers where name = 'Inventory - Stock-in-Trade'), 'debit', (select round(sum(b.quantity * p.cost_price), 2) from inventory_balances b join products p using (product_id)), 'credit', 0),
  jsonb_build_object('ledger_id', (select ledger_id from ledgers where name = 'Retained Earnings'), 'debit', 0, 'credit', (select round(sum(b.quantity * p.cost_price), 2) from inventory_balances b join products p using (product_id)))),
  'opening', null, 'posted', auth.uid());
select set_journal_pack_status('inventory_cogs', 'active');""")
    out.append(TAIL)
    return "\n".join(out)

def finish_sql():
    offs = []
    for o in orders:
        if o.status == "delivered": offs.append("(%s,'d',%d)" % (q_(o.ext), (o.deliv - o.date).days))
        elif o.status == "rto": offs.append("(%s,'r',%d)" % (q_(o.ext), (o.rto["a0"] - o.date).days))
    return f"""-- 90_finish.sql - the order timeline (pending > processing > shipped > delivered / returned to origin / cancelled) with the real dates.
{HEAD}
delete from order_status_history;
with off(ext, k, n) as (values
{",".join(offs)}
), st as (
  select o.order_id, o.order_date, o.fulfilment_status fs, o.payment_status ps, o.payment_type pt, off.k, off.n,
         exists (select 1 from automation_issues a where a.entity_id = o.order_id and a.kind = 'cancelled_after_dispatch') cad
  from orders o left join off on off.ext = o.external_order_id
)
insert into order_status_history (order_id, fulfilment_status, payment_status, changed_at, changed_by)
select st.order_id, h.fs, h.ps, h.at, null
from st cross join lateral (values
  ('pending',    case when st.pt = 'prepaid' and st.fs <> 'pending' and st.fs <> 'cancelled' then 'paid' else 'pending' end, st.order_date, true),
  ('processing', case when st.pt = 'prepaid' then 'paid' else 'pending' end, st.order_date + interval '6 hours', st.fs in ('processing', 'shipped', 'delivered', 'rto') or st.cad),
  ('shipped',    case when st.pt = 'prepaid' then 'paid' else 'pending' end, st.order_date + interval '30 hours', st.fs in ('shipped', 'delivered', 'rto') or st.cad),
  ('delivered',  st.ps, st.order_date + (st.n || ' days')::interval + interval '3 hours', st.fs = 'delivered'),
  ('rto',        st.ps, st.order_date + (st.n || ' days')::interval, st.fs = 'rto'),
  ('cancelled',  st.ps, st.order_date + case when st.cad then interval '1 day' else interval '5 hours' end, st.fs = 'cancelled')
) h(fs, ps, at, keep) where h.keep;
{TAIL}"""

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "02_opening.sql"), "w").write(opening_sql())
    open(os.path.join(OUT, "90_finish.sql"), "w").write(finish_sql())
    open(os.path.join(OUT, "00_reset.sql"), "w").write(reset_sql())
    os.makedirs(OUT, exist_ok=True)
    import glob
    for old in glob.glob(os.path.join(OUT, "1[0-9]_*.sql")): os.remove(old)
    for i, (nm, text) in enumerate(month_files()):
        name = f"{10 + i}_{nm}.sql"
        open(os.path.join(OUT, name), "w").write(text)
        print(name, len(text) // 1024, "KB")
