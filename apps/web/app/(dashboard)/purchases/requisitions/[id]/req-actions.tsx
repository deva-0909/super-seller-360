"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, Lbl, primaryBtn, smallBtn } from "@/components/purchases/bits";

export function ReqActions({ reqId, status, isCreator, canDecide, canPo, anyLeft, suppliers }: { reqId: string; status: string; isCreator: boolean; canDecide: boolean; canPo: boolean; anyLeft: boolean; suppliers: { supplier_id: string; name: string }[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [note, setNote] = useState("");
  const [sup, setSup] = useState(suppliers[0]?.supplier_id ?? "");
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function call(key: string, fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>, after?: (d: unknown) => void) {
    setBusy(key); setErr(null);
    const { data, error } = await fn();
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    if (after) after(data); else router.refresh();
  }
  return (
    <div className="mt-6 space-y-4">
      {status === "pending" && canDecide ? (
        <div className="space-y-2 border border-line bg-surface p-4">
          <p className="text-sm font-medium text-ink">Waiting for approval{isCreator ? " (you raised it, so another manager must decide)" : ""}</p>
          <input className={inputCls} placeholder="Note (needed if rejecting)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="flex gap-2">
            <button className={primaryBtn} disabled={!!busy} onClick={() => call("ok", () => supabase.rpc("req_decide", { p_id: reqId, p_approve: true, p_note: note || null }))}>Approve</button>
            <button className={smallBtn} disabled={!!busy} onClick={() => call("no", () => supabase.rpc("req_decide", { p_id: reqId, p_approve: false, p_note: note || null }))}>Reject</button>
          </div>
        </div>
      ) : null}
      {status === "approved" && canPo && anyLeft ? (
        <div className="space-y-2 border border-line bg-surface p-4">
          <p className="text-sm font-medium text-ink">Order what is still not ordered</p>
          <Lbl label="Supplier"><select className={inputCls} value={sup} onChange={(e) => setSup(e.target.value)}>{suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.name}</option>)}</select></Lbl>
          <p className="text-xs text-ink-muted">Prices start from each product&apos;s cost price. Change them with Amend on the new order.</p>
          <button className={primaryBtn} disabled={!!busy || !sup} onClick={() => call("po", () => supabase.rpc("po_from_requisition", { p_req: reqId, p_supplier: sup }), (d) => router.push(`/purchases/orders/${d as string}`))}>{busy === "po" ? "Creating…" : "Create purchase order"}</button>
        </div>
      ) : null}
      {["pending", "approved"].includes(status) ? (
        <div className="flex flex-wrap items-end gap-2">
          <input className={`${inputCls} max-w-xs`} placeholder="Reason to cancel / close" value={note} onChange={(e) => setNote(e.target.value)} />
          <button className={smallBtn} disabled={!!busy || !note.trim()} onClick={() => call("cancel", () => supabase.rpc("req_cancel", { p_id: reqId, p_reason: note }))}>Cancel requisition</button>
          {status === "approved" && canPo ? <button className={smallBtn} disabled={!!busy || !note.trim()} onClick={() => call("close", () => supabase.rpc("req_close", { p_id: reqId, p_note: note }))}>Close (rest not needed)</button> : null}
        </div>
      ) : null}
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
