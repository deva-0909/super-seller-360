"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import type { EventType } from "../types";

export function Simulator({ events }: { events: EventType[] }) {
  const supabase = createClient();
  const [ev, setEv] = useState(events[0]?.event_type ?? "");
  const [ctx, setCtx] = useState<Record<string, string>>(() => toStr(events[0]?.sample_ctx ?? {}));
  const [result, setResult] = useState<unknown>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const event = events.find((e) => e.event_type === ev);

  function toStr(o: Record<string, unknown>) { return Object.fromEntries(Object.entries(o).map(([k, v]) => [k, String(v ?? "")])); }
  function pick(e: string) { setEv(e); setCtx(toStr(events.find((x) => x.event_type === e)?.sample_ctx ?? {})); setResult(null); }

  async function run() {
    setBusy(true); setError(null); setResult(null);
    const typed: Record<string, unknown> = {};
    for (const f of event?.fields ?? []) {
      const raw = ctx[f.field];
      if (raw === undefined || raw === "") continue;
      typed[f.field] = f.data_type === "number" ? Number(raw) : f.data_type === "boolean" ? raw === "true" : raw;
    }
    const { data, error } = await supabase.rpc("simulate_journal_rules", { p_event: ev, p_ctx: typed });
    setBusy(false);
    if (error) { setError(friendlyError(error.message)); return; }
    setResult(data);
  }

  type Match = { rule_code: string; name: string; action: string; auto_post: boolean; balanced: boolean; error: string | null; narration: string; lines: { side: string; ledger_name: string; amount: number }[] };
  const matches = Array.isArray(result) ? (result as Match[]) : null;

  return (
    <div className="grid gap-6 md:grid-cols-2">
      <div className="border border-line bg-surface p-4">
        <label className="text-sm font-medium text-ink">Pretend this happens
          <select className="mt-1.5 h-10 w-full border border-line bg-surface px-2 text-sm" value={ev} onChange={(e) => pick(e.target.value)}>
            {events.map((e) => <option key={e.event_type} value={e.event_type}>{e.label}</option>)}
          </select>
        </label>
        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          {(event?.fields ?? []).map((f) => (
            <label key={f.field} className="text-xs font-medium text-ink">{f.label}
              <input className="mt-1 h-9 w-full border border-line bg-surface px-2 text-sm font-normal" value={ctx[f.field] ?? ""} onChange={(e) => setCtx({ ...ctx, [f.field]: e.target.value })} />
            </label>
          ))}
        </div>
        <button onClick={run} disabled={busy} className="mt-4 h-10 rounded-lg bg-accent px-5 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50">{busy ? "Testing…" : "Test"}</button>
        <p className="mt-2 text-xs text-ink-muted">Nothing is posted — this only shows which rule would catch it and what it would write.</p>
      </div>
      <div className="border border-line bg-surface p-4">
        <h3 className="text-sm font-semibold text-ink">What would happen</h3>
        {error ? <p className="mt-3 text-sm text-danger">{error}</p> : null}
        {!result && !error ? <p className="mt-3 text-xs text-ink-muted">Fill in the facts on the left and press Test.</p> : null}
        {matches && matches.length === 0 ? <p className="mt-3 text-sm text-warning">No active rule would act on this. A real event like this would be logged as &quot;skipped&quot;.</p> : null}
        {matches?.map((m, k) => (
          <div key={k} className="mt-3 border-t border-line pt-3 first:border-t-0 first:pt-0">
            <p className="text-sm text-ink"><span className="font-semibold">{m.rule_code}</span> — {m.name}</p>
            <p className="mt-1 text-xs text-ink-muted">{m.action === "ignore" ? "Leave alone — no entry." : m.auto_post ? "Would post automatically." : "Would create a draft for review."}</p>
            {m.error ? <p className="mt-1 text-xs text-danger">{m.error}</p> : null}
            {m.action === "post" ? (
              <>
                <p className="mt-1 text-xs text-ink-muted">Narration: {m.narration}</p>
                <table className="mt-2 w-full text-xs"><tbody>
                  {m.lines.map((l, i) => <tr key={i} className="border-t border-line"><td className="w-10 py-1 text-ink-muted">{l.side === "debit" ? "Dr" : "Cr"}</td><td className="py-1 text-ink">{l.ledger_name}</td><td className="py-1 text-right font-data text-ink">{Number(l.amount).toLocaleString("en-IN", { minimumFractionDigits: 2 })}</td></tr>)}
                </tbody></table>
                {!m.balanced ? <p className="mt-1 text-xs text-danger">This entry would not balance.</p> : null}
              </>
            ) : null}
          </div>
        ))}
      </div>
    </div>
  );
}
