"use client";

import { useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { buildIndex, lookup, type CatRow } from "@/lib/scan/catalog";
import { beep } from "@/lib/scan/feedback";
import { ScanBox, type ScanBoxHandle } from "@/components/scan/scan-box";

type W = { warehouse_id: string; name: string };
type Line = { key: string; product_id: string; label: string; lot: string; lot_tracked: boolean; qty: number };
const inputCls = "h-10 border border-line bg-surface px-2 text-sm text-ink";

export function TransferSend({ catalog, from, all }: { catalog: CatRow[]; from: W[]; all: W[] }) {
  const router = useRouter();
  const idx = useMemo(() => buildIndex(catalog), [catalog]);
  const box = useRef<ScanBoxHandle>(null);
  const [src, setSrc] = useState(from[0]?.warehouse_id ?? "");
  const [dst, setDst] = useState("");
  const [ref, setRef] = useState("");
  const [lot, setLot] = useState("");
  const [lines, setLines] = useState<Line[]>([]);
  const [msg, setMsg] = useState<{ tone: "ok" | "warn" | "bad"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  function say(tone: "ok" | "warn" | "bad", text: string) { beep(tone); setMsg({ tone, text }); }
  function onScan(raw: string) {
    setErr(null);
    const r = lookup(idx, raw);
    if (r.kind === "none") { say("bad", `Unknown code ${raw.trim()}. Link it on the Stock in screen first.`); return; }
    if (r.kind === "many") { say("bad", `Code ${raw.trim()} belongs to more than one product.`); return; }
    const h = r.hit;
    const lotUse = h.lot_tracked ? lot.trim() : "";
    if (h.lot_tracked && !lotUse) { say("warn", `${h.sku} needs a lot number. Type it in the Lot box, then scan again.`); return; }
    const key = `${h.product_id}|${lotUse}`;
    setLines((l) => l.some((x) => x.key === key) ? l.map((x) => (x.key === key ? { ...x, qty: x.qty + h.pack_qty } : x)) : [...l, { key, product_id: h.product_id, label: h.label, lot: lotUse, lot_tracked: h.lot_tracked, qty: h.pack_qty }]);
    say("ok", `${h.sku} +${h.pack_qty}`);
  }
  async function send() {
    setErr(null);
    if (!dst) { setErr("Choose the store it is going to."); return; }
    if (!lines.length) { setErr("Scan at least one item."); return; }
    setBusy(true);
    const { data, error } = await createClient().rpc("transfer_dispatch", { p_from: src, p_to: dst, p_ref: ref || null, p_lines: lines.filter((l) => l.qty > 0).map((l) => ({ product_id: l.product_id, quantity: l.qty, lot_no: l.lot || null })) });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/inventory/transfers/${data as string}`);
  }
  const tone = (t: string) => (t === "ok" ? "border-success bg-success-tint text-success" : t === "warn" ? "border-warning bg-warning-tint text-ink" : "border-danger bg-danger-tint text-danger");
  return (
    <div className="space-y-4 border border-line bg-surface p-4">
      <div className="flex flex-wrap items-end gap-3 text-xs text-ink-muted">
        <label className="flex flex-col gap-1">From store<select className={inputCls} value={src} onChange={(e) => setSrc(e.target.value)}>{from.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.name}</option>)}</select></label>
        <label className="flex flex-col gap-1">To store<select className={inputCls} value={dst} onChange={(e) => setDst(e.target.value)}><option value="">Choose…</option>{all.filter((w) => w.warehouse_id !== src).map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.name}</option>)}</select></label>
        <label className="flex flex-col gap-1">Gate pass / challan no.<input className={inputCls} value={ref} onChange={(e) => setRef(e.target.value)} /></label>
        <label className="flex flex-col gap-1">Lot no. (lot-tracked items)<input className={inputCls} value={lot} onChange={(e) => setLot(e.target.value)} /></label>
      </div>
      <ScanBox ref={box} onScan={onScan} disabled={busy} />
      {msg ? <div className={`border-2 p-3 text-sm font-medium ${tone(msg.tone)}`} aria-live="polite">{msg.text}</div> : null}
      <table className="w-full text-left text-sm">
        <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-2 py-2 font-medium">Item</th><th className="px-2 py-2 font-medium">Lot</th><th className="px-2 py-2 text-right font-medium">Qty</th><th /></tr></thead>
        <tbody>
          {lines.map((l) => (
            <tr key={l.key} className="border-b border-line/60">
              <td className="px-2 py-2">{l.label}</td><td className="px-2 py-2 text-ink-muted">{l.lot || "—"}</td>
              <td className="px-2 py-2 text-right"><input className={`${inputCls} w-20 text-right`} inputMode="numeric" value={l.qty} onChange={(e) => setLines(lines.map((x) => (x.key === l.key ? { ...x, qty: Math.max(0, Math.floor(Number(e.target.value) || 0)) } : x)))} /></td>
              <td className="px-2 py-2"><button type="button" className="text-xs text-accent hover:underline" onClick={() => setLines(lines.filter((x) => x.key !== l.key))}>Remove</button></td>
            </tr>
          ))}
          {!lines.length ? <tr><td colSpan={4} className="px-2 py-6 text-center text-ink-muted">Nothing scanned yet.</td></tr> : null}
        </tbody>
      </table>
      <div className="flex items-center gap-3">
        <button className="h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white disabled:opacity-50" disabled={busy || !lines.some((l) => l.qty > 0)} onClick={send}>{busy ? "Dispatching…" : `Dispatch ${lines.reduce((s, l) => s + l.qty, 0)} units`}</button>
        {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
      </div>
    </div>
  );
}
