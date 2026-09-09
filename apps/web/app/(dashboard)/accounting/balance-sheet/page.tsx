import { createClient } from "@/lib/supabase/server";

export default async function BalanceSheetPage() {
  const supabase = await createClient();

  const { data: ledgers } = await supabase
    .from("ledgers")
    .select("ledger_id, name, nature")
    .in("nature", ["asset", "liability", "equity", "income", "expense"])
    .eq("status", "active");

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

  function rowsFor(nature: string, balanceFn: (d: number, c: number) => number) {
    return (ledgers ?? [])
      .filter((l) => l.nature === nature)
      .map((l) => {
        const t = totals.get(l.ledger_id) ?? { debit: 0, credit: 0 };
        return { name: l.name, amount: balanceFn(t.debit, t.credit) };
      });
  }

  const assetRows = rowsFor("asset", (d, c) => d - c);
  const liabilityRows = rowsFor("liability", (d, c) => c - d);
  const equityRows = rowsFor("equity", (d, c) => c - d);
  const incomeTotal = rowsFor("income", (d, c) => c - d).reduce((s, r) => s + r.amount, 0);
  const expenseTotal = rowsFor("expense", (d, c) => d - c).reduce((s, r) => s + r.amount, 0);
  const unclosedProfit = incomeTotal - expenseTotal;

  const totalAssets = assetRows.reduce((s, r) => s + r.amount, 0);
  const totalLiabilities = liabilityRows.reduce((s, r) => s + r.amount, 0);
  const totalEquity = equityRows.reduce((s, r) => s + r.amount, 0) + unclosedProfit;
  const balanced = Math.abs(totalAssets - (totalLiabilities + totalEquity)) < 0.01;

  return (
    <div className="mx-auto max-w-2xl px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Balance Sheet
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        As of today — computed live from posted vouchers.
      </p>

      <p className="mt-4 border border-line bg-surface p-3 text-xs text-ink-muted">
        No formal period-close process exists yet (that&apos;s a larger
        feature on its own), so current-period profit hasn&apos;t been
        formally transferred to an equity/retained-earnings ledger. It&apos;s
        shown below as &quot;Current period profit (unclosed)&quot; instead
        of being silently folded into a ledger that doesn&apos;t reflect it
        yet.
      </p>

      <div className="mt-6 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Assets</h2>
        <dl className="mt-2 flex flex-col gap-1.5 text-sm">
          {assetRows.map((r) => (
            <div key={r.name} className="flex justify-between">
              <dt className="text-ink-muted">{r.name}</dt>
              <dd className="font-data text-ink">₹{r.amount.toLocaleString("en-IN")}</dd>
            </div>
          ))}
        </dl>
        <div className="mt-3 flex justify-between border-t border-line-strong pt-2 text-sm font-medium">
          <span className="text-ink">Total assets</span>
          <span className="font-data text-ink">₹{totalAssets.toLocaleString("en-IN")}</span>
        </div>
      </div>

      <div className="mt-4 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Liabilities</h2>
        <dl className="mt-2 flex flex-col gap-1.5 text-sm">
          {liabilityRows.map((r) => (
            <div key={r.name} className="flex justify-between">
              <dt className="text-ink-muted">{r.name}</dt>
              <dd className="font-data text-ink">₹{r.amount.toLocaleString("en-IN")}</dd>
            </div>
          ))}
        </dl>
        <div className="mt-3 flex justify-between border-t border-line-strong pt-2 text-sm font-medium">
          <span className="text-ink">Total liabilities</span>
          <span className="font-data text-ink">₹{totalLiabilities.toLocaleString("en-IN")}</span>
        </div>
      </div>

      <div className="mt-4 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Equity</h2>
        <dl className="mt-2 flex flex-col gap-1.5 text-sm">
          {equityRows.map((r) => (
            <div key={r.name} className="flex justify-between">
              <dt className="text-ink-muted">{r.name}</dt>
              <dd className="font-data text-ink">₹{r.amount.toLocaleString("en-IN")}</dd>
            </div>
          ))}
          <div className="flex justify-between">
            <dt className="text-ink-muted">Current period profit (unclosed)</dt>
            <dd className="font-data text-ink">
              ₹{unclosedProfit.toLocaleString("en-IN")}
            </dd>
          </div>
        </dl>
        <div className="mt-3 flex justify-between border-t border-line-strong pt-2 text-sm font-medium">
          <span className="text-ink">Total equity</span>
          <span className="font-data text-ink">₹{totalEquity.toLocaleString("en-IN")}</span>
        </div>
      </div>

      <div
        className={`mt-4 border p-5 ${balanced ? "border-line bg-accent-tint" : "border-danger/40 bg-danger-tint"}`}
      >
        <div className="flex justify-between text-base font-semibold">
          <span className="text-ink">Assets = Liabilities + Equity</span>
          <span className={`font-data ${balanced ? "text-success" : "text-danger"}`}>
            {balanced ? "Balanced" : "Out of balance"}
          </span>
        </div>
      </div>
    </div>
  );
}
