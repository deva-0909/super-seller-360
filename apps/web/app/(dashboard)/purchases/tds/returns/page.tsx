import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { CsvButton } from "@/components/ui/csv-button";
import { financialYearStart, inr } from "@/lib/report-utils";
import { FilingBox } from "./filing-box";

type Row = { bill_no: string; deducted_on: string; deductee: string; pan: string | null; holder_type: string | null; section: string; payment_code: string | null; amount_credited: number; amount_deducted_on: number; rate: number; tds: number; challan_cin: string | null; deposited_on: string | null; due_date: string; interest_due: number; remark: string | null };
type Cert = { deductee: string; pan: string | null; section: string; amount_credited: number; tds: number; challans: string | null };
type Chk = { severity: string; code: string; message: string; n: number };
type Sum = { from: string; to: string; return_due: string; cert_due: string; deducted: number; deductions: number; deposited: number; interest_due: number; filed: boolean; filed_on: string | null; ack_no: string | null; late_fee: number; filing_key: string };
const SEV: Record<string, string> = { error: "border-danger/40 bg-danger-tint", warning: "border-warning/40", info: "border-line", ok: "border-success/40" };

export default async function ReturnsPage({ searchParams }: { searchParams: Promise<{ fy?: string; q?: string }> }) {
  const sp = await searchParams;
  const curFy = Number(financialYearStart(new Date()).slice(0, 4));
  const fy = /^\d{4}$/.test(sp.fy ?? "") ? Number(sp.fy) : curFy;
  const q = [1, 2, 3, 4].includes(Number(sp.q)) ? Number(sp.q) : Math.max(1, Math.min(4, Math.floor(((new Date().getMonth() + 9) % 12) / 3) + 1));
  const supabase = await createClient();
  const [{ data: sum }, { data: rows }, { data: certs }, { data: chk }, { data: canWrite }, { data: ss }] = await Promise.all([
    supabase.rpc("tds_quarter_summary", { p_fy: fy, p_q: q }),
    supabase.rpc("tds_statement_rows", { p_fy: fy, p_q: q }),
    supabase.rpc("tds_certificate_rows", { p_fy: fy, p_q: q }),
    supabase.rpc("tds_statement_validate", { p_fy: fy, p_q: q }),
    supabase.rpc("has_accounting_write"),
    supabase.from("statutory_settings").select("tan, deductor_name").eq("id", 1).maybeSingle(),
  ]);
  const s = sum as unknown as Sum | null;
  const r = (rows ?? []) as unknown as Row[]; const c = (certs ?? []) as unknown as Cert[]; const k = (chk ?? []) as unknown as Chk[];
  const fyl = `${fy}-${String(fy + 1).slice(2)}`;
  const csv140: (string | number | null)[][] = [
    [`Form 140 working papers (was 26Q), FY ${fyl} Q${q}`, `TAN ${ss?.tan ?? ""}`, ss?.deductor_name ?? ""],
    ["Bill", "Date of deduction", "Deductee", "PAN", "Holder type", "Section", "Payment code", "Amount paid or credited", "Amount deducted on", "Rate %", "Tax deducted", "Challan (BSR/serial/date)", "Deposited on", "Deposit due", "Interest due", "Remark"],
    ...r.map((x) => [x.bill_no, x.deducted_on, x.deductee, x.pan ?? "PANNOTAVBL", x.holder_type, x.section, x.payment_code, Number(x.amount_credited), Number(x.amount_deducted_on), Number(x.rate), Number(x.tds), x.challan_cin, x.deposited_on, x.due_date, Number(x.interest_due), x.remark]),
  ];
  const csv131: (string | number | null)[][] = [
    [`Form 131 certificate data (was 16A), FY ${fyl} Q${q}`, `Give to deductees by ${s?.cert_due ?? ""}`],
    ["Deductee", "PAN", "Section", "Amount paid or credited", "Tax deducted", "Challans"],
    ...c.map((x) => [x.deductee, x.pan ?? "PANNOTAVBL", x.section, Number(x.amount_credited), Number(x.tds), x.challans]),
  ];
  const th = "px-3 py-2 font-medium"; const td = "px-3 py-2";
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/tds" className="text-sm text-accent hover:underline">← TDS to deposit</Link>
      <h1 className="mt-2 text-lg font-semibold tracking-tight text-ink">TDS return: Form 140 and certificates</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">From 1 April 2026 the quarterly statement for payments to residents (earlier Form 26Q) is Form 140, and the supplier certificate (earlier 16A) is Form 131. This page prepares the working papers and checks them before you file on the income-tax portal. Salary TDS (Form 138) comes with payroll.</p>
      <div className="mt-4 flex flex-wrap items-center gap-3 text-sm">
        {[1, 2, 3, 4].map((n) => <Link key={n} href={`?fy=${fy}&q=${n}`} className={`rounded-lg border px-3 py-1.5 ${n === q ? "border-accent bg-accent text-white" : "border-line text-ink hover:bg-surface-sunken"}`}>Q{n}</Link>)}
        <span className="mx-2 text-ink-muted">|</span>
        <Link href={`?fy=${fy - 1}&q=${q}`} className="text-accent hover:underline">← {fy - 1}-{String(fy).slice(2)}</Link><span className="font-medium text-ink">FY {fyl}</span>
        {fy < curFy ? <Link href={`?fy=${fy + 1}&q=${q}`} className="text-accent hover:underline">{fy + 1}-{String(fy + 2).slice(2)} →</Link> : null}
      </div>
      {s ? (
        <div className="mt-4 grid gap-3 md:grid-cols-4">
          {[["Statement due", s.return_due], ["Certificates due", s.cert_due], ["Tax deducted", inr(Number(s.deducted))], ["Deposited", inr(Number(s.deposited))], ["Interest due", inr(Number(s.interest_due))], ["Late fee so far", inr(Number(s.late_fee))], ["Deductions", String(s.deductions)], ["Status", s.filed ? `Filed ${s.filed_on}` : "Not filed"]].map(([l, v]) => (
            <div key={l} className="border border-line bg-surface p-3"><div className="text-xs text-ink-muted">{l}</div><div className="font-data text-sm text-ink">{v}</div></div>
          ))}
        </div>
      ) : null}
      <h2 className="mt-6 text-sm font-semibold text-ink">Checks before you file</h2>
      <div className="mt-2 space-y-2">
        {k.map((x) => <div key={x.code} className={`border p-3 text-sm text-ink ${SEV[x.severity] ?? "border-line"}`}>{x.n > 0 ? <strong className="font-data">{x.n} · </strong> : null}{x.message}</div>)}
      </div>
      {s && Number(s.deductions) > 0 ? <FilingBox filingKey={s.filing_key} period={`${fy}-Q${q}`} filed={s.filed} filedOn={s.filed_on} ack={s.ack_no} canWrite={canWrite === true} /> : null}
      <div className="mt-6 flex flex-wrap items-center justify-between gap-2"><h2 className="text-sm font-semibold text-ink">Form 140 working papers</h2><CsvButton rows={csv140} filename={`form-140-${fy}-Q${q}`} label="Download working papers (CSV)" /></div>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm"><thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className={th}>Date</th><th className={th}>Deductee</th><th className={th}>PAN</th><th className={th}>Section</th><th className={`${th} text-right`}>Paid or credited</th><th className={`${th} text-right`}>Rate</th><th className={`${th} text-right`}>Tax</th><th className={th}>Challan</th><th className={`${th} text-right`}>Interest</th></tr></thead>
          <tbody>{r.map((x, i) => <tr key={x.bill_no} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}><td className={`${td} font-data whitespace-nowrap`}>{x.deducted_on}</td><td className={td}>{x.deductee}{x.remark ? <div className="text-xs text-warning">{x.remark}</div> : null}</td><td className={`${td} font-data`}>{x.pan ?? "—"}</td><td className={td}>{x.section}</td><td className={`${td} text-right font-data`}>{inr(Number(x.amount_credited))}</td><td className={`${td} text-right font-data`}>{Number(x.rate)}%</td><td className={`${td} text-right font-data`}>{inr(Number(x.tds))}</td><td className={`${td} font-data text-xs`}>{x.challan_cin ?? "—"}</td><td className={`${td} text-right font-data`}>{Number(x.interest_due) ? inr(Number(x.interest_due)) : "—"}</td></tr>)}
            {r.length === 0 ? <tr><td colSpan={9} className="px-3 py-6 text-ink-muted">No tax was deducted in this quarter.</td></tr> : null}</tbody></table>
      </div>
      <div className="mt-6 flex flex-wrap items-center justify-between gap-2"><h2 className="text-sm font-semibold text-ink">Form 131 certificate data</h2><CsvButton rows={csv131} filename={`form-131-${fy}-Q${q}`} label="Download certificate data (CSV)" /></div>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm"><thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className={th}>Deductee</th><th className={th}>PAN</th><th className={th}>Section</th><th className={`${th} text-right`}>Paid or credited</th><th className={`${th} text-right`}>Tax</th></tr></thead>
          <tbody>{c.map((x, i) => <tr key={x.deductee + x.section} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}><td className={td}>{x.deductee}</td><td className={`${td} font-data`}>{x.pan ?? "—"}</td><td className={td}>{x.section}</td><td className={`${td} text-right font-data`}>{inr(Number(x.amount_credited))}</td><td className={`${td} text-right font-data`}>{inr(Number(x.tds))}</td></tr>)}
            {c.length === 0 ? <tr><td colSpan={5} className="px-3 py-6 text-ink-muted">Nothing to certify this quarter.</td></tr> : null}</tbody></table>
      </div>
      <p className="mt-4 max-w-3xl text-xs text-ink-muted">Interest is 1.5% a month or part of a month from the date of deduction to the date of deposit. The late filing fee is Rs 200 a day, capped at the tax deducted (section 427). The portal&apos;s correction and challan-addition features for the new forms were still being rolled out in mid-2026, so keep your challan proofs. Confirm all of this with your CA before filing.</p>
    </div>
  );
}
