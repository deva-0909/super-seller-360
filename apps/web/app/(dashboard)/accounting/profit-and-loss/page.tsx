import { createClient } from "@/lib/supabase/server";

export default async function ProfitAndLossPage() {
  const supabase = await createClient();

  const { data: ledgers } = await supabase
    .from("ledgers")
    .select("ledger_id, name, nature, account_groups(name)")
    .in("nature", ["income", "expense"])
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

  const income = (ledgers ?? []).filter((l) => l.nature === "income");
  const expenses = (ledgers ?? []).filter((l) => l.nature === "expense");

  const incomeRows = income.map((l) => {
    const t = totals.get(l.ledger_id) ?? { debit: 0, credit: 0 };
    return { name: l.name, amount: t.credit - t.debit };
  });
  const expenseRows = expenses.map((l) => {
    const t = totals.get(l.ledger_id) ?? { debit: 0, credit: 0 };
    return { name: l.name, amount: t.debit - t.credit };
  });

  const totalIncome = incomeRows.reduce((s, r) => s + r.amount, 0);
  const totalExpense = expenseRows.reduce((s, r) => s + r.amount, 0);
  const netProfit = totalIncome - totalExpense;

  return (
    <div className="mx-auto max-w-2xl px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Profit &amp; Loss
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Computed live from posted vouchers — revenue and expense ledgers
        only, never draft or cancelled entries.
      </p>

      {!expenseRows.length ? (
        <p className="mt-4 border border-line bg-surface p-3 text-xs text-ink-muted">
          No expense ledgers exist yet — the accounting engine currently only
          posts Sales Revenue automatically via order invoicing. This
          statement will fill in as expense ledgers (commission, shipping,
          packaging, etc.) get added and posted against.
        </p>
      ) : null}

      <div className="mt-6 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Income</h2>
        <dl className="mt-2 flex flex-col gap-1.5 text-sm">
          {incomeRows.map((r) => (
            <div key={r.name} className="flex justify-between">
              <dt className="text-ink-muted">{r.name}</dt>
              <dd className="font-data text-ink">
                ₹{r.amount.toLocaleString("en-IN")}
              </dd>
            </div>
          ))}
          {!incomeRows.length ? (
            <p className="text-ink-faint">No income posted yet.</p>
          ) : null}
        </dl>
        <div className="mt-3 flex justify-between border-t border-line-strong pt-2 text-sm font-medium">
          <span className="text-ink">Total income</span>
          <span className="font-data text-ink">
            ₹{totalIncome.toLocaleString("en-IN")}
          </span>
        </div>
      </div>

      <div className="mt-4 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Expenses</h2>
        <dl className="mt-2 flex flex-col gap-1.5 text-sm">
          {expenseRows.map((r) => (
            <div key={r.name} className="flex justify-between">
              <dt className="text-ink-muted">{r.name}</dt>
              <dd className="font-data text-ink">
                ₹{r.amount.toLocaleString("en-IN")}
              </dd>
            </div>
          ))}
          {!expenseRows.length ? (
            <p className="text-ink-faint">No expenses posted yet.</p>
          ) : null}
        </dl>
        <div className="mt-3 flex justify-between border-t border-line-strong pt-2 text-sm font-medium">
          <span className="text-ink">Total expenses</span>
          <span className="font-data text-ink">
            ₹{totalExpense.toLocaleString("en-IN")}
          </span>
        </div>
      </div>

      <div className="mt-4 border border-line bg-accent-tint p-5">
        <div className="flex justify-between text-base font-semibold">
          <span className="text-ink">Net profit</span>
          <span
            className={`font-data ${netProfit >= 0 ? "text-success" : "text-danger"}`}
          >
            ₹{netProfit.toLocaleString("en-IN")}
          </span>
        </div>
      </div>
    </div>
  );
}
