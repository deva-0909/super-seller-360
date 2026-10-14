import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fetchAll } from "@/lib/fetch-all";
import type { CatRow } from "@/lib/scan/catalog";
import { StockInHost } from "./host";

const REASON: Record<string, string> = {
  direct_purchase: "Direct purchase", free_goods: "Free goods", sample: "Sample", supplier_replacement: "Supplier replacement", not_on_order: "Not on the order", other: "Other",
};

export default async function StockInPage() {
  const supabase = await createClient();
  const { data: canGrn } = await supabase.rpc("has_grn_write");
  if (canGrn !== true) {
    return (
      <div className="px-4 md:px-8 py-8">
        <h1 className="text-lg font-semibold tracking-tight text-ink">Stock in</h1>
        <p className="mt-4 text-sm text-ink-muted">Your role can view stock but not receive goods. Operations and Warehouse roles can.</p>
      </div>
    );
  }
  const { data: u } = await supabase.auth.getUser();
  const [cat, { data: whs }, { data: scope }, { data: sups }, { data: recent }] = await Promise.all([
    fetchAll<CatRow>(() => supabase.rpc("scan_catalog")),
    supabase.from("warehouses").select("warehouse_id, name").eq("status", "active").order("name"),
    supabase.from("user_warehouse_scope").select("warehouse_id").eq("user_id", u.user?.id ?? ""),
    supabase.from("suppliers").select("supplier_id, name").eq("status", "active").order("name"),
    supabase.from("stock_ins").select("stock_in_id, si_no, received_on, reason, via, ref_no, created_at, warehouses(name), suppliers(name), stock_in_lines(quantity)").order("created_at", { ascending: false }).limit(15),
  ]);
  const mine = new Set((scope ?? []).map((s) => s.warehouse_id));
  // a warehouse person sees only the warehouses they are assigned to; others see all
  const warehouses = (whs ?? []).filter((w) => mine.size === 0 || mine.has(w.warehouse_id)).map((w) => ({ id: w.warehouse_id, label: w.name }));
  const suppliers = (sups ?? []).map((s) => ({ id: s.supplier_id, label: s.name }));

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link href="/inventory" className="text-xs text-accent hover:underline">← Inventory</Link>
          <h1 className="mt-1 text-lg font-semibold tracking-tight text-ink">Stock in</h1>
          <p className="mt-1 max-w-3xl text-sm text-ink-muted">
            Receive goods that did not come through a purchase order: a walk-in purchase, free goods, samples, a supplier replacement. Scan with a scanner or the phone camera, or paste or upload a list for 100 or more items.
            Goods that arrive against an order are received on that order&apos;s page.
          </p>
        </div>
      </div>
      {cat.error ? <p className="mt-3 text-sm text-danger">Could not load the product codes: {cat.error}</p> : null}
      <div className="mt-4">
        <StockInHost catalog={cat.data} warehouses={warehouses} suppliers={suppliers} defaultWarehouse={warehouses[0]?.id ?? ""} />
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Recent stock-ins</h2>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-2 font-medium">No.</th><th className="px-3 py-2 font-medium">Date</th><th className="px-3 py-2 font-medium">Warehouse</th><th className="px-3 py-2 font-medium">Why</th><th className="px-3 py-2 font-medium">Supplier</th><th className="px-3 py-2 font-medium">Challan</th><th className="px-3 py-2 text-right font-medium">Units</th></tr></thead>
          <tbody>
            {(recent ?? []).map((r) => (
              <tr key={r.stock_in_id} className="border-b border-line/60">
                <td className="px-3 py-2 font-data">{r.si_no}</td><td className="px-3 py-2">{r.received_on}</td>
                <td className="px-3 py-2">{(r.warehouses as unknown as { name: string } | null)?.name}</td>
                <td className="px-3 py-2">{REASON[r.reason] ?? r.reason}</td>
                <td className="px-3 py-2">{(r.suppliers as unknown as { name: string } | null)?.name ?? "—"}</td>
                <td className="px-3 py-2">{r.ref_no ?? "—"}</td>
                <td className="px-3 py-2 text-right font-data">{((r.stock_in_lines as unknown as { quantity: number }[]) ?? []).reduce((s, l) => s + Number(l.quantity), 0)}</td>
              </tr>
            ))}
            {!(recent ?? []).length ? <tr><td colSpan={7} className="px-3 py-6 text-center text-sm text-ink-muted">No stock-ins yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
