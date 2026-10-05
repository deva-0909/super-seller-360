import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { PayrollTabs } from "@/components/payroll/tabs";
import { RpcButton, PayForm } from "@/components/payroll/actions";
import { FnfForm } from "./fnf-form";

const ST: Record<string, string> = { draft: "Draft", approved: "Approved, not paid", paid: "Paid", cancelled: "Cancelled" };
type Liab = { emp_id: string; emp_code: string; name: string; date_of_joining: string; years_actual: number; last_wage: number; eligible: boolean; amount_if_left_today: number; months_to_eligible: number };

export default async function ExitsPage({ searchParams }: { searchParams: Promise<{ e?: string; f?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const [{ data: list }, { data: liab }, { data: emps }, { data: canWrite }, { data: canApprove }, { data: banks }] = await Promise.all([
    supabase.from("fnf_settlements").select("*, employees(emp_code, name)").neq("status", "cancelled").order("created_at", { ascending: false }),
    supabase.rpc("gratuity_liability"),
    supabase.from("employees").select("emp_id, emp_code, name, status").order("emp_code"),
    supabase.rpc("has_payroll_write"), supabase.rpc("has_purchase_approve"),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_name").eq("status", "active"),
  ]);
  const sel = (list ?? []).find((r) => r.fnf_id === sp.f);
  const bankOpts = (banks ?? []).map((b) => ({ id: b.bank_account_id, label: `${b.bank_name} ${b.account_name ?? ""}`.trim() }));
  const settled = new Set((list ?? []).map((r) => r.emp_id));
  const startable = (emps ?? []).filter((e) => !settled.has(e.emp_id) && e.status === "active");
  const L = (liab ?? []) as Liab[];
  const totalLiab = L.reduce((s, r) => s + Number(r.amount_if_left_today), 0);
  const today = new Date().toISOString().slice(0, 10);
  const newEmp = sp.e && !sel ? (emps ?? []).find((e) => e.emp_id === sp.e) : null;
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Exits, final settlement and gratuity</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">When someone leaves, work out what is owed: remaining salary days, unused leave, gratuity, bonus, less any notice or advance recovery. A different person approves it, it posts to the books, and then you record the payment. Gratuity is 15 days of basic + DA for each year of service (a part over 6 months counts as a year) after the minimum years set in Settings.</p>
      <div className="mt-4"><PayrollTabs active="/payroll/exits" /></div>
      {canWrite === true ? (
        <form className="flex flex-wrap items-center gap-2">
          <select name="e" className="h-10 rounded-lg border border-line bg-surface px-3 text-sm" defaultValue="">
            <option value="" disabled>Choose who is leaving</option>{startable.map((e) => <option key={e.emp_id} value={e.emp_id}>{e.name} ({e.emp_code})</option>)}
          </select>
          <button className="h-10 rounded-lg border border-line px-4 text-sm font-semibold">Start settlement</button>
        </form>
      ) : null}
      {newEmp ? (<><h2 className="mt-4 text-sm font-semibold text-ink">New settlement for {newEmp.name}</h2><FnfForm empId={newEmp.emp_id} initial={{ fnf_id: null, last_day: today, salary_days: 0, leave_days: null, gratuity_override: null, bonus_amount: 0, other_earning: 0, notice_recovery: 0, other_deduction: 0, tds: 0, note: null }} /></>) : null}
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3 font-medium">Number</th><th className="px-3 py-3 font-medium">Employee</th><th className="px-3 py-3 font-medium">Last day</th><th className="px-3 py-3 text-right font-medium">Net payable</th><th className="px-3 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(list ?? []).map((r) => { const e = r.employees as unknown as { name: string; emp_code: string } | null; return (
              <tr key={r.fnf_id} className="border-b border-line last:border-0"><td className="px-3 py-2"><Link className="text-accent hover:underline" href={`/payroll/exits?f=${r.fnf_id}`}>{r.fnf_no}</Link></td><td className="px-3 py-2">{e?.name} <span className="text-xs text-ink-muted">{e?.emp_code}</span></td><td className="px-3 py-2">{r.last_day}</td><td className="px-3 py-2 text-right font-data">{inr(Number(r.net))}</td><td className="px-3 py-2">{ST[r.status]}{r.paid_on ? ` on ${r.paid_on}` : ""}</td></tr>); })}
            {(list ?? []).length === 0 ? <tr><td colSpan={5} className="px-3 py-6 text-center text-ink-muted">No final settlements yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
      {sel ? (() => { const e = sel.employees as unknown as { name: string }; const rows: [string, number, boolean][] = [["Salary for " + sel.salary_days + " days", Number(sel.salary_amount), false], ["Leave encashment (" + sel.leave_days + " days)", Number(sel.leave_amount), false], ["Gratuity", Number(sel.gratuity_amount), false], ["Bonus", Number(sel.bonus_amount), false], ["Other amount", Number(sel.other_earning), false], ["Notice pay recovery", Number(sel.notice_recovery), true], ["Other recovery", Number(sel.other_deduction), true], ["Tax deducted", Number(sel.tds), true]];
        return (
        <section className="mt-6 border border-line bg-surface p-4">
          <h2 className="text-sm font-semibold text-ink">{sel.fnf_no}: {e?.name}, last day {sel.last_day} ({ST[sel.status]})</h2>
          <table className="mt-2 w-full max-w-md text-sm"><tbody>
            {rows.filter(([, v]) => v !== 0).map(([k, v, minus]) => (<tr key={k} className="border-b border-line"><td className="py-1.5">{k}</td><td className={`py-1.5 text-right font-data ${minus ? "text-danger" : ""}`}>{minus ? "-" : ""}{inr(v)}</td></tr>))}
            <tr><td className="py-2 font-semibold">Net payable</td><td className="py-2 text-right font-data font-semibold">{inr(Number(sel.net))}</td></tr>
          </tbody></table>
          <div className="mt-3 flex flex-wrap items-center gap-3">
            {sel.status === "draft" && canWrite === true ? <RpcButton rpc="fnf_cancel" args={{ p_fnf: sel.fnf_id }} label="Cancel" confirmText="Cancel this settlement?" /> : null}
            {sel.status === "draft" && canApprove === true ? <RpcButton primary rpc="fnf_approve" args={{ p_fnf: sel.fnf_id }} label="Approve and post" confirmText={`Approve ${inr(Number(sel.net))} and post to the books? This also marks the employee as exited and uses up their leave balance.`} /> : null}
            {sel.status === "approved" && canWrite === true ? <PayForm rpc="fnf_pay" idKey="p_fnf" id={sel.fnf_id} banks={bankOpts} label="Record payment" /> : null}
          </div>
          {sel.status === "draft" && canWrite === true ? (<><p className="mt-4 text-xs text-ink-muted">Change the figures:</p><FnfForm empId={sel.emp_id} initial={{ fnf_id: sel.fnf_id, last_day: sel.last_day, salary_days: Number(sel.salary_days), leave_days: Number(sel.leave_days), gratuity_override: Number(sel.gratuity_amount), bonus_amount: Number(sel.bonus_amount), other_earning: Number(sel.other_earning), notice_recovery: Number(sel.notice_recovery), other_deduction: Number(sel.other_deduction), tds: Number(sel.tds), note: sel.note }} /></>) : null}
        </section>); })() : null}
      <section className="mt-8">
        <h2 className="text-sm font-semibold text-ink">Gratuity you would owe if everyone left today: {inr(totalLiab)}</h2>
        <p className="text-xs text-ink-muted">Keep this in mind when planning cash. It is not booked as an expense until a person leaves.</p>
        <div className="mt-2 overflow-x-auto border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3 font-medium">Employee</th><th className="px-3 py-3 font-medium">Joined</th><th className="px-3 py-3 text-right font-medium">Years</th><th className="px-3 py-3 text-right font-medium">Basic + DA</th><th className="px-3 py-3 text-right font-medium">Owed today</th><th className="px-3 py-3 font-medium">Eligible</th></tr></thead>
            <tbody>{L.map((r) => (<tr key={r.emp_id} className="border-b border-line last:border-0"><td className="px-3 py-2">{r.name} <span className="text-xs text-ink-muted">{r.emp_code}</span></td><td className="px-3 py-2">{r.date_of_joining}</td><td className="px-3 py-2 text-right font-data">{r.years_actual}</td><td className="px-3 py-2 text-right font-data">{inr(Number(r.last_wage))}</td><td className="px-3 py-2 text-right font-data">{r.eligible ? inr(Number(r.amount_if_left_today)) : "-"}</td><td className="px-3 py-2 text-xs">{r.eligible ? <span className="text-success">Yes</span> : <span className="text-ink-muted">In about {r.months_to_eligible} month{r.months_to_eligible === 1 ? "" : "s"}</span>}</td></tr>))}</tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
