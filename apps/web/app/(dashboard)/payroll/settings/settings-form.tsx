"use client";

// DEV POINTER: PF, ESI, Gujarat PT, LWF and salary-TDS values are seeded defaults (migration 0076). CA must confirm; LWF notification is old. See docs/DEVELOPER_HANDOVER.md section 2.

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn } from "@/components/purchases/bits";

const GROUPS: { title: string; note?: string; fields: [string, string][] }[] = [
  { title: "Provident fund", fields: [["pf_wage_ceiling", "Wage ceiling (₹)"], ["pf_emp_pct", "Employee share (%)"], ["pf_eps_pct", "Employer pension share (%)"], ["pf_er_total_pct", "Employer total (%)"], ["edli_pct", "EDLI (%)"], ["edli_cap", "EDLI wage cap (₹)"], ["pf_admin_pct", "Admin charge (%)"], ["pf_admin_min", "Admin minimum per month (₹)"]] },
  { title: "ESI", fields: [["esi_ceiling", "Wage ceiling (₹ a month)"], ["esi_emp_pct", "Employee share (%)"], ["esi_er_pct", "Employer share (%)"], ["esi_daily_exempt", "Employee share exempt at daily wage up to (₹)"]] },
  { title: "Gujarat professional tax and labour welfare", note: "Professional tax: nil at or below the threshold. Labour welfare is deducted in June and December. Confirm the current amounts with your CA; the labour welfare notification is old.", fields: [["pt_threshold", "Professional tax: monthly pay above (₹)"], ["pt_amount", "Professional tax a month (₹)"], ["lwf_emp", "Labour welfare: employee (₹)"], ["lwf_er", "Labour welfare: employer (₹)"]] },
  { title: "Salary income tax", fields: [["std_deduction_new", "Standard deduction, new regime (₹)"], ["std_deduction_old", "Standard deduction, old regime (₹)"], ["rebate_new_limit", "Rebate limit, new regime (₹)"], ["rebate_old_limit", "Rebate limit, old regime (₹)"], ["rebate_old_max", "Maximum rebate, old regime (₹)"], ["cess_pct", "Health and education cess (%)"], ["cap_80c", "80C limit (₹)"], ["cap_home_loan", "Home loan interest limit (₹)"]] },
];

export function SettingsForm({ initial, canEdit }: { initial: Record<string, number | boolean>; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [v, setV] = useState<Record<string, string>>(() => Object.fromEntries(GROUPS.flatMap((g) => g.fields.map(([k]) => [k, String(initial[k] ?? "")]))));
  const [code, setCode] = useState(initial.use_code_on_wages === true);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  async function save() {
    setBusy(true); setErr(null); setMsg(null);
    const p: Record<string, number | boolean> = { use_code_on_wages: code };
    for (const [k, x] of Object.entries(v)) p[k] = Number(x);
    const { error } = await supabase.rpc("payroll_settings_save", { p });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg("Settings saved."); router.refresh();
  }
  return (
    <div className="mt-4 space-y-4">
      {GROUPS.map((g) => (
        <div key={g.title} className="border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">{g.title}</h2>
          {g.note ? <p className="mt-1 text-xs text-ink-muted">{g.note}</p> : null}
          <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {g.fields.map(([k, label]) => (<label key={k} className="text-xs text-ink-muted">{label}<input className={inputCls} inputMode="decimal" disabled={!canEdit} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} /></label>))}
          </div>
        </div>
      ))}
      <div className="border border-line bg-surface p-4">
        <label className="flex items-start gap-2 text-sm text-ink"><input type="checkbox" className="mt-1" disabled={!canEdit} checked={code} onChange={(e) => setCode(e.target.checked)} /><span>Treat PF wages as at least 50% of total pay (Code on Wages, in force from 21 November 2025). Untick only if your CA advises a different basis.</span></label>
      </div>
      {canEdit ? <div className="flex items-center gap-3"><button className={primaryBtn} disabled={busy} onClick={save}>Save settings</button>{msg ? <span className="text-sm text-success">{msg}</span> : null}{err ? <span className="text-sm text-danger">{err}</span> : null}</div> : <p className="text-sm text-ink-muted">Only a Finance Manager or Super Admin can change these.</p>}
    </div>
  );
}
