#!/usr/bin/env python3
"""Part 2 of the demo data: the cost side (rent, utilities, couriers, advertising, payroll, claims, assets) and the tax filings, month by month, with the real dates."""
import os, json, datetime as dt, calendar
from collections import defaultdict
from model import q_, TODAY
from gen_demo import HEAD, gstin, OUT
from helpers_costs import HELPERS2, USERS

HEAD2 = """begin;
select set_config('request.jwt.claims', json_build_object('sub', (select user_id from user_profiles where email = 'amitsdeva@gmail.com'), 'role', 'authenticated')::text, false);
select set_config('demo.t0', clock_timestamp()::text, false);
"""
TAIL2 = """select set_config('app.today', '', false);
commit;
"""

HELPERS3 = r"""
create or replace function pg_temp.courier_bill(p_month date, p_inv text) returns uuid language plpgsql as $f$
declare n_s bigint := pg_temp.month_orders(p_month, 'Shopify%'); n_r bigint := pg_temp.month_orders(p_month, 'Shopify%', 'o.fulfilment_status = ''rto'''); v_lines jsonb := '[]'::jsonb;
begin
  if n_s > 0 then v_lines := v_lines || jsonb_build_object('d', 'Shopify parcels dispatched in ' || to_char(p_month, 'FMMonth YYYY') || ' (' || n_s || ' at Rs 78)', 'h', '996812', 'q', n_s, 'p', 78, 'r', 18, 'l', 'Freight & Courier Charges - Outward'); end if;
  if n_r > 0 then v_lines := v_lines || jsonb_build_object('d', 'Return-to-origin freight, ' || to_char(p_month, 'FMMonth YYYY') || ' (' || n_r || ' at Rs 62)', 'h', '996812', 'q', n_r, 'p', 62, 'r', 18, 'l', 'Reverse Logistics & RTO Charges'); end if;
  if jsonb_array_length(v_lines) = 0 then return null; end if;
  return pg_temp.bill_new('SwiftRoute Couriers Pvt Ltd', p_inv, app_today(), v_lines);
end $f$;

create or replace function pg_temp.fulfil_bill(p_month date, p_inv text) returns uuid language plpgsql as $f$
declare n bigint := pg_temp.month_orders_wh(p_month, 'Mumbai%'); v_lines jsonb;
begin
  v_lines := jsonb_build_array(jsonb_build_object('d', 'Storage and space, Mumbai, ' || to_char(p_month, 'FMMonth YYYY'), 'h', '996729', 'q', 1, 'p', 15000, 'r', 18, 'l', 'Freight & Courier Charges - Outward'));
  if n > 0 then v_lines := v_lines || jsonb_build_object('d', 'Pick, pack and dispatch, ' || to_char(p_month, 'FMMonth YYYY') || ' (' || n || ' orders at Rs 26)', 'h', '996729', 'q', n, 'p', 26, 'r', 18, 'l', 'Freight & Courier Charges - Outward'); end if;
  return pg_temp.bill_new('Mehta Warehousing & Logistics Pvt Ltd', p_inv, app_today(), v_lines);
end $f$;

create or replace function pg_temp.pay_run(p_utr_seed text, p_names text[]) returns void language plpgsql as $f$
declare n text; i int := 0;
begin
  foreach n in array p_names loop i := i + 1; perform pg_temp.pay_sup(n, p_utr_seed || lpad(i::text, 2, '0')); end loop;
end $f$;
"""

