"use client";

import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { buildIndex, lookup, productsFromCatalog, type CatRow } from "@/lib/scan/catalog";
import { beep } from "@/lib/scan/feedback";
import { ScanBox, type ScanBoxHandle } from "./scan-box";
import { LinkCode } from "./link-code";
import { Proofs } from "@/components/ui/proofs";
import { linkProofs, type Proof } from "@/lib/attachments";

export type RecvLine = { po_line_id: string; product_id: string; line_no: number; sku: string; name: string; quantity: number; received_qty: number; rejected_qty: number; lot_tracked: boolean };

type Entry = { id: string; po_line_id: string; lot: string; good: number; bad: number };
type Extra = { id: string; product_id: string; label: string; lot: string; lot_tracked: boolean; qty: number; note: string };
type Hist = { kind: "entry" | "extra"; id: string; field: "good" | "bad" | "qty"; n: number };
type Log = { n: number; tone: "ok" | "warn" | "bad"; text: string };
type Draft = { entries: Entry[]; extras: Extra[]; challan: string; recvDate: string; lot: string };

const REASONS = ["Supplier sent extra", "Substituted for an ordered item", "Free goods / sample", "Wrong item delivered", "Other (write below)"];
const draftKey = (po: string) => `ss-grn-draft-${po}`;
const uid = () => Math.random().toString(36).slice(2, 10);
const inputCls = "h-10 border border-line bg-surface px-2 text-sm text-ink";

function loadDraft(po: string): Draft | null {
  try { const s = window.localStorage.getItem(draftKey(po)); return s ? (JSON.parse(s) as Draft) : null; } catch { return null; }
}

export function ReceiveScan(props: { poId: string; lines: RecvLine[]; catalog: CatRow[]; onDone: () => void }) {
  // the draft lives in this browser, so the screen draws only after it is on the client (no server/browser mismatch)
  const ready = useSyncExternalStore(() => () => {}, () => true, () => false);
  if (!ready) return <div className="border border-line bg-surface p-4 text-sm text-ink-muted">Loading the scanner…</div>;
  return <Inner {...props} />;
}

