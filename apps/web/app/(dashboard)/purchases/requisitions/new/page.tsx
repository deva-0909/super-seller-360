import { createClient } from "@/lib/supabase/server";
import { ReqForm } from "./req-form";

export default async function NewRequisitionPage() {
  const supabase = await createClient();
  const [{ data: canWrite }, { data: warehouses }, { data: products }] = await Promise.all([
    supabase.rpc("has_req_write"),
    supabase.from("warehouses").select("warehouse_id, name").eq("status", "active").order("name"),
    supabase.from("products").select("product_id, sku, name").eq("status", "active").order("sku").limit(2000),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">New requisition</h1>
      {canWrite === true ? <ReqForm warehouses={warehouses ?? []} products={products ?? []} />
        : <p className="mt-4 text-sm text-ink-muted">Your role cannot raise requisitions.</p>}
    </div>
  );
}
