"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { inputCls, smallBtn } from "@/components/purchases/bits";

export type Line = { line_id: string; paid_days: number; lop_days: number; gross: number; extra_earning: number; extra_is_wage: boolean; extra_note: string | null; pf_ee: number; pf_eps: number; pf_epf: number; edli: number; pf_admin: number; esi_ee: number; esi_er: number; pt: number; lwf_ee: number; lwf_er: number; tds: number; other_ded: number; ded_note: string | null; net_pay: number; emp: { emp_code: string; name: string } };

function Row({ runId, l, editable }: { runId: string; l: Line; editable: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ lop: String(l.lop_days), extra: String(l.extra_earning), wage: l.extra_is_wage, enote: l.extra_note ?? "", ded: String(l.other_ded), dnote: l.ded_note ?? "" });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("payroll_line_adjust", { p_line: l.line_id, p_lop: Number(f.lop || 0), p_extra: Number(f.extra || 0), p_extra_wage: f.wage, p_extra_note: f.enote || null, p_other_ded: Number(f.ded || 0), p_ded_note: f.dnote || null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setOpen(false); router.refresh();
  }
  const pf = Number(l.pf_ee), esi = Number(l.esi_ee);
  return (
    <>
      <tr className="border-b border-line">
        <td className="px-3 py-2 font-data text-xs">{l.emp.emp_code}</td>
        <td className="px-3 py-2">{l.emp.name}</td>
        <td className="px-3 py-2 text-right font-data">{Number(l.paid_days)}{Number(l.lop_days) > 0 ? <span className="text-warning"> ({Number(l.lop_days)} LOP)</span> : null}</td>
        <td className="px-3 py-2 text-right font-data">{inr(l.gross)}</td>
        <td className="px-3 py-2 text-right font-data">{inr(pf)}</td><td className="px-3 py-2 text-right font-data">{inr(esi)}</td><td className="px-3 py-2 text-right font-data">{inr(l.pt)}</td>
        <td className="px-3 py-2 text-right font-data">{inr(l.lwf_ee)}</td><td className="px-3 py-2 text-right font-data">{inr(l.tds)}</td><td className="px-3 py-2 text-right font-data">{inr(l.other_ded)}</td>
        <td className="px-3 py-2 text-right font-data font-semibold">{inr(l.net_pay)}</td>
        <td className="px-3 py-2 whitespace-nowrap text-right text-xs">
          <Link className="text-accent hover:underline" href={`/payroll/runs/${runId}/payslip/${l.line_id}`}>Payslip</Link>
          {editable ? <button className="ml-3 text-accent hover:underline" onClick={() => setOpen(!open)}>{open ? "Close" : "Adjust"}</button> : null}
        </td>
      </tr>
      {open ? (
        <tr className="border-b border-line bg-surface-sunken/50"><td colSpan={12} className="px-3 py-3">
          <div className="grid gap-2 md:grid-cols-6">
            <label className="text-xs text-ink-muted">Days without pay<input className={inputCls} inputMode="decimal" value={f.lop} onChange={(e) => setF({ ...f, lop: e.target.value })} /></label>
            <label className="text-xs text-ink-muted">Extra earning (₹)<input className={inputCls} inputMode="decimal" value={f.extra} onChange={(e) => setF({ ...f, extra: e.target.value })} /></label>
            <label className="text-xs text-ink-muted md:col-span-2">Extra earning reason<input className={inputCls} value={f.enote} onChange={(e) => setF({ ...f, enote: e.target.value })} /></label>
            <label className="text-xs text-ink-muted">Recovery (₹)<input className={inputCls} inputMode="decimal" value={f.ded} onChange={(e) => setF({ ...f, ded: e.target.value })} /></label>
            <label className="text-xs text-ink-muted">Recovery reason<input className={inputCls} value={f.dnote} onChange={(e) => setF({ ...f, dnote: e.target.value })} /></label>
          </div>
          <label className="mt-2 flex items-center gap-2 text-sm text-ink"><input type="checkbox" checked={f.wage} onChange={(e) => setF({ ...f, wage: e.target.checked })} />Extra earning counts as wages for PF and ESI (leave unticked for a one-off bonus or reimbursement)</label>
          <div className="mt-2 flex items-center gap-3"><button className={smallBtn} disabled={busy} onClick={save}>Save and recalculate</button>{err ? <span className="text-sm text-danger">{err}</span> : null}</div>
        </td></tr>
      ) : null}
    </>
  );
}

export function RunTable({ runId, rows, editable }: { runId: string; rows: Line[]; editable: boolean }) {
  return (
    <div className="mt-4 overflow-x-auto border border-line bg-surface">
      <table className="w-full text-left text-sm">
        <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
          <th className="px-3 py-3 font-medium">Code</th><th className="px-3 py-3 font-medium">Name</th><th className="px-3 py-3 text-right font-medium">Paid days</th><th className="px-3 py-3 text-right font-medium">Gross</th>
          <th className="px-3 py-3 text-right font-medium">PF</th><th className="px-3 py-3 text-right font-medium">ESI</th><th className="px-3 py-3 text-right font-medium">Prof. tax</th><th className="px-3 py-3 text-right font-medium">LWF</th>
          <th className="px-3 py-3 text-right font-medium">TDS</th><th className="px-3 py-3 text-right font-medium">Recovery</th><th className="px-3 py-3 text-right font-medium">Net pay</th><th className="px-3 py-3" />
        </tr></thead>
        <tbody>
          {rows.map((l) => <Row key={l.line_id} runId={runId} l={l} editable={editable} />)}
          {rows.length === 0 ? <tr><td colSpan={12} className="px-3 py-6 text-ink-muted">No employees in this run.</td></tr> : null}
        </tbody>
      </table>
    </div>
  );
}
