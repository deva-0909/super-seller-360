import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { PayrollTabs } from "@/components/payroll/tabs";
import { StartRun } from "./start-run";

const STATUS: Record<string, string> = { draft: "Draft", approved: "Approved, not paid", paid: "Paid", cancelled: "Cancelled" };

export default async function PayrollPage() {
  const supabase = await createClient();
  const [{ data: runs }, { data: lines }, { data: canWrite }, { count: empCount }] = await Promise.all([
    supabase.from("payroll_runs").select("run_id, run_no, month, status, paid_on").order("month", { ascending: false }).limit(36),
    supabase.from("payroll_lines").select("run_id, gross, net_pay").limit(5000),
    supabase.rpc("has_payroll_write"),
    supabase.from("employees").select("emp_id", { count: "exact", head: true }).eq("status", "active"),
  ]);
  const tot = new Map<string, { gross: number; net: number; n: number }>();
  for (const l of lines ?? []) { const t = tot.get(l.run_id) ?? { gross: 0, net: 0, n: 0 }; t.gross += Number(l.gross); t.net += Number(l.net_pay); t.n += 1; tot.set(l.run_id, t); }
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Payroll</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Pay your team each month with provident fund, ESI, Gujarat professional tax, labour welfare and salary TDS worked out for you. One person drafts the run, a Finance Manager approves it, then you record the payment and pay the statutory dues. Rates are set in Settings; have your CA confirm them.</p>
      <div className="mt-4"><PayrollTabs active="/payroll" /></div>
      {canWrite === true ? <StartRun hasEmployees={(empCount ?? 0) > 0} /> : null}
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Month</th><th className="px-4 py-3 font-medium">Run</th><th className="px-4 py-3 text-right font-medium">Employees</th><th className="px-4 py-3 text-right font-medium">Gross pay</th><th className="px-4 py-3 text-right font-medium">Net pay</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(runs ?? []).map((r, i) => { const t = tot.get(r.run_id); return (
              <tr key={r.run_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3">{String(r.month).slice(0, 7)}</td>
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/payroll/runs/${r.run_id}`}>{r.run_no}</Link></td>
                <td className="px-4 py-3 text-right font-data">{t?.n ?? 0}</td><td className="px-4 py-3 text-right font-data">{inr(t?.gross ?? 0)}</td><td className="px-4 py-3 text-right font-data">{inr(t?.net ?? 0)}</td>
                <td className="px-4 py-3 text-ink-muted">{STATUS[r.status] ?? r.status}{r.paid_on ? ` on ${r.paid_on}` : ""}</td>
              </tr>); })}
            {(runs ?? []).length === 0 ? <tr><td colSpan={6} className="px-4 py-6 text-ink-muted">No payroll runs yet. Add your employees and their salaries first, then start a run.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
