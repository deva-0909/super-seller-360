#!/usr/bin/env python3
"""
Generates the garment-retail demo dataset for Super Seller 360°.

Outputs (deterministic, seed=360):
  supabase/migrations/0045_seed_garment_catalogue.sql   (periods, SKUs, channel listings)
  supabase/migrations/0046_seed_garment_transactions.sql (stock, orders, invoices, returns,
                                                          RTO, COD, settlements, claims, credit notes)

GST: apparel & clothing — 5% where sale value per piece <= Rs 2,500, 18% above.
Interstate (ship_to_state != Gujarat) -> IGST; intrastate -> CGST+SGST (handled by post_sales_voucher).
"""
import random, json, datetime as dt, os

R = random.Random(360)
OUT = os.path.join(os.path.dirname(__file__), "..", "migrations")
SA = "2911a288-1727-4d24-869d-06ba96fc8ffa"        # Super Admin (acts as poster)
CLAIMS_OWNER = "f08a6962-1e79-4a95-85a8-e59910ebdaff"
WH_SURAT = "cbbf5d13-e7e0-450d-bb37-6e5f09e82f4e"
WH_MUM = "721474ad-510d-43e5-b0f1-b41149b4275a"
CH = {"SHOP": "91c52e15-376f-4a85-b900-10113f695ce3",
      "AMAZ": "b9f37f58-411a-4b8e-a07f-69b3a302187e",
      "FLIP": "839765d6-e205-405d-af6c-3079174d2fd0"}
BANK_CUR = "d49edd6e-b260-4a23-b8d5-deac2ee71c20"
BANK_COL = "ddd25939-a85f-40ed-9751-77c4de11082c"

def q(s):
    return "null" if s is None else "'" + str(s).replace("'", "''") + "'"

# ---------------------------------------------------------------- catalogue
MEN_SZ = ["S", "M", "L", "XL"]
WOM_SZ = ["S", "M", "L", "XL"]
KID_SZ = ["4-5Y", "6-7Y", "8-9Y", "10-11Y"]
# (code, name, category, brand, hsn, cost, price_ex_tax, colours[(code,name)], sizes)
STYLES = [
 # ---- MEN (40)
 ("MTEE","Men Round Neck Cotton T-Shirt","Men - T-Shirts","UrbanLoom","610910",160,449,[("BLK","Black"),("WHT","White")],["M","L","XL"]),
 ("MPOL","Men Pique Polo T-Shirt","Men - T-Shirts","UrbanLoom","610510",250,699,[("NVY","Navy"),("MRN","Maroon")],["M","L","XL"]),
 ("MSHF","Men Formal Cotton Shirt","Men - Shirts","UrbanLoom","620520",340,999,[("WHT","White"),("SKY","Sky Blue")],["M","L","XL"]),
 ("MSHC","Men Casual Checked Shirt","Men - Shirts","UrbanLoom","620520",320,899,[("RED","Red Check"),("GRN","Green Check")],["M","L","XL"]),
 ("MJNS","Men Slim Fit Denim Jeans","Men - Bottomwear","UrbanLoom","620342",480,1399,[("IND","Indigo"),("BLK","Black")],["30","32","34"]),
 ("MCHN","Men Stretch Chinos","Men - Bottomwear","UrbanLoom","620342",420,1199,[("KHK","Khaki"),("OLV","Olive")],["30","32","34"]),
 ("MHOD","Men Fleece Hoodie","Men - Winterwear","UrbanLoom","611020",450,1299,[("GRY","Grey"),("BLK","Black")],["M","L","XL"]),
 ("MKUR","Men Cotton Kurta","Men - Ethnic","UrbanLoom","621139",380,1099,[("MUS","Mustard"),("WHT","White")],["M","L","XL"]),
 ("MBLZ","Men Tailored Blazer","Men - Formal","UrbanLoom","620311",1750,3799,[("NVY","Navy")],["38","40","42"]),
 ("MTRK","Men Track Pants","Men - Activewear","UrbanLoom","611030",230,649,[("BLK","Black")],["M","L","XL"]),
 # ---- WOMEN (40)
 ("WKRT","Women Printed Cotton Kurti","Women - Ethnic","Anaya","620440",290,849,[("PNK","Pink"),("TEL","Teal")],["S","M","L","XL"]),
 ("WLEG","Women Churidar Leggings","Women - Bottomwear","Anaya","610469",120,349,[("BLK","Black"),("MAR","Maroon"),("NVY","Navy")],["M","L"]),
 ("WPAL","Women Cotton Palazzo","Women - Bottomwear","Anaya","620469",210,599,[("WHT","White"),("YLW","Yellow")],["M","L","XL"]),
 ("WSAR","Women Surat Silk Saree","Women - Sarees","Anaya","540720",900,2199,[("RED","Red"),("GRN","Green"),("BLU","Royal Blue")],["FREE"]),
 ("WTOP","Women Casual Top","Women - Topwear","Anaya","610610",210,599,[("WHT","White"),("PCH","Peach")],["S","M","L"]),
 ("WJNS","Women High-Rise Denim Jeans","Women - Bottomwear","Anaya","620462",460,1349,[("IND","Indigo"),("BLK","Black")],["28","30","32"]),
 ("WDRS","Women Floral Midi Dress","Women - Dresses","Anaya","620442",520,1499,[("FLR","Floral Blue"),("FLP","Floral Pink")],["S","M","L"]),
 ("WLHG","Women Bridal Lehenga Set","Women - Occasion","Anaya","620442",2600,5499,[("RED","Red"),("MAG","Magenta")],["M","L"]),
 ("WDUP","Women Embroidered Dupatta","Women - Accessories","Anaya","621420",160,449,[("GLD","Gold"),("SLV","Silver")],["FREE"]),
 ("WJKT","Women Quilted Winter Jacket","Women - Winterwear","Anaya","620230",1100,2699,[("BLK","Black")],["M","L","XL"]),
 # ---- BOYS (20)
 ("BTEE","Boys Graphic T-Shirt","Boys - Topwear","Tiny Trends","610910",110,329,[("BLU","Blue"),("RED","Red")],KID_SZ[:3]),
 ("BSHT","Boys Cotton Shorts","Boys - Bottomwear","Tiny Trends","610339",120,349,[("NVY","Navy"),("GRY","Grey")],KID_SZ[:3]),
 ("BJNS","Boys Denim Jeans","Boys - Bottomwear","Tiny Trends","620342",290,799,[("IND","Indigo")],KID_SZ),
 ("BKUR","Boys Kurta Pyjama Set","Boys - Ethnic","Tiny Trends","621139",330,949,[("CRM","Cream"),("MUS","Mustard")],KID_SZ[:3]),
 ("BTRK","Boys Tracksuit","Boys - Activewear","Tiny Trends","611220",360,999,[("BLK","Black")],KID_SZ),
 ("BSHF","Boys Party Shirt","Boys - Topwear","Tiny Trends","620520",210,599,[("WHT","White")],KID_SZ),
 # ---- GIRLS (20)
 ("GFRK","Girls Party Frock","Girls - Dresses","Tiny Trends","610442",260,749,[("PNK","Pink"),("LIL","Lilac")],KID_SZ[:3]),
 ("GTOP","Girls Printed Top","Girls - Topwear","Tiny Trends","610610",120,349,[("YLW","Yellow"),("WHT","White")],KID_SZ[:3]),
 ("GLEG","Girls Leggings","Girls - Bottomwear","Tiny Trends","610469",90,279,[("BLK","Black"),("PNK","Pink")],KID_SZ[:3]),
 ("GLHG","Girls Lehenga Choli","Girls - Ethnic","Tiny Trends","620442",800,1999,[("RED","Red"),("TEL","Teal")],KID_SZ[:3]),
 ("GJNS","Girls Denim Jeans","Girls - Bottomwear","Tiny Trends","620462",280,779,[("IND","Indigo")],KID_SZ),
 ("GNGT","Girls Night Suit Set","Girls - Nightwear","Tiny Trends","610830",190,549,[("PNK","Pink")],KID_SZ),
]
GENDER = lambda cat: cat.split(" - ")[0]

