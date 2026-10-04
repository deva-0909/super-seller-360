import { createClient } from "@/lib/supabase/server";
import { LedgerManager, type GroupRow, type LedgerRow } from "./ledger-manager";

// post_sales_voucher / reconcile_settlement (older code) find these accounts by exact name.
const LOCKED = new Set([
  "Trade Receivables", "Sales Revenue", "CGST Payable (Output)", "SGST Payable (Output)", "IGST Payable (Output)",
  "GST Payable (Output)", "GST Input Tax Credit (ITC)", "Marketplace Commission Expense",
]);

export default async function LedgersPage() {
  const supabase = await createClient();
  const [{ data: lg }, { data: gr }, { data: canEdit }] = await Promise.all([
    supabase.from("ledgers").select("ledger_id, name, nature, status, account_group_id, account_groups(name)").order("name"),
    supabase.from("account_groups").select("account_group_id, name, nature, is_primary").eq("status", "active").order("name"),
    supabase.rpc("has_accounting_write"),
  ]);
  const ledgers: LedgerRow[] = ((lg ?? []) as unknown as (Omit<LedgerRow, "group" | "locked"> & { account_groups: { name: string } | null })[]).map((l) => ({
    ledger_id: l.ledger_id, name: l.name, nature: l.nature, status: l.status, account_group_id: l.account_group_id,
    group: l.account_groups?.name ?? "Other", locked: LOCKED.has(l.name),
  }));
  const groups = ((gr ?? []) as unknown as (GroupRow & { is_primary: boolean })[]).filter((g) => !g.is_primary);
  return <LedgerManager ledgers={ledgers} groups={groups} canEdit={canEdit === true} />;
}
