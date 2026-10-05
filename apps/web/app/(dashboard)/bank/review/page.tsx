import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { ReviewTable, type ReviewLine, type Opt } from "./review-table";
import { PayeeRules, type PayeeRule } from "./payee-rules";

export default async function ReviewPage({ searchParams }: { searchParams: Promise<{ account?: string }> }) {
  const { account } = await searchParams;
  const supabase = await createClient();
  const { data: accountsRaw } = await supabase.from("bank_accounts").select("bank_account_id, bank_name, account_number_last4, ledger_id").eq("status", "active").order("bank_name");
  const accounts = accountsRaw ?? [];
  const acct = accounts.find((a) => a.bank_account_id === account) ?? accounts[0];
  if (!acct) {
    return <div className="px-4 md:px-8 py-8"><h1 className="text-lg font-semibold tracking-tight text-ink">For review</h1><p className="mt-3 text-sm text-ink-muted">Add a bank account first (Bank transactions tab), then come back here.</p></div>;
  }

  const [{ data: linesRaw, error }, { data: ledgersRaw }, { data: suppliersRaw }, { data: rulesRaw }, { data: w }] = await Promise.all([
    supabase.rpc("bank_review_list", { p_bank_account_id: acct.bank_account_id, p_limit: 300 }),
    supabase.from("ledgers").select("ledger_id, name, nature, account_groups(name)").eq("status", "active").order("name"),
    supabase.from("suppliers").select("supplier_id, name").order("name"),
    supabase.from("bank_payee_rules").select("payee_rule_id, keyword, direction, supplier_id, ledger_id, source, hits, status").order("keyword"),
    supabase.rpc("has_accounting_write"),
  ]);
  const bankLedgerIds = new Set(accounts.map((a) => a.ledger_id).filter(Boolean));
  const ledgers: Opt[] = ((ledgersRaw ?? []) as unknown as { ledger_id: string; name: string; account_groups: { name: string } | null }[])
    .filter((l) => !bankLedgerIds.has(l.ledger_id)).map((l) => ({ id: l.ledger_id, label: `${l.name} — ${l.account_groups?.name ?? ""}` }));
  const suppliers: Opt[] = (suppliersRaw ?? []).map((s) => ({ id: s.supplier_id, label: s.name }));
  const lines = ((linesRaw ?? []) as unknown as ReviewLine[]).map((l) => ({ ...l, amount: Number(l.amount) }));
  const rules = ((rulesRaw ?? []) as unknown as PayeeRule[]);
  const canWrite = w === true;

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">For review</h1>
          <p className="mt-1 max-w-3xl text-sm text-ink-muted">
            Bank lines that are not in your books yet. We suggest the account and vendor from what you booked before; check, change if needed, and press Accept.
            Lines that already match an entry in your books are handled under <Link href="/bank/reconcile" className="text-accent underline">Reconcile</Link>.
          </p>
        </div>
        <form action="/bank/review" className="flex items-center gap-2">
          <select name="account" defaultValue={acct.bank_account_id} className="h-10 border border-line bg-surface px-2 text-sm">
            {accounts.map((a) => <option key={a.bank_account_id} value={a.bank_account_id}>{a.bank_name} •• {a.account_number_last4}</option>)}
          </select>
          <button className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold hover:bg-surface-sunken">Show</button>
        </form>
      </div>
      {error ? <p className="mt-4 text-sm text-danger">Could not load: {error.message}</p> : null}
      <ReviewTable accountId={acct.bank_account_id} lines={lines} ledgers={ledgers} suppliers={suppliers} canWrite={canWrite} />
      <PayeeRules rules={rules} ledgers={ledgers} suppliers={suppliers} canWrite={canWrite} />
    </div>
  );
}