def ean13(n12):
    s = sum(int(d) * (3 if i % 2 else 1) for i, d in enumerate(n12))
    return n12 + str((10 - s % 10) % 10)

products = []
idx = 0
for code, name, cat, brand, hsn, cost, price, colours, sizes in STYLES:
    for ccode, cname in colours:
        for sz in sizes:
            idx += 1
            sku = f"{code}-{ccode}-{sz.replace('-', '').replace('Y','Y')}"
            rate = 5 if price <= 2500 else 18
            products.append(dict(sku=sku, name=f"{name} - {cname}", variant=f"{cname} / {sz}",
                                 barcode=ean13("890" + f"{4000000 + idx * 37:09d}"), hsn=hsn, rate=rate,
                                 brand=brand, category=cat, cost=cost, pack=12 if "Men" == GENDER(cat) or "Women" == GENDER(cat) else 10,
                                 price=price, gender=GENDER(cat), status="active", style=code))
assert len({p["sku"] for p in products}) == len(products)
# lifecycle variety for filters: 4 inactive, 3 discontinued (old season, dead stock)
for i in (7, 31, 58, 90):
    products[i]["status"] = "inactive"
for i in (12, 45, 77):
    products[i]["status"] = "discontinued"
print("SKUs:", len(products), {g: sum(1 for p in products if p['gender'] == g) for g in ("Men", "Women", "Boys", "Girls")})
PBY = {p["sku"]: p for p in products}

# channel listings
def amz(): return "B0" + "".join(R.choice("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789") for _ in range(8))
def fsn(): return "APR" + "".join(R.choice("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789") for _ in range(13))
maps = []
for i, p in enumerate(products):
    maps.append((p["sku"], "SHOP", f"{p['sku']}", str(7400000000000 + i * 13), "active"))
    if R.random() < .78:
        maps.append((p["sku"], "AMAZ", f"AMZ-{p['sku']}", amz(), "inactive" if p["status"] != "active" else "active"))
    if R.random() < .62:
        maps.append((p["sku"], "FLIP", f"FK-{p['sku']}", fsn(), "inactive" if p["status"] != "active" else "active"))
print("channel listings:", len(maps))

# ------------------------------------------------------------ SQL: 0045
def arr(xs): return "array[" + ",".join(q(x) for x in xs) + "]"
sty_rows = []
for code, name, cat, brand, hsn, cost, price, colours, sizes in STYLES:
    cols = "array[" + ",".join(f"array['{c}','{n}']" for c, n in colours) + "]"
    sty_rows.append(f"({q(code)},{q(name)},{q(cat)},{q(brand)},{q(hsn)},{cost},{price},{cols},{arr(sizes)})")
