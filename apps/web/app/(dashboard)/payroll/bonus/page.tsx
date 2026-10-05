import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { PayrollTabs } from "@/components/payroll/tabs";
import { RpcButton, PayForm } from "@/components/payroll/actions";
import { NewBonus, LineEdit, PctForm } from "./bonus-bits";

type Line = { line_id: string; days_worked: number; months: number; bonus_wage: number; computed: number; amount: number; tds: number; note: string | null; eligible: boolean; reason: string | null; employees: { emp_code: string; name: string } | null };
const ST: Record<string, string> = { draft: "Draft", approved: "Approved, not paid", paid: "Paid", cancelled: "Cancelled" };

export default async function BonusPage({ searchParams }: { searchParams: Promise<{ b?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const now = new Date();
  const fyNow = now.getMonth() >= 3 ? now.getFullYear() : now.getFullYear() - 1;
  const [{ data: runs }, { data: canWrite }, { data: canApprove }, { data: banks }] = await Promise.all([
    supabase.from("bonus_runs").select("bonus_id, bonus_no, fy, status, pct, paid_on, created_by").order("fy", { ascending: false }),
    supabase.rpc("has_payroll_write"), supabase.rpc("has_purchase_approve"),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_name").eq("status", "active"),
  ]);
  const sel = (runs ?? []).find((r) => r.bonus_id === sp.b);
  const { data: lines } = sel ? await supabase.from("bonus_lines").select("line_id, days_worked, months, bonus_wage, computed, amount, tds, note, eligible, reason, employees(emp_code, name)").eq("bonus_id", sel.bonus_id) : { data: null };
  const rows = ((lines ?? []) as unknown as Line[]).sort((a, b) => (a.employees?.emp_code ?? "").localeCompare(b.employees?.emp_code ?? ""));
  const tot = rows.reduce((s, r) => s + Number(r.amount), 0), totTds = rows.reduce((s, r) => s + Number(r.tds), 0);
  const bankOpts = (banks ?? []).map((b) => ({ id: b.bank_account_id, label: `${b.bank_name} ${b.account_name ?? ""}`.trim() }));
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Statutory bonus</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Yearly bonus under the Payment of Bonus Act (now Code on Wages). It is worked out from your approved pay runs for the year: the rate on basic + DA, up to a monthly ceiling, for people within the pay limit who worked the minimum days. All four numbers are on the Settings tab. Have your CA confirm them. Bonus is taxable salary: enter the tax to deduct for each person if any.</p>
      <div className="mt-4"><PayrollTabs active="/payroll/bonus" /></div>
      {canWrite === true ? <NewBonus defaultFy={fyNow - 1} /> : null}
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3 font-medium">Number</th><th className="px-3 py-3 font-medium">Year</th><th className="px-3 py-3 text-right font-medium">Rate</th><th className="px-3 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(runs ?? []).map((r) => (<tr key={r.bonus_id} className="border-b border-line last:border-0"><td className="px-3 py-2"><Link className="text-accent hover:underline" href={`/payroll/bonus?b=${r.bonus_id}`}>{r.bonus_no}</Link></td><td className="px-3 py-2">{r.fy}-{String(r.fy + 1).slice(2)}</td><td className="px-3 py-2 text-right font-data">{r.pct}%</td><td className="px-3 py-2">{ST[r.status] ?? r.status}{r.paid_on ? ` on ${r.paid_on}` : ""}</td></tr>))}
            {(runs ?? []).length === 0 ? <tr><td colSpan={4} className="px-3 py-6 text-center text-ink-muted">No bonus prepared yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
      {sel ? (
        <section className="mt-6">
          <h2 className="text-sm font-semibold text-ink">{sel.bonus_no}: FY {sel.fy}-{String(sel.fy + 1).slice(2)}, {ST[sel.status]}</h2>
          <div className="mt-2 flex flex-wrap items-center gap-3">
            {sel.status === "draft" && canWrite === true ? <PctForm bonusId={sel.bonus_id} pct={Number(sel.pct)} /> : null}
            {sel.status === "draft" && canWrite === true ? <RpcButton rpc="bonus_cancel" args={{ p_bonus: sel.bonus_id }} label="Cancel this bonus" confirmText="Cancel this bonus?" /> : null}
            {sel.status === "draft" && canApprove === true ? <RpcButton primary rpc="bonus_approve" args={{ p_bonus: sel.bonus_id }} label="Approve and post" confirmText={`Approve bonus of ${inr(tot)} and post it to the books?`} /> : null}
            {sel.status === "approved" && canWrite === true ? <PayForm rpc="bonus_pay" idKey="p_bonus" id={sel.bonus_id} banks={bankOpts} label="Record payment" /> : null}
          </div>
          <p className="mt-2 text-sm text-ink">Total bonus {inr(tot)}, tax to deduct {inr(totTds)}, to pay {inr(tot - totTds)}.</p>
          <div className="mt-2 overflow-x-auto border border-line bg-surface">
            <table className="w-full text-left text-sm">
              <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3 font-medium">Employee</th><th className="px-3 py-3 text-right font-medium">Days worked</th><th className="px-3 py-3 text-right font-medium">Wage counted</th><th className="px-3 py-3 text-right font-medium">Calculated</th><th className="px-3 py-3 text-right font-medium">Bonus</th><th className="px-3 py-3 text-right font-medium">Tax</th><th className="px-3 py-3 font-medium">Note</th><th /></tr></thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.line_id} className="border-b border-line align-top last:border-0">
                    <td className="px-3 py-2">{r.employees?.name}<div className="text-xs text-ink-muted">{r.employees?.emp_code}</div></td>
                    <td className="px-3 py-2 text-right font-data">{r.days_worked}</td><td className="px-3 py-2 text-right font-data">{inr(Number(r.bonus_wage))}</td><td className="px-3 py-2 text-right font-data">{inr(Number(r.computed))}</td>
                    <td className="px-3 py-2 text-right font-data font-semibold">{inr(Number(r.amount))}</td><td className="px-3 py-2 text-right font-data">{Number(r.tds) ? inr(Number(r.tds)) : "-"}</td>
                    <td className="px-3 py-2 text-xs text-ink-muted">{!r.eligible ? r.reason : r.note}</td>
                    <td className="px-3 py-2 text-right">{sel.status === "draft" && canWrite === true ? <LineEdit lineId={r.line_id} amount={Number(r.amount)} tds={Number(r.tds)} note={r.note} computed={Number(r.computed)} /> : null}</td>
                  </tr>))}
              </tbody>
            </table>
          </div>
        </section>
      ) : null}
    </div>
  );
}
