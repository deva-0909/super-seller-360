import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { BillForm } from "../bill-form";

export default async function NewBillPage() {
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data: suppliers }, { data: ledgers }] = await Promise.all([
    supabase.from("suppliers").select("supplier_id, name, gstin").eq("status", "active").order("name"),
    supabase.from("ledgers").select("ledger_id, name, nature").eq("status", "active").in("nature", ["expense", "asset"]).order("name"),
  ]);
  const options = (ledgers ?? []).filter((l) => l.nature === "expense" || l.name === "Inventory - Stock-in-Trade");
  const def = options.find((l) => l.name === "Inventory - Stock-in-Trade")?.ledger_id ?? options[0]?.ledger_id ?? "";
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Enter a purchase bill</h1>
      <p className="mt-1 text-sm text-ink-muted">Goods for resale go to Inventory. Services and running costs go to the matching expense ledger. A second person approves it before anything is posted.</p>
      {canWrite ? <BillForm suppliers={suppliers ?? []} ledgers={options} defaultLedger={def} /> : <p className="mt-4 text-sm text-ink-muted">Your role can view purchase bills but not enter them.</p>}
    </div>
  );
}