inactive_skus = [products[i]["sku"] for i in (7, 31, 58, 90)]
disc_skus = [products[i]["sku"] for i in (12, 45, 77)]
s = []
s.append("-- 0045: garment-retail catalogue (men, women, boys, girls), channel listings, October period.\n"
         "-- Generated by supabase/seed/gen_garment_seed.py. GST: apparel <= Rs2,500/pc = 5%, above = 18%.\n"
         "-- The 8 legacy non-garment SKUs are kept (orders/invoices reference them) but marked discontinued.\n")
s.append("update products set status='discontinued' where sku in ('BAG-CNV','BOTL-750','EARBUD-PRO','MUG-350','SLEEVE-14','TS-BLK-M','TS-WHT-M','YOGA-6MM');\n")
s.append("insert into accounting_periods (financial_year_id, period_name, start_date, end_date, status)\n"
         "select 'FY2026-27','October 2026','2026-10-01','2026-10-31','open'\n"
         "where not exists (select 1 from accounting_periods where start_date='2026-10-01');\n")
s.append("""with styles(ord,code,name,cat,brand,hsn,cost,price,cols,sizes) as (
  select row_number() over (), * from (values
""" + ",\n".join(sty_rows) + """
  ) t(code,name,cat,brand,hsn,cost,price,cols,sizes)
), exp as (
  select s.*, c.cc[1] ccode, c.cc[2] cname, c.ci, z.sz, z.si
  from styles s
  cross join lateral (select array[ (s.cols)[i][1], (s.cols)[i][2] ] cc, i ci from generate_subscripts(s.cols,1) i) c
  cross join lateral (select sz, si from unnest(s.sizes) with ordinality u(sz,si)) z
), numbered as (
  select *, row_number() over (order by ord, ci, si) n from exp
)
insert into products (company_id, sku, name, variant, barcode, hsn, gst_rate, brand, category, cost_price, packaging_cost, status)
select (select company_id from companies limit 1),
  code||'-'||ccode||'-'||replace(sz,'-',''), name||' - '||cname, cname||' / '||sz,
  b12||((10 - (select sum(substr(b12,g,1)::int * case when g%2=0 then 3 else 1 end) from generate_series(1,12) g) % 10) % 10)::text,
  hsn, case when price <= 2500 then 5 else 18 end, brand, cat, cost, case when cat like 'Men%' or cat like 'Women%' then 12 else 10 end,
  case when code||'-'||ccode||'-'||replace(sz,'-','') = any(""" + arr(disc_skus) + """) then 'discontinued'
       when code||'-'||ccode||'-'||replace(sz,'-','') = any(""" + arr(inactive_skus) + """) then 'inactive' else 'active' end
from (select *, '890'||lpad((4000000 + n*37)::text, 9, '0') b12 from numbered) x
on conflict (company_id, sku) do nothing;
""")
s.append("""-- channel listings: every SKU on Shopify; ~78% on Amazon, ~62% on Flipkart (deterministic). Non-active SKUs are inactive on marketplaces.
insert into channel_sku_map (product_id, channel_id, channel_sku, listing_id, status)
select p.product_id, c.channel_id,
  case c.type when 'd2c' then p.sku when 'marketplace' then (case when c.name like 'Amazon%' then 'AMZ-' else 'FK-' end)||p.sku end,
  case when c.type='d2c' then (7400000000000 + abs(hashtext(p.sku)))::text
       when c.name like 'Amazon%' then 'B0'||upper(substr(md5(p.sku||'amz'),1,8))
       else 'APR'||upper(substr(md5(p.sku||'fk'),1,13)) end,
  case when c.type<>'d2c' and p.status<>'active' then 'inactive' else 'active' end
from products p cross join channels c
where p.sku ~ '^[A-Z]+-[A-Z]+-' and p.sku not in ('BAG-CNV','BOTL-750','EARBUD-PRO','MUG-350','SLEEVE-14','TS-BLK-M','TS-WHT-M','YOGA-6MM')
  and (c.type='d2c' or (c.name like 'Amazon%' and abs(hashtext(p.sku||'a'))%100 < 78) or (c.name like 'Flipkart%' and abs(hashtext(p.sku||'f'))%100 < 62))
on conflict do nothing;
""")
open(os.path.join(OUT, "0045_seed_garment_catalogue.sql"), "w").write("\n".join(s))

# ------------------------------------------------------------ orders
STATES = [("Gujarat", 40), ("Maharashtra", 18), ("Rajasthan", 8), ("Delhi", 8), ("Karnataka", 7),
          ("Tamil Nadu", 5), ("Madhya Pradesh", 5), ("Uttar Pradesh", 5), ("West Bengal", 4)]
def pick_state(ch):
    w = [(s_, wt * (1.6 if (ch == "SHOP" and s_ == "Gujarat") else 1)) for s_, wt in STATES]
    tot = sum(x for _, x in w); r = R.random() * tot
    for s_, wt in w:
        r -= wt
        if r <= 0: return s_
    return "Gujarat"
NAMES = ["Riya Shah","Kunal Desai","Neha Patel","Aarav Mehta","Pooja Jain","Harsh Modi","Isha Gupta","Dev Trivedi","Sonal Parekh","Manav Joshi",
         "Tanvi Rana","Yash Vora","Kiran Naik","Jigar Chauhan","Nidhi Agarwal","Rahul Bhatt","Sejal Kapadia","Mitul Dave","Anjali Verma","Rohit Iyer",
         "Bhavna Solanki","Chirag Zaveri","Meghna Rao","Sanjay Gajera","Foram Thakkar","Vivek Singh","Heena Khan","Amit Sethi","Kavya Menon","Pratik Lad"]
