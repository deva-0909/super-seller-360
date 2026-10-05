"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { inputCls, primaryBtn } from "@/components/purchases/bits";

export type PlanItem = { item_id: string; item_date: string; direction: "in" | "out"; amount: number; label: string; repeat: string; until: string | null };

export function PlanPanel({ items, buffer, canWrite, canSet }: { items: PlanItem[]; buffer: number; canWrite: boolean; canSet: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [f, setF] = useState({ date: "", dir: "out", amount: "", label: "", repeat: "none", until: "" });
  const [buf, setBuf] = useState(String(buffer));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function add() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("cash_plan_add", { p_date: f.date || null, p_direction: f.dir, p_amount: Number(f.amount), p_label: f.label, p_repeat: f.repeat, p_until: f.until || null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setF({ date: "", dir: "out", amount: "", label: "", repeat: "none", until: "" }); router.refresh();
  }
  async function cancel(id: string) {
    const { error } = await supabase.rpc("cash_plan_cancel", { p_item: id });
    if (error) setErr(friendlyError(error.message)); else router.refresh();
  }
  async function saveBuf() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("forecast_settings_save", { p: { min_cash_buffer: buf } });
    setBusy(false);
    if (error) setErr(friendlyError(error.message)); else router.refresh();
  }
  return (
    <section className="mt-8 border border-line bg-surface p-4">
      <h2 className="text-sm font-semibold text-ink">Your own planned money in and out</h2>
      <p className="mt-1 max-w-3xl text-xs text-ink-muted">Add anything the system cannot know: GST payment, TDS deposits other than salary, rent, a loan instalment, a big marketing spend, an expected receipt. Monthly items repeat on the same day each month.</p>
      {items.length > 0 ? (
        <table className="mt-3 w-full text-left text-sm">
          <thead><tr className="border-b border-line text-xs text-ink-muted"><th className="py-2 font-medium">Date</th><th className="py-2 font-medium">For</th><th className="py-2 font-medium">Repeats</th><th className="py-2 text-right font-medium">Amount</th><th /></tr></thead>
          <tbody>{items.map((i) => (
            <tr key={i.item_id} className="border-b border-line last:border-0">
              <td className="py-2">{i.item_date}</td><td className="py-2">{i.label}</td><td className="py-2 text-ink-muted">{i.repeat === "none" ? "Once" : i.repeat === "weekly" ? "Every week" : "Every month"}{i.until ? ` until ${i.until}` : ""}</td>
              <td className={`py-2 text-right font-data ${i.direction === "in" ? "text-success" : "text-danger"}`}>{i.direction === "in" ? "+" : "-"}{inr(Number(i.amount))}</td>
              <td className="py-2 text-right">{canWrite ? <button className="text-xs text-accent hover:underline" onClick={() => cancel(i.item_id)}>Remove</button> : null}</td>
            </tr>))}</tbody>
        </table>
      ) : <p className="mt-3 text-sm text-ink-muted">Nothing planned yet.</p>}
      {canWrite ? (
        <div className="mt-4 grid gap-2 sm:grid-cols-6">
          <input type="date" className={inputCls} value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} />
          <select className={inputCls} value={f.dir} onChange={(e) => setF({ ...f, dir: e.target.value })}><option value="out">Money out</option><option value="in">Money in</option></select>
          <input className={inputCls} inputMode="decimal" placeholder="Amount" value={f.amount} onChange={(e) => setF({ ...f, amount: e.target.value })} />
          <input className={`${inputCls} sm:col-span-2`} placeholder="What is it for" value={f.label} onChange={(e) => setF({ ...f, label: e.target.value })} />
          <select className={inputCls} value={f.repeat} onChange={(e) => setF({ ...f, repeat: e.target.value })}><option value="none">Once</option><option value="weekly">Every week</option><option value="monthly">Every month</option></select>
          {f.repeat !== "none" ? <input type="date" className={inputCls} value={f.until} onChange={(e) => setF({ ...f, until: e.target.value })} title="Stop repeating after this date (optional)" /> : null}
          <button className={primaryBtn} disabled={busy} onClick={add}>Add</button>
        </div>
      ) : null}
      {canSet ? (
        <div className="mt-4 flex flex-wrap items-end gap-2 border-t border-line pt-4">
          <label className="text-xs text-ink-muted">Lowest cash you want to keep (weeks below this are flagged)
            <input className={`${inputCls} !w-48`} inputMode="decimal" value={buf} onChange={(e) => setBuf(e.target.value)} />
          </label>
          <button className={primaryBtn} disabled={busy} onClick={saveBuf}>Save</button>
        </div>
      ) : null}
      {err ? <p className="mt-2 text-sm text-danger">{err}</p> : null}
    </section>
  );
}
