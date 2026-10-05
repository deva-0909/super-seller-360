import { createClient } from "@/lib/supabase/server";
import { CsvButton } from "@/components/ui/csv-button";
import { financialYearStart, inr } from "@/lib/report-utils";
import { PayrollTabs } from "@/components/payroll/tabs";

export default async function PayrollReturnsPage({ searchParams }: { searchParams: Promise<{ fy?: string; q?: string }> }) {
  const sp = await searchParams;
  const curFy = Number(financialYearStart(new Date()).slice(0, 4));
  const fy = /^\d{4}$/.test(sp.fy ?? "") ? Number(sp.fy) : curFy;
  const q = [1, 2, 3, 4].includes(Number(sp.q)) ? Number(sp.q) : 1;
  const supabase = await createClient();
  const [{ data: qr }, { data: ar }] = await Promise.all([
    supabase.rpc("payroll_tds_summary", { p_fy: fy, p_q: q }),
    supabase.rpc("payroll_form130_rows", { p_fy: fy }),
  ]);
  type Q = { emp_code: string; name: string; pan: string | null; month: string; gross: number; tds: number };
  type A = { emp_code: string; name: string; pan: string | null; gross: number; pf: number; pt: number; tds: number; regime: string; taxable: number | null; annual_tax: number | null };
  const qrows = (qr ?? []) as Q[]; const arows = (ar ?? []) as A[];
  const link = "rounded-lg border border-line px-3 py-1.5 text-sm hover:bg-surface-sunken";
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Payroll returns data</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">Figures for the quarterly salary TDS return (Form 138, earlier 24Q) and the annual salary certificate (Form 130, earlier Form 16 Part B). Give these to your CA or load them into the return utility.</p>
      <div className="mt-4"><PayrollTabs active="/payroll/returns" /></div>
      <div className="mt-4 flex flex-wrap items-center gap-2">
        <span className="text-sm text-ink-muted">Year starting April</span>
        {[curFy - 1, curFy].map((y) => <a key={y} href={`/payroll/returns?fy=${y}&q=${q}`} className={`${link} ${y === fy ? "bg-surface-sunken font-semibold" : ""}`}>{y}</a>)}
        <span className="ml-3 text-sm text-ink-muted">Quarter</span>
        {[1, 2, 3, 4].map((n) => <a key={n} href={`/payroll/returns?fy=${fy}&q=${n}`} className={`${link} ${n === q ? "bg-surface-sunken font-semibold" : ""}`}>Q{n}</a>)}
      </div>
      <div className="mt-6 flex items-center justify-between"><h2 className="text-sm font-semibold text-ink">Form 138 data, Q{q} (tax deducted from salary)</h2>
        <CsvButton filename={`form138-${fy}-Q${q}`} rows={[["Emp code", "Name", "PAN", "Month", "Gross", "TDS"], ...qrows.map((r) => [r.emp_code, r.name, r.pan, String(r.month).slice(0, 7), r.gross, r.tds])]} /></div>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Employee</th><th className="px-4 py-3 font-medium">PAN</th><th className="px-4 py-3 font-medium">Month</th><th className="px-4 py-3 text-right font-medium">Gross</th><th className="px-4 py-3 text-right font-medium">TDS</th></tr></thead>
          <tbody>
            {qrows.map((r, i) => (<tr key={i} className="border-b border-line"><td className="px-4 py-2">{r.name} <span className="font-data text-xs text-ink-muted">{r.emp_code}</span></td><td className={`px-4 py-2 font-data text-xs ${r.pan ? "" : "text-danger"}`}>{r.pan ?? "Missing"}</td><td className="px-4 py-2">{String(r.month).slice(0, 7)}</td><td className="px-4 py-2 text-right font-data">{inr(r.gross)}</td><td className="px-4 py-2 text-right font-data">{inr(r.tds)}</td></tr>))}
            {qrows.length === 0 ? <tr><td colSpan={5} className="px-4 py-4 text-ink-muted">No salary TDS deducted in this quarter.</td></tr> : null}
          </tbody>
        </table>
      </div>
      <div className="mt-6 flex items-center justify-between"><h2 className="text-sm font-semibold text-ink">Form 130 data, year {fy}-{String(fy + 1).slice(2)}</h2>
        <CsvButton filename={`form130-${fy}`} rows={[["Emp code", "Name", "PAN", "Gross salary", "PF", "Professional tax", "Taxable income (latest)", "Annual tax (latest)", "TDS deducted", "Regime"], ...arows.map((r) => [r.emp_code, r.name, r.pan, r.gross, r.pf, r.pt, r.taxable, r.annual_tax, r.tds, r.regime])]} /></div>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Employee</th><th className="px-4 py-3 font-medium">PAN</th><th className="px-4 py-3 text-right font-medium">Gross</th><th className="px-4 py-3 text-right font-medium">PF</th><th className="px-4 py-3 text-right font-medium">Prof. tax</th><th className="px-4 py-3 text-right font-medium">Taxable</th><th className="px-4 py-3 text-right font-medium">Annual tax</th><th className="px-4 py-3 text-right font-medium">TDS</th><th className="px-4 py-3 font-medium">Regime</th></tr></thead>
          <tbody>
            {arows.map((r) => (<tr key={r.emp_code} className="border-b border-line"><td className="px-4 py-2">{r.name} <span className="font-data text-xs text-ink-muted">{r.emp_code}</span></td><td className={`px-4 py-2 font-data text-xs ${r.pan ? "" : "text-danger"}`}>{r.pan ?? "Missing"}</td><td className="px-4 py-2 text-right font-data">{inr(r.gross)}</td><td className="px-4 py-2 text-right font-data">{inr(r.pf)}</td><td className="px-4 py-2 text-right font-data">{inr(r.pt)}</td><td className="px-4 py-2 text-right font-data">{r.taxable == null ? "-" : inr(r.taxable)}</td><td className="px-4 py-2 text-right font-data">{r.annual_tax == null ? "-" : inr(r.annual_tax)}</td><td className="px-4 py-2 text-right font-data">{inr(r.tds)}</td><td className="px-4 py-2 text-ink-muted">{r.regime}</td></tr>))}
            {arows.length === 0 ? <tr><td colSpan={9} className="px-4 py-4 text-ink-muted">No approved payroll in this year.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