COURIERS = ["Delhivery - Sachin GIDC Surat","Ecom Express - Udhna Hub","DTDC - Ring Road Surat","Bluedart - Surat City","Xpressbees - Pandesara"]

by_gender = {g: [p for p in products if p["gender"] == g and p["status"] == "active"] for g in ("Men","Women","Boys","Girls")}
active = [p for p in products if p["status"] == "active"]

# status plan for 72 orders (index -> final status)
plan = (["delivered"] * 42 + ["shipped"] * 8 + ["processing"] * 7 + ["pending"] * 5 + ["cancelled"] * 4 + ["rto"] * 6)
R.shuffle(plan)
start = dt.datetime(2026, 9, 2, 10, 0)
orders = []
cnt = {"SHOP": 1100, "AMAZ": 1100, "FLIP": 1100}
for i, st in enumerate(plan):
    ch = R.choices(["SHOP", "AMAZ", "FLIP"], [.38, .34, .28])[0]
    cnt[ch] += 1
    # delivered/rto/shipped skew earlier; processing/pending are recent
    if st in ("pending", "processing"):
        day = R.randint(26, 31)  # Oct 3 etc (offset from Sep 2)
    elif st == "shipped":
        day = R.randint(21, 29)
    else:
        day = R.randint(0, 24)
    od = start + dt.timedelta(days=day, hours=R.randint(0, 9), minutes=R.randint(0, 59))
    # basket: 1-4 lines, themed by who the buyer is
    g = R.choice(["Men", "Women", "Women", "Boys", "Girls", "Men"])
    n_lines = R.choices([1, 2, 3, 4], [.4, .35, .17, .08])[0]
    skus = R.sample(by_gender[g], n_lines)
    if R.random() < .2:
        skus[-1] = R.choice(active)
    seen, lines = set(), []
    for p in skus:
        if p["sku"] in seen: continue
        seen.add(p["sku"])
        qty = R.choices([1, 2, 3], [.7, .22, .08])[0]
        disc_pct = R.choice([0, 0, 0.05, 0.10, 0.15])
        gross = round(qty * p["price"], 2)
        disc = round(gross * disc_pct, 2)
        tax = round((gross - disc) * p["rate"] / 100, 2)
        lines.append(dict(sku=p["sku"], qty=qty, up=p["price"], disc=disc, tax=tax, gross=gross))
    state = pick_state(ch)
    gross = round(sum(l["gross"] for l in lines), 2)
    disc = round(sum(l["disc"] for l in lines), 2)
    tax = round(sum(l["tax"] for l in lines), 2)
    net = round(gross - disc + tax, 2)
    cod = (R.random() < (.30 if ch != "AMAZ" else .18))
    if st == "pending" and not cod: pay = "pending"
    elif st == "cancelled": pay = "refunded" if not cod else "failed"
    elif st == "rto": pay = "refunded" if not cod else "failed"
    elif cod and st in ("shipped", "processing", "pending"): pay = "pending"
    else: pay = "paid"
    orders.append(dict(ext=f"{ch}-{cnt[ch]}", ch=ch, date=od, cod=cod, gross=gross, disc=disc, tax=tax, net=net,
                       status=st, pay=pay, state=state, cust=R.choice(NAMES), lines=lines))
orders.sort(key=lambda o: o["date"])
print("orders:", len(orders), "invoiced-eligible:", sum(1 for o in orders if o["status"] in ("shipped", "delivered", "rto")))

def wh_for(o):
    return WH_MUM if o["state"] in ("Maharashtra", "Karnataka", "Tamil Nadu") else WH_SURAT

# dispatch demand per (sku, wh) -> initial stock covers it
dem = {}
for o in orders:
    if o["status"] in ("shipped", "delivered", "rto"):
        for l in o["lines"]:
            dem[(l["sku"], wh_for(o))] = dem.get((l["sku"], wh_for(o)), 0) + l["qty"]

# target closing stock profile
final = {}
low, oos = set(), set()
act_skus = [p["sku"] for p in active]
for sku in R.sample(act_skus, 9): low.add(sku)
for sku in R.sample([x for x in act_skus if x not in low], 5): oos.add(sku)
for p in products:
    for wh in (WH_SURAT, WH_MUM):
        if p["sku"] in oos: f = 0
        elif p["sku"] in low: f = R.randint(1, 4) if wh == WH_SURAT else 0
        elif p["status"] == "discontinued": f = R.randint(25, 60) if wh == WH_SURAT else 0
        elif p["status"] == "inactive": f = R.randint(5, 20) if wh == WH_SURAT else 0
        else: f = R.randint(25, 110) if wh == WH_SURAT else (R.randint(8, 45) if R.random() < .65 else 0)
        final[(p["sku"], wh)] = f
init = {k: final[k] + dem.get(k, 0) for k in final}
print("low stock:", len(low), "out of stock:", len(oos))

# ------------------------------------------------------------ SQL: 0046
WHS = "case when o.ship_to_state in ('Maharashtra','Karnataka','Tamil Nadu') then '%s'::uuid else '%s'::uuid end" % (WH_MUM, WH_SURAT)
t = []
t.append("-- 0046: garment demo transactions - opening stock, 72 orders across Shopify/Amazon/Flipkart, invoices (CGST+SGST vs IGST),\n"
         "-- returns, RTOs, COD, settlements, claims, credit notes. Generated by supabase/seed/gen_garment_seed.py.\n"
         "-- Runs as the Super Admin so the SECURITY DEFINER engine functions (post_sales_voucher, disposition_*,\n"
         "-- reconcile_settlement, ...) execute their real posting logic rather than being bypassed.\n")
