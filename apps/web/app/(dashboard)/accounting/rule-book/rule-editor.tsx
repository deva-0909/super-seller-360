"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import {
  EventType, LedgerOption, NO_VALUE_OPERATORS, OPERATORS, RuleCondition, RuleDef, RuleLine, VOUCHER_TYPE_HELP, GROUP_ORDER, inr, previewLines,
} from "./types";

type HistoryRow = { version: number; change_note: string | null; changed_at: string };

const sel = "h-10 w-full border border-line bg-surface px-2 text-sm text-ink outline-none focus:border-accent disabled:opacity-60";
const inp = "h-10 w-full border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent disabled:opacity-60";

export function RuleEditor({
  initial, events, ledgers, voucherTypes, canEdit, history,
}: {
  initial: RuleDef;
  events: EventType[];
  ledgers: LedgerOption[];
  voucherTypes: string[];
  canEdit: boolean;
  history: HistoryRow[];
}) {
  const router = useRouter();
  const supabase = createClient();
  const [rule, setRule] = useState<RuleDef>(initial);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const isNew = !initial.journal_rule_id;
  const ro = !canEdit;

  const event = events.find((e) => e.event_type === rule.event_type);
  const fields = event?.fields ?? [];
  const numericFields = fields.filter((f) => f.data_type === "number");
  const amountChoices = [
    ...numericFields.map((f) => ({ value: f.field, label: f.label })),
    ...(((rule.gst_rate_pct ?? 0) > 0)
      ? [{ value: "base", label: "Amount before GST" }, { value: "tax", label: "GST (total)" }, { value: "cgst", label: "CGST" }, { value: "sgst", label: "SGST" }]
      : [{ value: "base", label: "Amount before GST (= amount)" }]),
    { value: "fixed", label: "A fixed amount" },
    { value: "remainder", label: "Balancing figure" },
  ];

  const ledgerName = (id: string | null, role: string | null) => (role === "bank" ? "Bank (the account used)" : ledgers.find((l) => l.ledger_id === id)?.name ?? "—");
  const preview = useMemo(() => (event ? previewLines(rule, event.sample_ctx, ledgerName) : null), [rule, event]); // eslint-disable-line react-hooks/exhaustive-deps

  function patch(p: Partial<RuleDef>) { setRule((r) => ({ ...r, ...p })); setSaved(false); }
  function setCond(i: number, p: Partial<RuleCondition>) { patch({ conditions: rule.conditions.map((c, k) => (k === i ? { ...c, ...p } : c)) }); }
  function setLine(i: number, p: Partial<RuleLine>) { patch({ lines: rule.lines.map((l, k) => (k === i ? { ...l, ...p } : l)) }); }

  function changeEvent(ev: string) {
    const e = events.find((x) => x.event_type === ev);
    patch({ event_type: ev, conditions: [], lines: e && isNew ? [] : rule.lines, pack: e?.pack ?? rule.pack });
  }

  async function save() {
    setBusy(true); setError(null); setSaved(false);
    const payload = {
      ...rule,
      conditions: rule.conditions.filter((c) => c.field),
      lines: rule.action === "post" ? rule.lines.map((l) => ({
        ...l,
        ledger_id: l.ledger_role === "bank" ? null : l.ledger_id,
        percent: l.percent === null || Number.isNaN(l.percent) ? null : l.percent,
      })) : [],
    };
    const { data, error } = await supabase.rpc("save_journal_rule", { p_rule: payload });
    setBusy(false);
    if (error) { setError(friendlyError(error.message)); return; }
    setSaved(true);
    if (isNew && data) router.replace(`/accounting/rule-book/${data}`); else router.refresh();
  }

  async function run(fn: string, confirmText: string, after: (data: unknown) => void) {
    if (!window.confirm(confirmText)) return;
    setBusy(true); setError(null);
    const { data, error } = await supabase.rpc(fn, { p_rule_id: rule.journal_rule_id });
    setBusy(false);
    if (error) { setError(friendlyError(error.message)); return; }
    after(data);
  }

  const groups = [...new Set([...GROUP_ORDER, rule.rule_group])];

  return (
    <div className="space-y-6">
      {ro ? <p className="border border-line bg-surface p-3 text-xs text-ink-muted">You can look at this rule but not change it. Only a Super Admin or Finance Manager can edit the rule book.</p> : null}

      <section className="border border-line bg-surface p-4">
        <h2 className="text-sm font-semibold text-ink">1. What is this rule?</h2>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <label className="text-sm font-medium text-ink">Rule name
            <input className={`${inp} mt-1.5`} value={rule.name} disabled={ro} onChange={(e) => patch({ name: e.target.value })} placeholder="e.g. Courier freight paid from bank" />
          </label>
          <label className="text-sm font-medium text-ink">Show under heading
            <select className={`${sel} mt-1.5`} value={rule.rule_group} disabled={ro} onChange={(e) => patch({ rule_group: e.target.value })}>
              {groups.map((g) => <option key={g}>{g}</option>)}
            </select>
          </label>
          <label className="text-sm font-medium text-ink md:col-span-2">Notes for your accountant (optional)
            <input className={`${inp} mt-1.5`} value={rule.description ?? ""} disabled={ro} onChange={(e) => patch({ description: e.target.value })} placeholder="Why does this rule exist?" />
          </label>
        </div>
      </section>

      <section className="border border-line bg-surface p-4">
        <h2 className="text-sm font-semibold text-ink">2. When should it run?</h2>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <label className="text-sm font-medium text-ink">Something happens
            <select className={`${sel} mt-1.5`} value={rule.event_type} disabled={ro} onChange={(e) => changeEvent(e.target.value)}>
              <option value="">Choose…</option>
              {events.map((e) => <option key={e.event_type} value={e.event_type}>{e.label}</option>)}
            </select>
            {event?.trigger_text ? <span className="mt-1 block text-xs font-normal text-ink-muted">{event.trigger_text}</span> : null}
          </label>
          <label className="text-sm font-medium text-ink">What to do
            <select className={`${sel} mt-1.5`} value={rule.action} disabled={ro} onChange={(e) => patch({ action: e.target.value as RuleDef["action"] })}>
              <option value="post">Make a journal entry</option>
              <option value="ignore">Leave it alone (no entry)</option>
            </select>
          </label>
        </div>

        <div className="mt-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <p className="text-sm font-medium text-ink">Only if…</p>
            <label className="flex items-center gap-2 text-xs text-ink-muted">
              Match
              <select className="h-8 border border-line bg-surface px-1 text-xs" value={rule.match_mode} disabled={ro} onChange={(e) => patch({ match_mode: e.target.value as "all" | "any" })}>
                <option value="all">all conditions</option>
                <option value="any">any one condition</option>
              </select>
            </label>
          </div>
          {rule.conditions.length === 0 ? <p className="mt-2 text-xs text-ink-muted">No conditions — runs for every {event?.label?.toLowerCase() ?? "event"}.</p> : null}
          <div className="mt-2 space-y-2">
            {rule.conditions.map((c, i) => {
              const op = OPERATORS.find((o) => o.value === c.operator);
              return (
                <div key={i} className="grid grid-cols-1 gap-2 md:grid-cols-[1fr_1fr_2fr_auto]">
                  <select className={sel} value={c.field} disabled={ro} onChange={(e) => setCond(i, { field: e.target.value })}>
                    <option value="">Field…</option>
                    {fields.map((f) => <option key={f.field} value={f.field}>{f.label}</option>)}
                  </select>
                  <select className={sel} value={c.operator} disabled={ro} onChange={(e) => setCond(i, { operator: e.target.value })}>
                    {OPERATORS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                  </select>
                  {NO_VALUE_OPERATORS.has(c.operator)
                    ? <div />
                    : <input className={inp} value={c.value ?? ""} disabled={ro} onChange={(e) => setCond(i, { value: e.target.value })} placeholder={op?.hint ?? "value"} title={op?.hint} />}
                  {!ro ? <button type="button" className="h-10 px-3 text-sm text-danger hover:underline" onClick={() => patch({ conditions: rule.conditions.filter((_, k) => k !== i) })}>Remove</button> : null}
                </div>
              );
            })}
          </div>
          {!ro ? <button type="button" className="mt-2 text-sm font-semibold text-accent hover:underline" onClick={() => patch({ conditions: [...rule.conditions, { field: fields[0]?.field ?? "", operator: "contains", value: "" }] })}>+ Add condition</button> : null}
        </div>
      </section>

      {rule.action === "post" ? (
        <section className="border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">3. What entry should it make?</h2>
          <div className="mt-3 grid gap-4 md:grid-cols-3">
            <label className="text-sm font-medium text-ink">Voucher type
              <select className={`${sel} mt-1.5`} value={rule.voucher_type_code} disabled={ro} onChange={(e) => patch({ voucher_type_code: e.target.value })}>
                {voucherTypes.map((v) => <option key={v} value={v}>{VOUCHER_TYPE_HELP[v] ?? v}</option>)}
              </select>
            </label>
            <label className="text-sm font-medium text-ink">GST included in amount (%)
              <input type="number" min={0} step="0.01" className={`${inp} mt-1.5`} value={rule.gst_rate_pct ?? ""} disabled={ro}
                onChange={(e) => patch({ gst_rate_pct: e.target.value === "" ? null : Number(e.target.value) })} placeholder="0 = none" />
            </label>
            <label className="text-sm font-medium text-ink">Narration
              <input className={`${inp} mt-1.5`} value={rule.narration_template ?? ""} disabled={ro} onChange={(e) => patch({ narration_template: e.target.value })} placeholder="e.g. Courier charges - {description}" />
            </label>
          </div>
          {event ? <p className="mt-2 text-xs text-ink-muted">Narration can use: {fields.map((f) => `{${f.field}}`).join(" ")}</p> : null}

          <div className="mt-4 space-y-2">
            {rule.lines.map((l, i) => (
              <div key={i} className="grid grid-cols-1 gap-2 md:grid-cols-[110px_2fr_1.5fr_90px_auto]">
                <select className={sel} value={l.side} disabled={ro} onChange={(e) => setLine(i, { side: e.target.value as RuleLine["side"] })}>
                  <option value="debit">Debit</option>
                  <option value="credit">Credit</option>
                </select>
                <select className={sel} value={l.ledger_role === "bank" ? "__bank" : l.ledger_id ?? ""} disabled={ro}
                  onChange={(e) => e.target.value === "__bank" ? setLine(i, { ledger_role: "bank", ledger_id: null }) : setLine(i, { ledger_role: null, ledger_id: e.target.value || null })}>
                  <option value="">Choose account…</option>
                  <option value="__bank">Bank (the account used)</option>
                  {ledgers.map((x) => <option key={x.ledger_id} value={x.ledger_id}>{x.name} — {x.group}</option>)}
                </select>
                <select className={sel} value={l.amount_source} disabled={ro} onChange={(e) => setLine(i, { amount_source: e.target.value })}>
                  {amountChoices.some((a) => a.value === l.amount_source) ? null : <option value={l.amount_source}>{l.amount_source}</option>}
                  {amountChoices.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
                </select>
                {l.amount_source === "fixed"
                  ? <input type="number" step="0.01" className={inp} value={l.fixed_amount ?? ""} disabled={ro} onChange={(e) => setLine(i, { fixed_amount: e.target.value === "" ? null : Number(e.target.value) })} placeholder="₹" />
                  : <input type="number" step="0.01" className={inp} value={l.percent ?? ""} disabled={ro} onChange={(e) => setLine(i, { percent: e.target.value === "" ? null : Number(e.target.value) })} placeholder="100 %" title="Percent of the amount (blank = 100)" />}
                {!ro ? <button type="button" className="h-10 px-3 text-sm text-danger hover:underline" onClick={() => patch({ lines: rule.lines.filter((_, k) => k !== i) })}>Remove</button> : null}
              </div>
            ))}
          </div>
          {!ro ? <button type="button" className="mt-2 text-sm font-semibold text-accent hover:underline" onClick={() => patch({ lines: [...rule.lines, { side: rule.lines.some((l) => l.side === "debit") ? "credit" : "debit", ledger_id: null, ledger_role: null, amount_source: "amount", percent: null, fixed_amount: null, narration: null }] })}>+ Add line</button> : null}

          {preview ? (
            <div className="mt-5 border border-line bg-surface-sunken p-3">
              <p className="text-xs font-semibold text-ink">Preview with a sample {event?.label?.toLowerCase()}</p>
              {preview.lines.length === 0 ? <p className="mt-1 text-xs text-ink-muted">Add lines to see the entry.</p> : (
                <table className="mt-2 w-full text-xs">
                  <tbody>
                    {preview.lines.map((p, i) => (
                      <tr key={i}>
                        <td className="w-12 py-0.5 text-ink-muted">{p.side === "debit" ? "Dr" : "Cr"}</td>
                        <td className="py-0.5 text-ink">{p.ledger}</td>
                        <td className="py-0.5 text-right font-data text-ink">{inr(p.amount)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
              <p className={`mt-2 text-xs ${preview.balanced ? "text-success" : "text-danger"}`}>
                {preview.balanced ? "Debits equal credits." : `Not balanced: Dr ${inr(preview.debit)} vs Cr ${inr(preview.credit)}. Add a "Balancing figure" line.`}
              </p>
            </div>
          ) : null}
        </section>
      ) : null}

      <section className="border border-line bg-surface p-4">
        <h2 className="text-sm font-semibold text-ink">4. How should it behave?</h2>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          {rule.action === "post" ? (
            <label className="text-sm font-medium text-ink">Posting
              <select className={`${sel} mt-1.5`} value={rule.auto_post ? "auto" : "review"} disabled={ro} onChange={(e) => patch({ auto_post: e.target.value === "auto" })}>
                <option value="auto">Post automatically</option>
                <option value="review">Create a draft for my review first</option>
              </select>
            </label>
          ) : null}
          <label className="text-sm font-medium text-ink">Priority (lower runs first)
            <input type="number" className={`${inp} mt-1.5`} value={rule.priority} disabled={ro} onChange={(e) => patch({ priority: Number(e.target.value) })} />
          </label>
          <label className="flex items-center gap-2 text-sm text-ink">
            <input type="checkbox" checked={rule.stop_on_match} disabled={ro} onChange={(e) => patch({ stop_on_match: e.target.checked })} />
            Stop here if this rule matches (don&apos;t try later rules)
          </label>
          <label className="text-sm font-medium text-ink">Status
            <select className={`${sel} mt-1.5`} value={rule.status} disabled={ro} onChange={(e) => patch({ status: e.target.value as RuleDef["status"] })}>
              <option value="active">On</option>
              <option value="inactive">Off</option>
            </select>
          </label>
          <label className="text-sm font-medium text-ink">Applies from
            <input type="date" className={`${inp} mt-1.5`} value={rule.effective_from ?? ""} disabled={ro} onChange={(e) => patch({ effective_from: e.target.value || null })} />
          </label>
          <label className="text-sm font-medium text-ink">Applies until
            <input type="date" className={`${inp} mt-1.5`} value={rule.effective_to ?? ""} disabled={ro} onChange={(e) => patch({ effective_to: e.target.value || null })} />
          </label>
        </div>
        <p className="mt-3 text-xs text-ink-muted">Entries already posted never change when you edit a rule — only future events use the new version.</p>
      </section>

      {!ro ? (
        <section className="border border-line bg-surface p-4">
          <label className="text-sm font-medium text-ink">What did you change? (saved in history)
            <input className={`${inp} mt-1.5`} value={rule.change_note ?? ""} onChange={(e) => patch({ change_note: e.target.value })} placeholder="e.g. Added BLUEDART keyword" />
          </label>
          {error ? <p className="mt-3 text-sm text-danger">{error}</p> : null}
          {saved ? <p className="mt-3 text-sm text-success">Saved.</p> : null}
          <div className="mt-4 flex flex-wrap items-center gap-3">
            <button type="button" disabled={busy} onClick={save} className="h-10 rounded-lg bg-accent px-5 text-sm font-semibold text-white shadow-sm hover:bg-accent-hover disabled:opacity-50">
              {busy ? "Saving…" : isNew ? "Create rule" : "Save changes"}
            </button>
            {!isNew ? (
              <>
                <button type="button" disabled={busy} className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken"
                  onClick={() => run("duplicate_journal_rule", "Make a copy of this rule?", (id) => router.push(`/accounting/rule-book/${id}`))}>Duplicate</button>
                {rule.is_system ? (
                  <button type="button" disabled={busy} className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken"
                    onClick={() => run("reset_journal_rule_to_default", "Put this rule back to the accountant's original setting? Your changes will be replaced.", () => router.refresh())}>Restore default</button>
                ) : (
                  <button type="button" disabled={busy} className="h-10 rounded-lg border border-danger/40 bg-surface px-4 text-sm font-semibold text-danger hover:bg-danger-tint"
                    onClick={() => run("delete_journal_rule", "Delete this rule for good?", () => router.push("/accounting/rule-book"))}>Delete</button>
                )}
              </>
            ) : null}
          </div>
        </section>
      ) : null}

      {history.length > 0 ? (
        <section className="border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">Change history</h2>
          <ul className="mt-2 divide-y divide-line text-xs">
            {history.map((h) => (
              <li key={h.version} className="flex justify-between gap-4 py-1.5">
                <span className="text-ink">v{h.version} replaced{h.change_note ? ` — ${h.change_note}` : ""}</span>
                <span className="text-ink-muted">{new Date(h.changed_at).toLocaleString("en-IN")}</span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </div>
  );
}
