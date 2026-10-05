"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn, primaryBtn } from "@/components/purchases/bits";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export function SettingsPanel({ damp, uplift, canEdit }: { damp: number; uplift: Record<number, number>; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [d, setD] = useState(String(damp));
  const [u, setU] = useState<Record<number, string>>(Object.fromEntries(MONTHS.map((_, i) => [i + 1, String(uplift[i + 1] ?? 0)])));
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  async function save() {
    setBusy(true); setMsg(null);
    const a = await supabase.rpc("forecast_settings_save", { p: { trend_damp: d } });
    if (a.error) { setBusy(false); setMsg(friendlyError(a.error.message)); return; }
    for (let m = 1; m <= 12; m++) {
      const now = Number(u[m] || 0);
      if (now === (uplift[m] ?? 0)) continue;
      const b = await supabase.rpc("forecast_uplift_set", { p_month: m, p_pct: now, p_note: null });
      if (b.error) { setBusy(false); setMsg(`${MONTHS[m - 1]}: ${friendlyError(b.error.message)}`); return; }
    }
    setBusy(false); setMsg("Saved."); router.refresh();
  }
  return (
    <details className="mt-6 border border-line bg-surface p-4">
      <summary className="cursor-pointer text-sm font-semibold text-ink">Season boost and forecast settings</summary>
      <p className="mt-2 max-w-3xl text-xs text-ink-muted">Your shop does not have years of history yet, so the system cannot learn festival months by itself. Enter how much more (or less) you expect to sell in a month, in percent. For example, put 40 against October and November if Diwali lifts your sales by 40%. It is added on top of the forecast for every week in that month.</p>
      <div className="mt-3 grid grid-cols-3 gap-2 sm:grid-cols-6 lg:grid-cols-12">
        {MONTHS.map((m, i) => (
          <label key={m} className="text-xs text-ink-muted">{m}
            <input className={`${inputCls} !h-9`} inputMode="decimal" disabled={!canEdit} value={u[i + 1]} onChange={(e) => setU({ ...u, [i + 1]: e.target.value })} />
          </label>
        ))}
      </div>
      <label className="mt-3 block max-w-xs text-xs text-ink-muted">How much of the recent trend to carry forward (0 = none, 1 = all)
        <input className={`${inputCls} !h-9`} inputMode="decimal" disabled={!canEdit} value={d} onChange={(e) => setD(e.target.value)} />
      </label>
      {canEdit ? <div className="mt-3 flex items-center gap-3"><button className={primaryBtn} disabled={busy} onClick={save}>Save</button>{msg ? <span className="text-sm text-ink-muted">{msg}</span> : null}</div> : <p className="mt-3 text-xs text-ink-muted">Only a Super Admin, Operations Manager or Finance Manager can change these.</p>}
    </details>
  );
}
void smallBtn;
