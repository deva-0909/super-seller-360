"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "../reconcile/types";
import type { Opt, ReviewLine } from "./review-table";

const field = "h-9 border border-line bg-surface px-2 text-xs text-ink";

export function SplitPanel({ line, ledgers, vendor, onDone }: { line: ReviewLine; ledgers: Opt[]; vendor: string | null; onDone: () => void }) {
  const supabase = createClient();
  const [rows, setRows] = useState<{ ledger: string; amount: string }[]>([{ ledger: "", amount: "" }, { ledger: "", amount: "" }]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const sum = rows.reduce((s, r) => s + (Number(r.amount) || 0), 0);
  const left = Math.round((line.amount - sum) * 100) / 100;
  const ready = Math.abs(left) < 0.005 && rows.every((r) => r.ledger && Number(r.amount) > 0);

  async function post() {
    if (busy || !ready) return;
    if (!window.confirm(`Book ${inr(line.amount)} split across ${rows.length} accounts? This posts an entry to the books.`)) return;
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("bank_review_accept_split", {
      p_txn: line.bank_txn_id, p_supplier: vendor, p_narration: null,
      p_splits: rows.map((r) => ({ ledger_id: r.ledger, amount: Number(r.amount) })),
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    onDone();
  }

  return (
    <div className="max-w-3xl">
      <p className="text-xs font-semibold text-ink">Split {inr(line.amount)} across accounts</p>
      <p className="mt-0.5 text-xs text-ink-muted">For example the amount before GST, plus Input CGST and Input SGST. The parts must add up to the bank amount.</p>
      <div className="mt-2 space-y-2">
        {rows.map((r, i) => (
          <div key={i} className="flex flex-wrap items-center gap-2">
            <select className={`${field} min-w-[14rem] flex-1`} aria-label="Account" value={r.ledger} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, ledger: e.target.value } : x)))}>
              <option value="">Choose account…</option>
              {ledgers.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
            </select>
            <input className={`${field} w-32`} inputMode="decimal" placeholder="Amount" aria-label="Amount" value={r.amount} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, amount: e.target.value } : x)))} />
            <button type="button" className="text-xs text-danger underline disabled:opacity-40" disabled={rows.length <= 2} onClick={() => setRows(rows.filter((_, j) => j !== i))}>Remove</button>
          </div>
        ))}
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-3">
        <button type="button" className="text-xs font-semibold text-accent underline" onClick={() => setRows([...rows, { ledger: "", amount: "" }])}>Add a part</button>
        <button type="button" className="text-xs font-semibold text-accent underline" disabled={left <= 0} onClick={() => { const i = rows.findIndex((r) => !r.amount); if (i >= 0) setRows(rows.map((x, j) => (j === i ? { ...x, amount: String(left) } : x))); }}>Put the rest in the next empty part</button>
        <span className={`text-xs ${Math.abs(left) < 0.005 ? "text-success" : "text-warning"}`}>{Math.abs(left) < 0.005 ? "Adds up." : `${inr(Math.abs(left))} ${left > 0 ? "left to place" : "too much"}`}</span>
      </div>
      <div className="mt-3 flex items-center gap-2">
        <button className="h-8 rounded-lg bg-accent px-3 text-xs font-semibold text-white hover:bg-accent-hover disabled:opacity-50" disabled={!ready || busy} onClick={post}>{busy ? "Booking…" : "Post split entry"}</button>
        {err ? <span role="alert" className="text-xs text-danger">{err}</span> : null}
      </div>
    </div>
  );
}
