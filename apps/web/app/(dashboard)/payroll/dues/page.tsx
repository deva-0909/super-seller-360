import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { PayrollTabs } from "@/components/payroll/tabs";
import { RemitForm } from "./remit-form";

const HEAD: Record<string, string> = { pf: "Provident fund (EPFO)", esi: "ESI", pt: "Gujarat professional tax", tds: "Salary TDS", lwf: "Labour welfare fund" };

export default async function DuesPage() {
  const supabase = await createClient();
  const [{ data: dues }, { data: rem }, { data: canWrite }, { data: banks }] = await Promise.all([
    supabase.from("payroll_dues").select("month, head, accrued, remitted, balance, due_date").order("month", { ascending: false }).limit(120),
    supabase.from("payroll_remittances").select("rem_id, head, month, amount, remit_date, reference").order("remit_date", { ascending: false }).limit(60),
    supabase.rpc("has_payroll_write"),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_name").eq("status", "active"),
  ]);
  const today = new Date().toISOString().slice(0, 10);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Statutory dues from payroll</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">What you owe the PF office, ESIC, the Gujarat professional tax office, the tax department and the labour welfare board for each approved month. Due dates here are the usual ones; your CA should confirm them for your registrations.</p>
      <div className="mt-4"><PayrollTabs active="/payroll/dues" /></div>
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Month</th><th className="px-4 py-3 font-medium">Payable to</th><th className="px-4 py-3 text-right font-medium">Amount</th><th className="px-4 py-3 text-right font-medium">Paid</th><th className="px-4 py-3 text-right font-medium">Still to pay</th><th className="px-4 py-3 font-medium">Due date</th><th className="px-4 py-3" /></tr></thead>
          <tbody>
            {(dues ?? []).map((d, i) => {
              const bal = Number(d.balance); const late = bal > 0 && String(d.due_date) < today;
              return (
                <tr key={`${d.month}${d.head}`} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                  <td className="px-4 py-3">{String(d.month).slice(0, 7)}</td><td className="px-4 py-3">{HEAD[d.head] ?? d.head}</td>
                  <td className="px-4 py-3 text-right font-data">{inr(d.accrued)}</td><td className="px-4 py-3 text-right font-data">{inr(d.remitted)}</td><td className="px-4 py-3 text-right font-data font-semibold">{inr(bal)}</td>
                  <td className={`px-4 py-3 ${late ? "text-danger" : "text-ink-muted"}`}>{bal <= 0 ? "Paid" : `${d.due_date}${late ? " (overdue)" : ""}`}</td>
                  <td className="px-4 py-3 text-right">{canWrite === true && bal > 0 ? <RemitForm head={d.head} month={String(d.month)} balance={bal} banks={(banks ?? []).map((b) => ({ id: b.bank_account_id, label: `${b.bank_name} ${b.account_name ?? ""}`.trim() }))} /> : null}</td>
                </tr>);
            })}
            {(dues ?? []).length === 0 ? <tr><td colSpan={7} className="px-4 py-6 text-ink-muted">Nothing due yet. Dues appear once a payroll run is approved.</td></tr> : null}
          </tbody>
        </table>
      </div>
      <h2 className="mt-6 text-sm font-semibold text-ink">Payments recorded</h2>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Paid on</th><th className="px-4 py-3 font-medium">For</th><th className="px-4 py-3 font-medium">Payable to</th><th className="px-4 py-3 text-right font-medium">Amount</th><th className="px-4 py-3 font-medium">Reference</th></tr></thead>
          <tbody>
            {(rem ?? []).map((r) => (<tr key={r.rem_id} className="border-b border-line"><td className="px-4 py-2">{r.remit_date}</td><td className="px-4 py-2">{String(r.month).slice(0, 7)}</td><td className="px-4 py-2">{HEAD[r.head] ?? r.head}</td><td className="px-4 py-2 text-right font-data">{inr(r.amount)}</td><td className="px-4 py-2 text-ink-muted">{r.reference ?? ""}</td></tr>))}
            {(rem ?? []).length === 0 ? <tr><td colSpan={5} className="px-4 py-4 text-ink-muted">No payments recorded yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
