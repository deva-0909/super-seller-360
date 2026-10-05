import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { drCr } from "@/lib/report-utils";

export default async function LedgersPage() {
  const supabase = await createClient();

  const { data } = await supabase.rpc("trial_balance", { p_from: null, p_to: new Date().toISOString().slice(0, 10) });
  const ledgers: { ledger_id: string; name: string; group: string; opening: number; debit: number; credit: number; closing: number }[] = (data ?? []).map((r: Record<string, unknown>) => ({
    ledger_id: String(r.ledger_id), name: String(r.ledger_name), group: String(r.group_name),
    opening: Number(r.opening), debit: Number(r.period_debit), credit: Number(r.period_credit), closing: Number(r.closing),
  }));
  const grandDebit = ledgers.reduce((t, l) => t + l.debit, 0);
  const grandCredit = ledgers.reduce((t, l) => t + l.credit, 0);

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Ledgers
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Closing balance of every ledger including its opening balance, from posted vouchers only. See also the <Link href="/accounting/trial-balance" className="text-accent hover:underline">Trial Balance</Link> and <Link href="/accounting/day-book" className="text-accent hover:underline">Day Book</Link>.
      </p>

      <div className="mt-6 border border-line bg-surface overflow-x-auto">
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
            {ledgers.map((l, i) => {
              return (
                <tr key={l.ledger_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                  <td className="px-4 py-3">
                    <Link href={`/accounting/ledgers/${l.ledger_id}`} className="text-accent hover:underline">{l.name}</Link>
                  </td>
                  <td className="px-4 py-3 text-ink-muted">{l.group}</td>
                  <td className="px-4 py-3 text-right font-data text-ink-muted">{l.debit ? `₹${l.debit.toLocaleString("en-IN")}` : "—"}</td>
                  <td className="px-4 py-3 text-right font-data text-ink-muted">{l.credit ? `₹${l.credit.toLocaleString("en-IN")}` : "—"}</td>
                  <td className="px-4 py-3 text-right font-data font-medium text-ink">{drCr(l.closing)}</td>
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
                {Math.abs(grandDebit - grandCredit) < 0.005 ? "Balanced" : "Out of balance"}
              </td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
  );
}
