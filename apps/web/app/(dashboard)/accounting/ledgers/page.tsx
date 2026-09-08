import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

const DEBIT_NATURE = new Set(["asset", "expense"]);

export default async function LedgersPage() {
  const supabase = await createClient();

  const { data: ledgers } = await supabase
    .from("ledgers")
    .select("ledger_id, name, nature, account_groups(name)")
    .eq("status", "active")
    .order("name");

  const { data: entries } = await supabase
    .from("journal_entries")
    .select("account_id, debit, credit");

  const totals = new Map<string, { debit: number; credit: number }>();
  for (const e of entries ?? []) {
    const t = totals.get(e.account_id) ?? { debit: 0, credit: 0 };
    t.debit += Number(e.debit);
    t.credit += Number(e.credit);
    totals.set(e.account_id, t);
  }

  let grandDebit = 0;
  let grandCredit = 0;

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Ledgers
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Running balance for every ledger, from posted vouchers only.
      </p>

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Ledger</th>
              <th className="px-4 py-3 font-medium">Group</th>
              <th className="px-4 py-3 font-medium text-right">Debit</th>
              <th className="px-4 py-3 font-medium text-right">Credit</th>
              <th className="px-4 py-3 font-medium text-right">Balance</th>
            </tr>
          </thead>
          <tbody>
            {ledgers?.map((l, i) => {
              const t = totals.get(l.ledger_id) ?? { debit: 0, credit: 0 };
              grandDebit += t.debit;
              grandCredit += t.credit;
              const isDebitNature = DEBIT_NATURE.has(l.nature);
              const net = isDebitNature
                ? t.debit - t.credit
                : t.credit - t.debit;
              return (
                <tr
                  key={l.ledger_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3">
                    <Link
                      href={`/accounting/ledgers/${l.ledger_id}`}
                      className="text-accent hover:underline"
                    >
                      {l.name}
                    </Link>
                  </td>
                  <td className="px-4 py-3 text-ink-muted">
                    {(l.account_groups as unknown as { name: string } | null)
                      ?.name ?? "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink-muted">
                    {t.debit ? `₹${t.debit.toLocaleString("en-IN")}` : "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink-muted">
                    {t.credit ? `₹${t.credit.toLocaleString("en-IN")}` : "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data font-medium text-ink">
                    {net !== 0
                      ? `₹${Math.abs(net).toLocaleString("en-IN")} ${net > 0 ? (isDebitNature ? "Dr" : "Cr") : isDebitNature ? "Cr" : "Dr"}`
                      : "—"}
                  </td>
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr className="border-t border-line-strong text-sm font-medium">
              <td className="px-4 py-3 text-ink" colSpan={2}>
                Total
              </td>
              <td className="px-4 py-3 text-right font-data text-ink">
                ₹{grandDebit.toLocaleString("en-IN")}
              </td>
              <td className="px-4 py-3 text-right font-data text-ink">
                ₹{grandCredit.toLocaleString("en-IN")}
              </td>
              <td className="px-4 py-3 text-right font-data text-ink-muted">
                {grandDebit === grandCredit ? "Balanced" : "Out of balance"}
              </td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
  );
}