function Inner({ poId, lines, catalog, onDone }: { poId: string; lines: RecvLine[]; catalog: CatRow[]; onDone: () => void }) {
  const supabase = createClient();
  const today = new Date().toISOString().slice(0, 10);
  const draft = useMemo(() => loadDraft(poId), [poId]);
  const [entries, setEntries] = useState<Entry[]>(draft?.entries ?? []);
  const [extras, setExtras] = useState<Extra[]>(draft?.extras ?? []);
  const [challan, setChallan] = useState(draft?.challan ?? "");
  const [recvDate, setRecvDate] = useState(draft?.recvDate ?? today);
  const [lot, setLot] = useState(draft?.lot ?? "");
  const [damageNote, setDamageNote] = useState("");
  const [challanPics, setChallanPics] = useState<Proof[]>([]);
  const [mode, setMode] = useState<"good" | "bad">("good");
  const [mult, setMult] = useState("1");
  const [hist, setHist] = useState<Hist[]>([]);
  const [log, setLog] = useState<Log[]>([]);
  const [unknown, setUnknown] = useState<string | null>(null);
  const [extraRows, setExtraRows] = useState<CatRow[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const box = useRef<ScanBoxHandle>(null);
  const lotInput = useRef<HTMLInputElement>(null);
  const seq = useRef(0);

  const allRows = useMemo(() => [...catalog, ...extraRows], [catalog, extraRows]);
  const idx = useMemo(() => buildIndex(allRows), [allRows]);
  const products = useMemo(() => productsFromCatalog(catalog), [catalog]);
  const dirty = entries.some((e) => e.good + e.bad > 0) || extras.length > 0;

  useEffect(() => {
    try {
      if (dirty) window.localStorage.setItem(draftKey(poId), JSON.stringify({ entries, extras, challan, recvDate, lot } satisfies Draft));
      else window.localStorage.removeItem(draftKey(poId));
    } catch { /* storage blocked: scans are still kept on screen */ }
  }, [entries, extras, challan, recvDate, lot, dirty, poId]);
  useEffect(() => {
    if (!dirty) return;
    const h = (e: BeforeUnloadEvent) => { e.preventDefault(); };
    window.addEventListener("beforeunload", h);
    return () => window.removeEventListener("beforeunload", h);
  }, [dirty]);

  const say = (tone: Log["tone"], text: string) => { beep(tone); setLog((l) => [{ n: ++seq.current, tone, text }, ...l].slice(0, 8)); };
  const scannedFor = (poLine: string, list = entries) => list.filter((e) => e.po_line_id === poLine).reduce((s, e) => s + e.good + e.bad, 0);

  function onScan(raw: string) {
    setDone(null); setErr(null);
    const res = lookup(idx, raw);
    if (res.kind === "none") { setUnknown(raw.trim()); say("bad", `Unknown code ${raw.trim()}: link it to a product below`); return; }
    if (res.kind === "many") { say("bad", `Code ${raw.trim()} belongs to more than one product. Ask the office to fix the barcodes.`); return; }
    const hit = res.hit;
    const n = Math.max(1, Math.floor(Number(mult) || 1)) * hit.pack_qty;
    const warnInactive = hit.status !== "active" ? " (this product is marked " + hit.status + ")" : "";
    const lotUse = hit.lot_tracked ? lot.trim() : "";
    if (hit.lot_tracked && !lotUse) { say("warn", `${hit.sku} needs a lot number. Type it in the Lot box, then scan again.`); lotInput.current?.focus(); return; }

    const line = lines.find((l) => l.product_id === hit.product_id);
    if (line) {
      const already = line.received_qty + line.rejected_qty;
      const total = already + scannedFor(line.po_line_id) + n;
      if (total > line.quantity * 1.1) { say("bad", `${hit.sku}: that would be ${total} against ${line.quantity} ordered. More than 10% over the order is not allowed.`); return; }
      const id = entries.find((e) => e.po_line_id === line.po_line_id && e.lot === lotUse)?.id ?? uid();
      setEntries((list) => list.some((e) => e.id === id)
        ? list.map((e) => (e.id === id ? { ...e, [mode]: e[mode] + n } : e))
        : [...list, { id, po_line_id: line.po_line_id, lot: lotUse, good: mode === "good" ? n : 0, bad: mode === "bad" ? n : 0 }]);
      setHist((h) => [...h, { kind: "entry", id, field: mode, n }]);
      say(total > line.quantity ? "warn" : "ok", `${hit.sku} +${n} ${mode === "good" ? "good" : "damaged"} (${total} of ${line.quantity})${total > line.quantity ? " over the order, within 10%" : ""}${warnInactive}`);
    } else {
      const id = extras.find((x) => x.product_id === hit.product_id && x.lot === lotUse)?.id ?? uid();
      setExtras((list) => list.some((x) => x.id === id)
        ? list.map((x) => (x.id === id ? { ...x, qty: x.qty + n } : x))
        : [...list, { id, product_id: hit.product_id, label: hit.label, lot: lotUse, lot_tracked: hit.lot_tracked, qty: n, note: "" }]);
      setHist((h) => [...h, { kind: "extra", id, field: "qty", n }]);
      say("warn", `${hit.sku} is NOT on this order. Added to "Not on the order": give a reason below.${warnInactive}`);
    }
  }

  function undo() {
    const h = hist[hist.length - 1];
    if (!h) return;
    setHist((x) => x.slice(0, -1));
    if (h.kind === "entry") setEntries((l) => l.map((e) => (e.id === h.id ? { ...e, [h.field]: Math.max(0, e[h.field as "good" | "bad"] - h.n) } : e)));
    else setExtras((l) => l.flatMap((x) => (x.id !== h.id ? [x] : x.qty - h.n > 0 ? [{ ...x, qty: x.qty - h.n }] : [])));
    say("warn", "Last scan taken back");
    box.current?.focus();
  }

  function linked(r: CatRow) {
    const base = catalog.find((c) => c.product_id === r.product_id);
    setExtraRows((l) => [...l, { ...(base ?? r), code: r.code, pack_qty: r.pack_qty, kind: r.kind }]);
    const code = unknown;
    setUnknown(null);
    if (code) setTimeout(() => onScanRef.current(code), 60);
  }
  const onScanRef = useRef(onScan);
  useEffect(() => { onScanRef.current = onScan; });

  async function submit() {
    setErr(null);
    const lineEntries = entries.filter((e) => e.good + e.bad > 0);
    if (!lineEntries.length && !extras.length) { setErr("Scan or enter at least one item first."); return; }
    const noReason = extras.find((x) => !x.note.trim());
    if (noReason) { setErr(`Say why ${noReason.label} is not on the order (Not on the order, Reason).`); return; }
    const noLot = extras.find((x) => x.lot_tracked && !x.lot.trim());
    if (noLot) { setErr(`${noLot.label} needs a lot number.`); return; }
    const bad = lineEntries.reduce((t, e) => t + e.bad, 0);
    if (lineEntries.length && !challan.trim()) { setErr("Enter the supplier's challan / delivery note number."); return; }
    if (lineEntries.length && !challanPics.length) { setErr("Attach a photo of the supplier's challan (Challan photo, below)."); return; }
    if (bad > 0 && !damageNote.trim()) { setErr("Some goods are damaged: write what was wrong with them."); return; }
    setBusy(true);
    const { data, error } = await supabase.rpc("grn_create_scanned", {
      p_po: poId, p_received_on: recvDate, p_challan: challan || null,
      p_lines: lineEntries.map((e) => ({ po_line_id: e.po_line_id, accepted: e.good, rejected: e.bad, lot_no: e.lot || null })),
      p_extras: extras.map((x) => ({ product_id: x.product_id, quantity: x.qty, lot_no: x.lot || null, note: x.note })),
      p_notes: damageNote.trim() || null,
    });
    if (!error) {
      const g = (data as { grn_id: string | null }).grn_id;
      if (g && challanPics.length) { try { await linkProofs(challanPics.map((x) => x.attachment_id), "goods_receipt", g); } catch { /* receipt is saved; photo can be added from the order page */ } }
    }
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    const r = data as { grn_id: string | null; stock_in_id: string | null };
    setEntries([]); setExtras([]); setHist([]); setLog([]); setChallanPics([]); setDamageNote(""); setChallan("");
    try { window.localStorage.removeItem(draftKey(poId)); } catch { /* ignore */ }
    setDone(`Receipt saved${r.grn_id ? " against the order" : ""}${r.stock_in_id ? `${r.grn_id ? " and" : ""} ${extras.length} off-order line(s) added to stock` : ""}.`);
    onDone();
  }

  const totalGood = entries.reduce((s, e) => s + e.good, 0);
  const totalBad = entries.reduce((s, e) => s + e.bad, 0);
  const extraQty = extras.reduce((s, x) => s + x.qty, 0);
  const latest = log[0];
  const tone = (t: Log["tone"]) => (t === "ok" ? "border-success bg-success-tint text-success" : t === "warn" ? "border-warning bg-warning-tint text-ink" : "border-danger bg-danger-tint text-danger");

  return (
    <div className="space-y-4 border border-line bg-surface p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-semibold text-ink">Receive goods: scan each item</p>
        <p className="text-xs text-ink-muted">{totalGood} good · {totalBad} damaged · {extraQty} not on order</p>
      </div>

      <div className="flex flex-wrap items-end gap-3 text-xs text-ink-muted">
        <label className="flex flex-col gap-1">Received on<input type="date" max={today} className={inputCls} value={recvDate} onChange={(e) => setRecvDate(e.target.value)} /></label>
        <label className="flex flex-col gap-1">Supplier challan no. (required)<input className={inputCls} value={challan} onChange={(e) => setChallan(e.target.value)} /></label>
        <label className="flex flex-col gap-1">Lot / batch no. <span className="text-ink-faint">(lot-tracked items only)</span>
          <input ref={lotInput} className={inputCls} value={lot} onChange={(e) => setLot(e.target.value)} placeholder="e.g. L-2410-A" />
        </label>
        <label className="flex flex-col gap-1">Each scan adds<input className={`${inputCls} w-20`} inputMode="numeric" value={mult} onChange={(e) => setMult(e.target.value)} /></label>
        <div className="flex flex-col gap-1">Scanning as
          <div className="flex border border-line text-sm">
            <button type="button" onClick={() => { setMode("good"); box.current?.focus(); }} className={`h-10 px-3 ${mode === "good" ? "bg-success text-white" : "bg-surface text-ink"}`}>Good</button>
            <button type="button" onClick={() => { setMode("bad"); box.current?.focus(); }} className={`h-10 px-3 ${mode === "bad" ? "bg-danger text-white" : "bg-surface text-ink"}`}>Damaged</button>
          </div>
        </div>
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        <Proofs entityType="goods_receipt" pending={challanPics} onPending={setChallanPics} kind="challan" label="Challan photo (required)" hint="Photograph the supplier's challan / delivery note." />
        {totalBad > 0 ? (
          <label className="flex flex-col gap-1 text-xs text-ink-muted">What was wrong with the damaged goods? (required)
            <input className={`${inputCls} w-full`} value={damageNote} onChange={(e) => setDamageNote(e.target.value)} placeholder="e.g. torn packs, wrong size labels" />
          </label>
        ) : null}
      </div>

      <ScanBox ref={box} onScan={onScan} disabled={busy} />

      {unknown ? <LinkCode code={unknown} products={products} onLinked={linked} onCancel={() => { setUnknown(null); box.current?.focus(); }} /> : null}

      {latest ? (
        <div className={`flex items-center justify-between gap-3 border-2 p-3 text-sm font-medium ${tone(latest.tone)}`} aria-live="polite">
          <span>{latest.text}</span>
          {hist.length ? <button type="button" onClick={undo} className="shrink-0 border border-current px-2 py-1 text-xs">Undo last scan</button> : null}
        </div>
      ) : null}

      <div className="overflow-x-auto border border-line">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-3 py-2 font-medium">Product on the order</th><th className="px-3 py-2 text-right font-medium">Ordered</th><th className="px-3 py-2 text-right font-medium">Already in</th>
            <th className="px-3 py-2 font-medium">Lot</th><th className="px-3 py-2 text-right font-medium">Good now</th><th className="px-3 py-2 text-right font-medium">Damaged now</th>
          </tr></thead>
          <tbody>
            {lines.map((l) => {
              const rows = entries.filter((e) => e.po_line_id === l.po_line_id);
              const got = scannedFor(l.po_line_id);
              const left = Math.max(l.quantity - l.received_qty - l.rejected_qty - got, 0);
              return (
                <FragmentRows key={l.po_line_id} l={l} rows={rows} left={left}
                  set={(id, f, v) => setEntries((list) => list.map((e) => (e.id === id ? { ...e, [f]: Math.max(0, Math.floor(Number(v) || 0)) } : e)))}
                  addLot={() => setEntries((list) => [...list, { id: uid(), po_line_id: l.po_line_id, lot: lot.trim(), good: 0, bad: 0 }])} />
              );
            })}
          </tbody>
        </table>
      </div>

      {extras.length ? (
        <div className="space-y-2 border-2 border-warning p-3">
          <p className="text-sm font-semibold text-ink">Not on the order: each needs a reason</p>
          {extras.map((x) => (
            <div key={x.id} className="grid grid-cols-12 items-end gap-2 text-sm">
              <span className="col-span-12 md:col-span-4 text-ink">{x.label}{x.lot ? <span className="text-ink-muted"> · lot {x.lot}</span> : null}</span>
              <input className={`${inputCls} col-span-3 md:col-span-1`} inputMode="numeric" value={x.qty} aria-label="Quantity"
                onChange={(e) => setExtras((l) => l.map((y) => (y.id === x.id ? { ...y, qty: Math.max(0, Math.floor(Number(e.target.value) || 0)) } : y)))} />
              <select className={`${inputCls} col-span-9 md:col-span-3`} value={REASONS.includes(x.note) ? x.note : x.note ? REASONS[4] : ""} aria-label="Reason"
                onChange={(e) => setExtras((l) => l.map((y) => (y.id === x.id ? { ...y, note: e.target.value === REASONS[4] ? "Other: " : e.target.value } : y)))}>
                <option value="">Choose a reason…</option>{REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
              </select>
              <input className={`${inputCls} col-span-9 md:col-span-3`} placeholder="Details (optional)" value={REASONS.includes(x.note) ? "" : x.note}
                onChange={(e) => setExtras((l) => l.map((y) => (y.id === x.id ? { ...y, note: e.target.value } : y)))} />
              <button type="button" className="col-span-3 md:col-span-1 h-10 text-xs text-danger underline" onClick={() => setExtras((l) => l.filter((y) => y.id !== x.id))}>Remove</button>
            </div>
          ))}
        </div>
      ) : null}

      <div className="flex flex-wrap items-center gap-3">
        <button type="button" disabled={busy || !dirty} onClick={submit} className="h-11 bg-accent px-5 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-60">
          {busy ? "Saving…" : "Save receipt"}
        </button>
        {dirty ? <button type="button" onClick={() => { if (confirm("Throw away everything scanned so far?")) { setEntries([]); setExtras([]); setHist([]); setLog([]); setChallanPics([]); setDamageNote(""); setChallan(""); } }} className="text-sm text-ink-muted hover:underline">Clear all</button> : null}
        <p className="text-xs text-ink-muted">Only the good quantity is added to stock. Up to 10% over the ordered quantity is accepted. Your scans are kept on this device if you close the page.</p>
      </div>
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
      {done ? <p className="text-sm text-success">{done}</p> : null}
    </div>
  );
}

function FragmentRows({ l, rows, left, set, addLot }: {
  l: RecvLine; rows: Entry[]; left: number;
  set: (id: string, f: "good" | "bad", v: string) => void; addLot: () => void;
}) {
  const sum = rows.reduce((s, e) => s + e.good + e.bad, 0);
  const full = left === 0 && sum + l.received_qty + l.rejected_qty >= l.quantity;
  return (
    <>
      <tr className={`border-b border-line/60 ${sum > 0 ? "bg-success-tint/40" : ""}`}>
        <td className="px-3 py-2 text-ink">{l.sku} <span className="text-ink-muted">· {l.name}</span>{l.lot_tracked ? <span className="ml-2 text-xs text-ink-muted">lot-tracked</span> : null}
          <span className="ml-2 text-xs text-ink-muted">{full ? "complete" : `${left} still to come`}</span></td>
        <td className="px-3 py-2 text-right font-data">{l.quantity}</td>
        <td className="px-3 py-2 text-right font-data text-ink-muted">{l.received_qty + l.rejected_qty}</td>
        <td className="px-3 py-2" colSpan={3}>{rows.length === 0 ? <span className="text-xs text-ink-faint">nothing scanned yet</span> : null}
          {l.lot_tracked ? <button type="button" onClick={addLot} className="text-xs text-accent hover:underline">+ add a lot row</button> : null}</td>
      </tr>
      {rows.map((e) => (
        <tr key={e.id} className="border-b border-line/60">
          <td className="px-3 py-1 pl-8 text-xs text-ink-muted" colSpan={3}>this receipt</td>
          <td className="px-3 py-1 font-data text-xs">{e.lot || "—"}</td>
          <td className="px-3 py-1 text-right"><input className={`${inputCls} h-8 w-20 text-right font-data`} inputMode="numeric" value={e.good} onChange={(ev) => set(e.id, "good", ev.target.value)} aria-label={`Good ${l.sku}`} /></td>
          <td className="px-3 py-1 text-right"><input className={`${inputCls} h-8 w-20 text-right font-data`} inputMode="numeric" value={e.bad} onChange={(ev) => set(e.id, "bad", ev.target.value)} aria-label={`Damaged ${l.sku}`} /></td>
        </tr>
      ))}
    </>
  );
}