# supplier masters: key -> (name, state, PAN, address, bank, IFSC, TDS section, terms, msme)
VEND = {
 "SGE": ("Shree Ganesh Estates", "24", "AAHFS6612D", "Plot 8, Udhna Magdalla Road, Surat, Gujarat 395007", "HDFC Bank", "HDFC0001840", None, 10, False),
 "AWH": ("Andheri Warehouse Holdings LLP", "27", "AAJFA4093K", "Unit 14, Marol Industrial Estate, Andheri East, Mumbai, Maharashtra 400059", "ICICI Bank", "ICIC0000118", None, 10, False),
 "DGV": ("Dakshin Gujarat Vij Company Ltd", "24", "AABCD1277F", "Nana Varachha Sub-division, Surat, Gujarat 395006", "State Bank of India", "SBIN0000304", None, 15, False),
 "ANB": ("Airnet Broadband Pvt Ltd", "24", "AACCA8841M", "3rd Floor, Parle Point, Surat, Gujarat 395007", "Axis Bank", "UTIB0000041", None, 15, False),
 "CKS": ("CloudKart Software Services LLP", "29", "AAKFC3052P", "Koramangala 5th Block, Bengaluru, Karnataka 560095", "HDFC Bank", "HDFC0000053", "194J-TEC", 15, False),
 "MWL": ("Mehta Warehousing & Logistics Pvt Ltd", "27", "AAECM5576B", "Bhiwandi Logistics Park, Thane, Maharashtra 421302", "Kotak Mahindra Bank", "KKBK0001371", "194C-OTH", 15, False),
 "SRC": ("SwiftRoute Couriers Pvt Ltd", "24", "AAGCS9021Q", "Sachin GIDC Road, Surat, Gujarat 394230", "Axis Bank", "UTIB0001166", "194C-OTH", 15, False),
 "ABD": ("AdBoost Digital Media Pvt Ltd", "27", "AABCA2290T", "Lower Parel, Mumbai, Maharashtra 400013", "ICICI Bank", "ICIC0000648", "194C-OTH", 20, False),
 "KAC": ("Kothari & Associates", "24", "AAGFK7719N", "Athwa Lines, Surat, Gujarat 395001", "State Bank of India", "SBIN0001552", "194J-PRO", 15, False),
 "DPC": ("Digital Planet Computers", "24", "AAJFD5504L", "Ring Road, Surat, Gujarat 395002", "HDFC Bank", "HDFC0000412", None, 7, False),
 "SOM": ("Surat Office Mart", "24", "AAPFS8836R", "Varachha Main Road, Surat, Gujarat 395006", "Bank of Baroda", "BARB0VARACH", None, 7, False),
 "GPI": ("Gujarat Pack Industries", "24", "AAECG6628A", "Pandesara GIDC, Surat, Gujarat 394221", "State Bank of India", "SBIN0003451", None, 15, True),
}
NAME = {k: v[0] for k, v in VEND.items()}

STAFF = [  # name, gender, dob, doj, designation, dept, pan, basic, da, hra, other, leave open, bank, ifsc
 ("Vikram Rao", "male", "1993-03-14", "2023-06-12", "Accountant", "Finance", "AKQPR4417L", 14500, 0, 5500, 4000, 9, "HDFC Bank", "HDFC0001840"),
 ("Kavita Desai", "female", "1990-08-02", "2022-02-01", "Warehouse Manager", "Operations", "BDRPD2291C", 15000, 0, 6000, 4000, 11, "State Bank of India", "SBIN0000304"),
 ("Rajesh Patel", "male", "1998-11-21", "2024-01-15", "Packer", "Operations", "CFTPP8830E", 9000, 0, 3000, 1500, 7, "Bank of Baroda", "BARB0VARACH"),
 ("Sunita Yadav", "female", "1996-05-09", "2024-08-05", "Packer", "Operations", "DKLPY5521N", 8500, 0, 3000, 1500, 6, "State Bank of India", "SBIN0001552"),
 ("Imran Qureshi", "male", "1999-01-30", "2025-06-02", "Packer", "Operations", "EQRPQ7745B", 9000, 0, 3000, 1500, 4, "Axis Bank", "UTIB0000041"),
]
NEHA = ("Neha Joshi", "female", "2001-09-17", "2026-07-15", "Catalogue and Listing Executive", "Marketplace", "FJSPJ3318H", 10500, 0, 4000, 2500, 0, "HDFC Bank", "HDFC0000412")

def emp_json(s, n):
    name, g, dob, doj, des, dep, pan, b, da, hra, oth, lv, bank, ifsc = s
    d = {"name": name, "gender": g, "date_of_birth": dob, "date_of_joining": doj, "designation": des, "department": dep, "pan": pan,
         "uan": "1012%08d" % (34500000 + n * 7311), "email": name.split()[0].lower() + "@superseller360.demo", "phone": "98250%05d" % (11000 + n * 137),
         "basic": b, "da": da, "hra": hra, "other": oth, "leave_open": lv, "bank": bank, "ifsc": ifsc, "account": "%014d" % (50100000000000 + n * 91007321), "regime": "new"}
    if b + da + hra + oth <= 21000: d["esic_no"] = "3100%09d" % (21000000 + n * 1319)
    return d

