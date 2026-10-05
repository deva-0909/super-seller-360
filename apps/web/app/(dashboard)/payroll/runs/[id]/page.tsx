import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { PayrollTabs } from "@/components/payroll/tabs";
import { RunTable, type Line } from "./run-table";
import { RunActions } from "./run-actions";

const STATUS: Record<string, string> = { draft: "Draft", approved: "Approved, not paid", paid: "Paid", cancelled: "Cancelled" };

export default async function RunPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const [{ data: run }, { data: lines }, { data: canWrite }, { data: canApprove }, { data: banks }] = await Promise.all([
    supabase.from("payroll_runs").select("run_id, run_no, month, status, paid_on, pay_reference, pf_admin_topup, created_by").eq("run_id", id).maybeSingle(),
    supabase.from("payroll_lines").select("line_id, paid_days, lop_days, gross, extra_earning, extra_is_wage, extra_note, pf_ee, pf_eps, pf_epf, edli, pf_admin, esi_ee, esi_er, pt, lwf_ee, lwf_er, tds, other_ded, ded_note, net_pay, employees(emp_code, name)").eq("run_id", id),
    supabase.rpc("has_payroll_write"),
    supabase.rpc("has_purchase_approve"),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_name").eq("status", "active"),
  ]);
  if (!run) notFound();
  const rows = ((lines ?? []) as unknown as (Omit<Line, "emp"> & { employees: { emp_code: string; name: string } | null })[])
    .map((l) => ({ ...l, emp: l.employees ?? { emp_code: "", name: "" } }))
    .sort((a, b) => a.emp.emp_code.localeCompare(b.emp.emp_code)) as Line[];
  const sum = (k: keyof Line) => rows.reduce((s, r) => s + Number(r[k] ?? 0), 0);
  const pfTotal = sum("pf_ee") + sum("pf_eps") + sum("pf_epf") + sum("edli") + sum("pf_admin") + Number(run.pf_admin_topup);
  const cards: [string, number][] = [["Gross pay", sum("gross")], ["Net pay to employees", sum("net_pay")], ["PF to deposit", pfTotal], ["ESI to deposit", sum("esi_ee") + sum("esi_er")], ["Professional tax", sum("pt")], ["Salary TDS", sum("tds")], ["Labour welfare", sum("lwf_ee") + sum("lwf_er")]];
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/payroll" className="text-sm text-accent hover:underline">← Pay runs</Link>
      <h1 className="mt-1 text-lg font-semibold tracking-tight text-ink">Payroll {String(run.month).slice(0, 7)} <span className="font-data text-sm text-ink-muted">{run.run_no}</span></h1>
      <p className="text-sm text-ink-muted">{STATUS[run.status] ?? run.status}{run.paid_on ? ` on ${run.paid_on}` : ""}{run.pay_reference ? `, ref ${run.pay_reference}` : ""}</p>
      <div className="mt-4"><PayrollTabs active="/payroll" /></div>
      <div className="mt-4 grid grid-cols-2 gap-2 md:grid-cols-4 lg:grid-cols-7">
        {cards.map(([k, v]) => (<div key={k} className="border border-line bg-surface p-3"><div className="text-xs text-ink-muted">{k}</div><div className="font-data text-sm text-ink">{inr(v)}</div></div>))}
      </div>
      <RunActions runId={run.run_id} status={run.status} month={String(run.month).slice(0, 7)} canWrite={canWrite === true} canApprove={canApprove === true}
        banks={(banks ?? []).map((b) => ({ id: b.bank_account_id, label: `${b.bank_name} ${b.account_name ?? ""}`.trim() }))} />
      <RunTable runId={run.run_id} rows={rows} editable={run.status === "draft" && canWrite === true} />
    </div>
  );
}
