"use client";

import { useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { buildIndex, lookup, type CatRow } from "@/lib/scan/catalog";
import { beep } from "@/lib/scan/feedback";
import { ScanBox, type ScanBoxHandle } from "@/components/scan/scan-box";

type Row = { line_id: string; label: string; product_id: string; lot: string | null; sent: number; got: number | null };
const inputCls = "h-10 border border-line bg-surface px-2 text-sm text-ink";
const btn = "h-10 rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";
const primary = "h-10 rounded-lg bg-accent px-4 text-sm font-semibold text-white disabled:opacity-50";

export function TransferActions({ id, status, lines, catalog, canGrn, canDecide, isSender }: { id: string; status: string; lines: Row[]; catalog: CatRow[]; canGrn: boolean; canDecide: boolean; isSender: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const idx = useMemo(() => buildIndex(catalog), [catalog]);
  const box = useRef<ScanBoxHandle>(null);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<{ tone: "ok" | "warn" | "bad"; text: string } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  function onScan(raw: string) {
    const r = lookup(idx, raw);
    if (r.kind !== "one") { beep("bad"); setMsg({ tone: "bad", text: r.kind === "none" ? `Unknown code ${raw.trim()}` : "That code belongs to more than one product" }); return; }
    const h = r.hit;
    // fill the first line of this product that is not yet full
    const cand = lines.filter((l) => l.product_id === h.product_id);
    if (!cand.length) { beep("bad"); setMsg({ tone: "bad", text: `${h.sku} is NOT on this transfer. Set it aside.` }); return; }
    const target = cand.find((l) => (counts[l.line_id] ?? 0) + h.pack_qty <= l.sent);
    if (!target) { beep("warn"); setMsg({ tone: "warn", text: `${h.sku}: more than the ${cand.reduce((s, l) => s + l.sent, 0)} that were sent. Set the extra aside.` }); return; }
    setCounts((c) => ({ ...c, [target.line_id]: (c[target.line_id] ?? 0) + h.pack_qty }));
    beep("ok"); setMsg({ tone: "ok", text: `${h.sku} +${h.pack_qty} (${(counts[target.line_id] ?? 0) + h.pack_qty} of ${target.sent})` });
  }
  async function run(key: string, fn: string, args: Record<string, unknown>) {
    setBusy(key); setErr(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  const tone = (t: string) => (t === "ok" ? "border-success bg-success-tint text-success" : t === "warn" ? "border-warning bg-warning-tint text-ink" : "border-danger bg-danger-tint text-danger");
  const short = lines.some((l) => (counts[l.line_id] ?? 0) < l.sent);
  return (
    <div className="mt-6 space-y-4">
      {status === "in_transit" && canGrn ? (
        <div className="space-y-3 border border-line bg-surface p-4">
          <p className="text-sm font-semibold text-ink">Receive: scan each item that arrived</p>
          {isSender ? <p className="text-xs text-ink-muted">You sent this transfer, so someone at the receiving store has to receive it.</p> : null}
          <ScanBox ref={box} onScan={onScan} disabled={!!busy} />
          {msg ? <div className={`border-2 p-3 text-sm font-medium ${tone(msg.tone)}`} aria-live="polite">{msg.text}</div> : null}
          <table className="w-full text-left text-sm">
            <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-2 py-2 font-medium">Item</th><th className="px-2 py-2 text-right font-medium">Sent</th><th className="px-2 py-2 text-right font-medium">Arrived</th></tr></thead>
            <tbody>{lines.map((l) => (
              <tr key={l.line_id} className="border-b border-line/60"><td className="px-2 py-2">{l.label}{l.lot ? ` · lot ${l.lot}` : ""}</td><td className="px-2 py-2 text-right font-data">{l.sent}</td>
                <td className="px-2 py-2 text-right"><input className={`${inputCls} w-20 text-right`} inputMode="numeric" value={counts[l.line_id] ?? 0} onChange={(e) => setCounts({ ...counts, [l.line_id]: Math.min(l.sent, Math.max(0, Math.floor(Number(e.target.value) || 0))) })} /></td></tr>))}</tbody>
          </table>
          {short ? <input className={`${inputCls} w-full`} placeholder="Some stock is missing: what happened? (required)" value={note} onChange={(e) => setNote(e.target.value)} /> : null}
          <button className={primary} disabled={!!busy || isSender || (short && !note.trim())} onClick={() => run("recv", "transfer_receive", { p_id: id, p_note: note || null, p_lines: lines.map((l) => ({ line_id: l.line_id, received: counts[l.line_id] ?? 0 })) })}>{busy === "recv" ? "Saving…" : "Confirm received"}</button>
        </div>
      ) : null}
      {status === "received_short" && canDecide ? (
        <div className="space-y-2 border border-line bg-surface p-4">
          <p className="text-sm font-semibold text-ink">Settle the shortfall</p>
          <input className={`${inputCls} w-full`} placeholder="What did you find? (required)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="flex gap-2">
            <button className={primary} disabled={!!busy || !note.trim()} onClick={() => run("ret", "transfer_resolve", { p_id: id, p_action: "return", p_note: note })}>Missing goods are back at the sending store</button>
            <button className={btn} disabled={!!busy || !note.trim()} onClick={() => run("wo", "transfer_resolve", { p_id: id, p_action: "write_off", p_note: note })}>Write off the loss</button>
          </div>
        </div>
      ) : null}
      {status === "in_transit" && (isSender || canDecide) ? (
        <div className="flex items-end gap-2"><input className={`${inputCls} max-w-xs`} placeholder="Reason to cancel" value={note} onChange={(e) => setNote(e.target.value)} />
          <button className={btn} disabled={!!busy || !note.trim()} onClick={() => run("cancel", "transfer_cancel", { p_id: id, p_reason: note })}>Cancel transfer</button></div>
      ) : null}
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
