"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

type Rule = { rule_id: string; channel_id: string; fee_type: string; percent: number; fixed: number; tolerance: number };

export function FeeRules({ channels, rules }: { channels: { channel_id: string; name: string }[]; rules: Rule[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [ch, setCh] = useState(channels[0]?.channel_id ?? "");
  const [ft, setFt] = useState("commission");
  const [pct, setPct] = useState("");
  const [fixed, setFixed] = useState("");
  const [tol, setTol] = useState("1");
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const name = (id: string) => channels.find((c) => c.channel_id === id)?.name ?? id;
  const input = "h-9 border border-line bg-surface px-2.5 text-sm text-ink outline-none focus:border-accent";

  async function save() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("set_fee_rule", { p_channel: ch, p_fee_type: ft, p_percent: Number(pct || 0), p_fixed: Number(fixed || 0), p_tolerance: Number(tol || 0) });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setPct(""); setFixed(""); router.refresh();
  }
  async function del(id: string) {
    const { error } = await supabase.rpc("delete_fee_rule", { p_rule: id });
    if (error) setErr(friendlyError(error.message)); else router.refresh();
  }
  return (
    <div className="mt-6">
      <h2 className="text-sm font-semibold text-ink">Agreed rates</h2>
      <ul className="mt-2 divide-y divide-line border border-line bg-surface text-sm">
        {rules.map((r) => (
          <li key={r.rule_id} className="flex items-center justify-between px-3 py-2"><span>{name(r.channel_id)} · {r.fee_type.replace("_", " ")} · {r.percent}% of order value{r.fixed ? ` + ₹${r.fixed}` : ""} <span className="text-xs text-ink-muted">(ignore up to ₹{r.tolerance})</span></span><button className="text-xs text-danger underline" onClick={() => del(r.rule_id)}>Remove</button></li>
        ))}
        {rules.length === 0 ? <li className="px-3 py-3 text-ink-muted">No rates entered yet.</li> : null}
      </ul>
      <div className="mt-3 flex flex-wrap items-end gap-2">
        <label className="text-xs text-ink-muted">Channel<br /><select className={input} value={ch} onChange={(e) => setCh(e.target.value)}>{channels.map((c) => <option key={c.channel_id} value={c.channel_id}>{c.name}</option>)}</select></label>
        <label className="text-xs text-ink-muted">Fee<br /><select className={input} value={ft} onChange={(e) => setFt(e.target.value)}><option value="commission">Commission</option><option value="shipping">Shipping</option><option value="gateway_fee">Gateway fee</option></select></label>
        <label className="text-xs text-ink-muted">% of order value<br /><input className={`${input} w-24`} inputMode="decimal" value={pct} onChange={(e) => setPct(e.target.value)} /></label>
        <label className="text-xs text-ink-muted">+ fixed ₹<br /><input className={`${input} w-24`} inputMode="decimal" value={fixed} onChange={(e) => setFixed(e.target.value)} /></label>
        <label className="text-xs text-ink-muted">Ignore up to ₹<br /><input className={`${input} w-20`} inputMode="decimal" value={tol} onChange={(e) => setTol(e.target.value)} /></label>
        <button className="h-9 bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50" onClick={save} disabled={busy}>Save rate</button>
      </div>
      {err ? <p role="alert" className="mt-2 text-sm text-danger">{err}</p> : null}
    </div>
  );
}

export function DismissButton({ lineId }: { lineId: string }) {
  const router = useRouter();
  async function go() {
    const note = prompt("Why is this acceptable? (for example: promotional rate)");
    if (!note) return;
    const { error } = await createClient().rpc("dismiss_fee_flag", { p_line: lineId, p_note: note });
    if (error) alert(friendlyError(error.message)); else router.refresh();
  }
  return <button className="text-xs text-accent hover:underline" onClick={go}>Accept</button>;
}
