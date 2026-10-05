"""The demo business story (1 Apr - 5 Oct 2026), simulated day by day in Python.
Every record the SQL files create comes from this one simulation, so stock, orders, purchases, returns, COD and settlements agree with each other.
Deterministic: same seed, same story."""
import random, datetime as dt, math
from decimal import Decimal, ROUND_HALF_UP
from collections import defaultdict
from catalogue import products, PBY, STYLES

R = random.Random(2026)
START, TODAY = dt.date(2026, 4, 1), dt.date(2026, 10, 5)
SUR, MUM = "Surat Main Warehouse", "Mumbai Fulfilment Center"
CHANNELS = {"SHOP": "Shopify - Main Store", "AMAZ": "Amazon - Seller Central", "FLIP": "Flipkart - Seller Hub"}
def d2(x): return float(Decimal(str(x)).quantize(Decimal("0.01"), ROUND_HALF_UP))

# ------------------------------------------------------------------ suppliers (goods)
SUPPLIERS = [
 # key, name, state code, city, terms, styles
 ("SAT", "Shree Ambika Textiles", "24", "Surat", 30, ["WKRT", "WPAL", "WSAR", "WDUP", "WLHG"]),
 ("TKF", "Tiruppur Knit Fashions Pvt Ltd", "33", "Tiruppur", 21, ["MTEE", "MPOL", "WLEG", "WTOP", "BTEE", "GTOP", "GLEG", "MTRK"]),
 ("LWW", "Ludhiana Winter Wear Co", "03", "Ludhiana", 30, ["MHOD", "WJKT", "BTRK"]),
 ("KDW", "Krishna Denim Works", "24", "Ahmedabad", 45, ["MJNS", "MCHN", "WJNS", "BJNS", "GJNS"]),
 ("RSM", "Rajdhani Shirting Mills", "27", "Mumbai", 30, ["MSHF", "MSHC", "MKUR", "MBLZ", "BSHF"]),
 ("LSG", "Little Stitch Garments", "24", "Surat", 15, ["BSHT", "BKUR", "GFRK", "GLHG", "GNGT", "WDRS"]),
]
STYLE_SUP = {s: k for k, _, _, _, _, ss in SUPPLIERS for s in ss}
assert all(st[0] in STYLE_SUP for st in STYLES), [st[0] for st in STYLES if st[0] not in STYLE_SUP]

# ------------------------------------------------------------------ demand
MONTH_RATE = {4: 5.0, 5: 5.8, 6: 6.8, 7: 8.0, 8: 9.5, 9: 12.0, 10: 13.0}   # orders per day before weekday / event effects
def day_orders(d):
    r = MONTH_RATE[d.month]
    r *= 1.14 if d.weekday() >= 5 else 0.96
    if dt.date(2026, 8, 24) <= d <= dt.date(2026, 8, 28): r *= 1.35      # Raksha Bandhan
    if dt.date(2026, 9, 10) <= d <= dt.date(2026, 9, 14): r *= 1.30      # Ganesh Chaturthi
    if dt.date(2026, 9, 24) <= d <= dt.date(2026, 10, 4): r *= 1.30      # festive sale on the marketplaces
    return max(1, int(round(R.gauss(r, r ** .5 * .8))))
def season(cat, d):
    m = d.month
    if "Winterwear" in cat: return {4: .15, 5: .1, 6: .1, 7: .15, 8: .3, 9: .8, 10: 2.2}[m]
    if "Occasion" in cat or "Sarees" in cat or "Ethnic" in cat: return 1.0 if m < 8 else 1.6 if m == 8 else 2.1
    if "Activewear" in cat: return 1.1
    return 1.0

ACTIVE = [p for p in products if p["status"] == "active"]
# popularity: some styles sell far better than others, bigger sizes a little more
style_pop = {st[0]: R.lognormvariate(0, .75) for st in STYLES}
def sku_weight(p):
    base = style_pop[p["style"]]
    sz = p["variant"].split(" / ")[1]
    bump = 1.25 if sz in ("M", "L", "32", "30", "6-7Y") else 1.0
    return base * bump * R.uniform(.85, 1.15)