ev = defaultdict(list)
def at(d, sql): ev[d].append(sql)
_u = [0]
def utr(d):
    _u[0] += 1
    return "HDFCN%s%03d" % (d.strftime("%y%m%d"), _u[0])
def paying(d, keys, seed=None):
    at(d, "select pg_temp.pay_run(%s, array[%s]);" % (q_("HDFCN%s" % d.strftime("%y%m%d")), ",".join(q_(NAME[k]) for k in keys)))
def bill(d, key, inv, lines):
    at(d, "select pg_temp.bill_new(%s, %s, %s, %s::jsonb);" % (q_(NAME[key]), q_(inv), q_(str(d)), q_(json.dumps(lines))))
def line(desc, hsn, p, rate, ledger, qty=1): return {"d": desc, "h": hsn, "q": qty, "p": p, "r": rate, "l": ledger}

def setup_sql():
    out = ["-- 20_setup.sql - part 2, the cost side: the people on the payroll, the rent / utility / courier / advertising / professional suppliers.", HEAD2,
           "select set_config('app.today', '2026-04-01', false);", HELPERS2, HELPERS3]
    for key, (name, st, pan, addr, bank, ifsc, tds, terms, msme) in VEND.items():
        i = list(VEND).index(key)
        j = {"name": name, "gstin": gstin(st, pan), "state_code": st, "payment_terms_days": terms, "is_msme": msme, "phone": "98250%05d" % (30000 + i * 913),
             "email": "accounts@%s.example.com" % key.lower(), "address": addr, "bank_name": bank, "ifsc": ifsc, "account_number": "%012d" % (60100000000 + i * 8467031), "account_holder": name}
        if tds: j["tds_section"] = tds
        out.append("select pg_temp.sup_new(%s::jsonb);" % q_(json.dumps(j)))
    for n, s in enumerate(STAFF, 1):
        out.append("select pg_temp.emp_new(%s::jsonb);" % q_(json.dumps(emp_json(s, n))))
    out.append(TAIL2)
    return "\n".join(out)

