import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { parseRange, inr, drCr } from "@/lib/report-utils";
import { CsvButton } from "@/components/ui/csv-button";
import { DateRangeForm } from "@/components/ui/date-range-form";

type Row = {
  ledger_id: string; ledger_name: string; group_name: string; nature: string;
  opening: number; period_debit: number; period_credit: number; closing: number;
};

export default async function TrialBalancePage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const { from, to } = parseRange(await searchParams);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("trial_balance", { p_from: from, p_to: to });
  const rows: Row[] = (data ?? []).map((r: Record<string, unknown>) => ({
    ledger_id: String(r.ledger_id), ledger_name: String(r.ledger_name), group_name: String(r.group_name), nature: String(r.nature),
    opening: Number(r.opening), period_debit: Number(r.period_debit), period_credit: Number(r.period_credit), closing: Number(r.closing),
  }));

  const dr = (n: number) => (n > 0 ? n : 0);
  const cr = (n: number) => (n < 0 ? -n : 0);
  const tot = rows.reduce(
    (t, r) => ({ od: t.od + dr(r.opening), oc: t.oc + cr(r.opening), d: t.d + r.period_debit, c: t.c + r.period_credit, cd: t.cd + dr(r.closing), cc: t.cc + cr(r.closing) }),
    { od: 0, oc: 0, d: 0, c: 0, cd: 0, cc: 0 },
  );
  const balanced = Math.abs(tot.cd - tot.cc) < 0.01;

  const csv: (string | number)[][] = [
    ["Trial balance", `${from} to ${to}`],
    ["Ledger", "Group", "Nature", "Opening Dr", "Opening Cr", "Debit", "Credit", "Closing Dr", "Closing Cr"],
    ...rows.map((r) => [r.ledger_name, r.group_name, r.nature, dr(r.opening), cr(r.opening), r.period_debit, r.period_credit, dr(r.closing), cr(r.closing)]),
    ["Total", "", "", tot.od, tot.oc, tot.d, tot.c, tot.cd, tot.cc],
  ];

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Trial Balance</h1>
          <p className="mt-1 text-sm text-ink-muted">
            Every ledger with its opening balance, the period&apos;s postings and the closing balance. Posted vouchers only.
          </p>
        </div>
        <CsvButton rows={csv} filename={`trial-balance-${from}-to-${to}`} />
      </div>
      <DateRangeForm from={from} to={to} />
      {error ? <p className="mt-4 text-sm text-danger">Could not load the trial balance: {error.message}</p> : null}

      <div className="mt-6 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Ledger</th>
              <th className="px-4 py-3 font-medium">Group</th>
              <th className="px-4 py-3 font-medium text-right">Opening</th>
              <th className="px-4 py-3 font-medium text-right">Debit</th>
              <th className="px-4 py-3 font-medium text-right">Credit</th>
              <th className="px-4 py-3 font-medium text-right">Closing Dr</th>
              <th className="px-4 py-3 font-medium text-right">Closing Cr</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={r.ledger_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3">
                  <Link href={`/accounting/ledgers/${r.ledger_id}?from=${from}&to=${to}`} className="text-accent hover:underline">{r.ledger_name}</Link>
                </td>
                <td className="px-4 py-3 text-ink-muted">{r.group_name}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{drCr(r.opening)}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(r.period_debit)}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(r.period_credit)}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(dr(r.closing))}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(cr(r.closing))}</td>
              </tr>
            ))}
            {!rows.length && !error ? (
              <tr><td colSpan={7} className="px-4 py-8 text-center text-sm text-ink-muted">Nothing posted yet.</td></tr>
            ) : null}
          </tbody>
          <tfoot>
            <tr className="border-t border-line-strong text-sm font-medium">
              <td className="px-4 py-3 text-ink" colSpan={2}>Total</td>
              <td className="px-4 py-3" />
              <td className="px-4 py-3 text-right font-data text-ink">{inr(tot.d)}</td>
              <td className="px-4 py-3 text-right font-data text-ink">{inr(tot.c)}</td>
              <td className="px-4 py-3 text-right font-data text-ink">{inr(tot.cd)}</td>
              <td className="px-4 py-3 text-right font-data text-ink">{inr(tot.cc)}</td>
            </tr>
          </tfoot>
        </table>
      </div>
      <p className={`mt-3 text-sm font-medium ${balanced ? "text-success" : "text-danger"}`}>
        {balanced
          ? "Balanced: closing debits equal closing credits."
          : `Out of balance by ${inr(Math.abs(tot.cd - tot.cc))}. Check the opening balances entered on the ledgers: they must total zero between debit and credit.`}
      </p>
    </div>
  );
}