t.append(f"select set_config('request.jwt.claims', json_build_object('sub','{SA}','role','authenticated')::text, true);\n"
         "-- (no role switch: the engine functions are SECURITY DEFINER and check auth.uid()'s role, so the real posting logic still runs)\n")

# orders + lines
t.append("-- orders")
t.append("insert into orders (external_order_id, channel_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, ship_to_state)\nvalues")
t.append(",\n".join(
    f"({q(o['ext'])},'{CH[o['ch']]}',{q(o['date'].strftime('%Y-%m-%d %H:%M+05:30'))},{q(o['cust'])},{q('cod' if o['cod'] else 'prepaid')},{o['gross']},{o['disc']},{o['tax']},{o['net']},"
    f"{q('shipped' if o['status']=='rto' else o['status'])},{q(o['pay'])},{q(o['state'])})" for o in orders) + ";\n")
t.append("insert into order_lines (order_id, product_id, quantity, unit_price, discount, tax)\nselect o.order_id, p.product_id, v.q, v.up, v.d, v.t from (values")
t.append(",\n".join(f"({q(o['ext'])},{q(l['sku'])},{l['qty']},{l['up']},{l['disc']},{l['tax']})" for o in orders for l in o["lines"]))
t.append(") as v(ext,sku,q,up,d,t) join orders o on o.external_order_id=v.ext join products p on p.sku=v.sku;\n")

# opening stock derived from demand so closing stock lands on the intended profile
t.append(f"""-- opening stock (31 Aug 2026) = intended closing stock + units dispatched, so balances and the movement ledger agree.
-- Profile: 9 low-stock SKUs, 5 out-of-stock SKUs, discontinued SKUs with dead stock, Mumbai 3PL stocks ~65% of active SKUs.
with oos as (select unnest({arr(sorted(oos))}) sku), low as (select unnest({arr(sorted(low))}) sku),
wh(id) as (values ('{WH_SURAT}'::uuid),('{WH_MUM}'::uuid)),
dem as (
  select ol.product_id, {WHS} wh, sum(ol.quantity) q
  from order_lines ol join orders o using(order_id) where o.fulfilment_status in ('shipped','delivered') group by 1,2
), fin as (
  select p.product_id, wh.id wh,
    case when p.sku in (select sku from oos) then 0
         when p.sku in (select sku from low) then (case when wh.id='{WH_SURAT}' then 1 + abs(hashtext(p.sku))%4 else 0 end)
         when p.status='discontinued' then (case when wh.id='{WH_SURAT}' then 25 + abs(hashtext(p.sku))%36 else 0 end)
         when p.status='inactive' then (case when wh.id='{WH_SURAT}' then 5 + abs(hashtext(p.sku))%16 else 0 end)
         when wh.id='{WH_SURAT}' then 25 + abs(hashtext(p.sku))%86
         when abs(hashtext(p.sku||'m'))%100 < 65 then 8 + abs(hashtext(p.sku||'q'))%38 else 0 end f
  from products p cross join wh where p.sku ~ '^[A-Z]+-[A-Z]+-' and p.sku not in ('BAG-CNV','BOTL-750','EARBUD-PRO','MUG-350','SLEEVE-14','TS-BLK-M','TS-WHT-M','YOGA-6MM')
)
select record_inventory_movement(fin.product_id, fin.wh, 'initial_stock', fin.f + coalesce(dem.q,0), 'opening', null)
from fin left join dem on dem.product_id=fin.product_id and dem.wh=fin.wh where fin.f + coalesce(dem.q,0) > 0;
update inventory_transactions set created_at='2026-08-31 09:00+05:30' where movement_type='initial_stock' and created_at > '2026-10-01';
""")
t.append(f"""-- dispatch (stock out) for shipped / delivered / RTO-bound orders, from the Mumbai 3PL for MH/KA/TN, else Surat
select record_inventory_movement(ol.product_id, {WHS}, 'sale_dispatch', -ol.quantity, 'order', o.order_id)
from order_lines ol join orders o using(order_id) where o.fulfilment_status in ('shipped','delivered') and o.external_order_id ~ '^(SHOP|AMAZ|FLIP)-11'
order by o.order_date;
update inventory_transactions it set created_at = o.order_date + interval '14 hours' from orders o
  where it.movement_type='sale_dispatch' and it.reference_id=o.order_id and it.created_at > '2026-10-01';
""")

# invoices
t.append("-- invoices + sales vouchers via the real posting engine (shipped, delivered and RTO-bound orders); RTO status flips afterwards")
t.append("select post_sales_voucher(order_id) from orders where fulfilment_status in ('shipped','delivered') and external_order_id ~ '^(SHOP|AMAZ|FLIP)-11' order by order_date;")
rto_orders = [o for o in orders if o["status"] == "rto"]
t.append("update orders set fulfilment_status='rto' where external_order_id in (" + ",".join(q(o['ext']) for o in rto_orders) + ");\n")

