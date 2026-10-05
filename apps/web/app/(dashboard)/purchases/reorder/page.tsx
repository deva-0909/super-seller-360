import { createClient } from "@/lib/supabase/server";
import { ReorderTable } from "./reorder-table";

export default async function ReorderPage() {
  const supabase = await createClient();
  const [{ data: rows }, { data: suppliers }, { data: warehouses }, { data: canWrite }] = await Promise.all([
    supabase.from("reorder_suggestions").select("product_id, sku, name, on_hand, reserved, on_order, sold_per_day, days_cover, needs_reorder, suggested_qty, reorder_level, lead_time_days, preferred_supplier_id").order("needs_reorder", { ascending: false }).order("sku").limit(1000),
    supabase.from("suppliers").select("supplier_id, name").eq("status", "active").order("name"),
    supabase.from("warehouses").select("warehouse_id, name").order("name"),
    supabase.rpc("has_po_write"),
  ]);
  const data = (rows ?? []).map((r) => ({ ...r, on_hand: Number(r.on_hand), reserved: Number(r.reserved), on_order: Number(r.on_order), sold_per_day: Number(r.sold_per_day), days_cover: r.days_cover == null ? null : Number(r.days_cover), suggested_qty: Number(r.suggested_qty), reorder_level: r.reorder_level == null ? null : Number(r.reorder_level) }));
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Re-order suggestions</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Based on stock, what is promised to orders, what is already on order and the last 30 days of sales. Set a re-order level, a re-order quantity or a lead time on a product and it shows here when it runs low.</p>
      <ReorderTable rows={data} suppliers={suppliers ?? []} warehouses={warehouses ?? []} canWrite={canWrite === true} />
    </div>
  );
}
