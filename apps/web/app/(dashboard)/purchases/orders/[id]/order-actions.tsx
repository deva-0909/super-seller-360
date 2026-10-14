"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, Lbl, primaryBtn, smallBtn } from "@/components/purchases/bits";
import { ReceiveScan } from "@/components/scan/receive-scan";
import type { CatRow } from "@/lib/scan/catalog";

type L = { po_line_id: string; product_id: string; lot_tracked: boolean; line_no: number; sku: string; name: string; quantity: number; unit_price: number; received_qty: number; rejected_qty: number; billed_qty: number };

export function OrderActions({ poId, status, lines, isCreator, canApprove, ownerOnly, canPo, canGrn, canBill, catalog }: { poId: string; status: string; lines: L[]; catalog: CatRow[]; isCreator: boolean; canApprove: boolean; ownerOnly: boolean; canPo: boolean; canGrn: boolean; canBill: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const today = new Date().toISOString().slice(0, 10);
  const [note, setNote] = useState("");
  const [inv, setInv] = useState("");
  const [invDate, setInvDate] = useState(today);
  const [prices, setPrices] = useState<Record<string, string>>({});
  const [qtys, setQtys] = useState<Record<string, string>>({});
  const [invTotal, setInvTotal] = useState("");
  const [rtvOpen, setRtvOpen] = useState(false);
  const [rtvReason, setRtvReason] = useState("");
  const [rtvRef, setRtvRef] = useState("");
  const [rtvQty, setRtvQty] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  async function call(key: string, fn: () => PromiseLike<{ data: unknown; error: { message: string } | null }>, ok?: (d: unknown) => string) {
    setBusy(key); setErr(null); setMsg(null);
    const { data, error } = await fn();
    setBusy(null);
    if (error) { setErr(friendlyError(error.message)); return; }
    if (ok) setMsg(ok(data));
    router.refresh();
  }

  const canReceive = canGrn && ["approved", "part_received"].includes(status);
  const unbilled = lines.some((l) => l.received_qty - l.billed_qty > 0);
  return (
    <div className="mt-6 space-y-6">
      {status === "pending" && canApprove ? (
        <div className="space-y-2 border border-line bg-surface p-4">
          <p className="text-sm font-medium text-ink">Waiting for approval{ownerOnly ? " by the Owner (above the manager limit)" : ""}{isCreator ? " (you raised it, so another approver must decide)" : ""}</p>
          <input className={inputCls} placeholder="Note (needed if rejecting)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="flex gap-2">
            <button className={primaryBtn} disabled={!!busy} onClick={() => call("ok", () => supabase.rpc("po_decide", { p_id: poId, p_approve: true, p_note: note || null }))}>Approve</button>
            <button className={smallBtn} disabled={!!busy} onClick={() => call("no", () => supabase.rpc("po_decide", { p_id: poId, p_approve: false, p_note: note || null }))}>Reject</button>
          </div>
        </div>
      ) : null}

      {canReceive ? <ReceiveScan poId={poId} lines={lines} catalog={catalog} onDone={() => router.refresh()} /> : null}

      {canBill && unbilled && ["approved", "part_received", "received", "closed"].includes(status) ? (
        <div className="space-y-3 border border-line bg-surface p-4">
          <p className="text-sm font-medium text-ink">Enter the supplier&apos;s invoice exactly as printed</p>
          <p className="text-xs text-ink-muted">It is checked against the order price and the goods actually received. Any difference puts the bill on hold until the Owner releases it.</p>
          <div className="grid gap-3 md:grid-cols-3">
            <Lbl label="Supplier invoice no."><input className={inputCls} value={inv} onChange={(e) => setInv(e.target.value)} /></Lbl>
            <Lbl label="Invoice date"><input type="date" max={today} className={inputCls} value={invDate} onChange={(e) => setInvDate(e.target.value)} /></Lbl>
            <Lbl label="Invoice total (with GST)"><input className={inputCls} inputMode="decimal" value={invTotal} onChange={(e) => setInvTotal(e.target.value)} /></Lbl>
          </div>
          {lines.filter((l) => l.received_qty - l.billed_qty > 0).map((l) => (
            <div key={l.po_line_id} className="grid gap-3 md:grid-cols-2">
              <Lbl label={`${l.sku}: quantity on invoice (received, not billed: ${l.received_qty - l.billed_qty})`}><input className={inputCls} inputMode="numeric" value={qtys[l.po_line_id] ?? ""} onChange={(e) => setQtys({ ...qtys, [l.po_line_id]: e.target.value })} /></Lbl>
              <Lbl label={`${l.sku}: price on invoice (ordered at ${l.unit_price})`}><input className={inputCls} inputMode="decimal" value={prices[l.po_line_id] ?? ""} onChange={(e) => setPrices({ ...prices, [l.po_line_id]: e.target.value })} /></Lbl>
            </div>
          ))}
          <button className={primaryBtn} disabled={!!busy} onClick={() => call("bill", () => supabase.rpc("po_create_bill", {
            p_po: poId, p_invoice_no: inv, p_invoice_date: invDate, p_bill_date: invDate, p_invoice_total: invTotal === "" ? null : Number(invTotal),
            p_lines: lines.filter((l) => l.received_qty - l.billed_qty > 0).map((l) => ({ po_line_id: l.po_line_id, quantity: Number(qtys[l.po_line_id] || 0), unit_price: prices[l.po_line_id] === undefined || prices[l.po_line_id] === "" ? l.unit_price : Number(prices[l.po_line_id]) })),
          }),
            (d) => { const r = d as { match_status: string; variances: unknown[] }; return r.match_status === "matched" ? "Invoice matches the order and the goods received. Sent for approval." : `Invoice saved but ON HOLD: ${r.variances.length} difference(s) found. The Owner must release it before it can be approved.`; })}>{busy === "bill" ? "Checking…" : "Check and create bill"}</button>
        </div>
      ) : null}

      {canGrn && ["approved", "part_received", "received"].includes(status) && lines.some((l) => l.received_qty > 0) ? (
        <div className="space-y-3 border border-line bg-surface p-4">
          <div className="flex items-center justify-between"><p className="text-sm font-medium text-ink">Return goods to the supplier</p>
            <button className={smallBtn} onClick={() => setRtvOpen(!rtvOpen)}>{rtvOpen ? "Hide" : "Open"}</button></div>
          {rtvOpen ? (<>
            <div className="grid gap-3 md:grid-cols-2">
              <Lbl label="Why are they going back?"><input className={inputCls} value={rtvReason} onChange={(e) => setRtvReason(e.target.value)} /></Lbl>
              <Lbl label="Gate pass / debit note no."><input className={inputCls} value={rtvRef} onChange={(e) => setRtvRef(e.target.value)} /></Lbl>
            </div>
            {lines.filter((l) => l.received_qty > 0).map((l) => (
              <Lbl key={l.po_line_id} label={`${l.sku}: quantity going back (held from this order: ${l.received_qty})`}><input className={inputCls} inputMode="numeric" value={rtvQty[l.po_line_id] ?? ""} onChange={(e) => setRtvQty({ ...rtvQty, [l.po_line_id]: e.target.value })} /></Lbl>
            ))}
            <button className={primaryBtn} disabled={!!busy} onClick={() => call("rtv", () => supabase.rpc("rtv_create", {
              p_po: poId, p_returned_on: today, p_reason: rtvReason, p_ref: rtvRef || null,
              p_lines: lines.filter((l) => Number(rtvQty[l.po_line_id] || 0) > 0).map((l) => ({ po_line_id: l.po_line_id, quantity: Number(rtvQty[l.po_line_id]) })),
            }), (d) => { const r = d as { rtv_no: string; needs_credit_note: boolean }; setRtvQty({}); setRtvReason(""); setRtvRef(""); return `${r.rtv_no} recorded and stock taken out.${r.needs_credit_note ? " Part of this was already billed: raise a supplier credit note." : ""}`; })}>{busy === "rtv" ? "Saving…" : "Record return"}</button>
          </>) : null}
        </div>
      ) : null}

      <div className="flex gap-3">
        {canPo && ["pending", "approved"].includes(status) ? <button className={smallBtn} disabled={!!busy} onClick={() => confirm("Cancel this order?") && call("cancel", () => supabase.rpc("po_cancel", { p_id: poId }))}>Cancel order</button> : null}
        {canPo && ["approved", "part_received", "received"].includes(status) ? <button className={smallBtn} disabled={!!busy} onClick={() => confirm("Close this order? Nothing more can be received.") && call("close", () => supabase.rpc("po_close", { p_id: poId, p_note: null }))}>Close order</button> : null}
      </div>
      {msg ? <p className="text-sm text-success">{msg}</p> : null}
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
    </div>
  );
}
