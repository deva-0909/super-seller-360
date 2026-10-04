"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { Lbl, inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Props = {
  id: string; status: string; isOwner: boolean; canReview: boolean; canFinal: boolean; canPay: boolean; managerStep: boolean;
  banks: { bank_account_id: string; label: string }[];
};

export function ExpenseActions({ id, status, isOwner, canReview, canFinal, canPay, managerStep, banks }: Props) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [ask, setAsk] = useState<"reject" | "cancel" | null>(null);
  const [mode, setMode] = useState<"bank" | "upi" | "cash">("bank");
  const [bank, setBank] = useState(banks[0]?.bank_account_id ?? "");
  const [utr, setUtr] = useState("");
  const [paidOn, setPaidOn] = useState(new Date().toISOString().slice(0, 10));

  async function run(fn: string, args: Record<string, unknown>) {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc(fn, args);
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setAsk(null); setNote("");
    router.refresh();
  }

  const showReview = status === "submitted" && canReview;
  const showFinal = canFinal && (status === "manager_approved" || (status === "submitted" && !managerStep));
  const showPay = status === "approved" && canPay;
  const showSubmit = status === "draft" && isOwner;
  const showCancel = (["draft", "submitted", "manager_approved"].includes(status) && (isOwner || canFinal)) || (status === "approved" && canFinal);
  if (!(showReview || showFinal || showPay || showSubmit || showCancel)) return null;

  return (
    <div className="mt-6 flex flex-col gap-3 border border-line bg-surface p-4">
      <div className="flex flex-wrap gap-2">
        {showSubmit ? <button className={primaryBtn} disabled={busy} onClick={() => run("submit_expense_claim", { p_id: id })}>Submit for review</button> : null}
        {showReview ? <button className={primaryBtn} disabled={busy} onClick={() => run("review_expense_claim", { p_id: id, p_approve: true, p_note: null })}>Approve (manager)</button> : null}
        {showFinal ? <button className={primaryBtn} disabled={busy} onClick={() => run("approve_expense_claim", { p_id: id, p_approve: true, p_note: null })}>Final approval: post to books</button> : null}
        {(showReview || showFinal) ? <button className={smallBtn} disabled={busy} onClick={() => setAsk("reject")}>Reject</button> : null}
        {showCancel ? <button className={smallBtn} disabled={busy} onClick={() => setAsk("cancel")}>{status === "approved" ? "Cancel claim" : "Withdraw"}</button> : null}
      </div>
      {ask ? (
        <div className="flex max-w-sm flex-col gap-2">
          <input className={inputCls} placeholder="Reason" value={note} onChange={(e) => setNote(e.target.value)} autoFocus />
          <div className="flex gap-2">
            <button className={smallBtn} disabled={busy || !note.trim()} onClick={() => {
              if (ask === "cancel") return run("cancel_expense_claim", { p_id: id, p_reason: note });
              return showFinal ? run("approve_expense_claim", { p_id: id, p_approve: false, p_note: note }) : run("review_expense_claim", { p_id: id, p_approve: false, p_note: note });
            }}>Confirm</button>
            <button className={smallBtn} onClick={() => setAsk(null)}>Back</button>
          </div>
        </div>
      ) : null}
      {showPay ? (
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <p className="text-sm font-semibold text-ink sm:col-span-2">Record the reimbursement</p>
          <Lbl label="Paid on"><input className={inputCls} type="date" max={new Date().toISOString().slice(0, 10)} value={paidOn} onChange={(e) => setPaidOn(e.target.value)} /></Lbl>
          <Lbl label="Paid by"><select className={inputCls} value={mode} onChange={(e) => setMode(e.target.value as "bank" | "upi" | "cash")}><option value="bank">Bank transfer</option><option value="upi">UPI</option><option value="cash">Cash</option></select></Lbl>
          {mode !== "cash" ? (<>
            <Lbl label="From bank account"><select className={inputCls} value={bank} onChange={(e) => setBank(e.target.value)}>{banks.map((b) => <option key={b.bank_account_id} value={b.bank_account_id}>{b.label}</option>)}</select></Lbl>
            <Lbl label="UTR / reference"><input className={inputCls} value={utr} onChange={(e) => setUtr(e.target.value)} /></Lbl>
          </>) : null}
          <div className="sm:col-span-2"><button className={primaryBtn} disabled={busy} onClick={() => run("pay_expense_claim", { p_id: id, p_date: paidOn, p_mode: mode, p_bank_account: mode === "cash" ? null : bank, p_utr: mode === "cash" ? null : utr })}>Mark as paid</button></div>
        </div>
      ) : null}
      {err ? <p className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
