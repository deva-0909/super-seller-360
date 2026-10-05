"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn, primaryBtn } from "@/components/purchases/bits";

export function NewBonus({ defaultFy }: { defaultFy: number }) {
  const router = useRouter();
  const supabase = createClient();
  const [fy, setFy] = useState(String(defaultFy));
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function go() {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("bonus_create", { p_fy: Number(fy) });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/payroll/bonus?b=${data}`);
  }
  return (
    <div className="mt-4 flex flex-wrap items-center gap-2">
      <label className="text-sm text-ink-muted">Year starting April</label>
      <input className={`${inputCls} !w-28`} inputMode="numeric" value={fy} onChange={(e) => setFy(e.target.value)} />
      <button className={primaryBtn} disabled={busy} onClick={go}>Prepare bonus</button>
      {err ? <span className="text-sm text-danger">{err}</span> : null}
    </div>
  );
}

export function LineEdit({ lineId, amount, tds, note, computed }: { lineId: string; amount: number; tds: number; note: string | null; computed: number }) {
  const router = useRouter();
  const supabase = createClient();
  const [open, setOpen] = useState(false);
  const [a, setA] = useState(String(amount)); const [t, setT] = useState(String(tds)); const [n, setN] = useState(note ?? "");
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setErr(null);
    const { error } = await supabase.rpc("bonus_line_set", { p_line: lineId, p_amount: Number(a), p_tds: Number(t || 0), p_note: n });
    if (error) { setErr(friendlyError(error.message)); return; }
    setOpen(false); router.refresh();
  }
  if (!open) return <button className="text-xs text-accent hover:underline" onClick={() => setOpen(true)}>Change</button>;
  return (
    <div className="flex flex-wrap items-center gap-1">
      <input className={`${inputCls} !h-8 !w-24`} inputMode="decimal" value={a} onChange={(e) => setA(e.target.value)} title={`Calculated: ${computed}`} />
      <input className={`${inputCls} !h-8 !w-20`} inputMode="decimal" placeholder="Tax" value={t} onChange={(e) => setT(e.target.value)} />
      <input className={`${inputCls} !h-8 !w-40`} placeholder="Why changed" value={n} onChange={(e) => setN(e.target.value)} />
      <button className={`${smallBtn} !h-8`} onClick={save}>Save</button>
      {err ? <span className="text-xs text-danger">{err}</span> : null}
    </div>
  );
}

export function PctForm({ bonusId, pct }: { bonusId: string; pct: number }) {
  const router = useRouter();
  const supabase = createClient();
  const [p, setP] = useState(String(pct));
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    setErr(null);
    const { error } = await supabase.rpc("bonus_recalculate", { p_bonus: bonusId, p_pct: Number(p) });
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (<span className="inline-flex items-center gap-2 text-sm text-ink-muted">Bonus rate (%)<input className={`${inputCls} !h-9 !w-20`} inputMode="decimal" value={p} onChange={(e) => setP(e.target.value)} /><button className={smallBtn} onClick={go}>Recalculate</button>{err ? <span className="text-xs text-danger">{err}</span> : null}</span>);
}
