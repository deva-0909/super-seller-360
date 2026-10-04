"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { EXCLUDE_REASONS, dateFmt, inr, type ReconLine } from "./types";

type Cand = { voucher_line_id: string; voucher_no: string; voucher_date: string; amount: number; narration: string | null; source_type: string | null; day_gap: number };
type LedgerOpt = { ledger_id: string; name: string; group: string };

const small = "h-8 rounded-lg border border-line bg-surface px-3 text-xs font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";
const primary = "h-8 rounded-lg bg-accent px-3 text-xs font-semibold text-white hover:bg-accent-hover disabled:opacity-50";

export function LineActions({ line, ledgers, canWrite }: { line: ReconLine; ledgers: LedgerOpt[]; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [panel, setPanel] = useState<null | "match" | "exclude" | "book">(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [cands, setCands] = useState<Cand[] | null>(null);
  const [picked, setPicked] = useState<string[]>([]);
  const [allowDiff, setAllowDiff] = useState(false);
  const [note, setNote] = useState("");
  const [reason, setReason] = useState("duplicate_import");
  const [reverse, setReverse] = useState(false);
  const [ledger, setLedger] = useState("");

  const ruleBooked = line.matches.some((m) => m.method === "rule_booked");

  async function call(fn: string, args: Record<string, unknown>, after?: () => void) {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc(fn, args);
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    after?.();
    setPanel(null);
    router.refresh();
  }

  async function openMatch() {
    setPanel("match"); setErr(null); setPicked([]);
    if (!cands) {
      const { data, error } = await supabase.rpc("bank_recon_candidates_for_txn", { p_txn: line.bank_txn_id, p_window: 45 });
      if (error) setErr(friendlyError(error.message)); else setCands((data ?? []) as Cand[]);
    }
  }

  if (!canWrite) return null;
  const sum = (cands ?? []).filter((c) => picked.includes(c.voucher_line_id)).reduce((s, c) => s + Number(c.amount), 0);
  const diff = Number(line.amount) - sum;

  return (
    <div className="mt-2">
      <div className="flex flex-wrap items-center gap-2">
        {line.suggestions.map((s) => (
          <span key={s.suggestion_id} className="contents">
            <button className={primary} disabled={busy} onClick={() => call("br_accept_suggestion", { p_suggestion: s.suggestion_id })}>Accept: {s.lines.map((l) => l.voucher_no).join(" + ")}</button>
            <button className={small} disabled={busy} title="Not this one - keep it out of future proposals and book the line as new" onClick={() => call("br_reject_suggestion", { p_suggestion: s.suggestion_id, p_book_it: true })}>Not a match</button>
          </span>
        ))}
        {line.recon_status === "excluded" ? (
          <button className={small} disabled={busy} onClick={() => call("br_include_txn", { p_txn: line.bank_txn_id })}>Include again</button>
        ) : (
          <>
            {line.recon_status !== "reconciled" || !ruleBooked ? <button className={small} onClick={openMatch}>{line.recon_status === "reconciled" ? "Change match" : "Match by hand"}</button> : null}
            {line.recon_status !== "reconciled" ? <button className={small} onClick={() => setPanel("book")}>Book it</button> : null}
            {line.recon_status === "reconciled" && !ruleBooked ? <button className={small} disabled={busy} onClick={() => call("br_unmatch", { p_txn: line.bank_txn_id })}>Unmatch</button> : null}
            <button className={small} onClick={() => setPanel("exclude")}>Exclude</button>
          </>
        )}
      </div>
      {err ? <p className="mt-2 text-xs text-danger">{err}</p> : null}

      {panel === "match" ? (
        <div className="mt-3 border border-line bg-surface-sunken p-3">
          <p className="text-xs font-semibold text-ink">Pick the book entr{picked.length === 1 ? "y" : "ies"} this bank line belongs to</p>
          <p className="mt-0.5 text-xs text-ink-muted">Already recorded in your books? Tie it to that entry here — it is not booked a second time.</p>
          {!cands ? <p className="mt-2 text-xs text-ink-muted">Loading…</p> : cands.length === 0 ? <p className="mt-2 text-xs text-ink-muted">No unmatched {line.type === "credit" ? "receipts" : "payments"} on this bank account within 45 days.</p> : (
            <div className="mt-2 max-h-56 overflow-y-auto border border-line bg-surface">
              {cands.map((c) => (
                <label key={c.voucher_line_id} className="flex cursor-pointer items-start gap-2 border-b border-line px-3 py-1.5 text-xs last:border-b-0 hover:bg-surface-sunken">
                  <input type="checkbox" className="mt-0.5" checked={picked.includes(c.voucher_line_id)} onChange={(e) => setPicked(e.target.checked ? [...picked, c.voucher_line_id] : picked.filter((x) => x !== c.voucher_line_id))} />
                  <span className="flex-1"><span className="font-semibold text-ink">{c.voucher_no}</span> · {dateFmt(c.voucher_date)} · {c.narration ?? ""}</span>
                  <span className={`font-data ${Number(c.amount) === Number(line.amount) ? "font-semibold text-success" : "text-ink"}`}>{inr(Number(c.amount))}</span>
                </label>
              ))}
            </div>
          )}
          {picked.length > 0 ? (
            <p className={`mt-2 text-xs ${Math.abs(diff) < 0.005 ? "text-success" : "text-warning"}`}>Chosen total {inr(sum)} vs bank line {inr(Number(line.amount))}{Math.abs(diff) < 0.005 ? " — agrees." : ` — differs by ${inr(Math.abs(diff))}.`}</p>
          ) : null}
          {picked.length > 0 && Math.abs(diff) >= 0.005 ? (
            <label className="mt-2 flex items-center gap-2 text-xs text-ink"><input type="checkbox" checked={allowDiff} onChange={(e) => setAllowDiff(e.target.checked)} /> Accept the difference (it stays visible in the reconciliation statement)</label>
          ) : null}
          <input className="mt-2 h-8 w-full border border-line bg-surface px-2 text-xs" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="mt-2 flex gap-2">
            <button className={primary} disabled={busy || picked.length === 0} onClick={() => call("br_match_manual", { p_txn: line.bank_txn_id, p_line_ids: picked, p_note: note || null, p_allow_difference: allowDiff })}>Match</button>
            <button className={small} onClick={() => setPanel(null)}>Cancel</button>
          </div>
        </div>
      ) : null}

      {panel === "exclude" ? (
        <div className="mt-3 border border-line bg-surface-sunken p-3">
          <p className="text-xs font-semibold text-ink">Keep this bank line out of the books</p>
          <p className="mt-0.5 text-xs text-ink-muted">If it is already recorded in your books, don&apos;t exclude it — <button className="font-semibold text-accent underline" onClick={openMatch}>match it to that entry</button> instead.</p>
          <div className="mt-2 space-y-1">
            {Object.entries(EXCLUDE_REASONS).map(([k, v]) => (
              <label key={k} className="flex items-center gap-2 text-xs text-ink"><input type="radio" name={`r-${line.bank_txn_id}`} checked={reason === k} onChange={() => setReason(k)} /> {v}</label>
            ))}
          </div>
          {line.draft_voucher ? <p className="mt-2 text-xs text-ink-muted">The draft entry {line.draft_voucher.voucher_no} made for this line will be cancelled.</p> : null}
          {ruleBooked ? (
            <label className="mt-2 flex items-start gap-2 text-xs text-ink"><input type="checkbox" className="mt-0.5" checked={reverse} onChange={(e) => setReverse(e.target.checked)} /> A rule already posted an entry for this line. Also reverse that entry (posts an equal and opposite journal; the original stays on record).</label>
          ) : null}
          <input className="mt-2 h-8 w-full border border-line bg-surface px-2 text-xs" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="mt-2 flex gap-2">
            <button className={primary} disabled={busy} onClick={() => call("br_exclude_txn", { p_txn: line.bank_txn_id, p_reason: reason, p_note: note || null, p_reverse: reverse })}>Exclude</button>
            <button className={small} onClick={() => setPanel(null)}>Cancel</button>
          </div>
        </div>
      ) : null}

      {panel === "book" ? (
        <div className="mt-3 border border-line bg-surface-sunken p-3">
          <p className="text-xs font-semibold text-ink">Book this {line.type === "credit" ? "receipt" : "payment"} now</p>
          <p className="mt-0.5 text-xs text-ink-muted">{line.type === "credit" ? "Debit the bank, credit" : "Credit the bank, debit"} the account you choose. Posts straight away and ties to this line.</p>
          <select className="mt-2 h-9 w-full border border-line bg-surface px-2 text-xs" value={ledger} onChange={(e) => setLedger(e.target.value)}>
            <option value="">Choose account…</option>
            {ledgers.map((l) => <option key={l.ledger_id} value={l.ledger_id}>{l.name} — {l.group}</option>)}
          </select>
          <input className="mt-2 h-8 w-full border border-line bg-surface px-2 text-xs" placeholder="Narration (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="mt-2 flex gap-2">
            <button className={primary} disabled={busy || !ledger} onClick={() => call("br_book_txn", { p_txn: line.bank_txn_id, p_ledger: ledger, p_narration: note || null })}>Post entry</button>
            <button className={small} onClick={() => setPanel(null)}>Cancel</button>
          </div>
        </div>
      ) : null}
    </div>
  );
}
