"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn } from "@/components/purchases/bits";

export type Policy = Record<string, number | string[]>;
const NUM: [string, string][] = [
  ["review_amount", "Always review entries from (₹)"], ["approval_amount", "Hold for approval from (₹)"], ["proof_amount", "Ask for a bill from (₹)"], ["backdate_days", "Back-dated after (days)"],
  ["dup_days", "Duplicate look-back (days)"], ["must_review_score", "Risk score that forces a review"], ["sample_pct", "Sample of the rest (%)"], ["daily_review_cap", "Most reviews asked for per day"],
  ["sla_days", "Review deadline (days)"], ["new_operator_entries", "Treat as new until (entries)"], ["error_rate_pct", "High error rate (%)"], ["odd_from_hour", "Odd hours from (0-23)"], ["odd_to_hour", "Odd hours until (0-23)"],
];

export function PolicyForm({ initial, canEdit }: { initial: Policy; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [v, setV] = useState<Record<string, string>>(() => Object.fromEntries(NUM.map(([k]) => [k, String(initial[k] ?? "")])));
  const [weak, setWeak] = useState(((initial.weak_words as string[]) ?? []).join(", "));
  const [groups, setGroups] = useState(((initial.control_groups as string[]) ?? []).join(", "));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const list = (s: string) => s.split(",").map((x) => x.trim()).filter(Boolean);
  async function save() {
    setBusy(true); setErr(null); setMsg(null);
    const p: Record<string, number | string[]> = { weak_words: list(weak), control_groups: list(groups) };
    for (const [k, x] of Object.entries(v)) p[k] = Number(x);
    const { error } = await supabase.rpc("journal_policy_save", { p });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg("Rules saved."); router.refresh();
  }
  return (
    <section className="mt-8 border border-line bg-surface p-4">
      <h2 className="text-sm font-semibold text-ink">Review rules</h2>
      <p className="mt-1 max-w-3xl text-xs text-ink-muted">Sized for about 500 to 1,000 vouchers a day, where most are posted by the system and only the hand-chosen ones are checked. Keep the daily cap at what one manager can clear in an hour; raise the sample percentage when you add new staff.</p>
      <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {NUM.map(([k, label]) => (<label key={k} className="text-xs text-ink-muted">{label}<input className={inputCls} inputMode="decimal" disabled={!canEdit} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} /></label>))}
      </div>
      <label className="mt-3 block text-xs text-ink-muted">Narrations treated as too weak (comma separated)<input className={inputCls} disabled={!canEdit} value={weak} onChange={(e) => setWeak(e.target.value)} /></label>
      <label className="mt-3 block text-xs text-ink-muted">Account groups the system normally updates (a hand entry on these gets a warning)<input className={inputCls} disabled={!canEdit} value={groups} onChange={(e) => setGroups(e.target.value)} /></label>
      {canEdit ? <div className="mt-3 flex items-center gap-3"><button className={primaryBtn} disabled={busy} onClick={save}>Save rules</button>{msg ? <span className="text-sm text-success">{msg}</span> : null}{err ? <span className="text-sm text-danger">{err}</span> : null}</div> : <p className="mt-3 text-xs text-ink-muted">Only a Finance Manager or Super Admin can change these.</p>}
    </section>
  );
}
