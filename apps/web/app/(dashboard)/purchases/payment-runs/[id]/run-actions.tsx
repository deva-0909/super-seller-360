"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Row = { supplier_id: string; beneficiary: string; account_number: string; ifsc: string; bank: string | null; amount: number; reference: string; bills: string };
const csvCell = (v: string | number | null) => `"${String(v ?? "").replace(/"/g, '""')}"`;

export function RunActions({ runId, runNo, status, suppliers, canWrite, canApprove, pendingPayments }: { runId: string; runNo: string; status: string; suppliers: { supplier_id: string; name: string }[]; canWrite: boolean; canApprove: boolean; pendingPayments: number }) {
  const router = useRouter();
  const supabase = createClient();
  const [utrs, setUtrs] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  async function exportFile() {
    setBusy("export"); setErr(null); setMsg(null);
    const { data, error } = await supabase.rpc("payment_run_export", { p_run: runId });
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    const rows = data as Row[];
    const head = ["Beneficiary name", "Account number", "IFSC", "Bank", "Amount", "Reference", "Bills"];
    const csv = [head, ...rows.map((r) => [r.beneficiary, r.account_number, r.ifsc, r.bank, r.amount.toFixed(2), r.reference, r.bills])].map((l) => l.map(csvCell).join(",")).join("\r\n");
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    a.download = `${runNo}-bank-file.csv`; a.click();
    setMsg("File downloaded. Upload it in your bank's bulk-payment screen. Come back and enter the UTRs once the bank has paid.");
    router.refresh();
  }
  async function complete() {
    setBusy("complete"); setErr(null); setMsg(null);
    const results = Object.entries(utrs).filter(([, v]) => v.trim()).map(([supplier_id, utr]) => ({ supplier_id, utr }));
    const { data, error } = await supabase.rpc("payment_run_complete", { p_run: runId, p_results: results });
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    const r = data as { suppliers_paid: number; suppliers_not_paid: number };
    setMsg(`${r.suppliers_paid} supplier payment(s) recorded${r.suppliers_not_paid ? `; ${r.suppliers_not_paid} left unpaid (their bills are payable again)` : ""}. A Finance Manager now approves them.`);
    router.refresh();
  }
  async function approve() {
    setBusy("approve"); setErr(null); setMsg(null);
    const { data, error } = await supabase.rpc("payment_run_approve_payments", { p_run: runId });
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    const r = data as { approved: number; failed: { payment: string; reason: string }[] };
    setMsg(`${r.approved} payment(s) approved and posted.${r.failed.length ? ` Not approved: ${r.failed.map((f) => `${f.payment} (${f.reason})`).join("; ")}` : ""}`);
    router.refresh();
  }
  async function cancel() {
    if (!confirm("Cancel this payment run? Its bills become payable again.")) return;
    setBusy("cancel");
    const { error } = await supabase.rpc("payment_run_cancel", { p_run: runId });
    setBusy(null);
    if (error) setErr(friendlyError(error.message)); else router.refresh();
  }

  return (
    <div className="mt-4 space-y-4">
      {canWrite && (status === "draft" || status === "exported") ? (
        <div className="space-y-3 border border-line bg-surface p-4">
          <p className="text-sm font-medium text-ink">{status === "draft" ? "Step 1: make the bank file" : "Bank file made. Step 2: after the bank has paid, enter the UTRs"}</p>
          <div className="flex flex-wrap gap-2">
            <button className={primaryBtn} disabled={!!busy} onClick={exportFile}>{busy === "export" ? "Preparing…" : status === "draft" ? "Download bank file" : "Download bank file again"}</button>
            <button className={smallBtn} disabled={!!busy} onClick={cancel}>Cancel run</button>
          </div>
          {status === "exported" ? (
            <div className="space-y-2">
              {suppliers.map((s) => (
                <label key={s.supplier_id} className="grid grid-cols-12 items-center gap-2 text-sm"><span className="col-span-12 md:col-span-5 text-ink">{s.name}</span><input className={`${inputCls} col-span-12 md:col-span-7`} placeholder="UTR (leave blank if the bank did not pay this supplier)" value={utrs[s.supplier_id] ?? ""} onChange={(e) => setUtrs({ ...utrs, [s.supplier_id]: e.target.value })} /></label>
              ))}
              <button className={primaryBtn} disabled={!!busy} onClick={complete}>{busy === "complete" ? "Saving…" : "Record the payments"}</button>
            </div>
          ) : null}
        </div>
      ) : null}
      {status === "completed" && pendingPayments > 0 ? (
        canApprove ? (
          <div className="border border-line bg-surface p-4"><p className="text-sm text-ink">{pendingPayments} payment(s) are waiting for approval. Approving posts them to the books.</p><button className={`${primaryBtn} mt-2`} disabled={!!busy} onClick={approve}>{busy === "approve" ? "Approving…" : "Approve all payments"}</button></div>
        ) : <p className="text-sm text-ink-muted">{pendingPayments} payment(s) are waiting for a Finance Manager to approve them.</p>
      ) : null}
      {msg ? <p className="text-sm text-success">{msg}</p> : null}
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
