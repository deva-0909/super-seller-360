"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { inputCls, smallBtn } from "@/components/purchases/bits";

export type Item = {
  voucher_id: string; voucher_no: string; entry_date: string; amount: number; created_by_name: string | null; narration: string | null; score: number;
  flags: { code: string; severity: string; message: string }[]; review_class: string; status: string; ack_reason: string | null; due_on: string | null;
  lines: { ledger: string; debit: number; credit: number }[]; proofs: number; source_label: string; mine: boolean;
};

function Card({ it, canReview, selected, onSelect }: { it: Item; canReview: boolean; selected?: boolean; onSelect?: (v: boolean) => void }) {
  const router = useRouter();
  const supabase = createClient();
  const [open, setOpen] = useState(it.review_class !== "sample");
  const [note, setNote] = useState("");
  const [rev, setRev] = useState(false);
  const [mode, setMode] = useState<"none" | "wrong" | "reject">("none");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function call(fn: () => PromiseLike<{ error: { message: string } | null }>) {
    setBusy(true); setErr(null);
    const { error } = await fn();
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  const held = it.status === "held";
  const canAct = canReview && !it.mine;
  const tone = it.score >= 60 ? "text-danger" : it.score >= 40 ? "text-warning" : "text-ink-muted";
  return (
    <div className="border border-line bg-surface">
      <div className="flex flex-wrap items-center gap-3 px-3 py-2">
        {onSelect && canAct ? <input type="checkbox" checked={selected} onChange={(e) => onSelect(e.target.checked)} aria-label="Select" /> : null}
        <span className="font-data text-xs text-ink">{it.voucher_no}</span>
        <span className="text-xs text-ink-muted">{it.entry_date} · {it.created_by_name ?? "?"} · {it.source_label}</span>
        <span className="ml-auto font-data text-sm text-ink">{inr(it.amount)}</span>
        <span className={`font-data text-xs ${tone}`}>risk {it.score}</span>
        <button className="text-xs text-accent hover:underline" onClick={() => setOpen(!open)}>{open ? "Hide" : "Show entry"}</button>
      </div>
      {it.narration ? <p className="px-3 pb-2 text-sm text-ink">{it.narration}</p> : null}
      {open ? (
        <div className="border-t border-line px-3 py-2 text-sm">
          <table className="w-full max-w-xl text-xs"><tbody>
            {it.lines.map((l, i) => (<tr key={i}><td className="py-0.5 pr-4 text-ink">{l.ledger}</td><td className="py-0.5 text-right font-data">{l.debit > 0 ? `Dr ${inr(l.debit)}` : ""}</td><td className="py-0.5 text-right font-data">{l.credit > 0 ? `Cr ${inr(l.credit)}` : ""}</td></tr>))}
          </tbody></table>
          <p className="mt-2 text-xs text-ink-muted">Proof attached: {it.proofs > 0 ? `yes (${it.proofs})` : "no"}</p>
          {it.flags.length ? <ul className="mt-2 space-y-1">{it.flags.map((f) => <li key={f.code} className={`text-xs ${f.severity === "warn" ? "text-warning" : "text-ink-muted"}`}>• {f.message}</li>)}</ul> : null}
          {it.ack_reason ? <p className="mt-2 text-xs text-ink">Operator&apos;s reason: <span className="italic">{it.ack_reason}</span></p> : null}
        </div>
      ) : null}
      <div className="border-t border-line px-3 py-2">
        {!canReview ? <span className="text-xs text-ink-muted">View only.</span> : it.mine ? <span className="text-xs text-ink-muted">You posted this, so a different manager must review it.</span> : mode === "none" ? (
          <div className="flex flex-wrap items-center gap-2">
            {held ? (
              <><button className={smallBtn} disabled={busy} onClick={() => call(() => supabase.rpc("journal_hold_decide", { p_voucher: it.voucher_id, p_approve: true, p_note: null }))}>Approve and post</button>
                <button className={smallBtn} disabled={busy} onClick={() => setMode("reject")}>Reject</button></>
            ) : (
              <><button className={smallBtn} disabled={busy} onClick={() => call(() => supabase.rpc("journal_review_set", { p_voucher: it.voucher_id, p_outcome: "ok", p_note: null, p_reverse: false }))}>Looks right</button>
                <button className={smallBtn} disabled={busy} onClick={() => setMode("wrong")}>Something is wrong</button></>
            )}
            {it.due_on ? <span className="text-xs text-ink-muted">Review by {it.due_on}</span> : null}
          </div>
        ) : (
          <div className="flex flex-wrap items-center gap-2">
            <input className={`${inputCls} !h-9 !w-72`} placeholder={mode === "reject" ? "Why is it rejected?" : "What is wrong?"} value={note} onChange={(e) => setNote(e.target.value)} />
            {mode === "wrong" && (it.source_label.includes("journal")) ? <label className="flex items-center gap-1 text-xs text-ink"><input type="checkbox" checked={rev} onChange={(e) => setRev(e.target.checked)} />Also reverse the entry</label> : null}
            <button className={smallBtn} disabled={busy} onClick={() => call(() => mode === "reject" ? supabase.rpc("journal_hold_decide", { p_voucher: it.voucher_id, p_approve: false, p_note: note }) : supabase.rpc("journal_review_set", { p_voucher: it.voucher_id, p_outcome: "wrong", p_note: note, p_reverse: rev }))}>Save</button>
            <button className="text-xs text-ink-muted hover:underline" onClick={() => setMode("none")}>Cancel</button>
          </div>
        )}
        {err ? <p className="mt-1 text-xs text-danger">{err}</p> : null}
      </div>
    </div>
  );
}

export function ReviewList({ held, must, sample, canReview }: { held: Item[]; must: Item[]; sample: Item[]; canReview: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const pick = (id: string, on: boolean) => setSel((s) => { const n = new Set(s); if (on) n.add(id); else n.delete(id); return n; });
  async function bulk() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("journal_review_bulk_ok", { p_vouchers: [...sel] });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setSel(new Set()); router.refresh();
  }
  const sec = (title: string, hint: string, list: Item[], extra?: React.ReactNode, selectable = false) => (
    <section className="mt-6">
      <div className="flex flex-wrap items-center justify-between gap-2"><div><h2 className="text-sm font-semibold text-ink">{title} ({list.length})</h2><p className="text-xs text-ink-muted">{hint}</p></div>{extra}</div>
      <div className="mt-2 space-y-2">
        {list.map((it) => <Card key={it.voucher_id} it={it} canReview={canReview} selected={sel.has(it.voucher_id)} onSelect={selectable ? (v) => pick(it.voucher_id, v) : undefined} />)}
        {list.length === 0 ? <p className="border border-line bg-surface p-3 text-sm text-ink-muted">Nothing here.</p> : null}
      </div>
    </section>
  );
  return (
    <>
      {sec("Waiting for approval", "Saved but not in the books. Posting needs a manager other than the person who entered it.", held)}
      {sec("Risky entries to review", "Highest risk first. These are already posted; mark them right or wrong.", must)}
      {sec("Sample to review", "A limited random sample, with extra weight on new operators and people with errors. Tick the ones that look fine and clear them together.", sample,
        canReview && sample.length ? <div className="flex items-center gap-2">{err ? <span className="text-xs text-danger">{err}</span> : null}<button className={smallBtn} disabled={busy || sel.size === 0} onClick={bulk}>Mark {sel.size} selected as fine</button></div> : null, true)}
    </>
  );
}
