"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, Lbl, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Line = { product_id: string; quantity: string; note: string };

export function ReqForm({ warehouses, products }: { warehouses: { warehouse_id: string; name: string }[]; products: { product_id: string; sku: string; name: string }[] }) {
  const router = useRouter();
  const [wh, setWh] = useState(warehouses[0]?.warehouse_id ?? "");
  const [needed, setNeeded] = useState("");
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState<Line[]>([{ product_id: "", quantity: "", note: "" }]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const setLine = (i: number, patch: Partial<Line>) => setLines(lines.map((l, k) => (k === i ? { ...l, ...patch } : l)));

  async function save() {
    setBusy(true); setErr(null);
    const payload = lines.filter((l) => l.product_id).map((l) => ({ product_id: l.product_id, quantity: Number(l.quantity), note: l.note || null }));
    const { data, error } = await createClient().rpc("req_create", { p_warehouse: wh, p_needed_by: needed || null, p_lines: payload, p_notes: notes || null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/purchases/requisitions/${data as string}`);
  }
  return (
    <div className="mt-4 max-w-4xl space-y-4">
      <div className="grid gap-3 md:grid-cols-2">
        <Lbl label="Branch store that needs the goods"><select className={inputCls} value={wh} onChange={(e) => setWh(e.target.value)}>{warehouses.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.name}</option>)}</select></Lbl>
        <Lbl label="Needed by"><input type="date" className={inputCls} value={needed} onChange={(e) => setNeeded(e.target.value)} /></Lbl>
      </div>
      <div className="space-y-2">
        {lines.map((l, i) => (
          <div key={i} className="grid grid-cols-12 items-end gap-2">
            <Lbl label={i === 0 ? "Product" : ""} className="col-span-12 md:col-span-5"><select className={inputCls} value={l.product_id} onChange={(e) => setLine(i, { product_id: e.target.value })}><option value="">Choose…</option>{products.map((p) => <option key={p.product_id} value={p.product_id}>{p.sku} · {p.name}</option>)}</select></Lbl>
            <Lbl label={i === 0 ? "Qty" : ""} className="col-span-4 md:col-span-2"><input className={inputCls} inputMode="numeric" value={l.quantity} onChange={(e) => setLine(i, { quantity: e.target.value })} /></Lbl>
            <Lbl label={i === 0 ? "Note" : ""} className="col-span-6 md:col-span-4"><input className={inputCls} value={l.note} onChange={(e) => setLine(i, { note: e.target.value })} placeholder="size / colour / why" /></Lbl>
            <button type="button" className={`${smallBtn} col-span-2 md:col-span-1`} onClick={() => setLines(lines.filter((_, k) => k !== i))} disabled={lines.length === 1} aria-label="Remove line">✕</button>
          </div>
        ))}
        <button type="button" className={smallBtn} onClick={() => setLines([...lines, { product_id: "", quantity: "", note: "" }])}>+ Add line</button>
      </div>
      <Lbl label="Notes (optional)"><input className={inputCls} value={notes} onChange={(e) => setNotes(e.target.value)} /></Lbl>
      <button className={primaryBtn} onClick={save} disabled={busy}>{busy ? "Saving…" : "Send for approval"}</button>
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
