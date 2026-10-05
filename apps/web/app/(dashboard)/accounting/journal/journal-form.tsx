"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { FREQUENCIES, occurrence, type Frequency } from "@/lib/recurring";
import { Proofs } from "@/components/ui/proofs";
import { linkProofs, type Proof } from "@/lib/attachments";

export type LedgerOpt = { ledger_id: string; name: string; group: string };
type Line = { ledger_id: string; debit: string; credit: string; narration: string };
type Flag = { code: string; severity: "info" | "warn"; points: number; message: string };
type Check = { score: number; amount: number; flags: Flag[]; summary: { text: string; amount: number; side: "debit" | "credit" }[]; hold: boolean; needs_reason: boolean };

const input = "h-10 border border-line bg-surface px-2 text-sm text-ink outline-none focus:border-accent";
const inr = (n: number) => "₹" + n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const blank = (): Line => ({ ledger_id: "", debit: "", credit: "", narration: "" });

export function JournalForm({ ledgers, canWrite }: { ledgers: LedgerOpt[]; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [narration, setNarration] = useState("");
  const [lines, setLines] = useState<Line[]>([blank(), blank()]);
  const [recurring, setRecurring] = useState(false);
  const [freq, setFreq] = useState<Frequency>("monthly");
  const [endDate, setEndDate] = useState("");
  const [proofs, setProofs] = useState<Proof[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [check, setCheck] = useState<{ key: string; res: Check } | null>(null);
  const [reason, setReason] = useState("");
  const [seen, setSeen] = useState(false);

  const dr = lines.reduce((s, l) => s + (Number(l.debit) || 0), 0);
  const cr = lines.reduce((s, l) => s + (Number(l.credit) || 0), 0);
  const diff = Math.round((dr - cr) * 100) / 100;
  const balanced = Math.abs(diff) < 0.005 && dr > 0;
  const set = (i: number, patch: Partial<Line>) => setLines((ls) => ls.map((l, k) => (k === i ? { ...l, ...patch } : l)));
  const filled = lines.filter((l) => l.ledger_id);
  const next = recurring && date ? occurrence(date, freq, 1) : null;
  // The read-back is tied to exactly what was typed; changing anything makes it stale and the button goes back to "Check entry".
  const key = JSON.stringify([date, narration, filled.map((l) => [l.ledger_id, l.debit, l.credit]), proofs.length > 0]);
  const fresh = check && check.key === key ? check.res : null;

  async function runCheck() {
    setBusy(true); setErr(null); setSeen(false); setReason("");
    const { data, error } = await supabase.rpc("journal_precheck", {
      p_date: date, p_narration: narration, p_has_proof: proofs.length > 0,
      p_lines: filled.map((l) => ({ ledger_id: l.ledger_id, debit: Number(l.debit) || 0, credit: Number(l.credit) || 0 })),
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setCheck({ key, res: data as Check });
  }

  async function post() {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("post_manual_journal", {
      p_date: date,
      p_narration: narration,
      p_lines: filled.map((l) => ({ ledger_id: l.ledger_id, debit: Number(l.debit) || 0, credit: Number(l.credit) || 0, narration: l.narration })),
      p_recurring: recurring ? { frequency: freq, end_date: endDate || null, name: narration } : null,
      p_has_proof: proofs.length > 0,
      p_reason: reason.trim() || null,
    });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    const d = data as { voucher_no: string; voucher_id: string; held?: boolean };
    let attach = "";
    if (proofs.length) {
      try { await linkProofs(proofs.map((p) => p.attachment_id), "voucher", d.voucher_id); }
      catch { attach = "&attach=failed"; }
    }
    router.push(`/accounting/journal?${d.held ? "held" : "posted"}=${encodeURIComponent(d.voucher_no)}${attach}`);
    router.refresh();
  }

  return (
    <div className="max-w-5xl">
      <div className="grid gap-4 md:grid-cols-[180px_1fr]">
        <label className="flex flex-col gap-1.5 text-sm font-medium text-ink">Entry date
          <input type="date" className={input} value={date} onChange={(e) => setDate(e.target.value)} />
        </label>
        <label className="flex flex-col gap-1.5 text-sm font-medium text-ink">Narration
          <input className={input} value={narration} onChange={(e) => setNarration(e.target.value)} placeholder="e.g. Monthly shop rent" />
        </label>
      </div>

      <div className="mt-5 border border-line bg-surface">
        <div className="hidden grid-cols-[1fr_130px_130px_1fr_auto] gap-2 border-b border-line px-3 py-2 text-xs font-semibold text-ink-muted md:grid">
          <span>Ledger</span><span className="text-right">Debit</span><span className="text-right">Credit</span><span>Line note</span><span />
        </div>
        {lines.map((l, i) => (
          <div key={i} className="grid grid-cols-1 gap-2 border-b border-line px-3 py-2 last:border-b-0 md:grid-cols-[1fr_130px_130px_1fr_auto]">
            <select className={input} value={l.ledger_id} onChange={(e) => set(i, { ledger_id: e.target.value })} aria-label="Ledger">
              <option value="">Choose ledger…</option>
              {ledgers.map((g) => <option key={g.ledger_id} value={g.ledger_id}>{g.name} ({g.group})</option>)}
            </select>
            <input className={`${input} text-right`} inputMode="decimal" placeholder="Debit" aria-label="Debit" value={l.debit} onChange={(e) => set(i, { debit: e.target.value, credit: e.target.value ? "" : l.credit })} />
            <input className={`${input} text-right`} inputMode="decimal" placeholder="Credit" aria-label="Credit" value={l.credit} onChange={(e) => set(i, { credit: e.target.value, debit: e.target.value ? "" : l.debit })} />
            <input className={input} placeholder="Optional" aria-label="Line note" value={l.narration} onChange={(e) => set(i, { narration: e.target.value })} />
            <button type="button" className="text-xs text-danger disabled:opacity-40" disabled={lines.length <= 2} onClick={() => setLines((ls) => ls.filter((_, k) => k !== i))}>Remove</button>
          </div>
        ))}
        <div className="flex flex-wrap items-center justify-between gap-3 border-t border-line bg-surface-sunken px-3 py-2">
          <button type="button" className="text-sm font-semibold text-accent hover:underline" onClick={() => setLines((ls) => [...ls, blank()])}>+ Add line</button>
          <span className="font-data text-sm text-ink">Debit {inr(dr)} · Credit {inr(cr)}
            <span className={`ml-3 ${balanced ? "text-success" : "text-warning"}`}>{balanced ? "Balanced ✓" : diff === 0 ? "Enter amounts" : `Out by ${inr(Math.abs(diff))}`}</span>
          </span>
        </div>
      </div>

      <div className="mt-5 border border-line bg-surface p-4">
        <Proofs entityType="voucher" pending={proofs} onPending={setProofs} label="Bill / receipt (proof)" hint="Photograph the bill with the phone camera or pick it from the gallery." />
      </div>

      <div className="mt-5 border border-line bg-surface p-4">
        <label className="flex items-center gap-2 text-sm font-semibold text-ink">
          <input type="checkbox" checked={recurring} onChange={(e) => setRecurring(e.target.checked)} className="h-4 w-4 accent-[var(--color-accent)]" />
          This is a recurring entry
        </label>
        {recurring ? (
          <div className="mt-3 grid gap-3 md:grid-cols-3">
            <label className="flex flex-col gap-1.5 text-sm font-medium text-ink">Repeats
              <select className={input} value={freq} onChange={(e) => setFreq(e.target.value as Frequency)}>
                {FREQUENCIES.map((f) => <option key={f.value} value={f.value}>{f.label}</option>)}
              </select>
            </label>
            <label className="flex flex-col gap-1.5 text-sm font-medium text-ink">Stop after (optional)
              <input type="date" className={input} value={endDate} min={date} onChange={(e) => setEndDate(e.target.value)} />
            </label>
            <p className="text-xs text-ink-muted md:self-end">
              This entry is the first one{next ? <>; the next posts automatically on <b className="text-ink">{next}</b></> : null}, with these same lines. If an accounting period is closed
              on a due date, the entry waits and shows the reason until it can post.
            </p>
          </div>
        ) : null}
      </div>

      {fresh ? (
        <div className="mt-5 border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">Please read this back before posting</h2>
          <ul className="mt-2 space-y-1 text-sm text-ink">
            {fresh.summary.map((x, i) => <li key={i} className="flex justify-between gap-4"><span>{x.text}</span><span className="font-data">{inr(x.amount)}</span></li>)}
          </ul>
          {fresh.flags.length === 0 ? <p className="mt-3 text-sm text-success">Nothing unusual found.</p> : (
            <ul className="mt-3 space-y-2">
              {fresh.flags.map((f) => (
                <li key={f.code} className={`border px-3 py-2 text-sm ${f.severity === "warn" ? "border-warning/40 bg-warning-tint text-ink" : "border-line text-ink-muted"}`}>
                  <span className="font-semibold">{f.severity === "warn" ? "Check: " : "Note: "}</span>{f.message}
                </li>
              ))}
            </ul>
          )}
          {fresh.needs_reason ? (
            <div className="mt-3 space-y-2">
              <label className="flex flex-col gap-1.5 text-sm font-medium text-ink">Why is this entry correct? (the reviewer will read this)
                <input className={input} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Landlord invoice 123 attached, owner agreed" />
              </label>
              <label className="flex items-center gap-2 text-sm text-ink"><input type="checkbox" checked={seen} onChange={(e) => setSeen(e.target.checked)} className="h-4 w-4 accent-[var(--color-accent)]" />I have read the warnings and the ledgers and amounts are right</label>
            </div>
          ) : null}
          {fresh.hold ? <p className="mt-3 text-sm font-semibold text-warning">This will be sent to a manager for approval. It does not reach the books until they approve.</p> : null}
        </div>
      ) : null}

      {err ? <p className="mt-3 text-sm text-danger">{err}</p> : null}
      {!canWrite ? <p className="mt-3 text-sm text-ink-muted">You can view journal entries but not post them.</p> : null}
      <div className="mt-4 flex gap-3">
        {fresh ? (
          <button type="button" disabled={busy || !canWrite || (fresh.needs_reason && (!seen || reason.trim().length < 5))}
            onClick={post} className="h-10 rounded-lg bg-accent px-5 text-sm font-semibold text-white shadow-sm hover:bg-accent-hover disabled:opacity-50">
            {busy ? "Posting…" : fresh.hold ? "Send for approval" : recurring ? "Post and schedule" : "Post entry"}
          </button>
        ) : (
          <button type="button" disabled={busy || !canWrite || !balanced || filled.length < 2 || !date}
            onClick={runCheck} className="h-10 rounded-lg bg-accent px-5 text-sm font-semibold text-white shadow-sm hover:bg-accent-hover disabled:opacity-50">
            {busy ? "Checking…" : "Check entry"}
          </button>
        )}
        <button type="button" className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken" onClick={() => router.push("/accounting/journal")}>Cancel</button>
      </div>
      <p className="mt-2 text-xs text-ink-muted">Posted entries cannot be edited. To correct one, post a reversing entry.</p>
    </div>
  );
}
