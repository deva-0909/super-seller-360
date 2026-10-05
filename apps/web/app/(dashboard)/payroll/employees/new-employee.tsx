"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn } from "@/components/purchases/bits";

export function NewEmployee() {
  const router = useRouter();
  const supabase = createClient();
  const [f, setF] = useState({ name: "", doj: new Date().toISOString().slice(0, 10), dob: "", pan: "", basic: "", da: "", hra: "", other: "", designation: "" });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function save() {
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("employee_save", { p_id: null, p: { name: f.name, date_of_joining: f.doj, date_of_birth: f.dob || null, pan: f.pan, designation: f.designation } });
    if (error) { setBusy(false); setErr(friendlyError(error.message)); return; }
    const { error: e2 } = await supabase.rpc("employee_set_salary", { p_emp: data, p_from: f.doj, p_basic: Number(f.basic), p_da: Number(f.da || 0), p_hra: Number(f.hra || 0), p_other: Number(f.other || 0) });
    setBusy(false);
    if (e2) { setErr(`Employee saved, but the salary was not: ${friendlyError(e2.message)}`); router.refresh(); return; }
    router.push(`/payroll/employees/${data}`);
  }
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: k === "pan" ? e.target.value.toUpperCase() : e.target.value });
  return (
    <div className="border border-line bg-surface p-4">
      <h2 className="text-sm font-semibold text-ink">Add an employee</h2>
      <div className="mt-3 grid gap-2 md:grid-cols-4">
        <input className={inputCls} placeholder="Full name" value={f.name} onChange={set("name")} />
        <input className={inputCls} placeholder="Designation" value={f.designation} onChange={set("designation")} />
        <label className="text-xs text-ink-muted">Date of joining<input type="date" className={inputCls} value={f.doj} onChange={set("doj")} /></label>
        <label className="text-xs text-ink-muted">Date of birth<input type="date" className={inputCls} value={f.dob} onChange={set("dob")} /></label>
        <input className={inputCls} placeholder="PAN" value={f.pan} onChange={set("pan")} />
        <input className={inputCls} inputMode="decimal" placeholder="Basic (₹ a month)" value={f.basic} onChange={set("basic")} />
        <input className={inputCls} inputMode="decimal" placeholder="Dearness allowance" value={f.da} onChange={set("da")} />
        <input className={inputCls} inputMode="decimal" placeholder="HRA" value={f.hra} onChange={set("hra")} />
        <input className={inputCls} inputMode="decimal" placeholder="Other allowances" value={f.other} onChange={set("other")} />
      </div>
      <button className={`${primaryBtn} mt-3`} disabled={busy || !f.name || !f.basic} onClick={save}>Add employee</button>
      {err ? <p className="mt-2 text-sm text-danger">{err}</p> : null}
    </div>
  );
}
