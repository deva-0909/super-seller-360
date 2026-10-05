import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { parseRange, inr } from "@/lib/report-utils";
import { CsvButton } from "@/components/ui/csv-button";
import { DateRangeForm } from "@/components/ui/date-range-form";

const LIMIT = 1000;

export default async function DayBookPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string; status?: string }> }) {
  const sp = await searchParams;
  const { from, to } = parseRange({ from: sp.from ?? new Date().toISOString().slice(0, 8) + "01", to: sp.to });
  const status = sp.status === "all" ? "all" : "posted";
  const supabase = await createClient();

  let q = supabase
    .from("vouchers")
    .select("voucher_id, voucher_no, voucher_date, status, source_type, narration, total_debit, voucher_types(name)")
    .gte("voucher_date", from)
    .lte("voucher_date", to)
    .order("voucher_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(LIMIT + 1);
  if (status === "posted") q = q.eq("status", "posted");
  const { data, error } = await q;

  const all = data ?? [];
  const truncated = all.length > LIMIT;
  const rows = all.slice(0, LIMIT);
  const typeName = (r: (typeof rows)[number]) => (r.voucher_types as unknown as { name: string } | null)?.name ?? "";
  const total = rows.filter((r) => r.status === "posted").reduce((s, r) => s + Number(r.total_debit), 0);

  const csv: (string | number)[][] = [
    ["Day book", `${from} to ${to}`],
    ["Date", "Voucher no", "Type", "Status", "Source", "Narration", "Amount"],
    ...rows.map((r) => [r.voucher_date, r.voucher_no, typeName(r), r.status, r.source_type ?? "", r.narration ?? "", Number(r.total_debit)]),
  ];

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Day Book</h1>
          <p className="mt-1 text-sm text-ink-muted">Every voucher in date order. Open one to see its lines and proofs.</p>
        </div>
        <CsvButton rows={csv} filename={`day-book-${from}-to-${to}`} />
      </div>
      <DateRangeForm from={from} to={to} />
      <div className="mt-3 flex gap-4 text-sm">
        <Link href={`?from=${from}&to=${to}`} className={status === "posted" ? "font-medium text-ink" : "text-accent hover:underline"}>Posted only</Link>
        <Link href={`?from=${from}&to=${to}&status=all`} className={status === "all" ? "font-medium text-ink" : "text-accent hover:underline"}>Include drafts and cancelled</Link>
      </div>
      {error ? <p className="mt-4 text-sm text-danger">Could not load vouchers: {error.message}</p> : null}
      {truncated ? <p className="mt-4 text-sm text-warning">Showing the latest {LIMIT} vouchers. Narrow the dates to see the rest.</p> : null}

      <div className="mt-6 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Date</th>
              <th className="px-4 py-3 font-medium">Voucher</th>
              <th className="px-4 py-3 font-medium">Type</th>
              <th className="px-4 py-3 font-medium">Narration</th>
              <th className="px-4 py-3 font-medium">Status</th>
              <th className="px-4 py-3 font-medium text-right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={r.voucher_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(r.voucher_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 font-data">
                  <Link href={`/accounting/vouchers/${r.voucher_id}`} className="text-accent hover:underline">{r.voucher_no}</Link>
                </td>
                <td className="px-4 py-3 text-ink-muted">{typeName(r)}</td>
                <td className="px-4 py-3 text-ink-muted">{r.narration ?? "—"}</td>
                <td className="px-4 py-3 text-ink-muted">{r.status}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(r.total_debit))}</td>
              </tr>
            ))}
            {!rows.length && !error ? (
              <tr><td colSpan={6} className="px-4 py-8 text-center text-sm text-ink-muted">No vouchers in this range.</td></tr>
            ) : null}
          </tbody>
          <tfoot>
            <tr className="border-t border-line-strong text-sm font-medium">
              <td className="px-4 py-3 text-ink" colSpan={5}>Total of posted vouchers</td>
              <td className="px-4 py-3 text-right font-data text-ink">{inr(total)}</td>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
  );
}