BASE_W = {p["sku"]: sku_weight(p) for p in ACTIVE}
# a handful of SKUs the supplier stops delivering from August: they run down and go out of stock (5 SKUs)
_cand = sorted(ACTIVE, key=lambda p: -BASE_W[p["sku"]])[8:60]
BLOCKED = {p["sku"]: dt.date(2026, 8, R.randint(1, 12)) for p in R.sample(_cand, 5)}
GENDER_MIX = [("Men", .30), ("Women", .40), ("Boys", .15), ("Girls", .15)]
STATES = [("Gujarat", 40), ("Maharashtra", 18), ("Rajasthan", 8), ("Delhi", 8), ("Karnataka", 7), ("Tamil Nadu", 5),
          ("Madhya Pradesh", 5), ("Uttar Pradesh", 5), ("West Bengal", 4)]
NAMES = ["Riya Shah","Kunal Desai","Neha Patel","Aarav Mehta","Pooja Jain","Harsh Modi","Isha Gupta","Dev Trivedi","Sonal Parekh","Manav Joshi",
         "Tanvi Rana","Yash Vora","Kiran Naik","Jigar Chauhan","Nidhi Agarwal","Rahul Bhatt","Sejal Kapadia","Mitul Dave","Anjali Verma","Rohit Iyer",
         "Bhavna Solanki","Chirag Zaveri","Meghna Rao","Sanjay Gajera","Foram Thakkar","Vivek Singh","Heena Khan","Amit Sethi","Kavya Menon","Pratik Lad",
         "Divya Nair","Karan Malhotra","Shreya Banerjee","Nikhil Pandey","Aditi Joshi","Mehul Shukla","Prachi Kulkarni","Sagar Rathod","Ritu Saxena","Vipul Gandhi"]
COURIERS = ["Delhivery - Sachin GIDC Surat", "Ecom Express - Udhna Hub", "DTDC - Ring Road Surat", "Bluedart - Surat City", "Xpressbees - Pandesara"]
def wchoice(pairs):
    tot = sum(w for _, w in pairs); r = R.random() * tot
    for v, w in pairs:
        r -= w
        if r <= 0: return v
    return pairs[-1][0]
def disc_choices(d, ch):
    big_sale = dt.date(2026, 9, 24) <= d <= dt.date(2026, 10, 4) and ch != "SHOP"
    if big_sale: return [0, .10, .15, .20, .25]
    if d.month in (8, 9) : return [0, 0, .05, .10, .15]
    return [0, 0, 0, .05, .10]

# ------------------------------------------------------------------ the world state
class Order:
    pass
orders, events = [], defaultdict(list)          # events[date] -> list of (priority, sql)
def ev(d, prio, sql):
    if d <= TODAY: events[d].append((prio, sql))
P_STOCK, P_ORDER, P_OPS, P_SETTLE, P_PAY, P_CLAIM = 10, 20, 30, 40, 50, 60

stock = defaultdict(int)                        # (sku, wh) -> on hand
reserved = defaultdict(int)                     # orders not yet dispatched
sold = defaultdict(lambda: defaultdict(int))    # (sku, wh) -> {date: units}
on_order = defaultdict(int)
arrivals = defaultdict(list)                    # date -> [(sku, wh, qty)]
po_seq = [0]
def wh_for_state(st): return MUM if st in ("Maharashtra", "Karnataka", "Tamil Nadu") else SUR
def avail(sku, wh): return stock[(sku, wh)] - reserved[(sku, wh)]

# ------------------------------------------------------------------ opening stock (1 Apr)
from catalogue import LISTED
exp_daily_units = MONTH_RATE[4] * 1.5
_tw = sum(BASE_W.values())
OPENING = {}                                     # (sku, wh) -> qty
for p in products:
    sku = p["sku"]
    if p["status"] == "active":
        d = exp_daily_units * BASE_W[sku] / _tw
        OPENING[(sku, SUR)] = max(6, math.ceil(d * .72 * 45))
        if R.random() < .7: OPENING[(sku, MUM)] = max(3, math.ceil(d * .28 * 45))
    elif p["status"] == "discontinued": OPENING[(sku, SUR)] = R.randint(25, 60)
    else: OPENING[(sku, SUR)] = R.randint(5, 20)
for k, v in OPENING.items(): stock[k] = v

