"use client";

import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { buildIndex, lookup, productsFromCatalog, type CatRow } from "@/lib/scan/catalog";
import { beep } from "@/lib/scan/feedback";
import { ScanBox, type ScanBoxHandle } from "./scan-box";
import { LinkCode } from "./link-code";

type Opt = { id: string; label: string };
type Line = { id: string; product_id: string; label: string; lot_tracked: boolean; lot: string; qty: number; note: string; code: string };
type Pending = { code: string; qty: number; lot: string };
type Draft = { lines: Line[]; warehouse: string; supplier: string; ref: string; reason: string; reasonNote: string; date: string };

const REASONS: [string, string][] = [
  ["direct_purchase", "Direct purchase (no purchase order)"],
  ["free_goods", "Free goods"],
  ["sample", "Sample"],
  ["supplier_replacement", "Supplier replacement"],
  ["other", "Other (write the reason)"],
];
const KEY = "ss-stockin-draft";
const uid = () => Math.random().toString(36).slice(2, 10);
const inputCls = "h-10 border border-line bg-surface px-2 text-sm text-ink";

function loadDraft(): Draft | null {
  try { const s = window.localStorage.getItem(KEY); return s ? (JSON.parse(s) as Draft) : null; } catch { return null; }
}

/** One text line from a paste or file → code, quantity, lot. A line with only a code counts as 1, so a raw list of scanned codes works. */
export function parseList(text: string): Pending[] {
  const out: Pending[] = [];
  // each line is split on tab, comma or semicolon (Excel pastes tabs; a CSV has commas), so mixed lists still work
  const rows = text.split(/\r?\n/).map((ln) => ln.split(/\t|,|;/).map((c) => c.trim().replace(/^"|"$/g, ""))).filter((r) => r.some((c) => c !== ""));
  rows.forEach((r, i) => {
    const code = (r[0] ?? "").trim();
    if (!code) return;
    const q = (r[1] ?? "").trim();
    const n = q === "" ? 1 : Number(q.replace(/,/g, ""));
    if (i === 0 && q !== "" && !Number.isFinite(n)) return; // header row such as "Barcode, Qty"
    if (!Number.isFinite(n) || n <= 0 || n !== Math.floor(n)) { out.push({ code, qty: NaN, lot: "" }); return; }
    out.push({ code, qty: n, lot: (r[2] ?? "").trim() });
  });
  return out;
}

export function StockIn(props: { catalog: CatRow[]; warehouses: Opt[]; suppliers: Opt[]; defaultWarehouse: string; onDone: () => void }) {
  const ready = useSyncExternalStore(() => () => {}, () => true, () => false);
  if (!ready) return <div className="border border-line bg-surface p-4 text-sm text-ink-muted">Loading the scanner…</div>;
  return <Inner {...props} />;
}

