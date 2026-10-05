import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";

type P = { month: string; run_no: string; status: string; emp_code: string; emp_name: string; designation: string | null; days_in_month: number; paid_days: number; lop_days: number; basic: number; da: number; hra: number; other_allowance: number; extra_earning: number; gross: number; pf_ee: number; esi_ee: number; pt: number; lwf_ee: number; tds: number; other_ded: number; net_pay: number; paid_on: string | null };

export default async function MyPayslips() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("my_payslips");
  const rows = (data ?? []) as P[];
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">My payslips</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Your own salary slips, matched on the e-mail you sign in with. If nothing shows, ask HR to check that your employee record has this e-mail address.</p>
      {rows.length === 0 ? <p className="mt-6 text-sm text-ink-muted">No payslips found.</p> : (
        <div className="mt-4 space-y-4">
          {rows.map((p) => {
            const earn: [string, number][] = [["Basic", p.basic], ["Dearness allowance", p.da], ["House rent allowance", p.hra], ["Other allowance", p.other_allowance], ["Other earnings", p.extra_earning]];
            const ded: [string, number][] = [["Provident fund", p.pf_ee], ["ESI", p.esi_ee], ["Professional tax", p.pt], ["Labour welfare", p.lwf_ee], ["Income tax (TDS)", p.tds], ["Other deductions", p.other_ded]];
            return (
              <section key={p.run_no} className="max-w-2xl border border-line bg-surface p-4 print:border-0">
                <div className="flex flex-wrap items-baseline justify-between gap-2"><h2 className="text-sm font-semibold text-ink">{new Date(p.month + "T00:00:00Z").toLocaleDateString("en-IN", { month: "long", year: "numeric", timeZone: "UTC" })}</h2><span className="text-xs text-ink-muted">{p.emp_name} ({p.emp_code}){p.designation ? `, ${p.designation}` : ""}</span></div>
                <p className="text-xs text-ink-muted">Paid days {p.paid_days} of {p.days_in_month}{Number(p.lop_days) ? `, loss of pay ${p.lop_days}` : ""}. {p.paid_on ? `Paid on ${p.paid_on}.` : "Payment pending."}</p>
                <div className="mt-3 grid gap-4 sm:grid-cols-2 text-sm">
                  <div><div className="text-xs font-medium text-ink-muted">Earnings</div>{earn.filter(([, v]) => Number(v) !== 0).map(([k, v]) => <div key={k} className="flex justify-between border-b border-line py-1"><span>{k}</span><span className="font-data">{inr(Number(v))}</span></div>)}<div className="flex justify-between py-1 font-semibold"><span>Gross</span><span className="font-data">{inr(Number(p.gross))}</span></div></div>
                  <div><div className="text-xs font-medium text-ink-muted">Deductions</div>{ded.filter(([, v]) => Number(v) !== 0).map(([k, v]) => <div key={k} className="flex justify-between border-b border-line py-1"><span>{k}</span><span className="font-data">{inr(Number(v))}</span></div>)}<div className="flex justify-between py-1 font-semibold"><span>Net pay</span><span className="font-data">{inr(Number(p.net_pay))}</span></div></div>
                </div>
              </section>
            );
          })}
        </div>
      )}
    </div>
  );
}