# ------------------------------------------------------------------ replenishment through purchase orders
LEAD = {"SAT": (3, 5), "TKF": (8, 10), "LWW": (9, 11), "KDW": (4, 6), "RSM": (4, 6), "LSG": (3, 5)}
sup_pos = defaultdict(list)                      # supplier key -> [(po_ref, grn_date_list)]
bill_no_seq = defaultdict(int)
utr_seq = [880000]
bills = []                                       # (supplier key, bill date, due date)
def lines_json(items):
    return "[" + ",".join('{"sku":"%s","q":%d%s}' % (s, q, (',"a":%d,"r":%d' % (a, r) if a is not None else "")) for s, q, a, r in items) + "]"
def last_28(sku, wh, d):
    return sum(u for dd, u in sold[(sku, wh)].items() if 0 < (d - dd).days <= 28)
def replenish(d):
    groups = defaultdict(list)
    days_known = (d - START).days
    for p in ACTIVE:
        sku = p["sku"]
        if sku in BLOCKED and d >= BLOCKED[sku]: continue
        for wh in (SUR, MUM):
            if wh == MUM and (sku, MUM) not in OPENING and not sold[(sku, MUM)]: continue
            s28 = last_28(sku, wh, d)
            rate = s28 / min(28, max(days_known, 7))
            pos = stock[(sku, wh)] + on_order[(sku, wh)] - reserved[(sku, wh)]
            lead = LEAD[STYLE_SUP[p["style"]]][1]
            if (rate > 0 and pos <= rate * (lead + 14) + 1) or (pos <= 1 and (rate > 0 or any(sold[(sku, wh)].values()))):
                tgt = math.ceil(rate * 38 * 1.25) + (2 if rate > .05 else 0)
                q = max(tgt - pos, 6)
                q = q + (q % 2)
                groups[(STYLE_SUP[p["style"]], wh)].append((sku, q))
    for (sk, wh), items in sorted(groups.items()):
        po_seq[0] += 1
        ref = "R%03d" % po_seq[0]
        sup = next(s for s in SUPPLIERS if s[0] == sk)
        note = f"Weekly replenishment {d:%d %b %Y} - {sup[1]} (ref {ref})"
        ev(d, P_STOCK, "select pg_temp.po_new(%s, %s, %s, '%s'::jsonb);" % (q_(note), q_(sup[1]), q_(wh), lines_json([(s, q, None, None) for s, q in items])))
        for s, q in items: on_order[(s, wh)] += q
        lead = R.randint(*LEAD[sk])
        two_part = R.random() < .2
        parts = [(d + dt.timedelta(days=lead), 1.0)] if not two_part else [(d + dt.timedelta(days=lead), .65), (d + dt.timedelta(days=lead + 4), .35)]
        given = {s: 0 for s, _ in items}
        for pi, (gd, frac) in enumerate(parts):
            gl = []
            for s, q in items:
                want = q - given[s] if pi == len(parts) - 1 else int(round(q * frac))
                if want <= 0: continue
                rej = 1 if (R.random() < .12 and want >= 6) else 0
                gl.append((s, want, want - rej, rej)); given[s] += want
            if gd > TODAY: continue
            bill_no_seq[sk] += 1
            inv = "%s/%d/%04d" % (sk, 26, bill_no_seq[sk] * 7 + 100 + R.randint(0, 6))
            ev(gd, P_STOCK, "select pg_temp.grn_new(%s, %s, '%s'::jsonb);" % (q_(note), q_("DC-%s-%04d" % (sk, bill_no_seq[sk] * 3 + 40)), lines_json([(s, w, a, r) for s, w, a, r in gl])))
            arrivals[gd].append([(s, wh, a) for s, w, a, r in gl])
            for s, w, a, r in gl: on_order[(s, wh)] -= w
            bd = gd + dt.timedelta(days=1)
            ev(bd, P_STOCK, "select pg_temp.bill_po(%s, %s, 1);" % (q_(note), q_(inv)))
            bills.append((sk, bd, bd + dt.timedelta(days=sup[4] - 1)))
            if gd + dt.timedelta(days=1) > TODAY: pass
def q_(s): return "'" + str(s).replace("'", "''") + "'"

