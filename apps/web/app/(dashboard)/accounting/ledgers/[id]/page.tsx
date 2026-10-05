import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { parseRange, drCr, inr } from "@/lib/report-utils";
import { CsvButton } from "@/components/ui/csv-button";
import { DateRangeForm } from "@/components/ui/date-range-form";

type Line = {
  seq: number; entry_date: string | null; voucher_id: string | null; voucher_no: string | null;
  narration: string | null; debit: number; credit: number; balance: number; is_opening: boolean;
};

export default async function LedgerDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  const { id } = await params;
  const { from, to } = parseRange(await searchParams);
  const supabase = await createClient();

  const { data: ledger } = await supabase
    .from("ledgers")
    .select("ledger_id, name, nature, account_groups(name)")
    .eq("ledger_id", id)
    .single();
  if (!ledger) notFound();

  const { data, error } = await supabase.rpc("ledger_statement", { p_ledger: id, p_from: from, p_to: to });
  const lines: Line[] = (data ?? []).map((r: Record<string, unknown>) => ({
    seq: Number(r.seq), entry_date: (r.entry_date as string) ?? null, voucher_id: (r.voucher_id as string) ?? null,
    voucher_no: (r.voucher_no as string) ?? null, narration: (r.narration as string) ?? null,
    debit: Number(r.debit), credit: Number(r.credit), balance: Number(r.balance), is_opening: Boolean(r.is_opening),
  }));
  const groupName = (ledger.account_groups as unknown as { name: string } | null)?.name;
  const periodLines = lines.filter((l) => !l.is_opening);
  const totalDebit = periodLines.reduce((s, l) => s + l.debit, 0);
  const totalCredit = periodLines.reduce((s, l) => s + l.credit, 0);
  const closing = lines.length ? lines[lines.length - 1].balance : 0;

  const csv: (string | number)[][] = [
    [`Ledger: ${ledger.name}`, `${from} to ${to}`],
    ["Date", "Voucher", "Narration", "Debit", "Credit", "Balance", "Dr/Cr"],
    ...lines.map((l) => [l.entry_date ?? "", l.voucher_no ?? "", l.narration ?? "", l.debit, l.credit, Math.abs(l.balance), l.balance >= 0 ? "Dr" : "Cr"]),
    ["Total", "", "", totalDebit, totalCredit, Math.abs(closing), closing >= 0 ? "Dr" : "Cr"],
  ];

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/accounting/ledgers" className="text-sm text-ink-muted hover:text-ink">← All ledgers</Link>
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">{ledger.name}</h1>
          <p className="mt-1 text-sm text-ink-muted">{groupName} · {ledger.nature}</p>
        </div>
        <CsvButton rows={csv} filename={`ledger-${ledger.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}-${from}-to-${to}`} />
      </div>
      <DateRangeForm from={from} to={to} />
      {error ? <p className="mt-4 text-sm text-danger">Could not load the statement: {error.message}</p> : null}

      <div className="mt-6 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Date</th>
              <th className="px-4 py-3 font-medium">Voucher</th>
              <th className="px-4 py-3 font-medium">Narration</th>
              <th className="px-4 py-3 font-medium text-right">Debit</th>
              <th className="px-4 py-3 font-medium text-right">Credit</th>
              <th className="px-4 py-3 font-medium text-right">Balance</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={l.seq} className={l.is_opening ? "bg-surface-sunken" : i % 2 === 0 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 font-data text-ink-muted">{l.is_opening ? "" : l.entry_date ? new Date(l.entry_date).toLocaleDateString("en-IN") : ""}</td>
                <td className="px-4 py-3 font-data text-accent">
                  {l.voucher_id ? <Link href={`/accounting/vouchers/${l.voucher_id}`} className="hover:underline">{l.voucher_no ?? "view"}</Link> : "—"}
                </td>
                <td className="px-4 py-3 text-ink-muted">{l.is_opening ? "Opening balance" : l.narration ?? "—"}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(l.debit)}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(l.credit)}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{l.balance === 0 ? "₹0.00" : drCr(l.balance)}</td>
              </tr>
            ))}
            {periodLines.length === 0 && !error ? (
              <tr><td colSpan={6} className="px-4 py-8 text-center text-sm text-ink-muted">No transactions posted to this ledger in this period.</td></tr>
            ) : null}
          </tbody>
          <tfoot>
            <tr className="border-t border-line-strong text-sm font-medium">
              <td className="px-4 py-3 text-ink" colSpan={3}>Total for the period · closing balance</td>
              <td className="px-4 py-3 text-right font-data text-ink">{inr(totalDebit)}</td>
              <td className="px-4 py-3 text-right font-data text-ink">{inr(totalCredit)}</td>
              <td className="px-4 py-3 text-right font-data text-ink">{closing === 0 ? "₹0.00" : drCr(closing)}</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
  );
}