# status history for earlier stages (trigger already logged the insert row and the RTO flip)
t.append("""-- order timeline: earlier stages (the trigger logged the insert-time status and the RTO flip)
insert into order_status_history (order_id, fulfilment_status, payment_status, changed_by)
select o.order_id, s.fs, case when s.fs='pending' or o.payment_type='cod' then 'pending' else 'paid' end, null
from orders o cross join lateral unnest(
  case o.fulfilment_status when 'processing' then array['pending'] when 'shipped' then array['pending','processing']
       when 'delivered' then array['pending','processing','shipped'] when 'cancelled' then array['pending']
       when 'rto' then array['pending','processing'] else array[]::text[] end) s(fs)
where o.external_order_id ~ '^(SHOP|AMAZ|FLIP)-11' and o.fulfilment_status in ('processing','shipped','delivered','cancelled','rto');
update order_status_history h set changed_at = o.order_date + (case h.fulfilment_status when 'pending' then interval '0' when 'processing' then interval '6 hours'
   when 'shipped' then interval '30 hours' when 'delivered' then interval '4 days' when 'cancelled' then interval '5 hours' else interval '8 days' end)
from orders o where o.order_id=h.order_id and o.external_order_id ~ '^(SHOP|AMAZ|FLIP)-11';
""")

# COD
cod_orders = [o for o in orders if o["cod"] and o["status"] in ("shipped", "delivered", "rto")]
cv = []
for o in cod_orders:
    cr = R.choice(COURIERS)
    if o["status"] == "delivered":
        cv.append((o, cr, (o["date"] + dt.timedelta(days=R.randint(3, 6))).date(), "collected"))
    else:
        cv.append((o, cr, None, "pending"))
t.append("-- COD collections (delivered = cash collected by courier; shipped/RTO = still pending)")
t.append("insert into cod_collections (order_id, courier_name, cod_amount, collected_amount, remitted_amount, status, collected_date)\nselect o.order_id, v.cr, o.net_amount, case when v.st='collected' then o.net_amount else 0 end, 0, v.st, v.cd::date from (values")
t.append(",\n".join(f"({q(o['ext'])},{q(cr)},{q(st)},{q(cd.isoformat() if cd else None)})" for o, cr, cd, st in cv))
t.append(") as v(ext,cr,st,cd) join orders o on o.external_order_id=v.ext;\n")
dc = [c for c in cv if c[3] == "collected"]
R.shuffle(dc)
nfull = int(len(dc) * .6); npart = max(1, int(len(dc) * .15))
if dc[:nfull]:
    t.append("select record_cod_remittance(c.cod_id, c.cod_amount) from cod_collections c join orders o using(order_id) where o.external_order_id in (" + ",".join(q(c[0]['ext']) for c in dc[:nfull]) + ");")
for c in dc[nfull:nfull + npart]:
    t.append(f"select record_cod_remittance(c.cod_id, round(c.cod_amount*0.6,2)) from cod_collections c join orders o using(order_id) where o.external_order_id={q(c[0]['ext'])};")
t.append("")

# returns
delivered = [o for o in orders if o["status"] == "delivered" and o["date"] <= dt.datetime(2026, 9, 19)]
R.shuffle(delivered)
ret_plan = [("requested", None), ("requested", None), ("approved", None), ("pickup", None), ("in_transit", None),
            ("received", None), ("received", None), ("restocked", "good"), ("restocked", "good"), ("quarantined", "damaged"),
            ("claimed", "wrong_item"), ("rejected", None)]
REASONS = ["Size did not fit", "Colour different from photo", "Item arrived damaged", "Customer changed mind", "Wrong item delivered", "Fabric quality not as expected"]
ret_rows = [(delivered[k], s_, i_, wh_for(delivered[k])) for k, (s_, i_) in enumerate(ret_plan)]
t.append("-- returns (mostly arriving via webhook; a few manual fallbacks)")
rv = []
for o, stt, insp, wh in ret_rows:
    base = (o["date"] + dt.timedelta(days=R.randint(8, 12))).date()
    pd_ = base if stt in ("pickup", "in_transit", "received", "restocked", "quarantined", "claimed") else None
    rd_ = base + dt.timedelta(days=2) if stt in ("received", "restocked", "quarantined", "claimed") else None
    stage = {"restocked": "received", "quarantined": "received", "claimed": "received"}.get(stt, stt)
    rv.append(f"({q(o['ext'])},{q(R.choice(REASONS))},{q(stage)},{q(pd_.isoformat() if pd_ else None)},{q(rd_.isoformat() if rd_ else None)},'{wh}',{q(R.choices(['webhook','manual'],[.7,.3])[0])})")
t.append("insert into returns (order_id, return_reason, status, pickup_date, received_date, restock_status, refund_status, warehouse_id, source)\nselect o.order_id, v.rs, v.st, v.pd::date, v.rd::date, 'pending', 'pending', v.wh::uuid, v.src from (values")
t.append(",\n".join(rv))
t.append(") as v(ext,rs,st,pd,rd,wh,src) join orders o on o.external_order_id=v.ext;\n")
for o, stt, insp, wh in ret_rows:
    if insp:
        t.append(f"select disposition_return(r.return_id, {q(insp)}, {q(stt)}) from returns r join orders o using(order_id) where o.external_order_id={q(o['ext'])};")
t.append("update returns r set refund_status='refunded' from orders o where o.order_id=r.order_id and r.status in ('restocked','quarantined','claimed') and o.external_order_id in (" +
         ",".join(q(o['ext']) for o, stt, insp, wh in ret_rows if insp) + ");")
