"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

type Opt = { id: string; label: string };
type Line = { description: string; hsn_code: string; quantity: string; unit_price: string; gst_rate: string; ledger_id: string };
const RATES = ["0", "5", "12", "18", "28"];
const field = "h-9 w-full border border-line bg-surface px-2 text-sm text-ink";

export function RecurringForm({ suppliers, ledgers }: { suppliers: Opt[]; ledgers: Opt[] }) {
  const router = useRouter();
  const supabase = createClient();
  const blank = (): Line => ({ description: "", hsn_code: "", quantity: "1", unit_price: "", gst_rate: "18", ledger_id: ledgers[0]?.id ?? "" });
  const [name, setName] = useState(""); const [supplier, setSupplier] = useState(""); const [freq, setFreq] = useState("monthly");
  const [first, setFirst] = useState(""); const [end, setEnd] = useState(""); const [prefix, setPrefix] = useState("REC"); const [itc, setItc] = useState(true); const [reason, setReason] = useState("");
  const [lines, setLines] = useState<Line[]>([blank()]);
  const [busy, setBusy] = useState(false); const [err, setErr] = useState<string | null>(null); const [ok, setOk] = useState(false);

  const setLine = (i: number, k: keyof Line, v: string) => setLines(lines.map((l, j) => (j === i ? { ...l, [k]: v } : l)));
  const total = lines.reduce((s, l) => s + Number(l.quantity || 0) * Number(l.unit_price || 0) * (1 + Number(l.gst_rate) / 100), 0);

  async function save() {
    setBusy(true); setErr(null); setOk(false);
    const { error } = await supabase.rpc("recurring_bill_save", {
      p_id: null,
      p: { name, supplier_id: supplier, frequency: freq, next_date: first, end_date: end || null, invoice_prefix: prefix, itc, itc_reason: itc ? null : reason,
           lines: lines.map((l) => ({ description: l.description, hsn_code: l.hsn_code, quantity: Number(l.quantity), unit_price: Number(l.unit_price), gst_rate: Number(l.gst_rate), ledger_id: l.ledger_id })) },
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setOk(true); setName(""); setFirst(""); setEnd(""); setLines([blank()]); router.refresh();
  }

  return (
    <div className="mt-10 max-w-4xl border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Add a recurring bill</h2>
      <div className="mt-3 grid gap-3 md:grid-cols-3">
        <label className="flex flex-col gap-1 text-xs text-ink-muted">Name<input className={field} value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Office rent" /></label>
        <label className="flex flex-col gap-1 text-xs text-ink-muted">Supplier<select className={field} value={supplier} onChange={(e) => setSupplier(e.target.value)}><option value="">Choose…</option>{suppliers.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}</select></label>
        <label className="flex flex-col gap-1 text-xs text-ink-muted">Repeats<select className={field} value={freq} onChange={(e) => setFreq(e.target.value)}><option value="monthly">Every month</option><option value="quarterly">Every 3 months</option><option value="yearly">Every year</option></select></label>
        <label className="flex flex-col gap-1 text-xs text-ink-muted">First bill date<input type="date" className={field} value={first} onChange={(e) => setFirst(e.target.value)} /></label>
        <label className="flex flex-col gap-1 text-xs text-ink-muted">Stop after (optional)<input type="date" className={field} value={end} onChange={(e) => setEnd(e.target.value)} /></label>
        <label className="flex flex-col gap-1 text-xs text-ink-muted">Invoice number starts with<input className={field} value={prefix} onChange={(e) => setPrefix(e.target.value)} /></label>
      </div>
      <p className="mt-1 text-xs text-ink-muted">Each bill gets the invoice number {prefix.toUpperCase() || "REC"}-YYYYMM, so the same month can never be entered twice. If the supplier sends its own invoice numbers, edit the bill after it is created.</p>

      <div className="mt-4 space-y-2">
        {lines.map((l, i) => (
          <div key={i} className="grid gap-2 md:grid-cols-12">
            <input className={`${field} md:col-span-4`} placeholder="Description" aria-label="Description" value={l.description} onChange={(e) => setLine(i, "description", e.target.value)} />
            <input className={`${field} md:col-span-1`} placeholder="HSN" aria-label="HSN or SAC" value={l.hsn_code} onChange={(e) => setLine(i, "hsn_code", e.target.value)} />
            <input className={`${field} md:col-span-1`} inputMode="decimal" aria-label="Quantity" value={l.quantity} onChange={(e) => setLine(i, "quantity", e.target.value)} />
            <input className={`${field} md:col-span-2`} inputMode="decimal" placeholder="Price" aria-label="Unit price" value={l.unit_price} onChange={(e) => setLine(i, "unit_price", e.target.value)} />
            <select className={`${field} md:col-span-1`} aria-label="GST rate" value={l.gst_rate} onChange={(e) => setLine(i, "gst_rate", e.target.value)}>{RATES.map((r) => <option key={r} value={r}>{r}%</option>)}</select>
            <select className={`${field} md:col-span-2`} aria-label="Account" value={l.ledger_id} onChange={(e) => setLine(i, "ledger_id", e.target.value)}>{ledgers.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}</select>
            <button type="button" className="text-xs text-danger underline md:col-span-1" disabled={lines.length === 1} onClick={() => setLines(lines.filter((_, j) => j !== i))}>Remove</button>
          </div>
        ))}
        <button type="button" className="text-xs font-semibold text-accent underline" onClick={() => setLines([...lines, blank()])}>Add a line</button>
      </div>

      <label className="mt-4 flex items-center gap-2 text-xs text-ink"><input type="checkbox" checked={itc} onChange={(e) => setItc(e.target.checked)} /> Claim GST credit on these bills</label>
      {!itc ? <input className={`${field} mt-2 max-w-md`} placeholder="Why is credit not claimed?" value={reason} onChange={(e) => setReason(e.target.value)} /> : null}

      <p className="mt-4 text-sm text-ink">About ₹{total.toLocaleString("en-IN", { maximumFractionDigits: 2 })} per bill, including GST</p>
      <div className="mt-3 flex items-center gap-3">
        <button className="h-9 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50" disabled={busy || !name || !supplier || !first} onClick={save}>Save recurring bill</button>
        {ok ? <span className="text-sm text-success">Saved. It appears in the list above.</span> : null}
        {err ? <span role="alert" className="text-sm text-danger">{err}</span> : null}
      </div>
    </div>
  );
}