# ------------------------------------------------------------------ orders and what happens to them
seq = {"SHOP": 1000, "AMAZ": 1000, "FLIP": 1000}
by_day = defaultdict(list)                       # date -> [Order]
cod_pool = []                                    # [ext, courier, collected date, amount, remitted?]
deliveries = defaultdict(list)                   # (channel, date) -> [Order]   delivered prepaid orders (settlement base)
refund_log = defaultdict(list)                   # (channel, date) -> [ext]     marketplace refunds netted in settlements
claims_log = []
awb_seq = [31000000]
SPECIAL = {"cancel_after_dispatch": set()}
def pick_status(o, age):
    cod = o.cod
    r = R.random()
    if age >= 12:
        rto_p = (.11 if cod else .02) if o.ch != "SHOP" or cod else 0
        if o.ch == "SHOP" and not cod: rto_p = 0
        if r < .03: return "cancelled"
        if r < .03 + rto_p: return "rto"
        return "delivered"
    if age >= 6:
        if r < .04: return "cancelled"
        if r < .08 and (cod or o.ch != "SHOP"): return "rto"
        return "delivered" if r < .72 else "shipped"
    if age >= 3:
        if r < .06: return "cancelled"
        return "shipped" if r < .70 else "delivered" if r < .78 else "processing"
    if age >= 1:
        if r < .05: return "cancelled"
        return "processing" if r < .62 else "pending" if r < .95 else "shipped"
    return "pending" if r < .7 else "processing"

SPECIAL_WANT = [(dt.date(2026, 8, 14), 'FLIP'), (dt.date(2026, 9, 21), 'AMAZ')]   # first order on/after the date that is cancelled after it was already dispatched
def make_orders(d):
    n = day_orders(d)
    sale = dt.date(2026, 9, 24) <= d <= dt.date(2026, 10, 4)
    for _ in range(n):
        ch = wchoice([("SHOP", .34 if not sale else .22), ("AMAZ", .38 if not sale else .45), ("FLIP", .28 if not sale else .33)])
        cod = R.random() < {"SHOP": .38, "FLIP": .26, "AMAZ": .07}[ch]
        special = next((w for w in SPECIAL_WANT if d >= w[0] and ch == w[1]), None)
        if special: SPECIAL_WANT.remove(special)
        if special: cod = False
        state = wchoice([(s, w * (1.6 if ch == "SHOP" and s == "Gujarat" else 1)) for s, w in STATES])
        pref = wh_for_state(state)
        gender = wchoice(GENDER_MIX)
        nl = wchoice([(1, .45), (2, .33), (3, .15), (4, .07)])
        wh = None; lines = []
        for try_wh in (pref, MUM if pref == SUR else SUR):
            cand = [p for p in ACTIVE if p["gender"] == gender and ch in LISTED[p["sku"]] and avail(p["sku"], try_wh) >= 1]
            if len(cand) < 1: continue
            chosen = []
            for _k in range(nl):
                pool = [p for p in cand if p["sku"] not in {c["sku"] for c in chosen}]
                if not pool: break
                if R.random() < .15:       # mixed basket: someone from another gender
                    alt = [p for p in ACTIVE if ch in LISTED[p["sku"]] and avail(p["sku"], try_wh) >= 1 and p["sku"] not in {c["sku"] for c in chosen}]
                    pool = alt or pool
                chosen.append(R.choices(pool, [BASE_W[p["sku"]] * season(p["category"], d) for p in pool])[0])
            wh = try_wh; lines = chosen
            break
        if not lines: continue
        pct = R.choice(disc_choices(d, ch))
        L = []
        for p in lines:
            qty = min(wchoice([(1, .72), (2, .22), (3, .06)]), avail(p["sku"], wh))
            gross = d2(qty * p["price"]); disc = d2(gross * pct); tax = d2((gross - disc) * p["rate"] / 100)
            L.append(dict(sku=p["sku"], qty=qty, up=p["price"], disc=disc, tax=tax, gross=gross))
        o = Order(); seq[ch] += 1
        o.ext = f"{ch}-{seq[ch]}"; o.ch = ch; o.date = d; o.cod = cod; o.state = state; o.wh = wh
        o.cust = R.choice(NAMES); o.lines = L
        o.hour = R.randint(9, 22); o.minute = R.randint(0, 59)
        o.gross = d2(sum(l["gross"] for l in L)); o.disc = d2(sum(l["disc"] for l in L)); o.tax = d2(sum(l["tax"] for l in L))
        o.net = d2(o.gross - o.disc + o.tax)
        o.status = pick_status(o, (TODAY - d).days)
        o.cancel_next = False
        if special:
            o.status = "shipped"; o.cancel_next = True
        o.deliv = None; o.courier = R.choice(COURIERS)
        o.ret = None; o.rto = None
        if o.status == "delivered":
            o.deliv = d + dt.timedelta(days=R.randint(3, 6))
            if o.deliv > TODAY: o.status = "shipped"; o.deliv = None
        o.pay = ("refunded" if not cod else "failed") if o.status == "cancelled" else ("paid" if (not cod and o.status != "pending") else "pending")
        if o.status == "pending" and not cod: o.pay = "pending"
        by_day[d].append(o); orders.append(o)
        plan_after = True
        dispatched = o.status in ("shipped", "delivered", "rto")
        if o.cancel_next: ev(d + dt.timedelta(days=1), P_OPS, "select pg_temp.cancel_order(%s);" % q_(o.ext))
        for l in L:
            if dispatched:
                stock[(l["sku"], wh)] -= l["qty"]; sold[(l["sku"], wh)][d] = sold[(l["sku"], wh)].get(d, 0) + l["qty"]
            elif o.status in ("pending", "processing"): reserved[(l["sku"], wh)] += l["qty"]
        plan_followups([o])

