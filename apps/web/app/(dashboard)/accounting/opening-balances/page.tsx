import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function OpeningBalancesPage() {
  const supabase = await createClient();
  const [{ data: ledgers }, { data: canUpload }] = await Promise.all([
    supabase.from("ledgers").select("ledger_id, name, opening_balance, opening_balance_type, account_groups(name)").neq("opening_balance", 0).order("name"),
    supabase.rpc("import_can", { p_kind: "ledger_opening" }),
  ]);
  const rows = ledgers ?? [];
  const dr = rows.filter((l) => l.opening_balance_type === "debit").reduce((t, l) => t + Number(l.opening_balance), 0);
  const cr = rows.filter((l) => l.opening_balance_type === "credit").reduce((t, l) => t + Number(l.opening_balance), 0);
  const diff = Math.round((dr - cr) * 100) / 100;
  const fmt = (n: number) => `₹${n.toLocaleString("en-IN", { minimumFractionDigits: 2 })}`;

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Opening balances</h1>
      <p className="mt-1 text-sm text-ink-muted">
        Ledger balances your books start from, taken from your old trial balance. The balance sheet is wrong until these are loaded.
        Supplier balances are entered under <Link href="/purchases/bills/opening" className="text-accent hover:underline">Purchases, Opening balances</Link>.
      </p>
      {canUpload === true ? (
        <p className="mt-3 flex gap-4 text-sm">
          <Link href="/imports/ledger_opening" className="font-medium text-accent hover:underline">Upload from your Tally trial balance</Link>
                    <a href={`/api/import-template/${"ledger_opening"}`} className="text-accent hover:underline">Download the template</a>
        </p>
      ) : null}

      <div className={`mt-4 border p-3 text-sm ${rows.length === 0 ? "border-warning/40 bg-warning-tint text-ink" : Math.abs(diff) < 0.01 ? "border-success/30 bg-success-tint text-ink" : "border-danger/30 bg-danger-tint text-ink"}`}>
        {rows.length === 0 ? "No opening balances loaded yet." : Math.abs(diff) < 0.01 ? `Balanced: debits ${fmt(dr)} equal credits ${fmt(cr)}.` : `Not balanced: debits ${fmt(dr)}, credits ${fmt(cr)}, difference ${fmt(Math.abs(diff))}.`}
      </div>

      <div className="mt-6 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Ledger</th><th className="px-4 py-3 font-medium">Group</th>
              <th className="px-4 py-3 font-medium text-right">Debit</th><th className="px-4 py-3 font-medium text-right">Credit</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((l, i) => (
              <tr key={l.ledger_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-2 text-ink">{l.name}</td>
                <td className="px-4 py-2 text-ink-muted">{(l.account_groups as unknown as { name: string } | null)?.name}</td>
                <td className="px-4 py-2 text-right font-data">{l.opening_balance_type === "debit" ? fmt(Number(l.opening_balance)) : ""}</td>
                <td className="px-4 py-2 text-right font-data">{l.opening_balance_type === "credit" ? fmt(Number(l.opening_balance)) : ""}</td>
              </tr>
            ))}
            {!rows.length ? <tr><td colSpan={4} className="px-4 py-8 text-center text-sm text-ink-muted">Nothing loaded.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
