"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { ACTION_TEXT, EXCLUDE_REASONS, type ReconRule } from "../types";
import { describeRule } from "./describe";

const sel = "h-10 w-full border border-line bg-surface px-2 text-sm text-ink outline-none focus:border-accent disabled:opacity-60";
const inp = "h-10 w-full border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent disabled:opacity-60";
const SOURCES: [string, string][] = [["settlement", "Settlements"], ["cod", "COD remittances"], ["order", "Orders"], ["return", "Returns"], ["rto", "RTOs"], ["claim", "Claims"]];

export function ReconRuleEditor({ initial, accounts, canEdit }: { initial: ReconRule; accounts: { bank_account_id: string; label: string }[]; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [r, setR] = useState<ReconRule>(initial);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const isNew = !initial.recon_rule_id;
  const ro = !canEdit;
  const p = (x: Partial<ReconRule>) => { setR((o) => ({ ...o, ...x })); setSaved(false); };
  const isExclude = r.action === "exclude";

  async function save() {
    setBusy(true); setErr(null); setSaved(false);
    const { data, error } = await supabase.rpc("save_bank_recon_rule", { p_rule: r });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setSaved(true);
    if (isNew && data) router.replace(`/bank/reconcile/rules/${data}`); else router.refresh();
  }
  async function run(fn: string, text: string, after: () => void) {
    if (!window.confirm(text)) return;
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc(fn, { p_rule_id: r.recon_rule_id });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    after();
  }

  return (
    <div className="space-y-6">
      {ro ? <p className="border border-line bg-surface p-3 text-xs text-ink-muted">You can look at this rule but not change it. Only a Super Admin or Finance Manager can edit the matching rules.</p> : null}

      <section className="border border-line bg-surface p-4">
        <h2 className="text-sm font-semibold text-ink">1. What is this rule?</h2>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <label className="text-sm font-medium text-ink">Rule name
            <input className={`${inp} mt-1.5`} value={r.name} disabled={ro} onChange={(e) => p({ name: e.target.value })} placeholder="e.g. Razorpay payout equals a settlement" />
          </label>
          <label className="text-sm font-medium text-ink">Order (lower runs first)
            <input type="number" className={`${inp} mt-1.5`} value={r.priority} disabled={ro} onChange={(e) => p({ priority: Number(e.target.value) })} />
          </label>
          <label className="text-sm font-medium text-ink md:col-span-2">Notes (optional)
            <input className={`${inp} mt-1.5`} value={r.description ?? ""} disabled={ro} onChange={(e) => p({ description: e.target.value })} />
          </label>
        </div>
      </section>

      <section className="border border-line bg-surface p-4">
        <h2 className="text-sm font-semibold text-ink">2. Which bank lines does it look at?</h2>
        <div className="mt-3 grid gap-4 md:grid-cols-3">
          <label className="text-sm font-medium text-ink">Direction
            <select className={`${sel} mt-1.5`} value={r.direction} disabled={ro} onChange={(e) => p({ direction: e.target.value as ReconRule["direction"] })}>
              <option value="any">Money in or out</option><option value="credit">Money in (credits)</option><option value="debit">Money out (debits)</option>
            </select>
          </label>
          <label className="text-sm font-medium text-ink">Bank account
            <select className={`${sel} mt-1.5`} value={r.bank_account_id ?? ""} disabled={ro} onChange={(e) => p({ bank_account_id: e.target.value || null })}>
              <option value="">All bank accounts</option>
              {accounts.map((a) => <option key={a.bank_account_id} value={a.bank_account_id}>{a.label}</option>)}
            </select>
          </label>
          <label className="text-sm font-medium text-ink">Only if the bank narration…
            <select className={`${sel} mt-1.5`} value={r.keyword_operator ?? ""} disabled={ro} onChange={(e) => p({ keyword_operator: e.target.value || null, keyword_value: e.target.value ? r.keyword_value : null })}>
              <option value="">(any narration)</option><option value="contains">contains</option><option value="contains_any">contains any of</option>
              <option value="starts_with">starts with</option><option value="ends_with">ends with</option><option value="equals">is exactly</option><option value="regex">matches pattern (advanced)</option>
            </select>
          </label>
          {r.keyword_operator ? (
            <label className="text-sm font-medium text-ink md:col-span-3">Words
              <input className={`${inp} mt-1.5`} value={r.keyword_value ?? ""} disabled={ro} onChange={(e) => p({ keyword_value: e.target.value })} placeholder={r.keyword_operator === "contains_any" ? "RAZORPAY|PAYU|CASHFREE   (separate with |)" : "e.g. SELF TRANSFER"} />
            </label>
          ) : null}
        </div>
      </section>

      <section className="border border-line bg-surface p-4">
        <h2 className="text-sm font-semibold text-ink">3. What should it do?</h2>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <label className="text-sm font-medium text-ink">Action
            <select className={`${sel} mt-1.5`} value={r.action} disabled={ro} onChange={(e) => p({ action: e.target.value as ReconRule["action"] })}>
              {Object.entries(ACTION_TEXT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </label>
          {isExclude ? (
            <label className="text-sm font-medium text-ink">Reason to record
              <select className={`${sel} mt-1.5`} value={r.exclude_reason ?? "other"} disabled={ro} onChange={(e) => p({ exclude_reason: e.target.value })}>
                {Object.entries(EXCLUDE_REASONS).filter(([k]) => k !== "duplicate_import").map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
            </label>
          ) : null}
        </div>
        {isExclude ? (
          <p className="mt-3 text-xs text-ink-muted">Excluded lines are kept out of the books and out of the Rule Book. They stay visible under “Excluded”, and you can include any of them again.</p>
        ) : (
          <div className="mt-4 grid gap-4 md:grid-cols-3">
            <label className="text-sm font-medium text-ink">Match
              <select className={`${sel} mt-1.5`} value={r.match_type} disabled={ro} onChange={(e) => p({ match_type: e.target.value as ReconRule["match_type"] })}>
                <option value="one_to_one">One book entry to one bank line</option><option value="sum_of_entries">Several entries that add up to one bank line</option>
              </select>
            </label>
            <label className="text-sm font-medium text-ink">Date may differ by (days)
              <input type="number" min={0} max={90} className={`${inp} mt-1.5`} value={r.date_window_days} disabled={ro} onChange={(e) => p({ date_window_days: Number(e.target.value) })} />
            </label>
            <label className="text-sm font-medium text-ink">Bank narration must quote our reference
              <select className={`${sel} mt-1.5`} value={r.reference_mode} disabled={ro} onChange={(e) => p({ reference_mode: e.target.value as ReconRule["reference_mode"] })}>
                <option value="ignore">No - amount and date are enough</option><option value="required">Yes - voucher no, settlement ID, order no or AWB</option>
              </select>
            </label>
            <label className="text-sm font-medium text-ink">Amount may differ by (₹)
              <input type="number" min={0} step="0.01" className={`${inp} mt-1.5`} value={r.amount_tolerance} disabled={ro} onChange={(e) => p({ amount_tolerance: Number(e.target.value) })} />
            </label>
            <label className="text-sm font-medium text-ink">… or by (%)
              <input type="number" min={0} step="0.01" className={`${inp} mt-1.5`} value={r.amount_tolerance_pct} disabled={ro} onChange={(e) => p({ amount_tolerance_pct: Number(e.target.value) })} />
            </label>
            <div className="text-sm font-medium text-ink">Only book entries from
              <div className="mt-1.5 flex flex-wrap gap-x-4 gap-y-1">
                {SOURCES.map(([k, v]) => (
                  <label key={k} className="flex items-center gap-1.5 text-xs font-normal"><input type="checkbox" disabled={ro} checked={(r.book_source_types ?? []).includes(k)}
                    onChange={(e) => { const cur = r.book_source_types ?? []; const next = e.target.checked ? [...cur, k] : cur.filter((x) => x !== k); p({ book_source_types: next.length ? next : null }); }} /> {v}</label>
                ))}
              </div>
              <p className="mt-1 text-xs font-normal text-ink-muted">None ticked = every kind of entry.</p>
            </div>
          </div>
        )}
        <p className="mt-4 border-l-2 border-accent bg-surface-sunken p-2 text-xs text-ink-muted">In words: {describeRule(r)} → <span className="font-semibold text-ink">{ACTION_TEXT[r.action]}</span>.
          {r.action === "auto_reconcile" ? " If more than one entry fits equally well, it is suggested instead of linked." : ""}</p>
        <label className="mt-4 flex items-center gap-2 text-sm text-ink">
          <input type="checkbox" disabled={ro} checked={r.status === "active"} onChange={(e) => p({ status: e.target.checked ? "active" : "inactive" })} /> Rule is on
        </label>
      </section>

      {!ro ? (
        <section className="border border-line bg-surface p-4">
          {err ? <p className="mb-3 text-sm text-danger">{err}</p> : null}
          {saved ? <p className="mb-3 text-sm text-success">Saved. It applies to bank lines imported from now on, and to “Match with books”.</p> : null}
          <div className="flex flex-wrap gap-3">
            <button type="button" disabled={busy} onClick={save} className="h-10 rounded-lg bg-accent px-5 text-sm font-semibold text-white shadow-sm hover:bg-accent-hover disabled:opacity-50">{busy ? "Saving…" : isNew ? "Create rule" : "Save changes"}</button>
            {!isNew && r.is_system ? <button type="button" disabled={busy} className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken"
              onClick={() => run("reset_bank_recon_rule", "Put this rule back to the accountant's original setting?", () => router.refresh())}>Restore default</button> : null}
            {!isNew && !r.is_system ? <button type="button" disabled={busy} className="h-10 rounded-lg border border-danger/40 bg-surface px-4 text-sm font-semibold text-danger hover:bg-danger-tint"
              onClick={() => run("delete_bank_recon_rule", "Delete this rule for good?", () => router.push("/bank/reconcile/rules"))}>Delete</button> : null}
          </div>
        </section>
      ) : null}
    </div>
  );
}
