import { createClient } from "@/lib/supabase/server";
import { PayrollTabs } from "@/components/payroll/tabs";
import { AccrueForm, RecordLeave } from "./leave-forms";

type Bal = { emp_id: string; emp_code: string; name: string; status: string; balance: number; earned: number; taken: number; encashed: number };

export default async function LeavePage() {
  const supabase = await createClient();
  const [{ data }, { data: canWrite }, { data: set }] = await Promise.all([
    supabase.from("leave_balances").select("*").order("emp_code"),
    supabase.rpc("has_payroll_write"),
    supabase.from("payroll_exit_settings").select("leave_per_month, leave_encash_cap").eq("id", 1).maybeSingle(),
  ]);
  const rows = (data ?? []) as Bal[];
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Leave balances</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Earned leave is added each month ({set?.leave_per_month ?? 1.5} days a month, change it in Settings). Record leave taken here. At exit, unused leave is paid out up to {set?.leave_encash_cap ?? 30} days in the final settlement. Leave without pay is handled as loss of pay in the pay run, not here.</p>
      <div className="mt-4"><PayrollTabs active="/payroll/leave" /></div>
      {canWrite === true ? <div className="space-y-3"><AccrueForm /><RecordLeave emps={rows.filter((r) => r.status === "active").map((r) => ({ id: r.emp_id, label: `${r.name} (${r.emp_code})` }))} /></div> : null}
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-3 font-medium">Employee</th><th className="px-3 py-3 text-right font-medium">Earned</th><th className="px-3 py-3 text-right font-medium">Taken</th><th className="px-3 py-3 text-right font-medium">Paid out</th><th className="px-3 py-3 text-right font-medium">Balance</th></tr></thead>
          <tbody>{rows.map((r) => (<tr key={r.emp_id} className="border-b border-line last:border-0"><td className="px-3 py-2">{r.name} <span className="text-xs text-ink-muted">{r.emp_code}{r.status === "exited" ? ", left" : ""}</span></td><td className="px-3 py-2 text-right font-data">{Number(r.earned)}</td><td className="px-3 py-2 text-right font-data">{Number(r.taken)}</td><td className="px-3 py-2 text-right font-data">{Number(r.encashed)}</td><td className="px-3 py-2 text-right font-data font-semibold">{Number(r.balance)}</td></tr>))}
            {rows.length === 0 ? <tr><td colSpan={5} className="px-3 py-6 text-center text-ink-muted">No employees yet.</td></tr> : null}</tbody>
        </table>
      </div>
    </div>
  );
}