t.append("update returns r set refund_status='rejected' from orders o where o.order_id=r.order_id and o.external_order_id=" + q(ret_rows[-1][0]['ext']) + ";")
t.append("update returns set refund_status='processing' where status='received' and refund_status='pending';\n")
t.append("""-- credit notes with proper CGST/SGST/IGST reversal for refunded returns
do $$
declare r record; v_vt uuid; v_per uuid; v_vid uuid; v_recv uuid; v_sales uuid; v_cg uuid; v_sg uuid; v_ig uuid; v_cs text; v_half numeric; v_n int;
begin
  select voucher_type_id into v_vt from voucher_types where code='CREDIT_NOTE';
  select ledger_id into v_recv from ledgers where name='Trade Receivables';
  select ledger_id into v_sales from ledgers where name='Sales Revenue';
  select ledger_id into v_cg from ledgers where name='CGST Payable (Output)';
  select ledger_id into v_sg from ledgers where name='SGST Payable (Output)';
  select ledger_id into v_ig from ledgers where name='IGST Payable (Output)';
  select state into v_cs from companies limit 1;
  select count(*) into v_n from credit_notes;
  for r in select ret.return_id, i.invoice_id, i.taxable_value, i.gst_amount, i.total, o.ship_to_state, ret.received_date
           from returns ret join orders o using(order_id) join invoices i on i.order_id=o.order_id
           where ret.refund_status='refunded' and not exists (select 1 from credit_notes cn where cn.return_id=ret.return_id)
           order by ret.received_date loop
    select accounting_period_id into v_per from accounting_periods where r.received_date between start_date and end_date and status='open' limit 1;
    continue when v_per is null;
    v_n := v_n + 1;
    insert into vouchers (voucher_type_id, voucher_no, voucher_date, accounting_period_id, status, source_type, source_id, narration, total_debit, total_credit)
    values (v_vt, 'CN-2026-' || lpad(v_n::text,5,'0'), r.received_date, v_per, 'draft', 'return', r.return_id,
            'Credit note for returned goods - ' || case when r.ship_to_state is distinct from v_cs then 'IGST' else 'CGST+SGST' end, r.total, r.total)
    returning voucher_id into v_vid;
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id) values (v_vid, v_sales, r.taxable_value, 0, 'return', r.return_id);
    if r.gst_amount > 0 then
      if r.ship_to_state is distinct from v_cs then
        insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id) values (v_vid, v_ig, r.gst_amount, 0, 'return', r.return_id);
      else
        v_half := round(r.gst_amount/2, 2);
        if v_half > 0 then insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id) values (v_vid, v_cg, v_half, 0, 'return', r.return_id); end if;
        if r.gst_amount - v_half > 0 then insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id) values (v_vid, v_sg, r.gst_amount - v_half, 0, 'return', r.return_id); end if;
      end if;
    end if;
    insert into voucher_lines (voucher_id, ledger_id, debit, credit, reference_type, reference_id) values (v_vid, v_recv, 0, r.total, 'return', r.return_id);
    update vouchers set status='posted' where voucher_id=v_vid;
    insert into credit_notes (invoice_id, return_id, amount, tax_amount, date, status, voucher_id)
    values (r.invoice_id, r.return_id, r.total, r.gst_amount, r.received_date, 'posted', v_vid);
  end loop;
end $$;
""")

# RTOs
rto_plan = [("initiated", None), ("in_transit", None), ("received", None), ("restocked", "good"), ("quarantined", "damaged"), ("received", None)]
t.append("-- RTOs (courier-initiated; mostly via webhook)")
rr = []
for o, (stt, insp) in zip(rto_orders, rto_plan):
    stage = {"restocked": "received", "quarantined": "received"}.get(stt, stt)
    rd_ = min((o["date"] + dt.timedelta(days=R.randint(8, 11))).date(), dt.date(2026, 10, 3)) if stt in ("received", "restocked", "quarantined") else None
    rr.append(f"({q(o['ext'])},{q('AWB' + str(R.randint(10**9, 10**10-1)))},{q(R.choice(['Customer refused delivery','Address incomplete','Customer unreachable','Delivery attempts exhausted']))},{q(stage)},{q(rd_.isoformat() if rd_ else None)},'{wh_for(o)}',{q(R.choices(['webhook','manual'],[.8,.2])[0])})")
t.append("insert into rtos (order_id, awb, reason, status, received_date, warehouse_id, source)\nselect o.order_id, v.awb, v.rs, v.st, v.rd::date, v.wh::uuid, v.src from (values")
t.append(",\n".join(rr))
t.append(") as v(ext,awb,rs,st,rd,wh,src) join orders o on o.external_order_id=v.ext;\n")
for o, (stt, insp) in zip(rto_orders, rto_plan):
    if insp:
        t.append(f"select disposition_rto(r.rto_id, {q(insp)}, {q(stt)}) from rtos r join orders o using(order_id) where o.external_order_id={q(o['ext'])};")
t.append("")