function Inner({ catalog, warehouses, suppliers, defaultWarehouse, onDone }: { catalog: CatRow[]; warehouses: Opt[]; suppliers: Opt[]; defaultWarehouse: string; onDone: () => void }) {
  const supabase = createClient();
  const today = new Date().toISOString().slice(0, 10);
  const draft = useMemo(() => loadDraft(), []);
  const [lines, setLines] = useState<Line[]>(draft?.lines ?? []);
  const [warehouse, setWarehouse] = useState(draft?.warehouse || defaultWarehouse || warehouses[0]?.id || "");
  const [supplier, setSupplier] = useState(draft?.supplier ?? "");
  const [ref, setRef] = useState(draft?.ref ?? "");
  const [reason, setReason] = useState(draft?.reason ?? "direct_purchase");
  const [reasonNote, setReasonNote] = useState(draft?.reasonNote ?? "");
  const [date, setDate] = useState(draft?.date ?? today);
  const [lot, setLot] = useState("");
  const [mult, setMult] = useState("1");
  const [pasteText, setPasteText] = useState("");
  const [unknown, setUnknown] = useState<Pending[]>([]);
  const [extraRows, setExtraRows] = useState<CatRow[]>([]);
  const [msg, setMsg] = useState<{ tone: "ok" | "warn" | "bad"; text: string } | null>(null);
  const [via, setVia] = useState<"scan" | "paste" | "upload">("scan");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const box = useRef<ScanBoxHandle>(null);
  const lotInput = useRef<HTMLInputElement>(null);
  const file = useRef<HTMLInputElement>(null);

  const allRows = useMemo(() => [...catalog, ...extraRows], [catalog, extraRows]);
  const idx = useMemo(() => buildIndex(allRows), [allRows]);
  const products = useMemo(() => productsFromCatalog(catalog), [catalog]);
  const dirty = lines.length > 0;
  const total = lines.reduce((s, l) => s + l.qty, 0);

  useEffect(() => {
    try {
      if (dirty) window.localStorage.setItem(KEY, JSON.stringify({ lines, warehouse, supplier, ref, reason, reasonNote, date } satisfies Draft));
      else window.localStorage.removeItem(KEY);
    } catch { /* storage blocked */ }
  }, [lines, warehouse, supplier, ref, reason, reasonNote, date, dirty]);
  useEffect(() => {
    if (!dirty) return;
    const h = (e: BeforeUnloadEvent) => { e.preventDefault(); };
    window.addEventListener("beforeunload", h);
    return () => window.removeEventListener("beforeunload", h);
  }, [dirty]);

  const say = (tone: "ok" | "warn" | "bad", text: string) => { beep(tone); setMsg({ tone, text }); };

  /** Adds quantity for a code; returns false if the code is unknown. Lines with the same product and lot are merged. */
  function add(code: string, qty: number, lotIn: string, silent = false, base: Line[] | null = null): { ok: boolean; next: Line[] } {
    const res = lookup(idx, code);
    const cur = base ?? lines;
    if (res.kind !== "one") {
      if (!silent) say("bad", res.kind === "many" ? `Code ${code} belongs to more than one product. Ask the office to fix the barcodes.` : `Unknown code ${code}`);
      return { ok: false, next: cur };
    }
    const h = res.hit;
    const n = qty * h.pack_qty;
    const lotUse = h.lot_tracked ? lotIn.trim() : "";
    if (h.lot_tracked && !lotUse && !silent) { say("warn", `${h.sku} needs a lot number. Type it in the Lot box, then scan again.`); lotInput.current?.focus(); return { ok: true, next: cur }; }
    const i = cur.findIndex((l) => l.product_id === h.product_id && l.lot === lotUse);
    const next = i >= 0
      ? cur.map((l, k) => (k === i ? { ...l, qty: l.qty + n } : l))
      : [...cur, { id: uid(), product_id: h.product_id, label: h.label, lot_tracked: h.lot_tracked, lot: lotUse, qty: n, note: "", code: code.trim() }];
    if (!base) setLines(next);
    if (!silent) say(h.status !== "active" ? "warn" : "ok", `${h.sku} +${n}${h.status !== "active" ? ` (this product is marked ${h.status})` : ""}`);
    return { ok: true, next };
  }

  function onScan(raw: string) {
    setDone(null); setErr(null); setVia("scan");
    const n = Math.max(1, Math.floor(Number(mult) || 1));
    const r = add(raw, n, lot);
    if (!r.ok) setUnknown((u) => (u.some((x) => x.code === raw.trim()) ? u : [...u, { code: raw.trim(), qty: n, lot }]));
  }

  function addList(text: string, source: "paste" | "upload") {
    setDone(null); setErr(null); setVia(source);
    const rows = parseList(text);
    if (!rows.length) { say("warn", "Nothing to add: the list is empty."); return; }
    let acc = lines; let ok = 0; let skipped = 0; const unk: Pending[] = [];
    for (const r of rows) {
      if (!Number.isFinite(r.qty)) { skipped += 1; continue; }
      const res = add(r.code, r.qty, r.lot || lot, true, acc);
      if (res.ok) { acc = res.next; ok += 1; } else unk.push(r);
    }
    setLines(acc);
    setUnknown((u) => [...u, ...unk.filter((x) => !u.some((y) => y.code === x.code))]);
    say(unk.length || skipped ? "warn" : "ok", `${ok} of ${rows.length} rows added${unk.length ? `, ${unk.length} unknown code(s) below` : ""}${skipped ? `, ${skipped} row(s) skipped (quantity must be a whole number)` : ""}.`);
    setPasteText("");
  }

  function linked(r: CatRow, pend: Pending) {
    const base = catalog.find((c) => c.product_id === r.product_id);
    const row = { ...(base ?? r), code: r.code, pack_qty: r.pack_qty, kind: r.kind };
    setExtraRows((l) => [...l, row]);
    setUnknown((u) => u.filter((x) => x.code !== pend.code));
    // count it right away with the freshly linked row
    const h = base ?? r;
    const n = pend.qty * r.pack_qty;
    const lotUse = h.lot_tracked ? (pend.lot || lot).trim() : "";
    setLines((cur) => {
      const i = cur.findIndex((l) => l.product_id === h.product_id && l.lot === lotUse);
      return i >= 0 ? cur.map((l, k) => (k === i ? { ...l, qty: l.qty + n } : l))
        : [...cur, { id: uid(), product_id: h.product_id, label: `${h.sku} · ${h.product_name}`, lot_tracked: h.lot_tracked, lot: lotUse, qty: n, note: "", code: pend.code }];
    });
    say("ok", `Linked ${pend.code} and counted ${n}`);
  }

  async function submit() {
    setErr(null);
    if (!warehouse) { setErr("Choose the warehouse."); return; }
    if (!lines.length) { setErr("Add at least one item."); return; }
    if (reason === "other" && !reasonNote.trim()) { setErr("Write the reason for this stock-in."); return; }
    const noLot = lines.find((l) => l.lot_tracked && !l.lot.trim());
    if (noLot) { setErr(`${noLot.label} needs a lot number.`); return; }
    if (lines.some((l) => !Number.isInteger(l.qty) || l.qty <= 0)) { setErr("Every quantity must be a whole number above zero."); return; }
    setBusy(true);
    const { error } = await supabase.rpc("stock_in_create", {
      p_warehouse: warehouse, p_supplier: supplier || null, p_received_on: date, p_ref: ref || null, p_reason: reason,
      p_reason_note: reasonNote || null, p_via: via,
      p_lines: lines.map((l) => ({ product_id: l.product_id, quantity: l.qty, lot_no: l.lot || null, code: l.code || null, note: l.note || null })),
      p_notes: null,
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setDone(`Stock-in saved: ${total} units across ${lines.length} line(s) added to stock.`);
    setLines([]); setUnknown([]); setMsg(null);
    try { window.localStorage.removeItem(KEY); } catch { /* ignore */ }
    onDone();
  }

  const tone = (t: "ok" | "warn" | "bad") => (t === "ok" ? "border-success bg-success-tint text-success" : t === "warn" ? "border-warning bg-warning-tint text-ink" : "border-danger bg-danger-tint text-danger");
  const lbl = "flex flex-col gap-1 text-xs text-ink-muted";

  return (
    <div className="space-y-4 border border-line bg-surface p-4">
      <div className="grid gap-3 md:grid-cols-3 lg:grid-cols-6">
        <label className={lbl}>Warehouse *<select className={inputCls} value={warehouse} onChange={(e) => setWarehouse(e.target.value)}>{warehouses.map((w) => <option key={w.id} value={w.id}>{w.label}</option>)}</select></label>
        <label className={lbl}>Received on<input type="date" max={today} className={inputCls} value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className={lbl}>Why is this stock coming in? *<select className={inputCls} value={reason} onChange={(e) => setReason(e.target.value)}>{REASONS.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
        <label className={lbl}>Supplier (optional)<select className={inputCls} value={supplier} onChange={(e) => setSupplier(e.target.value)}><option value="">None</option>{suppliers.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}</select></label>
        <label className={lbl}>Challan / delivery note<input className={inputCls} value={ref} onChange={(e) => setRef(e.target.value)} /></label>
        <label className={lbl}>Details {reason === "other" ? "*" : "(optional)"}<input className={inputCls} value={reasonNote} onChange={(e) => setReasonNote(e.target.value)} /></label>
      </div>

      <div className="flex flex-wrap items-end gap-3 text-xs text-ink-muted">
        <label className="flex flex-col gap-1">Lot / batch no. <span className="text-ink-faint">(lot-tracked items only)</span>
          <input ref={lotInput} className={inputCls} value={lot} onChange={(e) => setLot(e.target.value)} placeholder="e.g. L-2410-A" /></label>
        <label className="flex flex-col gap-1">Each scan adds<input className={`${inputCls} w-20`} inputMode="numeric" value={mult} onChange={(e) => setMult(e.target.value)} /></label>
      </div>

      <ScanBox ref={box} onScan={onScan} disabled={busy} />

      {msg ? <div className={`border-2 p-3 text-sm font-medium ${tone(msg.tone)}`} aria-live="polite">{msg.text}</div> : null}

      <details className="border border-line p-3">
        <summary className="cursor-pointer text-sm font-medium text-ink">Add many at once: paste a list or upload a file</summary>
        <div className="mt-3 space-y-2 text-sm">
          <p className="text-xs text-ink-muted">One item per line: <span className="font-data">barcode, quantity, lot</span> (quantity and lot are optional; a line with only a code counts as 1, so a plain list of scanned codes works). Paste straight from Excel, or upload a CSV (in Excel: Save As, CSV).</p>
          <textarea className="h-32 w-full border border-line bg-surface p-2 font-data text-xs text-ink" value={pasteText} onChange={(e) => setPasteText(e.target.value)} placeholder={"8900040000379, 24\n8900040000386, 12, L-2410-A\n8900040000393"} />
          <div className="flex flex-wrap items-center gap-3">
            <button type="button" disabled={!pasteText.trim()} onClick={() => addList(pasteText, "paste")} className="h-10 border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50">Add the pasted list</button>
            <input ref={file} type="file" accept=".csv,.txt,text/csv,text/plain" className="text-xs"
              onChange={async (e) => { const f = e.target.files?.[0]; if (f) addList(await f.text(), "upload"); if (file.current) file.current.value = ""; }} />
          </div>
        </div>
      </details>

      {unknown.map((u) => (
        <LinkCode key={u.code} code={u.code} products={products} onLinked={(r) => linked(r, u)} onCancel={() => setUnknown((l) => l.filter((x) => x.code !== u.code))} />
      ))}

      <div className="overflow-x-auto border border-line">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-2 font-medium">Product</th><th className="px-3 py-2 font-medium">Lot</th><th className="px-3 py-2 text-right font-medium">Quantity</th><th className="px-3 py-2 font-medium">Note</th><th /></tr></thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.id} className="border-b border-line/60">
                <td className="px-3 py-2 text-ink">{l.label}</td>
                <td className="px-3 py-2">{l.lot_tracked
                  ? <input className={`${inputCls} h-8 w-32 ${l.lot.trim() ? "" : "border-danger"}`} value={l.lot} placeholder="lot no." onChange={(e) => setLines((x) => x.map((y) => (y.id === l.id ? { ...y, lot: e.target.value } : y)))} />
                  : <span className="text-ink-faint">—</span>}</td>
                <td className="px-3 py-2 text-right"><input className={`${inputCls} h-8 w-24 text-right font-data`} inputMode="numeric" value={l.qty}
                  onChange={(e) => setLines((x) => x.map((y) => (y.id === l.id ? { ...y, qty: Math.max(0, Math.floor(Number(e.target.value) || 0)) } : y)))} /></td>
                <td className="px-3 py-2"><input className={`${inputCls} h-8 w-48`} value={l.note} onChange={(e) => setLines((x) => x.map((y) => (y.id === l.id ? { ...y, note: e.target.value } : y)))} /></td>
                <td className="px-3 py-2 text-right"><button type="button" className="text-xs text-danger underline" onClick={() => setLines((x) => x.filter((y) => y.id !== l.id))}>Remove</button></td>
              </tr>
            ))}
            {!lines.length ? <tr><td colSpan={5} className="px-3 py-6 text-center text-sm text-ink-muted">Nothing scanned yet.</td></tr> : null}
          </tbody>
          {lines.length ? <tfoot><tr className="bg-surface-sunken/60 text-sm font-semibold"><td className="px-3 py-2" colSpan={2}>Total ({lines.length} lines)</td><td className="px-3 py-2 text-right font-data">{total}</td><td colSpan={2} /></tr></tfoot> : null}
        </table>
      </div>

      <div className="flex flex-wrap items-center gap-3">
        <button type="button" disabled={busy || !dirty} onClick={submit} className="h-11 bg-accent px-5 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-60">{busy ? "Saving…" : "Add to stock"}</button>
        {dirty ? <button type="button" onClick={() => { if (confirm("Throw away everything scanned so far?")) { setLines([]); setUnknown([]); setMsg(null); } }} className="text-sm text-ink-muted hover:underline">Clear all</button> : null}
        <p className="text-xs text-ink-muted">Your list is kept on this device if you close the page. Every stock change is logged with who, when and the quantity before and after.</p>
      </div>
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
      {done ? <p className="text-sm text-success">{done}</p> : null}
    </div>
  );
}
