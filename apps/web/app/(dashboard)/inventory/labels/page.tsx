import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fetchAll } from "@/lib/fetch-all";
import { LabelPrinter, type LabelProduct } from "./label-printer";

type P = { product_id: string; sku: string; name: string; size: string | null; colour: string | null; category: string | null; internal_code: string | null; barcode: string | null; status: string };

export default async function LabelsPage() {
  const supabase = await createClient();
  const [prods, codes, log, { data: canPrint }] = await Promise.all([
    fetchAll<P>(() => supabase.from("products").select("product_id, sku, name, size, colour, category, internal_code, barcode, status").order("sku")),
    fetchAll<{ code_id: string; product_id: string; code: string; kind: string; pack_qty: number }>(() => supabase.from("product_barcodes").select("code_id, product_id, code, kind, pack_qty").order("created_at")),
    fetchAll<{ log_id: string; product_id: string; copies: number; printed_at: string }>(() => supabase.from("product_label_log").select("log_id, product_id, copies, printed_at").order("printed_at", { ascending: false })),
    supabase.rpc("has_grn_write"),
  ]);
  const byCode = new Map<string, LabelProduct["codes"]>();
  for (const c of codes.data) byCode.set(c.product_id, [...(byCode.get(c.product_id) ?? []), { code_id: c.code_id, code: c.code, kind: c.kind, pack_qty: Number(c.pack_qty) }]);
  const printed = new Map<string, { copies: number; last: string }>();
  for (const l of log.data) { const p = printed.get(l.product_id); printed.set(l.product_id, { copies: (p?.copies ?? 0) + Number(l.copies), last: p?.last ?? l.printed_at.slice(0, 10) }); }
  const products: LabelProduct[] = prods.data.filter((p) => p.internal_code).map((p) => ({
    product_id: p.product_id, sku: p.sku, name: p.name, size: p.size, colour: p.colour, category: p.category, internal_code: p.internal_code!, main_barcode: p.barcode, status: p.status,
    codes: byCode.get(p.product_id) ?? [], printed_copies: printed.get(p.product_id)?.copies ?? 0, last_printed: printed.get(p.product_id)?.last ?? null,
  }));
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/inventory" className="text-xs text-accent hover:underline">← Inventory</Link>
      <h1 className="mt-1 text-lg font-semibold tracking-tight text-ink">Product labels</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">
        Every product has one barcode and QR of our own that never changes. Stick it on the goods when they arrive; the supplier&apos;s barcode stays linked to the same product, so either label scans to the right item.
      </p>
      {prods.error ? <p className="mt-3 text-sm text-danger">Could not load products: {prods.error}</p> : null}
      <div className="mt-4"><LabelPrinter products={products} canPrint={canPrint === true} /></div>
    </div>
  );
}
