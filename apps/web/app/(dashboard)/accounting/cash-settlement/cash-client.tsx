"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { Proofs } from "@/components/ui/proofs";
import { linkProofs, type Proof } from "@/lib/attachments";

export type LedgerOpt = { ledger_id: string; name: string };

const btn = "h-9 rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50";
const primary = "h-9 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50";
const input = "h-9 border border-line bg-surface px-2 text-sm text-ink outline-none focus:border-accent";
const inr = (n: number) => "₹" + n.toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

const KINDS = [
  { value: "spent", label: "Spent (books an expense entry)" },
  { value: "returned_to_bank", label: "Returned / deposited to the bank" },
  { value: "kept_in_hand", label: "Still in hand (counted cash)" },
  { value: "other_recorded", label: "Already recorded elsewhere" },
] as const;

type Line = { kind: string; amount: string; ledger_id: string; narration: string };

export function SettleForm({ movementId, openAmount, ledgers }: { movementId: string; openAmount: number; ledgers: LedgerOpt[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [open, setOpen] = useState(false);
  const [lines, setLines] = useState<Line[]>([{ kind: "spent", amount: String(openAmount), ledger_id: "", narration: "" }]);
  const [note, setNote] = useState("");
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [proofs, setProofs] = useState<Proof[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const total = lines.reduce((s, l) => s + (Number(l.amount) || 0), 0);
  const gap = Math.round((openAmount - total) * 100) / 100;
  const set = (i: number, patch: Partial<Line>) => setLines((ls) => ls.map((l, k) => (k === i ? { ...l, ...patch } : l)));

  async function submit() {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("submit_cash_settlement", {
      p_movement: movementId,
      p_lines: lines.map((l) => ({ kind: l.kind, amount: Number(l.amount), ledger_id: l.kind === "spent" ? l.ledger_id || null : null, narration: l.narration })),
      p_note: note || null,
      p_date: date,
    });
    if (error) { setBusy(false); setErr(friendlyError(error.message)); return; }
    const reportId = (data as { report_id?: string } | null)?.report_id;
    if (proofs.length && reportId) {
      try { await linkProofs(proofs.map((p) => p.attachment_id), "cash_settlement_report", reportId); }
      catch (e) { setBusy(false); setErr(`Report submitted, but the attachments could not be linked: ${(e as Error).message}`); router.refresh(); return; }
    }
    setBusy(false);
    setOpen(false);
    router.refresh();
  }

  if (!open) return <button type="button" className={primary} onClick={() => setOpen(true)}>Submit settlement report</button>;

  return (
    <div className="mt-3 w-full border border-line bg-surface-sunken p-4">
      <p className="text-sm font-semibold text-ink">Where did the {inr(openAmount)} go?</p>
      <p className="mt-1 text-xs text-ink-muted">Add a line for each use of the cash. Together they must add up to {inr(openAmount)}. “Spent” lines post the expense entry for you (Dr expense, Cr Cash in Hand).</p>
      <div className="mt-3 space-y-2">
        {lines.map((l, i) => (
          <div key={i} className="grid grid-cols-1 gap-2 md:grid-cols-[210px_110px_1fr_1fr_auto]">
            <select className={input} value={l.kind} onChange={(e) => set(i, { kind: e.target.value })} aria-label="What happened to the cash">
              {KINDS.map((k) => <option key={k.value} value={k.value}>{k.label}</option>)}
            </select>
            <input className={`${input} text-right`} inputMode="decimal" value={l.amount} onChange={(e) => set(i, { amount: e.target.value })} aria-label="Amount" placeholder="Amount" />
            {l.kind === "spent" ? (
              <select className={input} value={l.ledger_id} onChange={(e) => set(i, { ledger_id: e.target.value })} aria-label="Expense ledger">
                <option value="">Choose expense ledger…</option>
                {ledgers.map((g) => <option key={g.ledger_id} value={g.ledger_id}>{g.name}</option>)}
              </select>
            ) : <span className="hidden md:block" />}
            <input className={input} value={l.narration} onChange={(e) => set(i, { narration: e.target.value })} aria-label="Note" placeholder={l.kind === "spent" ? "What was it for?" : "Where is it recorded / how was it counted?"} />
            <button type="button" className="text-xs text-danger disabled:opacity-40" disabled={lines.length === 1} onClick={() => setLines((ls) => ls.filter((_, k) => k !== i))}>Remove</button>
          </div>
        ))}
      </div>
      <div className="mt-2 flex flex-wrap items-center gap-3">
        <button type="button" className={btn} onClick={() => setLines((ls) => [...ls, { kind: "spent", amount: gap > 0 ? String(gap) : "", ledger_id: "", narration: "" }])}>+ Add line</button>
        <label className="flex items-center gap-2 text-xs text-ink-muted">Expense entry date
          <input type="date" className={input} value={date} onChange={(e) => setDate(e.target.value)} />
        </label>
        <span className={`ml-auto font-data text-sm ${Math.abs(gap) < 0.005 ? "text-success" : "text-warning"}`}>
          Accounted {inr(total)} of {inr(openAmount)}{Math.abs(gap) < 0.005 ? " ✓" : ` · ${inr(Math.abs(gap))} ${gap > 0 ? "left" : "too much"}`}
        </span>
      </div>
      <div className="mt-3"><Proofs entityType="cash_settlement_report" pending={proofs} onPending={setProofs} label="Proof of spend (bills, receipts, deposit slip)" hint="Photograph each bill with the phone camera or pick from the gallery." /></div>
      <textarea className="mt-3 w-full border border-line bg-surface p-2 text-sm text-ink outline-none focus:border-accent" rows={2} placeholder="Remarks for the owner (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
      {err ? <p className="mt-2 text-sm text-danger">{err}</p> : null}
      <div className="mt-3 flex gap-2">
        <button type="button" className={primary} disabled={busy || Math.abs(gap) >= 0.005} onClick={submit}>{busy ? "Submitting…" : "Submit report & clear the warning"}</button>
        <button type="button" className={btn} onClick={() => setOpen(false)}>Cancel</button>
      </div>
    </div>
  );
}

export function RescanButton() {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  async function go() {
    setBusy(true); setMsg(null);
    const { data, error } = await supabase.rpc("cash_backfill");
    setBusy(false);
    if (error) { setMsg(friendlyError(error.message)); return; }
    const d = data as { movements_found: number; open: number };
    setMsg(`Checked all posted entries. ${d.open} open.`);
    router.refresh();
  }
  return (
    <span className="inline-flex items-center gap-2">
      <button type="button" className={btn} disabled={busy} onClick={go}>{busy ? "Checking…" : "Re-check all entries"}</button>
      {msg ? <span className="text-xs text-ink-muted">{msg}</span> : null}
    </span>
  );
}

export function SettingsForm({ remind, repeat, tolerance, extra, canEdit }: { remind: number; repeat: number; tolerance: number; extra: string; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [v, setV] = useState({ remind: String(remind), repeat: String(repeat), tolerance: String(tolerance), extra });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  async function save() {
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("save_cash_settings", { p_remind_minutes: Number(v.remind), p_mail_repeat_hours: Number(v.repeat), p_tolerance: Number(v.tolerance), p_extra_recipients: v.extra });
    setBusy(false);
    setMsg(error ? friendlyError(error.message) : "Saved.");
    if (!error) router.refresh();
  }
  const lbl = "flex flex-col gap-1 text-xs text-ink-muted";
  return (
    <div className="grid gap-3 md:grid-cols-4">
      <label className={lbl}>On-screen reminder every (minutes)<input className={input} disabled={!canEdit} inputMode="numeric" value={v.remind} onChange={(e) => setV({ ...v, remind: e.target.value })} /></label>
      <label className={lbl}>E-mail again every (hours)<input className={input} disabled={!canEdit} inputMode="numeric" value={v.repeat} onChange={(e) => setV({ ...v, repeat: e.target.value })} /></label>
      <label className={lbl}>Rounding tolerance (₹)<input className={input} disabled={!canEdit} inputMode="decimal" value={v.tolerance} onChange={(e) => setV({ ...v, tolerance: e.target.value })} /></label>
      <label className={`${lbl} md:col-span-4`}>Also e-mail these addresses (comma separated; Super Admins are always e-mailed)<input className={input} disabled={!canEdit} value={v.extra} onChange={(e) => setV({ ...v, extra: e.target.value })} /></label>
      {canEdit ? (
        <div className="flex items-center gap-3 md:col-span-4">
          <button type="button" className={primary} disabled={busy} onClick={save}>{busy ? "Saving…" : "Save settings"}</button>
          {msg ? <span className="text-xs text-ink-muted">{msg}</span> : null}
        </div>
      ) : <p className="text-xs text-ink-muted md:col-span-4">Only a Super Admin or Finance Manager can change these.</p>}
    </div>
  );
}
