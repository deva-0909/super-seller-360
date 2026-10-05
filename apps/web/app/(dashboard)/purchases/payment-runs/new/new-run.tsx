"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, Lbl, primaryBtn } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";

type Row = { bill_id: string; bill_no: string; supplier_name: string; due_date: string; outstanding: number; is_msme: boolean; msme_days_left: number | null; has_bank: boolean };

export function NewRun({ due, banks, rows }: { due: string; banks: { id: string; label: string }[]; rows: Row[] }) {
  const router = useRouter();
  const [bank, setBank] = useState(banks[0]?.id ?? "");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [note, setNote] = useState("");
  const [sel, setSel] = useState<Set<string>>(new Set(rows.filter((r) => r.has_bank).map((r) => r.bill_id)));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const total = rows.filter((r) => sel.has(r.bill_id)).reduce((t, r) => t + r.outstanding, 0);

  async function create() {
    setBusy(true); setErr(null);
    const { data, error } = await createClient().rpc("payment_run_create", { p_bank: bank, p_run_date: date, p_items: [...sel].map((id) => ({ bill_id: id })), p_note: note || null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/purchases/payment-runs/${data as string}`);
  }

  return (
    <div className="mt-4 space-y-4">
      <form method="get" className="flex flex-wrap items-end gap-3">
        <Lbl label="Bills due up to"><input type="date" name="due" defaultValue={due} className={inputCls} /></Lbl>
        <button className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken">Show</button>
      </form>
      <div className="overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3" /><th className="px-3 py-3 font-medium">Supplier</th><th className="px-3 py-3 font-medium">Bill</th><th className="px-3 py-3 font-medium">Due</th><th className="px-3 py-3 text-right font-medium">To pay</th><th className="px-3 py-3 font-medium">Note</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.bill_id} className="border-b border-line last:border-0">
                <td className="px-3 py-3"><input type="checkbox" aria-label={`Pay ${r.bill_no}`} checked={sel.has(r.bill_id)} onChange={(e) => { const n = new Set(sel); if (e.target.checked) n.add(r.bill_id); else n.delete(r.bill_id); setSel(n); }} /></td>
                <td className="px-3 py-3 text-ink">{r.supplier_name}</td><td className="px-3 py-3 font-data text-xs">{r.bill_no}</td><td className="px-3 py-3 text-ink-muted">{r.due_date}</td>
                <td className="px-3 py-3 text-right font-data">{inr(r.outstanding)}</td>
                <td className="px-3 py-3 text-xs">{r.is_msme ? <span className={(r.msme_days_left ?? 99) <= 7 ? "text-danger" : "text-ink-muted"}>MSME{r.msme_days_left != null ? ` · ${r.msme_days_left} days left` : ""}</span> : null}{!r.has_bank ? <span className="ml-2 text-warning">bank details missing</span> : null}</td>
              </tr>
            ))}
            {rows.length === 0 ? <tr><td colSpan={6} className="px-3 py-6 text-ink-muted">No approved bills are due and unpaid.</td></tr> : null}
          </tbody>
        </table>
      </div>
      <div className="grid max-w-3xl gap-3 md:grid-cols-3">
        <Lbl label="Pay from"><select className={inputCls} value={bank} onChange={(e) => setBank(e.target.value)}>{banks.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}</select></Lbl>
        <Lbl label="Payment date"><input type="date" className={inputCls} value={date} onChange={(e) => setDate(e.target.value)} /></Lbl>
        <Lbl label="Note (optional)"><input className={inputCls} value={note} onChange={(e) => setNote(e.target.value)} /></Lbl>
      </div>
      <p className="text-sm text-ink">{sel.size} bill(s) · total <span className="font-data font-medium">₹{inr(total)}</span></p>
      <button className={primaryBtn} onClick={create} disabled={busy || sel.size === 0}>{busy ? "Creating…" : "Create payment run"}</button>
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