restocks = defaultdict(list)
def plan_followups(olist):
    """What happens after the order date: delivery, COD, returns, RTO, claims. Scheduled as dated events."""
    ret_rate = {"SHOP": .06, "AMAZ": .11, "FLIP": .13}
    rsn = ["Size did not fit", "Colour different from photo", "Item arrived damaged", "Customer changed mind", "Wrong item delivered", "Fabric quality not as expected"]
    for o in olist:
        if o.status == "delivered" and o.cod:
            ev(o.deliv, P_OPS, "select pg_temp.cod_collect(array[%s]::text[]);" % q_(o.ext))
            cod_pool.append([o.ext, o.courier, o.deliv, o.net])
        if o.status == "delivered" and not o.cod:
            deliveries[(o.ch, o.deliv)].append(o)
            if R.random() < ret_rate[o.ch]:
                r0 = o.deliv + dt.timedelta(days=R.randint(2, 7))
                reason = R.choice(rsn)
                insp = wchoice([("good", 72), ("damaged", 15), ("wrong_item", 8), ("missing", 5)])
                if reason == "Item arrived damaged" and insp == "good": insp = "damaged"
                src = "webhook" if o.ch != "SHOP" or R.random() < .5 else "manual"
                o.ret = dict(r0=r0, reason=reason, insp=insp, src=src, rej=(R.random() < .04))
                ev(r0, P_OPS, "select pg_temp.ret_new(%s, %s, %s);" % (q_(o.ext), q_(reason), q_(src)))
                ev(r0 + dt.timedelta(days=1), P_OPS, "select pg_temp.ret_set(%s, 'approved');" % q_(o.ext))
                if o.ret["rej"]:
                    ev(r0 + dt.timedelta(days=1), P_OPS, "select pg_temp.ret_reject(%s);" % q_(o.ext)); continue
                ev(r0 + dt.timedelta(days=2), P_OPS, "select pg_temp.ret_set(%s, 'pickup');" % q_(o.ext))
                ev(r0 + dt.timedelta(days=4), P_OPS, "select pg_temp.ret_set(%s, 'in_transit');" % q_(o.ext))
                rc = r0 + dt.timedelta(days=R.randint(6, 8)); o.ret["recv"] = rc
                ev(rc, P_OPS, "select pg_temp.ret_recv(%s);" % q_(o.ext))
                disp = {"good": "restocked", "damaged": "quarantined", "wrong_item": "claimed", "missing": "claimed"}[insp]
                dd = rc + dt.timedelta(days=R.randint(1, 2)); o.ret["disp_date"] = dd; o.ret["disp"] = disp
                ev(dd, P_OPS, "select pg_temp.ret_dispo(%s, %s, %s);" % (q_(o.ext), q_(insp), q_(disp)))
                if disp == "restocked": restocks[dd].extend((l["sku"], o.wh, l["qty"]) for l in o.lines)
                if o.ch == "SHOP":
                    rf = dd + dt.timedelta(days=R.randint(1, 3)); o.ret["refund"] = rf
                    ev(rf, P_OPS, "select pg_temp.ret_refund_d2c(%s, %s);" % (q_(o.ext), q_("UPI-REFUND-%s" % o.ext)))
                else:
                    refund_log[(o.ch, rc)].append(o.ext)
                if disp == "claimed" or (disp == "quarantined" and o.ch != "SHOP"):
                    ctype = "damaged_return" if disp == "quarantined" else ("other" if insp == "wrong_item" else "lost_shipment")
                    claims_log.append((o, ctype, dd))
        if o.status == "rto":
            a0 = o.date + dt.timedelta(days=R.randint(4, 6))
            awb_seq[0] += R.randint(3, 40)
            reason = R.choice(["Customer refused delivery", "Address incomplete", "Customer unreachable", "Delivery attempts exhausted"])
            lost = R.random() < .12 and o.ch != "SHOP"
            o.rto = dict(a0=a0, awb="AWB%d" % awb_seq[0], lost=lost)
            ev(a0, P_OPS, "select pg_temp.rto_new(%s, %s, %s);" % (q_(o.ext), q_(o.rto["awb"]), q_(reason)))
            ev(a0 + dt.timedelta(days=2), P_OPS, "select pg_temp.rto_set(%s, 'in_transit');" % q_(o.ext))
            if lost:
                claims_log.append((o, "lost_shipment", a0 + dt.timedelta(days=24)))
            else:
                rc = a0 + dt.timedelta(days=R.randint(5, 8)); insp = wchoice([("good", 80), ("damaged", 20)])
                o.rto["recv"] = rc; o.rto["insp"] = insp
                if insp == "good": restocks[rc + dt.timedelta(days=0)].extend((l["sku"], o.wh, l["qty"]) for l in o.lines)
                ev(rc, P_OPS, "select pg_temp.rto_recv(%s, %s, %s);" % (q_(o.ext), q_(insp), q_("restocked" if insp == "good" else "quarantined")))

