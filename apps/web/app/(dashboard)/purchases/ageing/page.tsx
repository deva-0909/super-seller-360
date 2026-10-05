import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { CsvButton } from "@/components/ui/csv-button";

type Row = {
  bill_id: string; bill_no: string; supplier_id: string; supplier_name: string; is_msme: boolean; supplier_invoice_no: string; due_date: string;
  outstanding: number; days_overdue: number; bucket: string; msme_due_date: string | null; msme_breach: boolean;
};
const BUCKETS = ["Not due", "1-30", "31-60", "61-90", "90+"];

export default async function AgeingPage() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("supplier_ageing", {});
  const rows: Row[] = ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    bill_id: String(r.bill_id), bill_no: String(r.bill_no), supplier_id: String(r.supplier_id), supplier_name: String(r.supplier_name), is_msme: Boolean(r.is_msme),
    supplier_invoice_no: String(r.supplier_invoice_no), due_date: String(r.due_date), outstanding: Number(r.outstanding), days_overdue: Number(r.days_overdue),
    bucket: String(r.bucket), msme_due_date: (r.msme_due_date as string) ?? null, msme_breach: Boolean(r.msme_breach),
  }));

  // advances: approved payments not tied to a bill
  const { data: pays } = await supabase.from("supplier_payments").select("payment_id, amount, payment_allocations(amount)").eq("status", "approved");
  const advance = (pays ?? []).reduce((t, p) => t + Number(p.amount) - ((p.payment_allocations as unknown as { amount: number }[]) ?? []).reduce((s, a) => s + Number(a.amount), 0), 0);

  const { data: tb } = await supabase.rpc("trial_balance", { p_from: null, p_to: new Date().toISOString().slice(0, 10) });
  const led = ((tb ?? []) as Record<string, unknown>[]).find((r) => r.ledger_name === "Sundry Creditors");
  const ledgerOwed = led ? -Number(led.closing) : 0;
  const booksVisible = !!led; // only the finance team can read the ledger, so others see no comparison

  const bySupplier = new Map<string, { name: string; total: number; byBucket: Record<string, number> }>();
  for (const r of rows) {
    const s = bySupplier.get(r.supplier_id) ?? { name: r.supplier_name, total: 0, byBucket: {} };
    s.total += r.outstanding;
    s.byBucket[r.bucket] = (s.byBucket[r.bucket] ?? 0) + r.outstanding;
    bySupplier.set(r.supplier_id, s);
  }
  const totalBucket = (b: string) => rows.filter((r) => r.bucket === b).reduce((t, r) => t + r.outstanding, 0);
  const total = rows.reduce((t, r) => t + r.outstanding, 0);
  const breaches = rows.filter((r) => r.msme_breach);
  const diff = booksVisible ? Math.round((ledgerOwed - (total - advance)) * 100) / 100 : 0;

  const csv: (string | number)[][] = [
    ["Creditors ageing", new Date().toISOString().slice(0, 10)],
    ["Supplier", "Bill", "Supplier invoice", "Due date", "Days overdue", "Bucket", "Outstanding", "MSME limit date", "MSME limit passed"],
    ...rows.map((r) => [r.supplier_name, r.bill_no, r.supplier_invoice_no, r.due_date, r.days_overdue, r.bucket, r.outstanding, r.msme_due_date ?? "", r.msme_breach ? "Yes" : ""]),
  ];

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Creditors ageing</h1>
          <p className="mt-1 text-sm text-ink-muted">What you owe suppliers, by how long it is overdue (from the due date).</p>
        </div>
        <CsvButton rows={csv} filename="creditors-ageing" />
      </div>

      {breaches.length ? (
        <div className="mt-4 border border-danger/40 bg-danger-tint p-4 text-sm text-danger">
          <p className="font-medium">{breaches.length} bill{breaches.length === 1 ? "" : "s"} to micro or small suppliers past the 45-day limit.</p>
          <p className="mt-1 text-xs">Interest is payable on these, and the expense is allowed for tax only when paid. Confirm the treatment with your CA.</p>
          <ul className="mt-2 flex flex-col gap-1">
            {breaches.map((r) => <li key={r.bill_id}><Link className="underline" href={`/purchases/bills/${r.bill_id}`}>{r.bill_no}</Link> · {r.supplier_name} · {inr(r.outstanding)} · limit was {r.msme_due_date ? new Date(r.msme_due_date).toLocaleDateString("en-IN") : ""}</li>)}
          </ul>
        </div>
      ) : null}

      <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        {BUCKETS.map((b) => (
          <div key={b} className="border border-line bg-surface p-4"><p className="text-xs text-ink-muted">{b === "Not due" ? "Not yet due" : `${b} days overdue`}</p><p className="mt-1 font-data text-base text-ink">{inr(totalBucket(b)) === "—" ? "₹0" : inr(totalBucket(b))}</p></div>
        ))}
        <div className="border border-line-strong bg-surface p-4"><p className="text-xs text-ink-muted">Total outstanding</p><p className="mt-1 font-data text-base font-semibold text-ink">{inr(total) === "—" ? "₹0" : inr(total)}</p></div>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">By supplier</h2>
      <div className="mt-2 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Supplier</th>{BUCKETS.map((b) => <th key={b} className="px-4 py-3 font-medium text-right">{b}</th>)}<th className="px-4 py-3 font-medium text-right">Total</th></tr></thead>
          <tbody>
            {[...bySupplier.entries()].map(([id, s]) => (
              <tr key={id}><td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/suppliers/${id}`}>{s.name}</Link></td>
                {BUCKETS.map((b) => <td key={b} className="px-4 py-3 text-right font-data text-ink-muted">{inr(s.byBucket[b] ?? 0)}</td>)}
                <td className="px-4 py-3 text-right font-data font-medium text-ink">{inr(s.total)}</td></tr>
            ))}
            {!rows.length ? <tr><td colSpan={7} className="px-4 py-8 text-center text-sm text-ink-muted">No outstanding supplier bills.</td></tr> : null}
          </tbody>
        </table>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Bill by bill</h2>
      <div className="mt-2 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Bill</th><th className="px-4 py-3 font-medium">Supplier</th><th className="px-4 py-3 font-medium">Due</th>
            <th className="px-4 py-3 font-medium text-right">Days overdue</th><th className="px-4 py-3 font-medium text-right">Outstanding</th></tr></thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={r.bill_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/bills/${r.bill_id}`}>{r.bill_no}</Link></td>
                <td className="px-4 py-3 text-ink">{r.supplier_name}{r.msme_breach ? <span className="ml-2 text-xs text-danger">MSME limit passed</span> : null}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(r.due_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{r.days_overdue || "—"}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(r.outstanding)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {booksVisible ? (
      <div className={`mt-6 border p-4 text-sm ${Math.abs(diff) < 0.01 ? "border-line bg-accent-tint text-ink" : "border-warning/40 bg-warning-tint text-ink"}`}>
        <p className="font-medium">Check against the books</p>
        <p className="mt-1 text-ink-muted">
          Sundry Creditors ledger shows {inr(ledgerOwed) === "—" ? "₹0" : inr(ledgerOwed)}. Bills outstanding {inr(total) === "—" ? "₹0" : inr(total)}{advance > 0.004 ? ` less advances paid ${inr(advance)}` : ""}.
          {Math.abs(diff) < 0.01 ? " They agree." : ` Difference ${inr(Math.abs(diff))}: usually a manual journal, an opening balance or a supplier balance carried over from before this module. Look in the Sundry Creditors ledger.`}
        </p>
      </div>
      ) : null}
    </div>
  );
}
