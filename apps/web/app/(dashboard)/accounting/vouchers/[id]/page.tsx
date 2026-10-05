import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { Proofs } from "@/components/ui/proofs";
import { CsvButton } from "@/components/ui/csv-button";

export default async function VoucherPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: v } = await supabase
    .from("vouchers")
    .select("voucher_id, voucher_no, voucher_date, status, source_type, narration, total_debit, total_credit, created_at, voucher_types(name), accounting_periods(period_name)")
    .eq("voucher_id", id)
    .maybeSingle();
  if (!v) notFound();

  const { data: lines } = await supabase
    .from("voucher_lines")
    .select("voucher_line_id, ledger_id, debit, credit, narration, ledgers(name)")
    .eq("voucher_id", id)
    .order("debit", { ascending: false });

  const ledgerName = (l: NonNullable<typeof lines>[number]) => (l.ledgers as unknown as { name: string } | null)?.name ?? "—";
  const typeName = (v.voucher_types as unknown as { name: string } | null)?.name ?? "";
  const period = (v.accounting_periods as unknown as { period_name: string } | null)?.period_name ?? "";

  const csv: (string | number)[][] = [
    ["Voucher", v.voucher_no, typeName, v.voucher_date, v.status],
    ["Narration", v.narration ?? ""],
    ["Ledger", "Debit", "Credit", "Line narration"],
    ...(lines ?? []).map((l) => [ledgerName(l), Number(l.debit), Number(l.credit), l.narration ?? ""]),
  ];

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/accounting/day-book" className="text-sm text-ink-muted hover:text-ink">← Day book</Link>
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Voucher {v.voucher_no}</h1>
          <p className="mt-1 text-sm text-ink-muted">
            {typeName} · {new Date(v.voucher_date).toLocaleDateString("en-IN")} · {period} · {v.status}
            {v.source_type ? ` · from ${v.source_type}` : ""}
          </p>
        </div>
        <CsvButton rows={csv} filename={`voucher-${v.voucher_no}`} />
      </div>
      {v.narration ? <p className="mt-3 text-sm text-ink">{v.narration}</p> : null}

      <div className="mt-6 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Ledger</th>
              <th className="px-4 py-3 font-medium">Narration</th>
              <th className="px-4 py-3 font-medium text-right">Debit</th>
              <th className="px-4 py-3 font-medium text-right">Credit</th>
            </tr>
          </thead>
          <tbody>
            {(lines ?? []).map((l, i) => (
              <tr key={l.voucher_line_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3">
                  <Link href={`/accounting/ledgers/${l.ledger_id}`} className="text-accent hover:underline">{ledgerName(l)}</Link>
                </td>
                <td className="px-4 py-3 text-ink-muted">{l.narration ?? "—"}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(l.debit))}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(l.credit))}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t border-line-strong text-sm font-medium">
              <td className="px-4 py-3 text-ink" colSpan={2}>Total</td>
              <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(v.total_debit))}</td>
              <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(v.total_credit))}</td>
            </tr>
          </tfoot>
        </table>
      </div>

      <div className="mt-3 border border-line bg-surface p-5">
        <Proofs entityType="voucher" entityId={v.voucher_id} readOnly kind="other" label="Proofs attached to this voucher" hint="" />
      </div>
    </div>
  );
}
