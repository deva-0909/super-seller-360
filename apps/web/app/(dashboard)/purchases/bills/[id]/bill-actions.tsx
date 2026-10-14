"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { smallBtn, primaryBtn, inputCls } from "@/components/purchases/bits";

export function BillActions({ id, status, matchStatus, canApprove, canRelease, isMaker }: { id: string; status: string; matchStatus: string; canApprove: boolean; canRelease: boolean; isMaker: boolean }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [ask, setAsk] = useState<"reject" | "cancel" | "release" | null>(null);

  async function run(fn: string, args: Record<string, unknown>) {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc(fn, args);
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setAsk(null); setReason("");
    router.refresh();
  }
  const held = status === "pending" && matchStatus === "held";
  const canCancel = (status === "pending" && (isMaker || canApprove)) || (status === "approved" && canApprove);
  if (!((status === "pending" && (canApprove || canRelease)) || canCancel)) return null;
  return (
    <div className="flex flex-col items-start gap-2 sm:items-end">
      <div className="flex flex-wrap gap-2">
        {status === "pending" && canApprove && !held ? <button className={primaryBtn} disabled={busy} onClick={() => run("approve_purchase_bill", { p_id: id })}>{busy ? "Working…" : "Approve and post"}</button> : null}
        {held && canRelease ? <button className={primaryBtn} disabled={busy} onClick={() => setAsk("release")}>Release hold (Owner)</button> : null}
        {status === "pending" && canApprove ? <button className={smallBtn} disabled={busy} onClick={() => setAsk("reject")}>Reject</button> : null}
        {canCancel ? <button className={smallBtn} disabled={busy} onClick={() => setAsk("cancel")}>{status === "pending" ? "Withdraw" : "Cancel bill"}</button> : null}
      </div>
      {held && !canRelease ? <p className="max-w-sm text-xs text-ink-muted">This bill is on hold. Only the Owner can release it.</p> : null}
      {ask ? (
        <div className="flex w-full max-w-sm flex-col gap-2">
          <input className={inputCls} placeholder={ask === "release" ? "Why is the difference acceptable?" : "Reason"} value={reason} onChange={(e) => setReason(e.target.value)} autoFocus />
          <div className="flex gap-2">
            <button className={smallBtn} disabled={busy || !reason.trim()} onClick={() => run(ask === "release" ? "bill_release_hold" : ask === "reject" ? "reject_purchase_bill" : "cancel_purchase_bill", ask === "release" ? { p_id: id, p_note: reason } : { p_id: id, p_reason: reason })}>Confirm {ask}</button>
            <button className={smallBtn} onClick={() => setAsk(null)}>Back</button>
          </div>
          {status === "approved" && ask === "cancel" ? <p className="text-xs text-ink-muted">A reversal voucher is posted. The original voucher stays on record.</p> : null}
        </div>
      ) : null}
      {err ? <span className="max-w-sm text-sm text-danger">{err}</span> : null}
    </div>
  );
}
