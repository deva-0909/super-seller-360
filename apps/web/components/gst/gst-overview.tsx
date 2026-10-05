import { createClient } from "@/lib/supabase/server";
import { inr, parseMonth } from "@/lib/report-utils";
import { CsvButton } from "@/components/ui/csv-button";

type W = {
  outward: { taxable: number; igst: number; cgst: number; sgst: number; nil_taxable: number };
  itc_bills: { igst: number; cgst: number; sgst: number; ineligible: number; bills: number };
  itc_notes?: { igst: number; cgst: number; sgst: number };
  itc_adj: { other_igst: number; other_cgst: number; other_sgst: number; rev_igst: number; rev_cgst: number; rev_sgst: number };
};

const n = (v: unknown) => Number(v ?? 0);
const m = (v: number) => (inr(v) === "—" ? "₹0.00" : inr(v));

function summarise(w: W) {
  const sales = n(w.outward.taxable) + n(w.outward.nil_taxable);
  const out = n(w.outward.igst) + n(w.outward.cgst) + n(w.outward.sgst);
  const bills = n(w.itc_bills.igst) + n(w.itc_bills.cgst) + n(w.itc_bills.sgst);
  const entered = n(w.itc_adj.other_igst) + n(w.itc_adj.other_cgst) + n(w.itc_adj.other_sgst);
  const notes = w.itc_notes ? n(w.itc_notes.igst) + n(w.itc_notes.cgst) + n(w.itc_notes.sgst) : 0;
  const rev = n(w.itc_adj.rev_igst) + n(w.itc_adj.rev_cgst) + n(w.itc_adj.rev_sgst);
  const input = bills + entered - notes - rev;
  return { sales, out, bills, entered, notes, rev, input, net: out - input };
}

function monthsBack(month: string, count: number): string[] {
  const [y, mo] = month.split("-").map(Number);
  return Array.from({ length: count }, (_, i) => {
    const d = new Date(y, mo - 1 - (count - 1 - i), 1);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
  });
}

function dueDate(month: string, day: number): Date {
  const [y, mo] = month.split("-").map(Number);
  return new Date(y, mo, day); // the month after the return month
}

