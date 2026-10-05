import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { financialYearStart } from "@/lib/report-utils";
import { CsvButton } from "@/components/ui/csv-button";
import { PrintButton } from "@/components/ui/print-button";
import { groupRows, TallyGroup, TallyTotal, money, type TallyGroupData } from "@/components/accounting/tally";

const ISO = /^\d{4}-\d{2}-\d{2}$/;

export default async function BalanceSheetPage({ searchParams }: { searchParams: Promise<{ to?: string; open?: string }> }) {
  const sp = await searchParams;
  const today = new Date().toISOString().slice(0, 10);
  const asOn = sp.to && ISO.test(sp.to) ? sp.to : today;
  const open = sp.open === "1";
  const fyFrom = financialYearStart(new Date(asOn));

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("trial_balance", { p_from: null, p_to: asOn });
  // closing is debit-positive; every ledger is shown on the side of its own nature
  type L = { id: string; name: string; group: string; nature: string; net: number };
  const all: L[] = (data ?? []).map((r: Record<string, unknown>) => ({
    id: String(r.ledger_id), name: String(r.ledger_name), group: String(r.group_name), nature: String(r.nature), net: Number(r.closing),
  }));
  const side = (nature: string, sign: 1 | -1) =>
    groupRows(all.filter((l) => l.nature === nature).map((l) => ({ id: l.id, name: l.name, group: l.group, amount: sign * l.net })));

  const assets = side("asset", 1);
  const liabilities = side("liability", -1);
  const equity = side("equity", -1);
  const incomeRows = groupRows(all.filter((l) => l.nature === "income").map((l) => ({ id: l.id, name: l.name, group: l.group, amount: -l.net })));
  const expenseRows = groupRows(all.filter((l) => l.nature === "expense").map((l) => ({ id: l.id, name: l.name, group: l.group, amount: l.net })));
  const sum = (g: TallyGroupData[]) => g.reduce((s, x) => s + x.total, 0);
  const totalIncome = sum(incomeRows), totalExpense = sum(expenseRows);
  const profit = totalIncome - totalExpense;

  const leftGroups = [...liabilities, ...equity];
  const totalLeft = sum(leftGroups) + profit;
  const totalAssets = sum(assets);
  const diff = totalAssets - totalLeft;
  const balanced = Math.abs(diff) < 0.01;
  const href = (id: string) => `/accounting/ledgers/${id}?from=${fyFrom}&to=${asOn}`;

  const csv: (string | number)[][] = [
    ["Balance sheet", `As on ${asOn}`],
    ["Side", "Group", "Ledger", "Amount"],
    ...[...leftGroups.map((g) => ["Liabilities", g, ] as const), ...assets.map((g) => ["Assets", g] as const)].flatMap(([s, g]) => [
      [s, g.label, "", g.total],
      ...g.rows.map((r) => [s, g.label, r.name, r.amount]),
    ]),
    ["Liabilities", "Profit and Loss (current, unclosed)", "", profit],
    ["Total liabilities", "", "", totalLeft],
    ["Total assets", "", "", totalAssets],
  ];

  return (
    <div className="px-4 md:px-8 py-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Balance Sheet</h1>
          <p className="mt-1 text-sm text-ink-muted">Liabilities on the left, assets on the right. Posted vouchers only. Click a group to see its ledgers.</p>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <form method="get" className="flex items-end gap-2 print:hidden">
            {open ? <input type="hidden" name="open" value="1" /> : null}
            <label className="flex flex-col gap-1 text-xs text-ink-muted">
              As on
              <input type="date" name="to" defaultValue={asOn} className="h-10 rounded-lg border border-line bg-surface px-3 text-sm text-ink" />
            </label>
            <button type="submit" className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">Show</button>
          </form>
          <Link
            href={`?to=${asOn}${open ? "" : "&open=1"}`}
            className="inline-flex h-10 items-center rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken print:hidden"
          >
            {open ? "Collapse all" : "Expand all"}
          </Link>
          <CsvButton rows={csv} filename={`balance-sheet-${asOn}`} />
          <PrintButton />
        </div>
      </div>
      {error ? <p className="mt-3 text-sm text-danger">Could not load the balance sheet: {error.message}</p> : null}

      <div
        className={`mt-3 flex flex-wrap items-center justify-between gap-2 border px-3 py-1.5 text-sm ${balanced ? "border-line bg-accent-tint" : "border-danger/40 bg-danger-tint"}`}
      >
        <span className="font-medium text-ink">Assets = Liabilities + Equity</span>
        <span className={`font-data font-semibold ${balanced ? "text-success" : "text-danger"}`}>
          {balanced ? `Balanced · ${money(totalAssets)}` : `Out of balance by ${money(Math.abs(diff))} (${diff > 0 ? "assets exceed" : "liabilities exceed"})`}
        </span>
      </div>

      <div className="mt-3 border border-line-strong bg-surface">
        <div className="border-b border-line-strong py-2 text-center">
          <div className="text-sm font-semibold tracking-wide text-ink">BALANCE SHEET</div>
          <div className="text-xs text-ink-muted">As on {asOn}</div>
        </div>
        <div className="grid grid-cols-1 divide-y divide-line-strong md:grid-cols-2 md:divide-x md:divide-y-0">
          <section className="flex flex-col p-3">
            <h2 className="mb-1 px-1 text-xs font-semibold tracking-wide text-ink-muted">LIABILITIES</h2>
            {leftGroups.map((g) => <TallyGroup key={g.key} g={g} open={open} ledgerHref={href} />)}
            {profit !== 0 ? (
              <details open={open} className="group">
                <summary className="flex cursor-pointer list-none items-center justify-between rounded px-1 py-0.5 text-sm hover:bg-surface-sunken">
                  <span className="flex items-center gap-1.5 font-medium text-ink">
                    <span aria-hidden className="inline-block w-3 text-ink-faint transition-transform group-open:rotate-90">›</span>
                    Profit &amp; Loss (current, unclosed)
                  </span>
                  <span className={`font-data ${profit >= 0 ? "text-success" : "text-danger"}`}>{money(profit)}</span>
                </summary>
                <div className="pb-1 pl-6 pr-1 text-xs text-ink-muted">
                  <div className="flex justify-between py-px"><span>Total income</span><span className="font-data">{money(totalIncome)}</span></div>
                  <div className="flex justify-between py-px"><span>Less: expenses</span><span className="font-data">{money(totalExpense)}</span></div>
                </div>
              </details>
            ) : null}
            {!leftGroups.length && profit === 0 ? <p className="px-1 text-xs text-ink-faint">Nothing posted yet.</p> : null}
            <div className="mt-auto pt-2"><TallyTotal label="TOTAL LIABILITIES" amount={totalLeft} strong /></div>
          </section>
          <section className="flex flex-col p-3">
            <h2 className="mb-1 px-1 text-xs font-semibold tracking-wide text-ink-muted">ASSETS</h2>
            {assets.map((g) => <TallyGroup key={g.key} g={g} open={open} ledgerHref={href} />)}
            {!assets.length ? <p className="px-1 text-xs text-ink-faint">Nothing posted yet.</p> : null}
            <div className="mt-auto pt-2"><TallyTotal label="TOTAL ASSETS" amount={totalAssets} strong /></div>
          </section>
        </div>
      </div>

      <p className="mt-2 text-xs text-ink-faint">
        Profit of periods that are not yet closed shows as &quot;Profit &amp; Loss (current, unclosed)&quot;. Once a period is closed it moves into Retained Earnings.
      </p>
    </div>
  );
}
