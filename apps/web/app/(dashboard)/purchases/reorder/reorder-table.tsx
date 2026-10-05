"use client";

import { Fragment, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Row = { product_id: string; sku: string; name: string; on_hand: number; reserved: number; on_order: number; sold_per_day: number; days_cover: number | null; needs_reorder: boolean; suggested_qty: number; reorder_level: number | null; lead_time_days: number | null; preferred_supplier_id: string | null };

export function ReorderTable({ rows, suppliers, warehouses, canWrite }: { rows: Row[]; suppliers: { supplier_id: string; name: string }[]; warehouses: { warehouse_id: string; name: string }[]; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [all, setAll] = useState(false);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [sup, setSup] = useState(suppliers[0]?.supplier_id ?? "");
  const [wh, setWh] = useState(warehouses[0]?.warehouse_id ?? "");
  const [edit, setEdit] = useState<string | null>(null);
  const [f, setF] = useState({ level: "", qty: "", lead: "", supplier: "" });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const shown = rows.filter((r) => all || r.needs_reorder);

  async function create() {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("po_from_reorder", { p_supplier: sup, p_warehouse: wh, p_products: [...sel] });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/purchases/orders/${data as string}`);
  }
  async function saveRule(r: Row) {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("po_set_reorder", { p_product: r.product_id, p_level: f.level === "" ? null : Number(f.level), p_qty: f.qty === "" ? null : Number(f.qty), p_lead: f.lead === "" ? null : Number(f.lead), p_supplier: f.supplier || null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setEdit(null); router.refresh();
  }

  return (
    <div className="mt-4">
      <label className="flex items-center gap-2 text-sm text-ink"><input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} /> Show every product, not only those running low</label>
      {canWrite && sel.size > 0 ? (
        <div className="mt-3 flex flex-wrap items-end gap-2 border border-line bg-surface p-3">
          <select className={`${inputCls} w-56`} value={sup} onChange={(e) => setSup(e.target.value)}>{suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.name}</option>)}</select>
          <select className={`${inputCls} w-44`} value={wh} onChange={(e) => setWh(e.target.value)}>{warehouses.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.name}</option>)}</select>
          <button className={primaryBtn} disabled={busy} onClick={create}>Create order for {sel.size} product{sel.size === 1 ? "" : "s"}</button>
        </div>
      ) : null}
      {err ? <p role="alert" className="mt-2 text-sm text-danger">{err}</p> : null}
      <div className="mt-3 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3" /><th className="px-3 py-3 font-medium">Product</th><th className="px-3 py-3 text-right font-medium">In stock</th><th className="px-3 py-3 text-right font-medium">Promised</th><th className="px-3 py-3 text-right font-medium">On order</th><th className="px-3 py-3 text-right font-medium">Sold/day</th><th className="px-3 py-3 text-right font-medium">Days left</th><th className="px-3 py-3 text-right font-medium">Suggest</th><th className="px-3 py-3" /></tr></thead>
          <tbody>
            {shown.map((r, i) => (
              <Fragment key={r.product_id}>
                <tr className={r.needs_reorder ? "bg-warning-tint/30" : i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                  <td className="px-3 py-3">{canWrite && r.suggested_qty > 0 ? <input type="checkbox" aria-label={`Select ${r.sku}`} checked={sel.has(r.product_id)} onChange={(e) => { const n = new Set(sel); if (e.target.checked) n.add(r.product_id); else n.delete(r.product_id); setSel(n); }} /> : null}</td>
                  <td className="px-3 py-3 text-ink">{r.sku} <span className="text-ink-muted">· {r.name}</span></td>
                  <td className="px-3 py-3 text-right font-data">{r.on_hand}</td><td className="px-3 py-3 text-right font-data">{r.reserved}</td><td className="px-3 py-3 text-right font-data">{r.on_order}</td>
                  <td className="px-3 py-3 text-right font-data">{r.sold_per_day}</td><td className="px-3 py-3 text-right font-data">{r.days_cover ?? "—"}</td><td className="px-3 py-3 text-right font-data font-medium">{r.suggested_qty}</td>
                  <td className="px-3 py-3 text-right">{canWrite ? <button className="text-xs text-accent hover:underline" onClick={() => { setEdit(edit === r.product_id ? null : r.product_id); setF({ level: r.reorder_level == null ? "" : String(r.reorder_level), qty: "", lead: r.lead_time_days == null ? "" : String(r.lead_time_days), supplier: r.preferred_supplier_id ?? "" }); }}>Rules</button> : null}</td>
                </tr>
                {edit === r.product_id ? (
                  <tr><td colSpan={9} className="bg-surface-sunken/50 px-3 py-3">
                    <div className="flex flex-wrap items-end gap-2">
                      <label className="text-xs text-ink-muted">Re-order when stock falls to<br /><input className={`${inputCls} w-28`} value={f.level} onChange={(e) => setF({ ...f, level: e.target.value })} /></label>
                      <label className="text-xs text-ink-muted">Always order<br /><input className={`${inputCls} w-28`} placeholder="auto" value={f.qty} onChange={(e) => setF({ ...f, qty: e.target.value })} /></label>
                      <label className="text-xs text-ink-muted">Supplier lead time (days)<br /><input className={`${inputCls} w-28`} value={f.lead} onChange={(e) => setF({ ...f, lead: e.target.value })} /></label>
                      <label className="text-xs text-ink-muted">Usual supplier<br /><select className={`${inputCls} w-48`} value={f.supplier} onChange={(e) => setF({ ...f, supplier: e.target.value })}><option value="">None</option>{suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.name}</option>)}</select></label>
                      <button className={smallBtn} disabled={busy} onClick={() => saveRule(r)}>Save</button>
                    </div>
                  </td></tr>
                ) : null}
              </Fragment>
            ))}
            {shown.length === 0 ? <tr><td colSpan={9} className="px-3 py-6 text-ink-muted">Nothing is running low. Set re-order levels or lead times on products to get suggestions.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
