import { createClient } from "@/lib/supabase/server";
import { JournalForm, type LedgerOpt } from "../journal-form";

export default async function NewJournalPage() {
  const supabase = await createClient();
  const [{ data: lg }, { data: canWrite }] = await Promise.all([
    supabase.from("ledgers").select("ledger_id, name, account_groups(name)").eq("status", "active").order("name"),
    supabase.rpc("has_accounting_write"),
  ]);
  const ledgers: LedgerOpt[] = ((lg ?? []) as unknown as { ledger_id: string; name: string; account_groups: { name: string } | null }[]).map((l) => ({
    ledger_id: l.ledger_id, name: l.name, group: l.account_groups?.name ?? "Other",
  }));
  return (
    <div className="px-4 md:px-8 py-6">
      <h1 className="text-xl font-semibold text-ink">New journal entry</h1>
      <p className="mb-5 mt-1 text-sm text-ink-muted">Debits must equal credits. Tick “recurring” for rent, subscriptions, depreciation and other entries that repeat.</p>
      <JournalForm ledgers={ledgers} canWrite={canWrite === true} />
    </div>
  );
}