def build_calendar():
    ads = {4: 16000, 5: 18000, 6: 20000, 7: 22000, 8: 26000, 9: 30000}
    elec = {5: 9200, 6: 10800, 7: 11600, 8: 11200, 9: 10400}
    pack = {4: 6200, 5: 7400, 6: 8800, 7: 9600, 8: 11800, 9: 15400, 10: 0}
    seqs = defaultdict(int)
    def inv(k, d): seqs[k] += 1; return "%s/%s/%03d" % (k, d.strftime("%y%m"), seqs[k])
    for M in range(4, 11):
        f = dt.date(2026, M, 1)
        ld = dt.date(2026, M, calendar.monthrange(2026, M)[1])
        mon = f.strftime("%B %Y")
        pm = (f - dt.timedelta(days=1)).replace(day=1)
        pper = pm.strftime("%Y-%m")
        D = lambda n: dt.date(2026, M, n)
        # rent
        bill(D(1), "SGE", inv("SGE", f), [line("Warehouse rent, Surat, " + mon, "997212", 30000, 18, "Rent")])
        bill(D(1), "AWH", inv("AWH", f), [line("Fulfilment centre rent, Mumbai, " + mon, "997212", 12000, 18, "Rent")])
        paying(D(5), ["SGE", "AWH"])
        if M >= 5:
            at(D(2), "select pg_temp.payroll_pay(%s);" % q_(str(pm)))
            at(D(3), "select pg_temp.fulfil_bill(%s, %s);" % (q_(str(pm)), q_(inv("MWL", D(3)))))
            at(D(3), "select pg_temp.courier_bill(%s, %s);" % (q_(str(pm)), q_(inv("SRC", D(3)))))
            if M != 9: at(D(7), "select pg_temp.tds_deposit(%s);" % q_(pper))
            else: at(D(12), "select pg_temp.tds_deposit('2026-08', 1);")   # August's deposit is made late, on 12 September, with a month's interest
        # packing material
        if pack[M]:
            bill(D(8), "GPI", inv("GPI", D(8)), [line("Cartons, poly mailers and tape, " + mon, "4819", pack[M], 18, "Packaging Materials Consumed")])
        if M >= 5 and M != 10:
            bill(D(10), "DGV", inv("DGV", D(10)), [line("Electricity, Surat warehouse, " + pm.strftime("%B %Y"), "997142", elec[M - 1] if (M - 1) in elec else 9200, 0, "Electricity & Utilities")])
        if M == 10:
            bill(D(4), "DGV", inv("DGV", D(4)), [line("Electricity, Surat warehouse, September 2026", "997142", elec[9], 0, "Electricity & Utilities")])
        if M <= 9:
            bill(D(12), "CKS", inv("CKS", D(12)), [line("Store apps and cloud tools, " + mon, "998314", 7500, 18, "Software & Subscriptions")])
            bill(D(14), "ANB", inv("ANB", D(14)), [line("Leased-line internet, " + mon, "998411", 4200, 18, "Telephone & Internet")])
        if 5 <= M <= 9:
            at(D(11), "select pg_temp.gst_file(%s, 'GSTR1');" % q_(pper))
            at(D(12), "select pg_temp.mtax_credits(%s%s);" % (q_(str(pm)), {6: ", 1850", 9: ", 0, true"}.get(M, "")))   # June: Flipkart credit short by 1,850; September: Amazon income-tax credit not yet in Form 26AS
            extra = "'[]'::jsonb"
            skip = "'{}'::text[]"
            if M == 6: extra = "jsonb_build_array(jsonb_build_object('gstin', %s, 'name', 'Vasant Trims and Laces', 'type', 'invoice', 'doc_no', 'VTL/2204', 'doc_date', '2026-05-22', 'taxable', 4200, 'igst', 0, 'cgst', 378, 'sgst', 378, 'itc_available', true))" % q_(gstin("24", "AAFPV3310E"))
            if M == 8: skip = "array[%s]" % q_("CKS/2607/001")
            at(D(14), "select pg_temp.gstr2b_load(%s, %s, %s);" % (q_(pper), skip, extra))
            at(D(15), "select pg_temp.payroll_remit_all(%s);" % q_(str(pm)))
        if M >= 5 and M <= 9:
            paying(D(18), ["DGV", "MWL", "SRC"])
            at(D(20), "select pg_temp.gst_setoff(%s);" % q_(pper))
            at(D(20), "select pg_temp.gst_file(%s, 'GSTR3B');" % q_(pper))
            paying(D(22), ["CKS", "ANB", "ABD", "KAC"])
            paying(D(25), ["GPI"])
        if M <= 9:
            bill(ld, "ABD", inv("ABD", ld), [line("Marketplace and social advertising management, " + mon, "998361", ads[M], 18, "Advertising & Promotion")])
            bill(ld, "KAC", inv("KAC", ld), [line("Monthly accounts and compliance retainer, " + mon, "998221", 8000, 18, "Professional & Audit Fees")])
            lop = {6: {"Rajesh Patel": 2}}.get(M, {})
            at(ld, "select pg_temp.payroll_close(%s::jsonb);" % q_(json.dumps(lop)))
            at(ld, "select asset_depreciate_month(%s);" % q_(str(f)))
            at(ld, "select pg_temp.bank_charge('hdfc', 590, 'Account maintenance and cheque charges');")
            at(ld, "select pg_temp.bank_charge('icici', 1180, 'Collection, RTGS and SMS charges');")
    # ------------------------------------------------------------------ one-offs
    d = dt.date(2026, 4, 6)
    at(d, "do $x$ declare b uuid; begin b := pg_temp.bill_new(%s, 'DPC/2604/118', '2026-04-06', %s::jsonb); perform pg_temp.asset_new('Laptop - Accounts desk', 'Computers & IT Equipment', b, 50000); perform pg_temp.asset_new('Laptop - Operations desk', 'Computers & IT Equipment', b, 50000); end $x$;"
       % (q_(NAME["DPC"]), q_(json.dumps([line("Business laptops, 15-inch, 16 GB (2 units)", "8471", 50000, 18, "Computers & IT Equipment", 2)]))))
    paying(dt.date(2026, 4, 10), ["DPC"])
    at(dt.date(2026, 5, 12), "do $x$ declare b uuid; begin b := pg_temp.bill_new(%s, 'SOM/2605/041', '2026-05-12', %s::jsonb); perform pg_temp.asset_new('Packing tables and storage racks', 'Furniture & Fixtures', b, 85000); end $x$;"
       % (q_(NAME["SOM"]), q_(json.dumps([line("Packing tables and steel storage racks", "9403", 85000, 18, "Furniture & Fixtures")]))))
    paying(dt.date(2026, 5, 20), ["SOM"])
    at(dt.date(2026, 6, 20), "do $x$ declare b uuid; begin b := pg_temp.bill_new(%s, 'DPC/2606/204', '2026-06-20', %s::jsonb); perform pg_temp.asset_new('Barcode label printer', 'Office Equipment', b, 32000); end $x$;"
       % (q_(NAME["DPC"]), q_(json.dumps([line("Thermal barcode label printer", "8443", 32000, 18, "Office Equipment")]))))
    paying(dt.date(2026, 6, 28), ["DPC"])
    at(dt.date(2026, 8, 18), "do $x$ declare b uuid; begin b := pg_temp.bill_new(%s, 'GPI/2608/017', '2026-08-18', %s::jsonb); perform pg_temp.asset_new('Heat sealing and strapping machine', 'Plant & Machinery', b, 48000, 'Mumbai Fulfilment Center'); end $x$;"
       % (q_(NAME["GPI"]), q_(json.dumps([line("Heat sealing and strapping machine", "8422", 48000, 18, "Plant & Machinery")]))))
    paying(dt.date(2026, 8, 28), ["GPI"])
    d = dt.date(2026, 9, 20)
    bill(d, "KAC", "KAC/2609/AUD", [line("Tax audit preparation and ITR advisory, FY 2025-26", "998221", 60000, 18, "Professional & Audit Fees")])
    # people: new joiner, leave, an exit and the final settlement, the bonus
    at(dt.date(2026, 7, 14), "select pg_temp.emp_new(%s::jsonb);" % q_(json.dumps(emp_json(NEHA, 7))))
    for (n, days, d, note) in [("Sunita Yadav", 2, dt.date(2026, 6, 12), "Family function"), ("Imran Qureshi", 1, dt.date(2026, 7, 25), "Personal"),
                               ("Kavita Desai", 1, dt.date(2026, 7, 10), "Medical appointment"), ("Vikram Rao", 3, dt.date(2026, 8, 21), "Out of town")]:
        at(d, "select pg_temp.leave_take(%s, %s, %s, %s);" % (q_(n), days, q_(str(d)), q_(note)))
    at(dt.date(2026, 8, 31), "select employee_exit((select emp_id from employees where name = 'Imran Qureshi'), '2026-08-31');")
    at(dt.date(2026, 9, 5), """do $x$ declare v uuid; v_net numeric; begin
  perform pg_temp.as_user('acc');
  v := fnf_save(null, (select emp_id from employees where name = 'Imran Qureshi'), '{"last_day":"2026-08-31","salary_days":0,"note":"Resigned, notice served"}'::jsonb);
  perform pg_temp.as_user('fin'); perform fnf_approve(v);
  select net into v_net from fnf_settlements where fnf_id = v;
  perform pg_temp.fund_hdfc(v_net + 25000);
  perform pg_temp.as_user('acc'); perform fnf_pay(v, pg_temp.hdfc(), app_today());
  perform pg_temp.bline(pg_temp.hdfc(), 'NEFT/FNF/IMRAN QURESHI', v_net, 'debit');
end $x$;""")
    at(dt.date(2026, 10, 2), "select pg_temp.as_user('acc'); select bonus_create(2026);")
    at(dt.date(2026, 10, 3), "select pg_temp.bill_new(%s, 'GPI/2610/001', '2026-10-03', %s::jsonb, false);"   # waiting for the Finance Manager
       % (q_(NAME["GPI"]), q_(json.dumps([line("Cartons, poly mailers and tape, October 2026", "4819", 9800, 18, "Packaging Materials Consumed")]))))
    # staff expense claims (receipts are placeholder attachment rows)
    def claim(d, who, title, lines, **kw):
        a = ", ".join("%s => %s" % (k, ("%s" % (q_(v) if isinstance(v, str) else str(v).lower()))) for k, v in kw.items())
        at(d, "select pg_temp.claim_new(%s, %s, %s::jsonb%s);" % (q_(who), q_(title), q_(json.dumps([{"date": str(d), "cat": c, "desc": t, "amt": a_} for c, t, a_ in lines])), (", " + a) if a else ""))
    claim(dt.date(2026, 4, 18), "wh", "Packing tape and local transport", [("PACKING", "Packing tape and bubble wrap, local shop", 1850), ("TRAVEL", "Auto to Sachin GIDC for pickup", 640)])
    claim(dt.date(2026, 5, 25), "mkt", "Product shoot props", [("COURIER", "Samples couriered to photographer", 1200), ("OTHER", "Props and backdrop for the shoot", 3400)])
    claim(dt.date(2026, 6, 22), "ops", "Mumbai fulfilment centre visit", [("TRAVEL", "Train and cab, Surat to Mumbai and back", 6800), ("FOOD", "Meals during the visit", 1150)], p_rev="sa")
    claim(dt.date(2026, 7, 18), "wh", "Warehouse repairs", [("REPAIR", "Shutter lock and shelf repairs", 4200)])
    claim(dt.date(2026, 8, 24), "mkt", "Client lunch", [("FOOD", "Lunch with a prospective supplier", 2600)], p_review="reject")
    claim(dt.date(2026, 9, 9), "wh", "Stationery for the warehouse", [("STATION", "Registers, labels and pens", 1320)], p_final="wait")
    claim(dt.date(2026, 9, 28), "ops", "Phone and data recharge", [("PHONE", "Mobile data pack for fulfilment calls", 1499)], p_review="wait")
    claim(dt.date(2026, 10, 2), "tax", "GST seminar, Delhi", [("TRAVEL", "Flight and cab to the seminar", 7400)], p_submit=False)

