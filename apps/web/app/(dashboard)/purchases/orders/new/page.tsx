import { createClient } from "@/lib/supabase/server";
import { PoForm } from "../po-form";

export default async function NewOrderPage({ searchParams }: { searchParams: Promise<{ supplier?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const [{ data: canWrite }, { data: suppliers }, { data: warehouses }, { data: products }] = await Promise.all([
    supabase.rpc("has_po_write"),
    supabase.from("suppliers").select("supplier_id, name").eq("status", "active").order("name"),
    supabase.from("warehouses").select("warehouse_id, name").order("name"),
    supabase.from("products").select("product_id, sku, name, cost_price, gst_rate").eq("status", "active").order("sku").limit(2000),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">New purchase order</h1>
      {canWrite === true ? <PoForm suppliers={suppliers ?? []} warehouses={warehouses ?? []} products={(products ?? []).map((p) => ({ ...p, cost_price: p.cost_price == null ? null : Number(p.cost_price), gst_rate: p.gst_rate == null ? null : Number(p.gst_rate) }))} supplier={sp.supplier} />
        : <p className="mt-4 text-sm text-ink-muted">Your role cannot raise purchase orders.</p>}
    </div>
  );
}
