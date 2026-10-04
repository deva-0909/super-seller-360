import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { CsvButton } from "@/components/ui/csv-button";
import { financialYearStart, inr } from "@/lib/report-utils";

type Row = { period: string; section: string; deducted: number; bills: number; paid: number; pending: number; to_pay: number; due_date: string; status: string };
const m = (n: number) => (inr(n) === "—" ? "₹0.00" : inr(n));
const STATUS: Record<string, { label: string; cls: string }> = {
  paid: { label: "Deposited", cls: "text-success" }, awaiting_approval: { label: "Awaiting approval", cls: "text-warning" },
  overdue: { label: "Overdue", cls: "text-danger" }, due: { label: "To deposit", cls: "text-ink" }, excess: { label: "Deposited more than deducted", cls: "text-danger" },
};

export default async function TdsPage({ searchParams }: { searchParams: Promise<{ fy?: string }> }) {
  const sp = await searchParams;
  const today = new Date();
  const curFy = Number(financialYearStart(today).slice(0, 4));
  const fy = /^\d{4}$/.test(sp.fy ?? "") ? Number(sp.fy) : curFy;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data, error }, { data: challans }] = await Promise.all([
    supabase.rpc("tds_register", { p_fy_start: `${fy}-04-01` }),
    supabase.from("tds_challans").select("challan_id, challan_no, period, section, tax, interest, late_fee, total, deposit_date, bsr_code, challan_serial, status")
      .gte("period", `${fy}-04`).lte("period", `${fy + 1}-03`).order("created_at", { ascending: false }).limit(200),
  ]);
  if (error) return <div className="px-4 md:px-8 py-8"><h1 className="text-lg font-semibold tracking-tight text-ink">TDS</h1><p className="mt-3 text-sm text-danger">{error.message}</p></div>;
  const rows = ((data ?? []) as unknown as Row[]).map((r) => ({ ...r, deducted: Number(r.deducted), paid: Number(r.paid), pending: Number(r.pending), to_pay: Number(r.to_pay) }));
  const sum = (k: "deducted" | "paid" | "pending" | "to_pay") => rows.reduce((t, r) => t + r[k], 0);
  const overdue = rows.filter((r) => r.status === "overdue");
  const csv: (string | number)[][] = [
    [`TDS register FY ${fy}-${String(fy + 1).slice(2)}`], ["Month", "Section", "Deducted", "Deposited", "Waiting approval", "Still to deposit", "Due date", "Status"],
    ...rows.map((r) => [r.period, r.section, r.deducted, r.paid, r.pending, r.to_pay, r.due_date, STATUS[r.status]?.label ?? r.status]),
  ];
  const th = "px-4 py-3 font-medium";
  const td = "px-4 py-3 text-right font-data text-ink";

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">TDS to deposit</h1>
          <p className="mt-1 text-sm text-ink-muted">Tax deducted from suppliers when bills were approved, and what has been deposited with the government. Due dates are the 7th of the next month (30 April for March); confirm with your CA.</p>
        </div>
        <div className="flex gap-2">
          <Link href="/purchases/tds/deductions" className="inline-flex h-10 items-center rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken">Deductions list</Link>
          <CsvButton rows={csv} filename={`tds-register-${fy}`} />
        </div>
      </div>
      <div className="mt-4 flex items-center gap-4 text-sm">
        <Link href={`?fy=${fy - 1}`} className="text-accent hover:underline">← {fy - 1}-{String(fy).slice(2)}</Link>
        <span className="font-medium text-ink">FY {fy}-{String(fy + 1).slice(2)}</span>
        {fy < curFy ? <Link href={`?fy=${fy + 1}`} className="text-accent hover:underline">{fy + 1}-{String(fy + 2).slice(2)} →</Link> : null}
      </div>
      {overdue.length ? <p className="mt-4 border border-danger/40 bg-danger-tint p-3 text-sm text-ink">{overdue.length} deposit{overdue.length === 1 ? " is" : "s are"} past the due date. Interest may apply; ask your CA how much and enter it on the challan.</p> : null}

      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className={th}>Month</th><th className={th}>Section</th><th className={`${th} text-right`}>Deducted</th><th className={`${th} text-right`}>Deposited</th>
            <th className={`${th} text-right`}>Waiting approval</th><th className={`${th} text-right`}>Still to deposit</th><th className={th}>Due</th><th className={th}>Status</th><th className={th} /></tr></thead>
          <tbody>
            {rows.map((r) => {
              const st = STATUS[r.status] ?? STATUS.due;
              return (
                <tr key={r.period + r.section} className="border-b border-line last:border-0">
                  <td className="px-4 py-3 font-data text-ink">{r.period}<div className="text-xs text-ink-muted">{r.bills} bill{r.bills === 1 ? "" : "s"}</div></td>
                  <td className="px-4 py-3 text-ink">{r.section}</td>
                  <td className={td}>{m(r.deducted)}</td><td className={td}>{m(r.paid)}</td><td className={td}>{m(r.pending)}</td><td className={td}>{m(r.to_pay)}</td>
                  <td className="px-4 py-3 font-data text-ink-muted">{new Date(r.due_date).toLocaleDateString("en-IN")}</td>
                  <td className={`px-4 py-3 font-medium ${st.cls}`}>{st.label}</td>
                  <td className="px-4 py-3 text-right">{canWrite && r.to_pay > 0 ? <Link className="text-accent hover:underline" href={`/purchases/tds/new?period=${r.period}&section=${encodeURIComponent(r.section)}&amount=${r.to_pay}`}>Record deposit</Link> : null}</td>
                </tr>
              );
            })}
            {!rows.length ? <tr><td colSpan={9} className="px-4 py-8 text-center text-ink-muted">No TDS was deducted in this year.</td></tr> : null}
          </tbody>
          {rows.length ? <tfoot><tr className="border-t border-line-strong text-sm font-medium"><td className="px-4 py-3 text-ink" colSpan={2}>Total</td><td className={td}>{m(sum("deducted"))}</td><td className={td}>{m(sum("paid"))}</td><td className={td}>{m(sum("pending"))}</td><td className={td}>{m(sum("to_pay"))}</td><td colSpan={3} /></tr></tfoot> : null}
        </table>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Challans</h2>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className={th}>Challan</th><th className={th}>For</th><th className={th}>BSR / serial</th><th className={th}>Deposited on</th><th className={`${th} text-right`}>Tax</th><th className={`${th} text-right`}>Interest + fee</th><th className={th}>Status</th></tr></thead>
          <tbody>
            {(challans ?? []).map((c) => (
              <tr key={c.challan_id} className="border-b border-line last:border-0">
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/tds/${c.challan_id}`}>{c.challan_no}</Link></td>
                <td className="px-4 py-3 text-ink">{c.section} · {c.period}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{c.bsr_code} / {c.challan_serial}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(c.deposit_date).toLocaleDateString("en-IN")}</td>
                <td className={td}>{m(Number(c.tax))}</td><td className={td}>{m(Number(c.interest) + Number(c.late_fee))}</td>
                <td className="px-4 py-3"><StatusTag status={c.status} /></td>
              </tr>
            ))}
            {!challans?.length ? <tr><td colSpan={7} className="px-4 py-8 text-center text-ink-muted">No challans recorded for this year.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
