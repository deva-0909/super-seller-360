"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { Lbl, inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

export type Adj = { adj_id: string; kind: string; igst: number; cgst: number; sgst: number; note: string; voided: boolean };

export function ItcAdjustments({ month, items, canWrite }: { month: string; items: Adj[]; canWrite: boolean }) {
  const router = useRouter();
  const [kind, setKind] = useState<"other_itc" | "reversal">("other_itc");
  const [igst, setIgst] = useState("");
  const [cgst, setCgst] = useState("");
  const [sgst, setSgst] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function add(e: React.FormEvent) {
    e.preventDefault();
    setErr(null); setBusy(true);
    const { error } = await createClient().rpc("add_gst_itc_adjustment", {
      p_period: month, p_kind: kind, p_igst: Number(igst) || 0, p_cgst: Number(cgst) || 0, p_sgst: Number(sgst) || 0, p_note: note,
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setIgst(""); setCgst(""); setSgst(""); setNote("");
    router.refresh();
  }
  async function voidIt(id: string) {
    if (!window.confirm("Remove this entry from the workings?")) return;
    const { error } = await createClient().rpc("void_gst_itc_adjustment", { p_id: id });
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }

  return (
    <div className="mt-3 border border-line bg-surface p-4">
      <ul className="flex flex-col gap-1 text-sm">
        {items.filter((i) => !i.voided).map((i) => (
          <li key={i.adj_id} className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-ink">{i.kind === "other_itc" ? "Credit from GSTR-2B" : "Credit reversed"}: IGST {inr(i.igst)} · CGST {inr(i.cgst)} · SGST {inr(i.sgst)} <span className="text-ink-muted">({i.note})</span></span>
            {canWrite ? <button className={smallBtn} onClick={() => voidIt(i.adj_id)}>Remove</button> : null}
          </li>
        ))}
        {!items.some((i) => !i.voided) ? <li className="text-ink-muted">No entries for this month.</li> : null}
      </ul>
      {canWrite ? (
        <form onSubmit={add} className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-6">
          <Lbl label="Type" className="col-span-2 sm:col-span-2">
            <select className={inputCls} value={kind} onChange={(e) => setKind(e.target.value as "other_itc" | "reversal")}>
              <option value="other_itc">Credit from GSTR-2B (marketplace fees, other invoices)</option>
              <option value="reversal">Credit to reverse (blocked or ineligible)</option>
            </select>
          </Lbl>
          <Lbl label="IGST"><input className={inputCls} type="number" step="0.01" min="0" inputMode="decimal" value={igst} onChange={(e) => setIgst(e.target.value)} /></Lbl>
          <Lbl label="CGST"><input className={inputCls} type="number" step="0.01" min="0" inputMode="decimal" value={cgst} onChange={(e) => setCgst(e.target.value)} /></Lbl>
          <Lbl label="SGST"><input className={inputCls} type="number" step="0.01" min="0" inputMode="decimal" value={sgst} onChange={(e) => setSgst(e.target.value)} /></Lbl>
          <Lbl label="Note *" className="col-span-2 sm:col-span-6"><input className={inputCls} value={note} onChange={(e) => setNote(e.target.value)} placeholder="Where the figure comes from, e.g. GSTR-2B Amazon seller fee invoices" required /></Lbl>
          <div className="col-span-2 sm:col-span-6"><button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : "Add entry"}</button></div>
        </form>
      ) : null}
      {err ? <p className="mt-2 text-sm text-danger">{err}</p> : null}
    </div>
  );
}