def month_files():
    cal = defaultdict(list)
    for d in sorted(ev):
        if d <= TODAY: cal[(d.year, d.month)].append(d)
    files = []
    for (y, m), days in sorted(cal.items()):
        name = "%02d_%s.sql" % (20 + m - 3, dt.date(y, m, 1).strftime("%b%y").replace("Apr26", "Apr26"))
        body = ["-- %s - %s: rent and bills, payroll, taxes and bank entries, day by day." % (name, dt.date(y, m, 1).strftime("%B %Y")), HEAD2, HELPERS2, HELPERS3]
        for d in days:
            body.append("select pg_temp.day(%s);" % q_(str(d)))
            body.extend(ev[d])
            body.append("select pg_temp.retime();")
        body.append(TAIL2)
        files.append((name, "\n".join(body)))
    return files

def finish_sql():
    return """-- 29_finish.sql - the Finance Manager goes through the hand-written journal entries posted this half-year and marks them checked; the last few stay in the queue.
%s
select set_config('request.jwt.claims', json_build_object('sub', (select user_id from user_profiles where email = '%s'), 'role', 'authenticated')::text, false);
select journal_review_set(r.voucher_id, 'ok', 'Checked against the bank statement')
  from (select jr.voucher_id from journal_review jr join vouchers v on v.voucher_id = jr.voucher_id where jr.status = 'pending' and jr.created_by is distinct from auth.uid() order by v.voucher_date desc, v.voucher_no desc offset 4) r;
%s""" % (HEAD2, USERS["fin"], TAIL2)

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build_calendar()
    allf = [("20_setup.sql", setup_sql())] + month_files() + [("29_finish.sql", finish_sql())]
    for n, t in allf:
        open(os.path.join(OUT, n), "w").write(t)
        print(n, len(t) // 1024, "KB")
