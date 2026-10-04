"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { GST_RATES } from "@/lib/purchase-calc";
import { inr } from "@/lib/report-utils";
import { linkProofs, type Proof } from "@/lib/attachments";
import { Proofs } from "@/components/ui/proofs";
import { Lbl, inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

export type BillOpt = { bill_id: string; label: string; taxable: number; intra: boolean; itc: boolean };
type Line = { description: string; taxable: string; rate: string };
const today = () => new Date().toISOString().slice(0, 10);
const r2 = (n: number) => Math.round(n * 100) / 100;

export function NoteForm({ bills, initialBill }: { bills: BillOpt[]; initialBill?: string }) {
  const router = useRouter();
  const [bill, setBill] = useState(initialBill && bills.some((b) => b.bill_id === initialBill) ? initialBill : "");
  const [noteNo, setNoteNo] = useState("");
  const [date, setDate] = useState(today());
  const [reason, setReason] = useState("return");
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState<Line[]>([{ description: "", taxable: "", rate: "12" }]);
  const [proofs, setProofs] = useState<Proof[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const b = bills.find((x) => x.bill_id === bill);
  const calc = lines.map((l) => {
    const tx = Number(l.taxable) || 0, tax = r2(tx * (Number(l.rate) || 0) / 100);
    return { tx, tax };
  });
  const taxable = calc.reduce((t, c) => t + c.tx, 0), tax = calc.reduce((t, c) => t + c.tax, 0);
  const set = (i: number, p: Partial<Line>) => setLines((ls) => ls.map((l, k) => (k === i ? { ...l, ...p } : l)));

  async function submit(e: React.FormEvent) {
    e.preventDefault(); setErr(null); setBusy(true);
    const payload = lines.filter((l) => Number(l.taxable) > 0).map((l) => ({ description: l.description, taxable: Number(l.taxable), gst_rate: Number(l.rate) }));
    const { data, error } = await createClient().rpc("create_supplier_credit_note", { p_bill: bill, p_note_no: noteNo, p_date: date, p_reason: reason, p_lines: payload, p_notes: notes });
    if (error || !data) { setBusy(false); setErr(friendlyError(error?.message ?? "Could not save")); return; }
    const id = data as unknown as string;
    let attach = "";
    if (proofs.length) { try { await linkProofs(proofs.map((p) => p.attachment_id), "supplier_credit_note", id); } catch { attach = "?attach=failed"; } }
    router.push(`/purchases/credit-notes/${id}${attach}`);
  }

  return (
    <form onSubmit={submit} className="mt-6 flex max-w-3xl flex-col gap-4">
      <Lbl label="Against which bill?">
        <select className={inputCls} value={bill} onChange={(e) => setBill(e.target.value)} required>
          <option value="">Choose a bill…</option>{bills.map((x) => <option key={x.bill_id} value={x.bill_id}>{x.label}</option>)}
        </select>
      </Lbl>
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
        <Lbl label="Supplier’s credit note number"><input className={inputCls} value={noteNo} onChange={(e) => setNoteNo(e.target.value)} required /></Lbl>
        <Lbl label="Note date"><input className={inputCls} type="date" max={today()} value={date} onChange={(e) => setDate(e.target.value)} required /></Lbl>
        <Lbl label="Reason">
          <select className={inputCls} value={reason} onChange={(e) => setReason(e.target.value)}>
            <option value="return">Goods returned</option><option value="rate_difference">Rate difference</option><option value="discount">Discount</option><option value="other">Other</option>
          </select>
        </Lbl>
      </div>
      <div>
        <p className="text-xs text-ink-muted">What the credit note covers (value before GST)</p>
        <div className="mt-2 flex flex-col gap-2">
          {lines.map((l, i) => (
            <div key={i} className="grid grid-cols-[1fr_8rem_6rem_auto] items-end gap-2">
              <input className={inputCls} placeholder="Description" value={l.description} onChange={(e) => set(i, { description: e.target.value })} />
              <input className={`${inputCls} text-right`} type="number" step="0.01" min="0" inputMode="decimal" placeholder="Value" value={l.taxable} onChange={(e) => set(i, { taxable: e.target.value })} />
              <select className={inputCls} value={l.rate} onChange={(e) => set(i, { rate: e.target.value })}>{GST_RATES.map((r) => <option key={r} value={r}>{r}%</option>)}</select>
              <button type="button" className={smallBtn} onClick={() => setLines((ls) => (ls.length > 1 ? ls.filter((_, k) => k !== i) : ls))}>Remove</button>
            </div>
          ))}
        </div>
        <button type="button" className={`${smallBtn} mt-2`} onClick={() => setLines((ls) => [...ls, { description: "", taxable: "", rate: "12" }])}>Add a line</button>
      </div>
      <div className="border border-line bg-surface p-4 text-sm">
        <div className="flex justify-between"><span className="text-ink-muted">Value before GST</span><span className="font-data">{inr(taxable) === "—" ? "₹0.00" : inr(taxable)}</span></div>
        <div className="flex justify-between"><span className="text-ink-muted">GST</span><span className="font-data">{inr(tax) === "—" ? "₹0.00" : inr(tax)}</span></div>
        <div className="flex justify-between font-medium"><span className="text-ink">Credit note total</span><span className="font-data">{inr(taxable + tax) === "—" ? "₹0.00" : inr(taxable + tax)}</span></div>
        {b ? <p className="mt-2 text-xs text-ink-muted">{b.itc ? "GST credit was claimed on this bill, so the GST here is reversed from your input credit." : "No GST credit was claimed on this bill, so nothing is reversed from input credit."} The bill’s value before GST is {inr(b.taxable)}. The database checks the final amounts when you save.</p> : null}
      </div>
      <Lbl label="Note (optional)"><input className={inputCls} value={notes} onChange={(e) => setNotes(e.target.value)} /></Lbl>
      <Proofs entityType="supplier_credit_note" pending={proofs} onPending={setProofs} kind="bill" label="Credit note (photo or PDF)" hint="Use the phone camera, or pick the supplier’s PDF." />
      {err ? <p className="text-sm text-danger">{err}</p> : null}
      <div><button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : "Save for approval"}</button></div>
    </form>
  );
}
