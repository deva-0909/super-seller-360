import { createClient } from "@/lib/supabase/server";
import { fetchAll } from "@/lib/fetch-all";
import type { CatRow } from "@/lib/scan/catalog";
import { TransferSend } from "./transfer-send";

export default async function NewTransferPage() {
  const supabase = await createClient();
  const { data: canWrite } = await supabase.rpc("has_grn_write");
  if (canWrite !== true) return <div className="px-4 md:px-8 py-8"><h1 className="text-lg font-semibold text-ink">New transfer</h1><p className="mt-4 text-sm text-ink-muted">Your role cannot send stock. Operations and Warehouse roles can.</p></div>;
  const { data: u } = await supabase.auth.getUser();
  const [cat, { data: whs }, { data: scope }] = await Promise.all([
    fetchAll<CatRow>(() => supabase.rpc("scan_catalog")),
    supabase.from("warehouses").select("warehouse_id, name").eq("status", "active").order("name"),
    supabase.from("user_warehouse_scope").select("warehouse_id").eq("user_id", u.user?.id ?? ""),
  ]);
  const mine = new Set((scope ?? []).map((s) => s.warehouse_id));
  const from = (whs ?? []).filter((w) => mine.size === 0 || mine.has(w.warehouse_id));
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">New transfer</h1>
      <p className="mt-1 text-sm text-ink-muted">Scan what is leaving. Stock is taken out of the sending store when you dispatch.</p>
      {cat.error ? <p className="mt-3 text-sm text-danger">Could not load the product codes: {cat.error}</p> : null}
      <div className="mt-4"><TransferSend catalog={cat.data} from={from} all={whs ?? []} /></div>
    </div>
  );
}
