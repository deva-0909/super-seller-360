"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

export type Emp = { emp_id: string; name: string; gender: string | null; date_of_birth: string | null; date_of_joining: string; date_of_leaving: string | null; pan: string | null; uan: string | null; esic_no: string | null; designation: string | null; department: string | null; email: string | null; phone: string | null; pf_applicable: boolean; pf_on_actual: boolean; esi_applicable: boolean; pt_applicable: boolean; lwf_applicable: boolean; status: string };
export type Sal = { effective_from: string; basic: number; da: number; hra: number; other_allowance: number; total: number };
export type Bank = { bank_name: string; ifsc: string; account_number: string; account_holder: string };
export type Decl = { regime: string; ded_80c: number; ded_80d: number; hra_exempt: number; home_loan_interest: number; other_deductions: number; prev_income: number; prev_tds: number };

export function EmployeeForms({ emp, salary, bank, decl, fy, canWrite }: { emp: Emp; salary: Sal[]; bank: Bank | null; decl: Decl | null; fy: number; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [e, setE] = useState({ ...emp, name: emp.name, dob: emp.date_of_birth ?? "", pan: emp.pan ?? "", uan: emp.uan ?? "", esic: emp.esic_no ?? "", designation: emp.designation ?? "", department: emp.department ?? "", email: emp.email ?? "", phone: emp.phone ?? "" });
  const cur = salary[0];
  const [s, setS] = useState({ from: new Date().toISOString().slice(0, 10), basic: String(cur?.basic ?? ""), da: String(cur?.da ?? 0), hra: String(cur?.hra ?? 0), other: String(cur?.other_allowance ?? 0) });
  const [b, setB] = useState({ bank: bank?.bank_name ?? "", ifsc: bank?.ifsc ?? "", acct: bank?.account_number ?? "", holder: bank?.account_holder ?? emp.name });
  const [d, setD] = useState({ regime: decl?.regime ?? "new", c80: String(decl?.ded_80c ?? 0), d80: String(decl?.ded_80d ?? 0), hra: String(decl?.hra_exempt ?? 0), home: String(decl?.home_loan_interest ?? 0), other: String(decl?.other_deductions ?? 0), pinc: String(decl?.prev_income ?? 0), ptds: String(decl?.prev_tds ?? 0) });
  const [leave, setLeave] = useState(emp.date_of_leaving ?? "");

  async function run(fn: () => PromiseLike<{ error: { message: string } | null }>, ok: string) {
    setBusy(true); setErr(null); setMsg(null);
    const { error } = await fn();
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(ok); router.refresh();
  }
  const sec = "border border-line bg-surface p-4";
  const chk = (k: "pf_applicable" | "pf_on_actual" | "esi_applicable" | "pt_applicable" | "lwf_applicable", label: string) => (
    <label className="flex items-center gap-2 text-sm text-ink"><input type="checkbox" disabled={!canWrite} checked={e[k]} onChange={(ev) => setE({ ...e, [k]: ev.target.checked })} />{label}</label>
  );
  return (
    <div className="mt-4 grid gap-4 lg:grid-cols-2">
      <div className={sec}>
        <h2 className="text-sm font-semibold text-ink">Details</h2>
        <div className="mt-3 grid grid-cols-2 gap-2">
          <input className={`${inputCls} col-span-2`} disabled={!canWrite} value={e.name} onChange={(x) => setE({ ...e, name: x.target.value })} />
          <input className={inputCls} disabled={!canWrite} placeholder="Designation" value={e.designation} onChange={(x) => setE({ ...e, designation: x.target.value })} />
          <input className={inputCls} disabled={!canWrite} placeholder="Department" value={e.department} onChange={(x) => setE({ ...e, department: x.target.value })} />
          <input className={inputCls} disabled={!canWrite} placeholder="PAN" value={e.pan} onChange={(x) => setE({ ...e, pan: x.target.value.toUpperCase() })} />
          <input className={inputCls} disabled={!canWrite} placeholder="UAN (12 digits)" value={e.uan} onChange={(x) => setE({ ...e, uan: x.target.value })} />
          <input className={inputCls} disabled={!canWrite} placeholder="ESIC number" value={e.esic} onChange={(x) => setE({ ...e, esic: x.target.value })} />
          <select className={inputCls} disabled={!canWrite} value={e.gender ?? ""} onChange={(x) => setE({ ...e, gender: x.target.value || null })}><option value="">Gender</option><option value="male">Male</option><option value="female">Female</option><option value="other">Other</option></select>
          <label className="text-xs text-ink-muted">Date of birth<input type="date" className={inputCls} disabled={!canWrite} value={e.dob} onChange={(x) => setE({ ...e, dob: x.target.value })} /></label>
          <label className="text-xs text-ink-muted">Date of joining<input type="date" className={inputCls} disabled={!canWrite} value={e.date_of_joining} onChange={(x) => setE({ ...e, date_of_joining: x.target.value })} /></label>
        </div>
        <div className="mt-3 space-y-1">
          {chk("pf_applicable", "Provident fund applies")}{chk("pf_on_actual", "PF on full basic (not capped at the ₹15,000 ceiling)")}{chk("esi_applicable", "ESI applies when pay is within the ceiling")}{chk("pt_applicable", "Gujarat professional tax applies")}{chk("lwf_applicable", "Labour welfare fund applies")}
        </div>
        {canWrite ? <button className={`${primaryBtn} mt-3`} disabled={busy} onClick={() => run(() => supabase.rpc("employee_save", { p_id: emp.emp_id, p: { name: e.name, gender: e.gender, date_of_birth: e.dob || null, date_of_joining: e.date_of_joining, pan: e.pan, uan: e.uan, esic_no: e.esic, designation: e.designation, department: e.department, email: e.email, phone: e.phone, pf_applicable: e.pf_applicable, pf_on_actual: e.pf_on_actual, esi_applicable: e.esi_applicable, pt_applicable: e.pt_applicable, lwf_applicable: e.lwf_applicable } }), "Details saved.")}>Save details</button> : null}
      </div>

      <div className="space-y-4">
        <div className={sec}>
          <h2 className="text-sm font-semibold text-ink">Salary (a month)</h2>
          <table className="mt-2 w-full text-left text-xs"><thead><tr className="text-ink-muted"><th className="py-1 font-medium">From</th><th className="font-medium">Basic</th><th className="font-medium">DA</th><th className="font-medium">HRA</th><th className="font-medium">Other</th><th className="text-right font-medium">Total</th></tr></thead>
            <tbody>{salary.map((x) => <tr key={x.effective_from}><td className="py-1">{x.effective_from}</td><td className="font-data">{inr(Number(x.basic))}</td><td className="font-data">{inr(Number(x.da))}</td><td className="font-data">{inr(Number(x.hra))}</td><td className="font-data">{inr(Number(x.other_allowance))}</td><td className="text-right font-data">{inr(Number(x.total))}</td></tr>)}</tbody></table>
          {canWrite ? <>
            <div className="mt-3 grid grid-cols-5 gap-2">
              <input type="date" className={`${inputCls} col-span-2`} value={s.from} onChange={(x) => setS({ ...s, from: x.target.value })} />
              <input className={inputCls} inputMode="decimal" placeholder="Basic" value={s.basic} onChange={(x) => setS({ ...s, basic: x.target.value })} />
              <input className={inputCls} inputMode="decimal" placeholder="DA" value={s.da} onChange={(x) => setS({ ...s, da: x.target.value })} />
              <input className={inputCls} inputMode="decimal" placeholder="HRA" value={s.hra} onChange={(x) => setS({ ...s, hra: x.target.value })} />
              <input className={`${inputCls} col-span-2`} inputMode="decimal" placeholder="Other allowances" value={s.other} onChange={(x) => setS({ ...s, other: x.target.value })} />
            </div>
            <button className={`${smallBtn} mt-2`} disabled={busy} onClick={() => run(() => supabase.rpc("employee_set_salary", { p_emp: emp.emp_id, p_from: s.from, p_basic: Number(s.basic), p_da: Number(s.da || 0), p_hra: Number(s.hra || 0), p_other: Number(s.other || 0) }), "Salary saved.")}>Save salary change</button></> : null}
        </div>

        {canWrite ? (
          <div className={sec}>
            <h2 className="text-sm font-semibold text-ink">Bank account (for the salary file)</h2>
            <div className="mt-3 grid grid-cols-2 gap-2">
              <input className={inputCls} placeholder="Bank" value={b.bank} onChange={(x) => setB({ ...b, bank: x.target.value })} /><input className={inputCls} placeholder="IFSC" value={b.ifsc} onChange={(x) => setB({ ...b, ifsc: x.target.value.toUpperCase() })} />
              <input className={inputCls} placeholder="Account number" value={b.acct} onChange={(x) => setB({ ...b, acct: x.target.value })} /><input className={inputCls} placeholder="Name on account" value={b.holder} onChange={(x) => setB({ ...b, holder: x.target.value })} />
            </div>
            <button className={`${smallBtn} mt-2`} disabled={busy} onClick={() => run(() => supabase.rpc("employee_set_bank", { p_emp: emp.emp_id, p_bank: b.bank, p_ifsc: b.ifsc, p_account: b.acct, p_holder: b.holder }), "Bank details saved.")}>Save bank details</button>
          </div>
        ) : null}

        <div className={sec}>
          <h2 className="text-sm font-semibold text-ink">Income tax choices, FY {fy}-{String(fy + 1).slice(2)}</h2>
          <p className="mt-1 text-xs text-ink-muted">The new regime is the default. Under the old regime the amounts below reduce the tax deducted from salary. Enter the totals the employee has declared for the year.</p>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <select className={`${inputCls} col-span-2`} disabled={!canWrite} value={d.regime} onChange={(x) => setD({ ...d, regime: x.target.value })}><option value="new">New regime (default)</option><option value="old">Old regime</option></select>
            {d.regime === "old" ? <>
              <input className={inputCls} disabled={!canWrite} inputMode="decimal" placeholder="80C investments (max 1,50,000)" value={d.c80} onChange={(x) => setD({ ...d, c80: x.target.value })} />
              <input className={inputCls} disabled={!canWrite} inputMode="decimal" placeholder="Health insurance (80D)" value={d.d80} onChange={(x) => setD({ ...d, d80: x.target.value })} />
              <input className={inputCls} disabled={!canWrite} inputMode="decimal" placeholder="HRA exemption" value={d.hra} onChange={(x) => setD({ ...d, hra: x.target.value })} />
              <input className={inputCls} disabled={!canWrite} inputMode="decimal" placeholder="Home loan interest (max 2,00,000)" value={d.home} onChange={(x) => setD({ ...d, home: x.target.value })} />
              <input className={`${inputCls} col-span-2`} disabled={!canWrite} inputMode="decimal" placeholder="Other deductions" value={d.other} onChange={(x) => setD({ ...d, other: x.target.value })} /></> : null}
            <input className={inputCls} disabled={!canWrite} inputMode="decimal" placeholder="Salary from a previous employer this year" value={d.pinc} onChange={(x) => setD({ ...d, pinc: x.target.value })} />
            <input className={inputCls} disabled={!canWrite} inputMode="decimal" placeholder="Tax already deducted by them" value={d.ptds} onChange={(x) => setD({ ...d, ptds: x.target.value })} />
          </div>
          {canWrite ? <button className={`${smallBtn} mt-2`} disabled={busy} onClick={() => run(() => supabase.rpc("employee_set_declaration", { p_emp: emp.emp_id, p_fy: fy, p_regime: d.regime, p_80c: Number(d.c80 || 0), p_80d: Number(d.d80 || 0), p_hra: Number(d.hra || 0), p_home: Number(d.home || 0), p_other: Number(d.other || 0), p_prev_income: Number(d.pinc || 0), p_prev_tds: Number(d.ptds || 0) }), "Tax choices saved. They apply from the next payroll calculation.")}>Save tax choices</button> : null}
        </div>

        {canWrite ? (
          <div className={sec}>
            <h2 className="text-sm font-semibold text-ink">Leaving</h2>
            <div className="mt-2 flex gap-2"><input type="date" className={inputCls} value={leave} onChange={(x) => setLeave(x.target.value)} /><button className={smallBtn} disabled={busy || !leave} onClick={() => run(() => supabase.rpc("employee_exit", { p_emp: emp.emp_id, p_date: leave }), "Last working day recorded.")}>Record last day</button></div>
          </div>
        ) : null}
        {err ? <p className="text-sm text-danger">{err}</p> : null}{msg ? <p className="text-sm text-ink">{msg}</p> : null}
      </div>
    </div>
  );
}