# ------------------------------------------------------------------ settlements, COD remittance, payments, claims, stock-takes
SETTLE_CFG = {"AMAZ": ("AMZ", 7, "Amazon - Seller Central"), "FLIP": ("FLK", 9, "Flipkart - Seller Hub"), "SHOP": ("SHP", 3, "Shopify - Main Store")}
settle_idx = defaultdict(int)
SHORT = {("AMAZ", 9): 320.0, ("AMAZ", 20): 85.0, ("FLIP", 12): 140.0, ("FLIP", 21): -60.0}
settlements = []                                 # (ref, ch, ws, we, orders, refunds, pay_date, short)
def plan_settlements(d):
    """Called on a Monday: the week that ended yesterday is statemented; the payout follows after the channel's cycle."""
    we = d - dt.timedelta(days=1); ws = max(we - dt.timedelta(days=6), START)
    for ch, (pref, lag, cname) in SETTLE_CFG.items():
        span = (we - ws).days + 1                      # the first statement is shorter than a week: do not run past its end
        ords = [o for k in range(span) for o in deliveries.get((ch, ws + dt.timedelta(days=k)), [])]
        refs = [e for k in range(span) for e in refund_log.get((ch, ws + dt.timedelta(days=k)), [])]
        if not ords and not refs: continue
        settle_idx[ch] += 1
        ref = "%s-STL-%s" % (pref, ws.strftime("%Y%m%d"))
        pay = we + dt.timedelta(days=lag)
        short = SHORT.get((ch, settle_idx[ch]), 0.0)
        ev(d, P_SETTLE, "select pg_temp.settle_new(%s, %s, %s, %s, array[%s]::text[], array[%s]::text[]);" % (
            q_(cname), q_(ref), q_(ws.isoformat()), q_(we.isoformat()), ",".join(q_(o.ext) for o in ords), ",".join(q_(e) for e in refs)))
        ev(pay, P_SETTLE, "select pg_temp.settle_pay(%s, %s);" % (q_(ref), repr(short)))
        settlements.append((ref, ch, ws, we, ords, refs, pay, short))
        if short and pay <= TODAY:
            o = ords[0]
            claims_log.append((o, "incorrect_deduction" if short > 0 else "excess_deduction", pay + dt.timedelta(days=2), abs(short)))

