"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn } from "@/components/purchases/bits";

export type Fnf = { fnf_id: string | null; last_day: string; salary_days: number; leave_days: number | null; gratuity_override: number | null; bonus_amount: number; other_earning: number; notice_recovery: number; other_deduction: number; tds: number; note: string | null };

export function FnfForm({ empId, initial }: { empId: string; initial: Fnf }) {
  const router = useRouter();
  const supabase = createClient();
  const [v, setV] = useState({ last_day: initial.last_day, salary_days: String(initial.salary_days), leave_days: initial.leave_days == null ? "" : String(initial.leave_days), gratuity_override: initial.gratuity_override == null ? "" : String(initial.gratuity_override),
    bonus_amount: String(initial.bonus_amount), other_earning: String(initial.other_earning), notice_recovery: String(initial.notice_recovery), other_deduction: String(initial.other_deduction), tds: String(initial.tds), note: initial.note ?? "" });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const f = (k: keyof typeof v, label: string, hint?: string, type = "decimal") => (
    <label className="text-xs text-ink-muted">{label}
      <input className={inputCls} inputMode={type === "date" ? undefined : "decimal"} type={type === "date" ? "date" : "text"} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} />
      {hint ? <span className="text-[11px]">{hint}</span> : null}
    </label>
  );
  async function save() {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("fnf_save", { p_fnf: initial.fnf_id, p_emp: empId, p: v });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.push(`/payroll/exits?f=${data}`); router.refresh();
  }
  return (
    <div className="mt-3 border border-line bg-surface p-4">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {f("last_day", "Last working day", undefined, "date")}
        {f("salary_days", "Salary days not in any pay run", "Put the full months through a normal pay run first (it takes care of PF, ESI, PT). Use this only for the days left over.")}
        {f("leave_days", "Leave days to pay out", "Leave empty to pay the whole balance (up to the limit).")}
        {f("gratuity_override", "Gratuity (₹)", "Leave empty to use the calculated amount.")}
        {f("bonus_amount", "Bonus due (₹)")}{f("other_earning", "Other amount to pay (₹)")}{f("notice_recovery", "Notice pay recovery (₹)")}{f("other_deduction", "Other recovery, e.g. advance (₹)")}
        {f("tds", "Tax to deduct (₹)", "Leave encashment and gratuity are tax free up to the limits; tax applies to the rest. Check with your CA.")}
        <label className="text-xs text-ink-muted sm:col-span-3">Note<input className={inputCls} value={v.note} onChange={(e) => setV({ ...v, note: e.target.value })} /></label>
      </div>
      <div className="mt-3 flex items-center gap-3"><button className={primaryBtn} disabled={busy} onClick={save}>Save and calculate</button>{err ? <span className="text-sm text-danger">{err}</span> : null}</div>
    </div>
  );
}
