"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { Lbl, inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

export type Filing = {
  filing_id: string; return_type: "GSTR1" | "GSTR3B"; arn: string; filed_on: string; cash_paid: number | null; note: string | null;
  withdrawn: boolean; withdrawn_reason: string | null; changed: boolean;
};

export function FilingPanel({ month, type, filings, canWrite, canWithdraw, suggestedCash }: {
  month: string; type: "GSTR1" | "GSTR3B"; filings: Filing[]; canWrite: boolean; canWithdraw: boolean; suggestedCash?: number;
}) {
  const router = useRouter();
  const label = type === "GSTR1" ? "GSTR-1" : "GSTR-3B";
  const mine = filings.filter((f) => f.return_type === type);
  const active = mine.find((f) => !f.withdrawn);
  const history = mine.filter((f) => f.withdrawn);
  const [arn, setArn] = useState("");
  const [on, setOn] = useState("");
  const [cash, setCash] = useState(suggestedCash && suggestedCash > 0 ? String(suggestedCash) : "");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function record(e: React.FormEvent) {
    e.preventDefault(); setErr(null); setBusy(true);
    const { error } = await createClient().rpc("record_gst_filing", { p_period: month, p_type: type, p_arn: arn, p_filed_on: on, p_cash_paid: type === "GSTR3B" && cash !== "" ? Number(cash) : null, p_note: note });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  async function withdraw(id: string) {
    const reason = window.prompt(`Why is this ${label} filing record being withdrawn?`) ?? "";
    if (!reason.trim()) return;
    const { error } = await createClient().rpc("withdraw_gst_filing", { p_id: id, p_reason: reason });
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }

  return (
    <div className="mt-8 border border-line bg-surface p-4">
      <h2 className="text-sm font-semibold text-ink">{label} filing record for {month}</h2>
      {active ? (
        <div className="mt-2 text-sm">
          <p className="text-ink">Filed on {active.filed_on} · ARN <span className="font-data">{active.arn}</span>{active.cash_paid !== null ? <> · cash paid {inr(Number(active.cash_paid)) === "—" ? "₹0.00" : inr(Number(active.cash_paid))}</> : null}</p>
          {active.note ? <p className="text-xs text-ink-muted">{active.note}</p> : null}
          {type === "GSTR3B" ? <p className="mt-1 text-xs text-ink-muted">This month is locked: credit adjustments and GSTR-2B uploads are blocked.</p> : null}
          {active.changed ? <p className="mt-2 border border-warning/40 bg-warning-tint p-2 text-xs text-ink">The figures for this month have changed since you recorded this filing. Take the difference into the next month’s return (or an amendment) with your CA.</p> : null}
          {canWithdraw ? <button className={`${smallBtn} mt-3`} onClick={() => withdraw(active.filing_id)}>Withdraw this record</button> : null}
        </div>
      ) : canWrite ? (
        <form onSubmit={record} className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Lbl label="ARN from the portal"><input className={inputCls} value={arn} onChange={(e) => setArn(e.target.value)} required placeholder="AA2410250000001" /></Lbl>
          <Lbl label="Filed on"><input className={inputCls} type="date" value={on} onChange={(e) => setOn(e.target.value)} required /></Lbl>
          {type === "GSTR3B" ? <Lbl label="Cash paid"><input className={inputCls} type="number" step="0.01" min="0" inputMode="decimal" value={cash} onChange={(e) => setCash(e.target.value)} /></Lbl> : null}
          <Lbl label="Note (optional)"><input className={inputCls} value={note} onChange={(e) => setNote(e.target.value)} /></Lbl>
          <div className="col-span-2 sm:col-span-4"><button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : `Record ${label} as filed`}</button>
            <span className="ml-3 text-xs text-ink-muted">Saves a copy of today’s figures{type === "GSTR3B" ? " and locks the month’s credit entries" : ""}. File on the GST portal first.</span></div>
        </form>
      ) : <p className="mt-2 text-sm text-ink-muted">Not recorded as filed yet.</p>}
      {err ? <p className="mt-2 text-sm text-danger">{err}</p> : null}
      {history.length ? <ul className="mt-3 text-xs text-ink-muted">{history.map((h) => <li key={h.filing_id}>Withdrawn: ARN {h.arn}, filed {h.filed_on}. Reason: {h.withdrawn_reason}</li>)}</ul> : null}
    </div>
  );
}
