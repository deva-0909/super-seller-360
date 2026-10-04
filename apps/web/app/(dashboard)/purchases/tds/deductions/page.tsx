import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { parseRange, inr } from "@/lib/report-utils";
import { DateRangeForm } from "@/components/ui/date-range-form";
import { CsvButton } from "@/components/ui/csv-button";

type D = { bill_id: string; bill_no: string; bill_date: string; supplier: string; pan: string | null; gstin: string | null; section: string; base: number; rate: number; tds: number; invoice_no: string; challans: string | null; no_pan: boolean };
const m = (n: number) => (inr(n) === "—" ? "₹0.00" : inr(n));

export default async function DeductionsPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
  const { from, to } = parseRange(await searchParams);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("tds_deductions", { p_from: from, p_to: to });
  if (error) return <div className="px-4 md:px-8 py-8"><h1 className="text-lg font-semibold tracking-tight text-ink">TDS deductions</h1><p className="mt-3 text-sm text-danger">{error.message}</p></div>;
  const rows = (data ?? []) as unknown as D[];
  const totBase = rows.reduce((t, r) => t + Number(r.base), 0), totTds = rows.reduce((t, r) => t + Number(r.tds), 0);
  const noPan = rows.filter((r) => r.no_pan).length;
  const csv: (string | number)[][] = [
    ["TDS deductions", from, to],
    ["Date", "Bill", "Supplier", "PAN", "Section", "Amount paid or credited (base)", "Rate %", "TDS", "Supplier invoice", "Challan (BSR/serial date)"],
    ...rows.map((r) => [r.bill_date, r.bill_no, r.supplier, r.pan ?? "", r.section, r.base, r.rate, r.tds, r.invoice_no, r.challans ?? ""]),
  ];
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/tds" className="text-sm text-ink-muted hover:text-ink">← TDS</Link>
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">TDS deductions</h1>
          <p className="mt-1 text-sm text-ink-muted">Every deduction in the period, with the supplier’s PAN and the challan it was deposited with. These are the working papers for the quarterly TDS return; the return itself is prepared and filed outside this app.</p>
        </div>
        <CsvButton rows={csv} filename={`tds-deductions-${from}-to-${to}`} />
      </div>
      <DateRangeForm from={from} to={to} />
      {noPan ? <p className="mt-4 border border-warning/40 bg-warning-tint p-3 text-sm text-ink">{noPan} deduction{noPan === 1 ? " is" : "s are"} for suppliers without a PAN. A higher rate usually applies; add the PAN on the supplier.</p> : null}
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Date</th><th className="px-4 py-3 font-medium">Supplier</th><th className="px-4 py-3 font-medium">Section</th>
            <th className="px-4 py-3 text-right font-medium">Base</th><th className="px-4 py-3 text-right font-medium">Rate</th><th className="px-4 py-3 text-right font-medium">TDS</th><th className="px-4 py-3 font-medium">Challan</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.bill_id} className="border-b border-line last:border-0">
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(r.bill_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-ink">{r.supplier}<div className="font-data text-xs text-ink-muted">{r.pan ?? "No PAN"} · <Link className="text-accent hover:underline" href={`/purchases/bills/${r.bill_id}`}>{r.bill_no}</Link></div></td>
                <td className="px-4 py-3 text-ink">{r.section}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{m(Number(r.base))}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{Number(r.rate)}%</td>
                <td className="px-4 py-3 text-right font-data text-ink">{m(Number(r.tds))}</td>
                <td className="px-4 py-3 font-data text-xs text-ink-muted">{r.challans ?? <span className="text-warning">Not deposited yet</span>}</td>
              </tr>
            ))}
            {!rows.length ? <tr><td colSpan={7} className="px-4 py-8 text-center text-ink-muted">No deductions in this period.</td></tr> : null}
          </tbody>
          {rows.length ? <tfoot><tr className="border-t border-line-strong text-sm font-medium"><td className="px-4 py-3 text-ink" colSpan={3}>Total</td><td className="px-4 py-3 text-right font-data text-ink">{m(totBase)}</td><td /><td className="px-4 py-3 text-right font-data text-ink">{m(totTds)}</td><td /></tr></tfoot> : null}
        </table>
      </div>
    </div>
  );
}