def plan_cod_remit(d):
    for courier in COURIERS:
        batch = [c for c in cod_pool if c[1] == courier and c[2] <= d - dt.timedelta(days=2) and len(c) == 4]
        if not batch: continue
        short = 0.0
        if d == dt.date(2026, 9, 18):
            short = d2(min(450, batch[0][3] * .5))
        for c in batch: c.append("done")
        ref = "COD-%s-%s" % (courier.split(" ")[0].upper(), d.strftime("%d%b").upper())
        ev(d, P_SETTLE, "select pg_temp.cod_remit(%s, %s, array[%s]::text[], %s);" % (q_(courier), q_(ref), ",".join(q_(c[0]) for c in batch), repr(short)))

def plan_payments(d):
    for sk, name, *_ in SUPPLIERS:
        utr_seq[0] += R.randint(11, 97)
        frac = .5 if (sk == "KDW" and d == dt.date(2026, 8, 14)) else 1
        ev(d, P_PAY, "select pg_temp.pay_due(%s, %s, %s, %s);" % (q_(name), q_((d + dt.timedelta(days=3)).isoformat()), q_("ICIC%012d" % utr_seq[0]), repr(frac)))

def plan_claims():
    for item in claims_log:
        o, ctype, c0 = item[0], item[1], item[2]
        amt = item[3] if len(item) > 3 else (o.net if ctype != "damaged_return" else d2(o.net * .6))
        ev(c0, P_CLAIM, "select pg_temp.claim_new(%s, %s, %s, %s);" % (q_(o.ext), q_(ctype), repr(amt), q_((c0 + dt.timedelta(days=30)).isoformat())))
        fate = R.random()
        ev(c0 + dt.timedelta(days=3), P_CLAIM, "select pg_temp.claim_step(%s, %s, 'claimed', null);" % (q_(o.ext), q_(ctype)))
        if fate < .72:
            part = d2(amt * .8) if R.random() < .3 else None
            ev(c0 + dt.timedelta(days=14), P_CLAIM, "select pg_temp.claim_step(%s, %s, 'approved', %s);" % (q_(o.ext), q_(ctype), "null" if part is None else repr(part)))
            if R.random() < .75:
                ev(c0 + dt.timedelta(days=25), P_CLAIM, "select pg_temp.claim_recover(%s, %s, %s);" % (q_(o.ext), q_(ctype), q_("CLAIM-CR-%s" % o.ext)))
        elif fate < .88:
            ev(c0 + dt.timedelta(days=14), P_CLAIM, "select pg_temp.claim_step(%s, %s, 'rejected', null);" % (q_(o.ext), q_(ctype)))

def plan_stocktakes(d):
    pool = [(k, v) for k, v in stock.items() if v >= 4 and k[0] in {p["sku"] for p in ACTIVE}]
    pool.sort(key=lambda kv: kv[0])
    for (sku, wh), v in R.sample(pool, 14):
        delta = R.choice([-1, -1, -2, 1])
        stock[(sku, wh)] += delta
        ev(d, P_STOCK, "select pg_temp.adjust(%s, %s, %d);" % (q_(sku), q_(wh), delta))

# ------------------------------------------------------------------ run the calendar
def run():
    d = START
    while d <= TODAY:
        for lst in arrivals.pop(d, []):
            for sku, wh, a in lst: stock[(sku, wh)] += a
        if d.weekday() == 0 and d > START: replenish(d)
        make_orders(d)
        for sku, wh, qty in restocks.pop(d, []): stock[(sku, wh)] += qty     # returns are put back after the day's dispatches
        if d in (dt.date(2026, 6, 30), dt.date(2026, 9, 30)): plan_stocktakes(d)
        if d.weekday() == 0 and d > START: plan_settlements(d)
        if d.weekday() == 4: plan_cod_remit(d); plan_payments(d)
        d += dt.timedelta(days=1)
    plan_claims()
    for o in orders:
        if o.status == "cancelled" and o.ch == "AMAZ": pass
run()
print("orders", len(orders), "events days", len(events), "settlements", len(settlements), "claims", len(claims_log))
