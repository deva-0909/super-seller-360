import { createClient } from "@/lib/supabase/server";
import { parseRange } from "@/lib/report-utils";
import { CsvButton } from "@/components/ui/csv-button";
import { DateRangeForm } from "@/components/ui/date-range-form";
import { PrintButton } from "@/components/ui/print-button";
import Link from "next/link";
import { groupRows, TallyGroup, TallyTotal, money } from "@/components/accounting/tally";

export default async function ProfitAndLossPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string; open?: string }> }) {
  const sp = await searchParams;
  const { from, to } = parseRange(sp);
  const open = sp.open === "1";

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("profit_and_loss", { p_from: from, p_to: to });
  const rows = (data ?? []).map((r: Record<string, unknown>) => ({
    id: String(r.ledger_id), name: String(r.ledger_name), group: String(r.group_name), nature: String(r.nature), amount: Number(r.amount),
  }));
  const income = groupRows(rows.filter((r: { nature: string }) => r.nature === "income"));
  const expense = groupRows(rows.filter((r: { nature: string }) => r.nature === "expense"));
  const grossIncome = income.reduce((s, g) => s + g.total, 0);
  const grossExpense = expense.reduce((s, g) => s + g.total, 0);
  const net = grossIncome - grossExpense;
  const margin = grossIncome !== 0 ? (net / grossIncome) * 100 : 0;
  const href = (id: string) => `/accounting/ledgers/${id}?from=${from}&to=${to}`;

  const csv: (string | number)[][] = [
    ["Profit and Loss account", `${from} to ${to}`],
    ["Section", "Group", "Ledger", "Amount"],
    ...income.flatMap((g) => [["Income", g.label, "", g.total], ...g.rows.map((r) => ["Income", g.label, r.name, r.amount])]),
    ["Gross income", "", "", grossIncome],
    ...expense.flatMap((g) => [["Expenditure", g.label, "", g.total], ...g.rows.map((r) => ["Expenditure", g.label, r.name, r.amount])]),
    ["Gross expenditure", "", "", grossExpense],
    [net >= 0 ? "Net profit" : "Net loss", "", "", Math.abs(net)],
  ];

  return (
    <div className="px-4 md:px-8 py-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Profit &amp; Loss</h1>
          <p className="mt-1 text-sm text-ink-muted">Income less expenditure for any period, from posted vouchers. Period-close entries are left out, so closed periods still show their real result.</p>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <Link
            href={`?from=${from}&to=${to}${open ? "" : "&open=1"}`}
            className="inline-flex h-10 items-center rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken print:hidden"
          >
            {open ? "Collapse all" : "Expand all"}
          </Link>
          <CsvButton rows={csv} filename={`profit-and-loss-${from}-to-${to}`} />
          <PrintButton />
        </div>
      </div>
      <div className="print:hidden"><DateRangeForm from={from} to={to} extra={open ? { open: "1" } : undefined} /></div>
      {error ? <p className="mt-3 text-sm text-danger">Could not load the report: {error.message}</p> : null}

      <div className="mt-3 border border-line-strong bg-surface">
        <div className="border-b border-line-strong py-2 text-center">
          <div className="text-sm font-semibold tracking-wide text-ink">PROFIT &amp; LOSS ACCOUNT</div>
          <div className="text-xs text-ink-muted">For the period {from} to {to}</div>
        </div>
        <div className="grid grid-cols-1 divide-y divide-line-strong md:grid-cols-2 md:divide-x md:divide-y-0">
          <section className="flex flex-col p-3">
            <h2 className="mb-1 px-1 text-xs font-semibold tracking-wide text-ink-muted">EXPENDITURE</h2>
            {expense.map((g) => <TallyGroup key={g.key} g={g} open={open} ledgerHref={href} />)}
            {!expense.length ? <p className="px-1 text-xs text-ink-faint">No expenses posted in this period.</p> : null}
            <div className="mt-auto pt-2"><TallyTotal label="GROSS EXPENDITURE" amount={grossExpense} /></div>
          </section>
          <section className="flex flex-col p-3">
            <h2 className="mb-1 px-1 text-xs font-semibold tracking-wide text-ink-muted">INCOME</h2>
            {income.map((g) => <TallyGroup key={g.key} g={g} open={open} ledgerHref={href} />)}
            {!income.length ? <p className="px-1 text-xs text-ink-faint">No income posted in this period.</p> : null}
            <div className="mt-auto pt-2"><TallyTotal label="GROSS INCOME" amount={grossIncome} /></div>
          </section>
        </div>
        <div className="border-t-2 border-line-strong bg-accent-tint px-4 py-2">
          <div className={`flex items-center justify-between text-base font-semibold ${net >= 0 ? "text-success" : "text-danger"}`}>
            <span>{net >= 0 ? "NET PROFIT" : "NET LOSS"}</span>
            <span className="font-data">{money(Math.abs(net))}</span>
          </div>
          {grossIncome !== 0 ? <div className="text-right text-xs text-ink-muted">{margin.toFixed(1)}% of income</div> : null}
        </div>
      </div>
    </div>
  );
}
