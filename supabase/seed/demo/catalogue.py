"""Garment catalogue shared by the demo-story generators (same styles as gen_garment_seed.py / migration 0045)."""
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
#print("SKUs:", len(products), {g: sum(1 for p in products if p['gender'] == g) for g in ("Men", "Women", "Boys", "Girls")})
PBY = {p["sku"]: p for p in products}


# which channels each SKU is listed on: every SKU on Shopify, ~78% on Amazon, ~62% on Flipkart (fixed seed, so always the same)
import random as _r
_L = _r.Random(77)
LISTED = {}
for _p in products:
    _c = {"SHOP"}
    if _L.random() < .78: _c.add("AMAZ")
    if _L.random() < .62: _c.add("FLIP")
    LISTED[_p["sku"]] = _c
