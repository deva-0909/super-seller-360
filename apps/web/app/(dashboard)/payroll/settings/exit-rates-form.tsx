"use client";

// DEV POINTER: bonus, gratuity and leave rates are seeded defaults (migration 0080). They must be confirmed by the CA / labour consultant. See docs/DEVELOPER_HANDOVER.md section 2.

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn } from "@/components/purchases/bits";

const GROUPS: { title: string; note: string; fields: [string, string][] }[] = [
  { title: "Statutory bonus", note: "The Act allows 8.33% to 20%. Bonus is worked out on basic + DA up to the ceiling below (or the state minimum wage if that is higher: enter it here). Confirm all four with your CA.", fields: [["bonus_pct", "Bonus rate (%)"], ["bonus_eligible_wage", "Not eligible if basic + DA above (₹ a month)"], ["bonus_calc_cap", "Wage ceiling for the calculation (₹ a month)"], ["bonus_min_days", "Minimum days worked in the year"]] },
  { title: "Gratuity", note: "15 days of basic + DA for each year, divided by 26. Five years of service is the usual rule; the new labour code gives fixed-term staff gratuity after one year, so set 1 if all your staff are fixed-term.", fields: [["gratuity_days", "Days of wage per year"], ["gratuity_divisor", "Days in a month used"], ["gratuity_min_years", "Minimum years of service"], ["gratuity_cap", "Most payable (₹)"]] },
  { title: "Leave", note: "Earned leave added every month, and how a day's pay is worked out at exit.", fields: [["leave_per_month", "Earned leave a month (days)"], ["leave_divisor", "Days in a month used for a day's pay"], ["leave_encash_cap", "Most days paid out at exit"]] },
];

export function ExitRatesForm({ initial, canEdit }: { initial: Record<string, number>; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [v, setV] = useState<Record<string, string>>(() => Object.fromEntries(GROUPS.flatMap((g) => g.fields.map(([k]) => [k, String(initial[k] ?? "")]))));
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  async function save() {
    setErr(null); setMsg(null);
    const { error } = await supabase.rpc("payroll_exit_settings_save", { p: v });
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg("Saved."); router.refresh();
  }
  return (
    <div className="mt-6 space-y-4">
      <h2 className="text-base font-semibold text-ink">Bonus, gratuity and leave</h2>
      {GROUPS.map((g) => (
        <div key={g.title} className="border border-line bg-surface p-4">
          <h3 className="text-sm font-semibold text-ink">{g.title}</h3><p className="mt-1 text-xs text-ink-muted">{g.note}</p>
          <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{g.fields.map(([k, l]) => (<label key={k} className="text-xs text-ink-muted">{l}<input className={inputCls} inputMode="decimal" disabled={!canEdit} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} /></label>))}</div>
        </div>
      ))}
      {canEdit ? <div className="flex items-center gap-3"><button className={primaryBtn} onClick={save}>Save these rates</button>{msg ? <span className="text-sm text-success">{msg}</span> : null}{err ? <span className="text-sm text-danger">{err}</span> : null}</div> : null}
    </div>
  );
}
