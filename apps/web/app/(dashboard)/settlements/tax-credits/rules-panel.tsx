"use client";

// DEV POINTER: GST TCS and 194-O rates and dates are seeded from the law as known (migration 0078); CA must confirm, and the marketplace GSTIN/TAN must be entered. See docs/DEVELOPER_HANDOVER.md sections 2 and 4.

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn } from "@/components/purchases/bits";

export type Rule = { rule_id: string; kind: string; rate: number; base: string; effective_from: string; note: string | null };
export type Settings = { individual_huf: boolean; threshold_194o: number; tolerance: number; tolerance_pct: number };
export type ChannelIds = { channel_id: string; operator_name: string | null; operator_gstin: string | null; operator_tan: string | null };
const BASES: [string, string][] = [["excl_gst_net", "Sales without GST, less returns"], ["excl_gst_gross", "Sales without GST"], ["incl_gst_net", "Sales with GST, less returns"], ["incl_gst_gross", "Sales with GST"]];
const KIND: Record<string, string> = { gst_tcs: "GST TCS", tds_194o: "194-O TDS" };

export function RulesPanel({ rules, settings, channels, ids, canWrite, canAdmin }: { rules: Rule[]; settings: Settings; channels: { channel_id: string; name: string }[]; ids: ChannelIds[]; canWrite: boolean; canAdmin: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [r, setR] = useState({ kind: "gst_tcs", rate: "", base: "excl_gst_net", from: "", note: "" });
  const [s, setS] = useState({ huf: settings.individual_huf, thr: String(settings.threshold_194o), tol: String(settings.tolerance), pct: String(settings.tolerance_pct) });
  const [idv, setIdv] = useState<Record<string, { n: string; g: string; t: string }>>(() => Object.fromEntries(channels.map((c) => { const i = ids.find((x) => x.channel_id === c.channel_id); return [c.channel_id, { n: i?.operator_name ?? "", g: i?.operator_gstin ?? "", t: i?.operator_tan ?? "" }]; })));
  async function run(fn: () => PromiseLike<{ error: { message: string } | null }>, ok: string) {
    setBusy(true); setErr(null); setMsg(null);
    const { error } = await fn();
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(ok); router.refresh();
  }
  return (
    <section className="mt-10 space-y-4">
      <h2 className="text-sm font-semibold text-ink">Rates and settings</h2>
      <p className="max-w-3xl text-xs text-ink-muted">These are the standard rates. Have your CA confirm them. If the marketplace charges the 194-O tax on a different value than the rate here assumes, the check column above shows which value it actually used; change the &quot;charged on&quot; below to match.</p>
      <div className="overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-2 font-medium">Tax</th><th className="px-3 py-2 font-medium">From</th><th className="px-3 py-2 text-right font-medium">Rate</th><th className="px-3 py-2 font-medium">Charged on</th><th className="px-3 py-2 font-medium">Note</th></tr></thead>
          <tbody>{rules.map((x) => (<tr key={x.rule_id} className="border-b border-line align-top last:border-0"><td className="px-3 py-2">{KIND[x.kind]}</td><td className="px-3 py-2">{x.effective_from}</td><td className="px-3 py-2 text-right font-data">{x.rate}%</td><td className="px-3 py-2">{BASES.find(([k]) => k === x.base)?.[1]}</td><td className="px-3 py-2 text-xs text-ink-muted">{x.note}</td></tr>))}</tbody>
        </table>
      </div>
      {canAdmin ? (
        <div className="flex flex-wrap items-end gap-2 border border-line bg-surface p-3">
          <label className="text-xs text-ink-muted">Tax<select className={`${inputCls} !w-36`} value={r.kind} onChange={(e) => setR({ ...r, kind: e.target.value })}><option value="gst_tcs">GST TCS</option><option value="tds_194o">194-O TDS</option></select></label>
          <label className="text-xs text-ink-muted">New rate (%)<input className={`${inputCls} !w-24`} inputMode="decimal" value={r.rate} onChange={(e) => setR({ ...r, rate: e.target.value })} /></label>
          <label className="text-xs text-ink-muted">Charged on<select className={`${inputCls} !w-64`} value={r.base} onChange={(e) => setR({ ...r, base: e.target.value })}>{BASES.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></label>
          <label className="text-xs text-ink-muted">Applies from<input type="date" className={`${inputCls} !w-40`} value={r.from} onChange={(e) => setR({ ...r, from: e.target.value })} /></label>
          <label className="text-xs text-ink-muted">Note<input className={`${inputCls} !w-56`} value={r.note} onChange={(e) => setR({ ...r, note: e.target.value })} /></label>
          <button className={smallBtn} disabled={busy} onClick={() => run(() => supabase.rpc("mtax_rule_save", { p_kind: r.kind, p_rate: Number(r.rate), p_base: r.base, p_from: r.from, p_note: r.note || null }), "Rate saved.")}>Add or change rate</button>
        </div>
      ) : null}
      <div className="border border-line bg-surface p-3">
        <h3 className="text-xs font-semibold text-ink">Seller type and tolerance</h3>
        <label className="mt-2 flex items-start gap-2 text-sm text-ink"><input type="checkbox" className="mt-1" disabled={!canAdmin} checked={s.huf} onChange={(e) => setS({ ...s, huf: e.target.checked })} /><span>We sell as an individual or HUF (proprietor). No 194-O tax is held until the year&apos;s sales on a marketplace pass the limit below, and it applies only to the amount beyond it.</span></label>
        <div className="mt-2 flex flex-wrap items-end gap-2">
          <label className="text-xs text-ink-muted">Yearly limit (₹)<input className={`${inputCls} !w-32`} disabled={!canAdmin} value={s.thr} onChange={(e) => setS({ ...s, thr: e.target.value })} /></label>
          <label className="text-xs text-ink-muted">Ignore difference up to (₹)<input className={`${inputCls} !w-32`} disabled={!canAdmin} value={s.tol} onChange={(e) => setS({ ...s, tol: e.target.value })} /></label>
          <label className="text-xs text-ink-muted">or (% of amount)<input className={`${inputCls} !w-24`} disabled={!canAdmin} value={s.pct} onChange={(e) => setS({ ...s, pct: e.target.value })} /></label>
          {canAdmin ? <button className={smallBtn} disabled={busy} onClick={() => run(() => supabase.rpc("mtax_settings_save", { p: { individual_huf: s.huf, threshold_194o: Number(s.thr), tolerance: Number(s.tol), tolerance_pct: Number(s.pct) } }), "Settings saved.")}>Save</button> : null}
        </div>
      </div>
      <div className="border border-line bg-surface p-3">
        <h3 className="text-xs font-semibold text-ink">Marketplace GSTIN and TAN (to find the entries in your portal)</h3>
        <div className="mt-2 space-y-2">
          {channels.map((c) => (
            <div key={c.channel_id} className="flex flex-wrap items-center gap-2">
              <span className="w-28 text-sm text-ink">{c.name}</span>
              <input className={`${inputCls} !w-48`} placeholder="Operator name" disabled={!canWrite} value={idv[c.channel_id].n} onChange={(e) => setIdv({ ...idv, [c.channel_id]: { ...idv[c.channel_id], n: e.target.value } })} />
              <input className={`${inputCls} !w-44 font-data`} placeholder="GSTIN" disabled={!canWrite} value={idv[c.channel_id].g} onChange={(e) => setIdv({ ...idv, [c.channel_id]: { ...idv[c.channel_id], g: e.target.value.toUpperCase() } })} />
              <input className={`${inputCls} !w-32 font-data`} placeholder="TAN" disabled={!canWrite} value={idv[c.channel_id].t} onChange={(e) => setIdv({ ...idv, [c.channel_id]: { ...idv[c.channel_id], t: e.target.value.toUpperCase() } })} />
              {canWrite ? <button className={smallBtn} disabled={busy} onClick={() => run(() => supabase.rpc("mtax_ids_save", { p_channel: c.channel_id, p_name: idv[c.channel_id].n, p_gstin: idv[c.channel_id].g, p_tan: idv[c.channel_id].t }), "Saved.")}>Save</button> : null}
            </div>
          ))}
          {channels.length === 0 ? <p className="text-sm text-ink-muted">No marketplace channels yet.</p> : null}
        </div>
      </div>
      {msg ? <p className="text-sm text-success">{msg}</p> : null}{err ? <p className="text-sm text-danger">{err}</p> : null}
      
    </section>
  );
}