# settlements - computed in SQL from delivered, non-COD (marketplace) orders; fee lines carry 18% GST for ITC
t.append(f"""-- settlements per channel per fortnight, derived from delivered prepaid orders. Fee lines carry GST (feeds ITC on reconcile).
-- Amazon 14% + Rs38 shipping, Flipkart 13% + Rs42 shipping, Shopify 2% gateway fee (all GST-inclusive deductions).
do $$
declare w record; s uuid; o record; comm numeric; shp numeric; v_ded numeric; v_gross numeric; pct numeric; ship numeric; pref text;
begin
  for w in select c.channel_id, c.name, x.ws, x.we, x.tag from channels c
           cross join (values ('2026-09-01'::date,'2026-09-15'::date,'S1'),('2026-09-16','2026-09-30','S2')) x(ws,we,tag) loop
    pct := case when w.name like 'Amazon%' then .14 when w.name like 'Flipkart%' then .13 else .02 end;
    ship := case when w.name like 'Amazon%' then 38 when w.name like 'Flipkart%' then 42 else 0 end;
    pref := case when w.name like 'Amazon%' then 'AMZ' when w.name like 'Flipkart%' then 'FK' else 'SHP' end;
    v_gross := 0; v_ded := 0; s := null;
    for o in select * from orders where channel_id=w.channel_id and fulfilment_status='delivered' and order_date::date between w.ws and w.we
                and payment_type='prepaid' and external_order_id ~ '^(SHOP|AMAZ|FLIP)-11' order by order_date loop
      if s is null then
        insert into settlements (channel_id, external_settlement_id, period_start, period_end, gross, deductions, expected_amount, status)
        values (w.channel_id, pref||'-SETTLE-2026-09-'||w.tag, w.ws, w.we, 0, 0, 0, 'pending') returning settlement_id into s;
      end if;
      comm := round(o.net_amount*pct/1.18, 2); shp := round(ship/1.18, 2);
      insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (s, o.order_id, 'order_value', o.net_amount, 0);
      insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount)
        values (s, o.order_id, case when pref='SHP' then 'gateway_fee' else 'commission' end, comm, round(comm*.18,2));
      if shp > 0 then insert into settlement_lines (settlement_id, order_id, fee_type, amount, tax_amount) values (s, o.order_id, 'shipping', shp, round(shp*.18,2)); end if;
      v_gross := v_gross + o.net_amount; v_ded := v_ded + comm + round(comm*.18,2) + shp + round(shp*.18,2);
    end loop;
    if s is not null then
      update settlements set gross=v_gross, deductions=round(v_ded,2), expected_amount=round(v_gross - v_ded,2) where settlement_id=s;
    end if;
  end loop;
end $$;
""")
t.append(f"""-- bank credits + reconciliation through the engine: Sep-A settlements - Amazon exact, Flipkart short-paid, Shopify exact, Sep S2 left pending
insert into bank_transactions (bank_account_id, txn_date, reference, amount, type, match_status)
select '{BANK_CUR}', '2026-09-20'::date + (row_number() over (order by external_settlement_id))::int,
  'NEFT-'||external_settlement_id, case when external_settlement_id like 'FK-%' then expected_amount - 140 else expected_amount end, 'credit', 'unmatched'
from settlements where external_settlement_id in ('AMZ-SETTLE-2026-09-S1','FK-SETTLE-2026-09-S1','SHP-SETTLE-2026-09-S1');
select reconcile_settlement(s.settlement_id, b.amount, b.bank_txn_id)
from settlements s join bank_transactions b on b.reference='NEFT-'||s.external_settlement_id
where s.external_settlement_id in ('AMZ-SETTLE-2026-09-S1','FK-SETTLE-2026-09-S1','SHP-SETTLE-2026-09-S1');
insert into bank_transactions (bank_account_id, txn_date, reference, amount, type, match_status) values
 ('{BANK_COL}','2026-09-12','UPI-CR-8801223344',1499,'credit','unmatched'),
 ('{BANK_COL}','2026-09-19','UPI-CR-8801556677',2398,'credit','unmatched'),
 ('{BANK_CUR}','2026-09-25','COURIER-FREIGHT-SEP26',4260,'debit','unmatched'),
 ('{BANK_CUR}','2026-09-28','PACKAGING-MATERIAL-SURAT',7850,'debit','unmatched'),
 ('{BANK_CUR}','2026-09-30','BANK-CHARGES-SEP26',236,'debit','unmatched');
""")

# claims
am = [o for o in orders if o["ch"] == "AMAZ" and o["status"] == "delivered" and not o["cod"]]
fk = [o for o in orders if o["ch"] == "FLIP" and o["status"] == "delivered" and not o["cod"]]
cl_orders = [(rto_orders[0], "lost_shipment", "potential"), (rto_orders[5], "lost_shipment", "claimed"), (ret_rows[9][0], "damaged_return", "approved"),
             (ret_rows[10][0], "other", "rejected"), (am[0], "incorrect_deduction", "recovered"), (fk[0], "excess_deduction", "approved")]
t.append("-- claims across every lifecycle state, advanced through the real state machine")
t.append("insert into claims (order_id, claim_type, potential_amount, deadline, owner, status)\nselect o.order_id, v.ct, case when v.ct in ('incorrect_deduction','excess_deduction') then round(o.net_amount*.08,2) else o.net_amount end, v.dl::date, '" + CLAIMS_OWNER + "', 'potential' from (values")
t.append(",\n".join(f"({q(o['ext'])},{q(ct)},'{(dt.date(2026,10,4)+dt.timedelta(days=R.randint(-3,25))).isoformat()}')" for o, ct, _ in cl_orders))
t.append(") as v(ext,ct,dl) join orders o on o.external_order_id=v.ext;")
ladder = {"potential": [], "claimed": ["claimed"], "approved": ["claimed", "approved"], "rejected": ["claimed", "rejected"], "recovered": ["claimed", "approved", "recovered"]}
for o, ct, goal in cl_orders:
    for stp in ladder[goal]:
        amt = ", c.approved_amount" if stp == "recovered" else ""
        t.append(f"select advance_claim(c.claim_id,'{stp}'{amt}) from claims c join orders o using(order_id) where o.external_order_id={q(o['ext'])} and c.claim_type={q(ct)};")
open(os.path.join(OUT, "0046_seed_garment_transactions.sql"), "w").write("\n".join(t))
print("done")
