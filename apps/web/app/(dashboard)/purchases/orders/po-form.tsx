"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, Lbl, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Product = { product_id: string; sku: string; name: string; cost_price: number | null; gst_rate: number | null };
type Line = { product_id: string; quantity: string; unit_price: string; gst_rate: string };
const RATES = ["0", "0.25", "3", "5", "12", "18", "28", "40"];

export function PoForm({ suppliers, warehouses, products, supplier }: { suppliers: { supplier_id: string; name: string }[]; warehouses: { warehouse_id: string; name: string }[]; products: Product[]; supplier?: string }) {
  const router = useRouter();
  const [sup, setSup] = useState(supplier ?? suppliers[0]?.supplier_id ?? "");
  const [wh, setWh] = useState(warehouses[0]?.warehouse_id ?? "");
  const [expected, setExpected] = useState("");
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState<Line[]>([{ product_id: "", quantity: "", unit_price: "", gst_rate: "5" }]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  function setLine(i: number, patch: Partial<Line>) { setLines(lines.map((l, k) => (k === i ? { ...l, ...patch } : l))); }
  function pick(i: number, id: string) {
    const p = products.find((x) => x.product_id === id);
    setLine(i, { product_id: id, unit_price: p?.cost_price != null ? String(p.cost_price) : "", gst_rate: p?.gst_rate != null && RATES.includes(String(p.gst_rate)) ? String(p.gst_rate) : "5" });
  }
  const total = lines.reduce((t, l) => t + (Number(l.quantity) || 0) * (Number(l.unit_price) || 0) * (1 + (Number(l.gst_rate) || 0) / 100), 0);

  async function save() {
    setBusy(true); setErr(null);
    const payload = lines.filter((l) => l.product_id).map((l) => ({ product_id: l.product_id, quantity: Number(l.quantity), unit_price: Number(l.unit_price), gst_rate: Number(l.gst_rate) }));
    const { data, error } = await createClient().rpc("po_create", { p_supplier: sup, p_warehouse: wh, p_lines: payload, p_expected: expected || null, p_notes: notes || null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/purchases/orders/${data as string}`);
  }

  return (
    <div className="mt-4 max-w-4xl space-y-4">
      <div className="grid gap-3 md:grid-cols-3">
        <Lbl label="Supplier"><select className={inputCls} value={sup} onChange={(e) => setSup(e.target.value)}>{suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.name}</option>)}</select></Lbl>
        <Lbl label="Deliver to warehouse"><select className={inputCls} value={wh} onChange={(e) => setWh(e.target.value)}>{warehouses.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.name}</option>)}</select></Lbl>
        <Lbl label="Expected by"><input type="date" className={inputCls} value={expected} onChange={(e) => setExpected(e.target.value)} /></Lbl>
      </div>
      <div className="space-y-2">
        {lines.map((l, i) => (
          <div key={i} className="grid grid-cols-12 items-end gap-2">
            <Lbl label={i === 0 ? "Product" : ""} className="col-span-12 md:col-span-5"><select className={inputCls} value={l.product_id} onChange={(e) => pick(i, e.target.value)}><option value="">Choose…</option>{products.map((p) => <option key={p.product_id} value={p.product_id}>{p.sku} · {p.name}</option>)}</select></Lbl>
            <Lbl label={i === 0 ? "Qty" : ""} className="col-span-3 md:col-span-2"><input className={inputCls} inputMode="numeric" value={l.quantity} onChange={(e) => setLine(i, { quantity: e.target.value })} /></Lbl>
            <Lbl label={i === 0 ? "Price" : ""} className="col-span-4 md:col-span-2"><input className={inputCls} inputMode="decimal" value={l.unit_price} onChange={(e) => setLine(i, { unit_price: e.target.value })} /></Lbl>
            <Lbl label={i === 0 ? "GST %" : ""} className="col-span-3 md:col-span-2"><select className={inputCls} value={l.gst_rate} onChange={(e) => setLine(i, { gst_rate: e.target.value })}>{RATES.map((r) => <option key={r}>{r}</option>)}</select></Lbl>
            <button type="button" className={`${smallBtn} col-span-2 md:col-span-1`} onClick={() => setLines(lines.filter((_, k) => k !== i))} disabled={lines.length === 1} aria-label="Remove line">✕</button>
          </div>
        ))}
        <button type="button" className={smallBtn} onClick={() => setLines([...lines, { product_id: "", quantity: "", unit_price: "", gst_rate: "5" }])}>+ Add line</button>
      </div>
      <Lbl label="Notes (optional)"><input className={inputCls} value={notes} onChange={(e) => setNotes(e.target.value)} /></Lbl>
      <p className="text-sm text-ink">Estimated total with GST: <span className="font-data font-medium">₹{total.toLocaleString("en-IN", { maximumFractionDigits: 2 })}</span></p>
      <button className={primaryBtn} onClick={save} disabled={busy}>{busy ? "Saving…" : "Create order"}</button>
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
