import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";
import { PrintButton } from "./print-button";

export default async function PayslipPage({ params }: { params: Promise<{ id: string; line: string }> }) {
  const { id, line } = await params;
  const supabase = await createClient();
  const [{ data: l }, { data: run }, { data: ss }] = await Promise.all([
    supabase.from("payroll_lines").select("*, employees(emp_code, name, designation, department, pan, uan, esic_no, date_of_joining)").eq("line_id", line).eq("run_id", id).maybeSingle(),
    supabase.from("payroll_runs").select("run_no, month, status").eq("run_id", id).maybeSingle(),
    supabase.from("statutory_settings").select("deductor_name").eq("id", 1).maybeSingle(),
  ]);
  if (!l || !run) notFound();
  const e = l.employees as unknown as { emp_code: string; name: string; designation: string | null; department: string | null; pan: string | null; uan: string | null; esic_no: string | null; date_of_joining: string };
  const n = (v: unknown) => Number(v ?? 0);
  const earn: [string, number][] = [["Basic", n(l.basic)], ["Dearness allowance", n(l.da)], ["House rent allowance", n(l.hra)], ["Other allowance", n(l.other_allowance)], [l.extra_note ? `Extra: ${l.extra_note}` : "Extra earning", n(l.extra_earning)]];
  const ded: [string, number][] = [["Provident fund", n(l.pf_ee)], ["ESI", n(l.esi_ee)], ["Professional tax (Gujarat)", n(l.pt)], ["Labour welfare fund", n(l.lwf_ee)], ["Income tax (TDS)", n(l.tds)], [l.ded_note ? `Recovery: ${l.ded_note}` : "Recovery", n(l.other_ded)]];
  const gross = earn.reduce((s, [, v]) => s + v, 0);
  const totDed = ded.reduce((s, [, v]) => s + v, 0);
  const cell = "px-3 py-1.5";
  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex items-center gap-3 print:hidden"><Link href={`/payroll/runs/${id}`} className="text-sm text-accent hover:underline">← Back to run</Link><PrintButton /></div>
      <div className="mt-4 max-w-3xl border border-line bg-surface p-6">
        <div className="flex items-start justify-between">
          <div><div className="text-base font-semibold text-ink">{ss?.deductor_name ?? "Employer"}</div><div className="text-sm text-ink-muted">Payslip for {new Date(String(run.month)).toLocaleDateString("en-IN", { month: "long", year: "numeric", timeZone: "UTC" })}</div></div>
          <div className="text-right font-data text-xs text-ink-muted">{run.run_no}</div>
        </div>
        <div className="mt-4 grid grid-cols-2 gap-x-6 gap-y-1 text-sm">
          <div><span className="text-ink-muted">Name: </span>{e.name} ({e.emp_code})</div><div><span className="text-ink-muted">Role: </span>{[e.designation, e.department].filter(Boolean).join(", ") || "-"}</div>
          <div><span className="text-ink-muted">PAN: </span>{e.pan ?? "-"}</div><div><span className="text-ink-muted">UAN: </span>{e.uan ?? "-"}</div>
          <div><span className="text-ink-muted">ESIC no: </span>{e.esic_no ?? "-"}</div><div><span className="text-ink-muted">Paid days: </span>{n(l.paid_days)} of {n(l.days_in_month)}{n(l.lop_days) > 0 ? ` (${n(l.lop_days)} without pay)` : ""}</div>
        </div>
        <div className="mt-4 grid gap-4 md:grid-cols-2 overflow-x-auto">
          <table className="w-full text-sm"><thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className={`${cell} text-left font-medium`}>Earnings</th><th className={`${cell} text-right font-medium`}>₹</th></tr></thead>
            <tbody>{earn.filter(([, v]) => v > 0).map(([k, v]) => <tr key={k} className="border-b border-line"><td className={cell}>{k}</td><td className={`${cell} text-right font-data`}>{inr(v)}</td></tr>)}
              <tr><td className={`${cell} font-semibold`}>Gross pay</td><td className={`${cell} text-right font-data font-semibold`}>{inr(gross)}</td></tr></tbody></table>
          <table className="w-full text-sm"><thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className={`${cell} text-left font-medium`}>Deductions</th><th className={`${cell} text-right font-medium`}>₹</th></tr></thead>
            <tbody>{ded.filter(([, v]) => v > 0).map(([k, v]) => <tr key={k} className="border-b border-line"><td className={cell}>{k}</td><td className={`${cell} text-right font-data`}>{inr(v)}</td></tr>)}
              <tr><td className={`${cell} font-semibold`}>Total deductions</td><td className={`${cell} text-right font-data font-semibold`}>{inr(totDed)}</td></tr></tbody></table>
        </div>
        <div className="mt-4 flex items-center justify-between border-t border-line-strong pt-3 text-base font-semibold text-ink"><span>Net pay</span><span className="font-data">{inr(n(l.net_pay))}</span></div>
        <p className="mt-3 text-xs text-ink-muted">Employer contributions (not deducted from pay): provident fund {inr(n(l.pf_eps) + n(l.pf_epf))}{n(l.esi_er) > 0 ? `, ESI ${inr(n(l.esi_er))}` : ""}{n(l.lwf_er) > 0 ? `, labour welfare ${inr(n(l.lwf_er))}` : ""}. This is a computer-generated payslip.</p>
      </div>
    </div>
  );
}
