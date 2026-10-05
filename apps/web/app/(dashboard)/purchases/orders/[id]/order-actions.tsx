"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, Lbl, primaryBtn, smallBtn } from "@/components/purchases/bits";

type L = { po_line_id: string; line_no: number; sku: string; name: string; quantity: number; unit_price: number; received_qty: number; rejected_qty: number; billed_qty: number };

export function OrderActions({ poId, status, lines, isCreator, canApprove, canPo, canGrn, canBill }: { poId: string; status: string; lines: L[]; isCreator: boolean; canApprove: boolean; canPo: boolean; canGrn: boolean; canBill: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const today = new Date().toISOString().slice(0, 10);
  const [note, setNote] = useState("");
  const [challan, setChallan] = useState("");
  const [recvDate, setRecvDate] = useState(today);
  const [acc, setAcc] = useState<Record<string, string>>({});
  const [rej, setRej] = useState<Record<string, string>>({});
  const [inv, setInv] = useState("");
  const [invDate, setInvDate] = useState(today);
  const [prices, setPrices] = useState<Record<string, string>>({});
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
          <p className="text-sm font-medium text-ink">Waiting for approval{isCreator ? " (you raised it, so another approver must decide)" : ""}</p>
          <input className={inputCls} placeholder="Note (needed if rejecting)" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="flex gap-2">
            <button className={primaryBtn} disabled={!!busy} onClick={() => call("ok", () => supabase.rpc("po_decide", { p_id: poId, p_approve: true, p_note: note || null }))}>Approve</button>
            <button className={smallBtn} disabled={!!busy} onClick={() => call("no", () => supabase.rpc("po_decide", { p_id: poId, p_approve: false, p_note: note || null }))}>Reject</button>
          </div>
        </div>
      ) : null}

      {canReceive ? (
        <div className="space-y-3 border border-line bg-surface p-4">
          <p className="text-sm font-medium text-ink">Receive goods</p>
          <div className="grid gap-3 md:grid-cols-2"><Lbl label="Received on"><input type="date" max={today} className={inputCls} value={recvDate} onChange={(e) => setRecvDate(e.target.value)} /></Lbl><Lbl label="Supplier challan no."><input className={inputCls} value={challan} onChange={(e) => setChallan(e.target.value)} /></Lbl></div>
          {lines.map((l) => (
            <div key={l.po_line_id} className="grid grid-cols-12 items-end gap-2 text-sm">
              <span className="col-span-12 md:col-span-6 text-ink">{l.sku} · {l.name} <span className="text-ink-muted">(still to come: {Math.max(l.quantity - l.received_qty - l.rejected_qty, 0)})</span></span>
              <Lbl label="Good" className="col-span-6 md:col-span-3"><input className={inputCls} inputMode="numeric" value={acc[l.po_line_id] ?? ""} onChange={(e) => setAcc({ ...acc, [l.po_line_id]: e.target.value })} /></Lbl>
              <Lbl label="Damaged / rejected" className="col-span-6 md:col-span-3"><input className={inputCls} inputMode="numeric" value={rej[l.po_line_id] ?? ""} onChange={(e) => setRej({ ...rej, [l.po_line_id]: e.target.value })} /></Lbl>
            </div>
          ))}
          <button className={primaryBtn} disabled={!!busy} onClick={() => call("grn", () => supabase.rpc("grn_create", { p_po: poId, p_received_on: recvDate, p_challan: challan || null, p_lines: lines.map((l) => ({ po_line_id: l.po_line_id, accepted: Number(acc[l.po_line_id] || 0), rejected: Number(rej[l.po_line_id] || 0) })) }), () => "Goods received and stock updated.")}>{busy === "grn" ? "Saving…" : "Save receipt"}</button>
          <p className="text-xs text-ink-muted">Only the good quantity is added to stock. Up to 10 percent over the ordered quantity is accepted.</p>
        </div>
      ) : null}

      {canBill && unbilled && ["approved", "part_received", "received", "closed"].includes(status) ? (
        <div className="space-y-3 border border-line bg-surface p-4">
          <p className="text-sm font-medium text-ink">Enter the supplier&apos;s bill (only what was received and not billed yet)</p>
          <div className="grid gap-3 md:grid-cols-2"><Lbl label="Supplier invoice no."><input className={inputCls} value={inv} onChange={(e) => setInv(e.target.value)} /></Lbl><Lbl label="Invoice date"><input type="date" max={today} className={inputCls} value={invDate} onChange={(e) => setInvDate(e.target.value)} /></Lbl></div>
          {lines.filter((l) => l.received_qty - l.billed_qty > 0).map((l) => (
            <Lbl key={l.po_line_id} label={`${l.sku}: price on the supplier's bill (ordered at ${l.unit_price})`}><input className={inputCls} inputMode="decimal" placeholder={String(l.unit_price)} value={prices[l.po_line_id] ?? ""} onChange={(e) => setPrices({ ...prices, [l.po_line_id]: e.target.value })} /></Lbl>
          ))}
          <button className={primaryBtn} disabled={!!busy} onClick={() => call("bill", () => supabase.rpc("po_create_bill", { p_po: poId, p_invoice_no: inv, p_invoice_date: invDate, p_bill_date: invDate, p_prices: Object.fromEntries(Object.entries(prices).filter(([, v]) => v !== "")) }),
            (d) => { const r = d as { price_differences: unknown[] }; return r.price_differences.length ? `Bill created and sent for approval. ${r.price_differences.length} line(s) are billed at a different price from the order.` : "Bill created and sent for approval."; })}>{busy === "bill" ? "Creating…" : "Create bill"}</button>
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
