import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { PayrollTabs } from "@/components/payroll/tabs";
import { NewEmployee } from "./new-employee";

export default async function EmployeesPage() {
  const supabase = await createClient();
  const [{ data: emps }, { data: sal }, { data: canWrite }] = await Promise.all([
    supabase.from("employees").select("emp_id, emp_code, name, designation, department, date_of_joining, date_of_leaving, status, pan, uan").order("emp_code"),
    supabase.from("employee_salary").select("emp_id, effective_from, total").order("effective_from", { ascending: false }),
    supabase.rpc("has_payroll_write"),
  ]);
  const cur = new Map<string, number>();
  for (const s of sal ?? []) if (!cur.has(s.emp_id)) cur.set(s.emp_id, Number(s.total));
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Employees</h1>
      <div className="mt-4"><PayrollTabs active="/payroll/employees" /></div>
      {canWrite === true ? <NewEmployee /> : null}
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Code</th><th className="px-4 py-3 font-medium">Name</th><th className="px-4 py-3 font-medium">Role</th><th className="px-4 py-3 font-medium">Joined</th><th className="px-4 py-3 text-right font-medium">Monthly pay</th><th className="px-4 py-3 font-medium">PAN / UAN</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(emps ?? []).map((e, i) => (
              <tr key={e.emp_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 font-data">{e.emp_code}</td><td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/payroll/employees/${e.emp_id}`}>{e.name}</Link></td>
                <td className="px-4 py-3 text-ink-muted">{[e.designation, e.department].filter(Boolean).join(", ")}</td><td className="px-4 py-3 text-ink-muted">{e.date_of_joining}</td>
                <td className="px-4 py-3 text-right font-data">{cur.has(e.emp_id) ? inr(cur.get(e.emp_id)!) : <span className="text-warning">No salary</span>}</td>
                <td className="px-4 py-3 font-data text-xs text-ink-muted">{e.pan ?? "no PAN"} / {e.uan ?? "no UAN"}</td><td className="px-4 py-3 text-ink-muted">{e.status}{e.date_of_leaving ? ` (${e.date_of_leaving})` : ""}</td>
              </tr>
            ))}
            {(emps ?? []).length === 0 ? <tr><td colSpan={7} className="px-4 py-6 text-ink-muted">No employees yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
