"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn } from "@/components/purchases/bits";

export function AccrueForm() {
  const router = useRouter();
  const supabase = createClient();
  const [m, setM] = useState(new Date().toISOString().slice(0, 7));
  const [msg, setMsg] = useState<string | null>(null);
  async function go() {
    setMsg(null);
    const { data, error } = await supabase.rpc("leave_accrue", { p_month: `${m}-01` });
    if (error) { setMsg(friendlyError(error.message)); return; }
    setMsg(`Added for ${data} employee${data === 1 ? "" : "s"}.`); router.refresh();
  }
  return (<div className="flex flex-wrap items-center gap-2"><input type="month" className={`${inputCls} !w-44`} value={m} onChange={(e) => setM(e.target.value)} /><button className={smallBtn} onClick={go}>Add earned leave for the month</button>{msg ? <span className="text-sm text-ink-muted">{msg}</span> : null}</div>);
}

export function RecordLeave({ emps }: { emps: { id: string; label: string }[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [f, setF] = useState({ emp: emps[0]?.id ?? "", kind: "taken", days: "", date: new Date().toISOString().slice(0, 10), note: "" });
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    setErr(null);
    const { error } = await supabase.rpc("leave_record", { p_emp: f.emp, p_kind: f.kind, p_days: Number(f.days), p_date: f.date, p_note: f.note });
    if (error) { setErr(friendlyError(error.message)); return; }
    setF({ ...f, days: "", note: "" }); router.refresh();
  }
  return (
    <div className="flex flex-wrap items-center gap-2">
      <select className={`${inputCls} !w-52`} value={f.emp} onChange={(e) => setF({ ...f, emp: e.target.value })}>{emps.map((e) => <option key={e.id} value={e.id}>{e.label}</option>)}</select>
      <select className={`${inputCls} !w-44`} value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="taken">Leave taken</option><option value="adjust">Correct balance (+ or -)</option></select>
      <input className={`${inputCls} !w-24`} inputMode="decimal" placeholder="Days" value={f.days} onChange={(e) => setF({ ...f, days: e.target.value })} />
      <input type="date" className={`${inputCls} !w-40`} value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} />
      <input className={`${inputCls} !w-48`} placeholder="Note (needed for a correction)" value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} />
      <button className={smallBtn} onClick={go}>Save</button>
      {err ? <span className="text-sm text-danger">{err}</span> : null}
    </div>
  );
}
