"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { toCsv } from "@/lib/report-utils";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Row = Record<string, string | number | null>;

function save(name: string, text: string) {
  const blob = new Blob([text], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a"); a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function RunActions({ runId, status, month, canWrite, canApprove, banks }: { runId: string; status: string; month: string; canWrite: boolean; canApprove: boolean; banks: { id: string; label: string }[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [bank, setBank] = useState(banks[0]?.id ?? "");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [ref, setRef] = useState("");

  async function call(fn: () => PromiseLike<{ error: { message: string } | null }>, ok: string) {
    setBusy(true); setErr(null); setMsg(null);
    const { error } = await fn();
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(ok); router.refresh();
  }
  async function bankFile() {
    const { data, error } = await supabase.rpc("payroll_bank_file", { p_run: runId });
    if (error) { setErr(friendlyError(error.message)); return; }
    const rows = (data ?? []) as Row[];
    save(`salary-bank-file-${month}.csv`, "﻿" + toCsv([["Beneficiary", "Account number", "IFSC", "Bank", "Amount", "Reference"], ...rows.map((r) => [r.beneficiary, r.account_number, r.ifsc, r.bank, r.amount, r.reference])]));
  }
  async function ecr() {
    const { data, error } = await supabase.rpc("payroll_ecr_rows", { p_run: runId });
    if (error) { setErr(friendlyError(error.message)); return; }
    const rows = (data ?? []) as Row[];
    save(`ecr-${month}.txt`, rows.map((r) => [r.uan, r.member_name, r.gross_wages, r.epf_wages, r.eps_wages, r.edli_wages, r.epf_ee, r.eps_er, r.epf_er_diff, r.ncp_days, r.refund].join("#~#")).join("\n"));
  }
  async function ecrCsv() {
    const { data, error } = await supabase.rpc("payroll_ecr_rows", { p_run: runId });
    if (error) { setErr(friendlyError(error.message)); return; }
    const rows = (data ?? []) as Row[];
    save(`pf-members-${month}.csv`, "﻿" + toCsv([["UAN", "Member name", "Gross wages", "EPF wages", "EPS wages", "EDLI wages", "EPF (employee)", "EPS (employer)", "EPF difference (employer)", "Days without pay", "Refund"], ...rows.map((r) => [r.uan, r.member_name, r.gross_wages, r.epf_wages, r.eps_wages, r.edli_wages, r.epf_ee, r.eps_er, r.epf_er_diff, r.ncp_days, r.refund])]));
  }
  const live = status === "approved" || status === "paid";
  return (
    <div className="mt-4 space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        {status === "draft" && canWrite ? <button className={smallBtn} disabled={busy} onClick={() => call(() => supabase.rpc("payroll_run_recalculate", { p_run: runId }), "Recalculated with the latest salary and rates.")}>Recalculate</button> : null}
        {status === "draft" && canApprove ? <button className={primaryBtn} disabled={busy} onClick={() => call(() => supabase.rpc("payroll_run_approve", { p_run: runId }), "Approved. The salary entry is posted to the books.")}>Approve run</button> : null}
        {(status === "draft" || status === "approved") && canWrite ? <button className={smallBtn} disabled={busy} onClick={() => { if (window.confirm("Cancel this payroll run? Any entry posted for it will be reversed.")) void call(() => supabase.rpc("payroll_run_cancel", { p_run: runId }), "Run cancelled."); }}>Cancel run</button> : null}
        {live ? <><button className={smallBtn} onClick={bankFile}>Bank transfer file</button><button className={smallBtn} onClick={ecr}>PF return file (ECR)</button><button className={smallBtn} onClick={ecrCsv}>PF members (Excel)</button></> : null}
      </div>
      {status === "draft" && !canApprove ? <p className="text-sm text-ink-muted">A Finance Manager approves the run once it looks right. The person who started it cannot approve it.</p> : null}
      {status === "approved" && canWrite ? (
        <div className="flex flex-wrap items-end gap-2 border border-line bg-surface p-3">
          <label className="text-xs text-ink-muted">Salary paid from<select className={`${inputCls} !w-56`} value={bank} onChange={(e) => setBank(e.target.value)}>{banks.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}</select></label>
          <label className="text-xs text-ink-muted">Paid on<input type="date" className={`${inputCls} !w-44`} value={date} onChange={(e) => setDate(e.target.value)} /></label>
          <label className="text-xs text-ink-muted">Reference<input className={`${inputCls} !w-44`} placeholder="Bank batch no." value={ref} onChange={(e) => setRef(e.target.value)} /></label>
          <button className={primaryBtn} disabled={busy || !bank} onClick={() => call(() => supabase.rpc("payroll_run_pay", { p_run: runId, p_bank: bank, p_date: date, p_reference: ref || null }), "Salary payment recorded.")}>Record salary paid</button>
        </div>
      ) : null}
      {msg ? <p className="text-sm text-success">{msg}</p> : null}
      {err ? <p className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