/** Overview block shown above the GST workings: summary cards, the payable − credit formula, a 6-month trend, filing dates and the input credit table. */
export async function GstOverview({ month }: { month?: string }) {
  const sel = parseMonth(month).month;
  const supabase = await createClient();
  const list = monthsBack(sel, 6);
  const results = await Promise.all(list.map((mm) => supabase.rpc("gstr3b_workings", { p_month: mm })));
  if (results.some((r) => r.error || !r.data)) return null;
  const rows = results.map((r, i) => ({ month: list[i], ...summarise(r.data as unknown as W) }));
  const cur = rows[rows.length - 1];
  const max = Math.max(1, ...rows.flatMap((r) => [r.out, Math.max(r.input, 0)]));

  const today = new Date(); today.setHours(0, 0, 0, 0);
  const due = [
    { label: "GSTR-1", date: dueDate(sel, 11) },
    { label: "GSTR-3B", date: dueDate(sel, 20) },
  ].map((d) => ({ ...d, days: Math.round((d.date.getTime() - today.getTime()) / 86400000) }));

  const card = "border border-line bg-surface p-4";
  const csv: (string | number)[][] = [
    ["GST monthly summary"],
    ["Month", "Sales", "GST collected", "Input credit", "Net payable"],
    ...rows.map((r) => [r.month, r.sales, r.out, r.input, r.net]),
  ];
  const itcCsv: (string | number)[][] = [
    ["Input credit ledger"],
    ["Month", "From purchase bills", "From GSTR-2B entries", "Less supplier credit notes", "Less reversals", "Net credit"],
    ...rows.map((r) => [r.month, r.bills, r.entered, r.notes, r.rev, r.input]),
  ];

  return (
    <section aria-label="GST overview" className="mb-2">
      <p className="text-xs text-ink-muted">Worked out automatically from your invoices, credit notes and purchase bills. Figures for {sel}.</p>
      <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className={card}><p className="text-xs text-ink-muted">Sales (taxable + nil-rated)</p><p className="mt-1 font-data text-xl font-semibold text-ink">{m(cur.sales)}</p></div>
        <div className={card}><p className="text-xs text-ink-muted">GST collected</p><p className="mt-1 font-data text-xl font-semibold text-ink">{m(cur.out)}</p></div>
        <div className={card}><p className="text-xs text-ink-muted">Input tax credit</p><p className="mt-1 font-data text-xl font-semibold text-ink">{m(cur.input)}</p></div>
        <div className={card}><p className="text-xs text-ink-muted">Net GST liability</p><p className={`mt-1 font-data text-xl font-semibold ${cur.net < 0 ? "text-success" : "text-ink"}`}>{m(cur.net)}</p></div>
      </div>
      <p className="mt-3 border border-line bg-surface-sunken/60 px-4 py-2 text-center font-data text-sm text-ink">
        GST payable {m(cur.out)} − Input credit {m(cur.input)} = Net liability {m(cur.net)}
      </p>

      <div className="mt-4 grid gap-3 lg:grid-cols-3">
        <div className={`${card} lg:col-span-2`}>
          <p className="text-sm font-semibold text-ink">Last 6 months</p>
          <div className="mt-3 flex h-40 items-end gap-3">
            {rows.map((r) => (
              <div key={r.month} className="flex h-full flex-1 flex-col justify-end">
                <div className="flex flex-1 items-end justify-center gap-1">
                  <div title={`Collected ${m(r.out)}`} className="w-1/2 bg-accent" style={{ height: `${(r.out / max) * 100}%` }} />
                  <div title={`Input credit ${m(Math.max(r.input, 0))}`} className="w-1/2 bg-success" style={{ height: `${(Math.max(r.input, 0) / max) * 100}%` }} />
                </div>
                <p className="mt-1 text-center text-[10px] text-ink-muted">{r.month.slice(2)}</p>
              </div>
            ))}
          </div>
          <p className="mt-2 text-xs text-ink-muted"><span className="inline-block h-2 w-2 bg-accent" /> GST collected · <span className="inline-block h-2 w-2 bg-success" /> Input credit</p>
        </div>
        <div className={card}>
          <p className="text-sm font-semibold text-ink">Filing due dates</p>
          <ul className="mt-3 space-y-3">
            {due.map((d) => (
              <li key={d.label} className="flex items-center justify-between text-sm">
                <span className="text-ink">{d.label}<span className="block text-xs text-ink-muted">{d.date.toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric" })}</span></span>
                <span className={`font-data text-xs ${d.days < 0 ? "text-danger" : d.days <= 5 ? "text-warning" : "text-ink-muted"}`}>
                  {d.days < 0 ? `${-d.days} days overdue` : d.days === 0 ? "Due today" : `${d.days} days left`}
                </span>
              </li>
            ))}
          </ul>
          <p className="mt-3 text-xs text-ink-muted">Standard dates; your due date may differ (QRMP, notified extensions).</p>
        </div>
      </div>

      <div className="mt-4 flex flex-wrap items-center gap-2">
        <span className="text-xs text-ink-muted">Reports:</span>
        <CsvButton rows={csv} filename={`gst-monthly-summary-${sel}`} />
        <CsvButton rows={itcCsv} filename={`gst-input-credit-${sel}`} />
      </div>

      <h3 className="mt-6 text-sm font-semibold text-ink">Input credit ledger</h3>
      <div className="mt-2 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Month</th>
            {["From purchase bills", "From GSTR-2B entries", "Less credit notes", "Less reversals", "Net credit"].map((h) => <th key={h} className="px-4 py-3 text-right font-medium">{h}</th>)}
          </tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.month} className="border-b border-line/60">
                <td className="px-4 py-2.5 text-ink-muted">{r.month}</td>
                <td className="px-4 py-2.5 text-right font-data text-ink">{m(r.bills)}</td>
                <td className="px-4 py-2.5 text-right font-data text-ink">{m(r.entered)}</td>
                <td className="px-4 py-2.5 text-right font-data text-ink">{m(r.notes)}</td>
                <td className="px-4 py-2.5 text-right font-data text-ink">{m(r.rev)}</td>
                <td className="px-4 py-2.5 text-right font-data font-medium text-ink">{m(r.input)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
