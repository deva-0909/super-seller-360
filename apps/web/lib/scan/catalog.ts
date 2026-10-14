// Everything a scanner may read, kept in memory while the screen is open, so a scan is answered instantly (no round trip per item).

export type CatRow = {
  code: string; product_id: string; sku: string; product_name: string; size: string | null; colour: string | null;
  lot_tracked: boolean; status: string; pack_qty: number; kind: string;
};
export type Hit = { product_id: string; sku: string; name: string; label: string; lot_tracked: boolean; status: string; pack_qty: number; kind: string };
export type Lookup = { kind: "none" } | { kind: "one"; hit: Hit } | { kind: "many"; hits: Hit[] };

export const normCode = (s: string) => s.replace(/[\u0000-\u001f]/g, "").trim().toLowerCase();

const toHit = (r: CatRow): Hit => ({
  product_id: r.product_id, sku: r.sku, name: r.product_name, lot_tracked: r.lot_tracked, status: r.status, pack_qty: Number(r.pack_qty) || 1, kind: r.kind,
  label: `${r.sku} · ${r.product_name}${r.size ? ` · ${r.size}` : ""}${r.colour ? ` · ${r.colour}` : ""}`,
});

export type CodeIndex = Map<string, Hit[]>;

export function buildIndex(rows: CatRow[]): CodeIndex {
  const idx: CodeIndex = new Map();
  for (const r of rows) {
    const list = idx.get(r.code) ?? [];
    const i = list.findIndex((h) => h.product_id === r.product_id);
    // the same product reached by barcode and by SKU is one hit; keep the more specific one (a carton code carries a pack size)
    if (i === -1) list.push(toHit(r));
    else if (r.kind !== "sku" && list[i].kind === "sku") list[i] = toHit(r);
    idx.set(r.code, list);
  }
  return idx;
}

export function lookup(idx: CodeIndex, raw: string): Lookup {
  const c = normCode(raw);
  if (!c) return { kind: "none" };
  // a 12-digit UPC-A and a 13-digit EAN with a leading zero are the same code
  const tries = [c];
  if (/^\d{12}$/.test(c)) tries.push("0" + c);
  if (/^0\d{12}$/.test(c)) tries.push(c.slice(1));
  for (const t of tries) {
    const hits = idx.get(t);
    if (hits?.length === 1) return { kind: "one", hit: hits[0] };
    if (hits && hits.length > 1) return { kind: "many", hits };
  }
  return { kind: "none" };
}

/** One entry per product, for the "link this code to a product" picker. */
export function productsFromCatalog(rows: CatRow[]): { product_id: string; label: string }[] {
  const seen = new Map<string, string>();
  for (const r of rows) if (!seen.has(r.product_id)) seen.set(r.product_id, toHit(r).label);
  return [...seen.entries()].map(([product_id, label]) => ({ product_id, label })).sort((a, b) => a.label.localeCompare(b.label));
}
