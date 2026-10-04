"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { allocateFifo } from "@/lib/purchase-calc";
import { inr } from "@/lib/report-utils";
import { linkProofs, type Proof } from "@/lib/attachments";
import { Proofs } from "@/components/ui/proofs";
import { Lbl, inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Open = { bill_id: string; bill_no: string; supplier_invoice_no: string; due_date: string; outstanding: number; msme_breach: boolean };
const today = () => new Date().toISOString().slice(0, 10);

export function PaymentForm({ suppliers, banks, initialSupplier }: {
  suppliers: { supplier_id: string; name: string }[];
  banks: { bank_account_id: string; label: string }[];
  initialSupplier?: string;
}) {
  const router = useRouter();
  const [supplier, setSupplier] = useState(initialSupplier ?? "");
  const [open, setOpen] = useState<Open[]>([]);
  const [alloc, setAlloc] = useState<Record<string, string>>({});
  const [date, setDate] = useState(today());
  const [mode, setMode] = useState<"bank" | "upi" | "cash">("bank");
  const [bank, setBank] = useState(banks[0]?.bank_account_id ?? "");
  const [amount, setAmount] = useState("");
  const [utr, setUtr] = useState("");
  const [notes, setNotes] = useState("");
  const [proofs, setProofs] = useState<Proof[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    (async () => {
      if (!supplier) { setOpen([]); setAlloc({}); return; }
      const { data } = await createClient().rpc("supplier_ageing", { p_as_of: today() });
      if (!live) return;
      const rows = ((data ?? []) as Record<string, unknown>[]).filter((r) => r.supplier_id === supplier)
        .map((r) => ({ bill_id: String(r.bill_id), bill_no: String(r.bill_no), supplier_invoice_no: String(r.supplier_invoice_no), due_date: String(r.due_date),
                       outstanding: Number(r.outstanding), msme_breach: Boolean(r.msme_breach) }));
      setOpen(rows); setAlloc({});
    })();
    return () => { live = false; };
  }, [supplier]);

  const allocated = Object.values(alloc).reduce((t, v) => t + (Number(v) || 0), 0);
  const amt = Number(amount) || 0;

  function autoAllocate() {
    const m = allocateFifo(amt, open.map((o) => ({ id: o.bill_id, outstanding: o.outstanding })));
    setAlloc(Object.fromEntries(Object.entries(m).map(([k, v]) => [k, String(v)])));
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    if (allocated - amt > 0.004) { setErr("The bills add up to more than the amount paid."); return; }
    setBusy(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("create_supplier_payment", {
      p_supplier: supplier, p_date: date, p_mode: mode, p_bank_account: mode === "cash" ? null : bank, p_amount: amt,
      p_utr: mode === "cash" ? null : utr, p_notes: notes || null,
      p_allocations: Object.entries(alloc).filter(([, v]) => Number(v) > 0).map(([bill_id, v]) => ({ bill_id, amount: Number(v) })),
    });
    if (error) { setBusy(false); setErr(friendlyError(error.message)); return; }
    const id = data as string;
    let attach = "";
    if (proofs.length) { try { await linkProofs(proofs.map((p) => p.attachment_id), "supplier_payment", id); } catch { attach = "?attach=failed"; } }
    router.push(`/purchases/payments/${id}${attach}`);
    router.refresh();
  }

  return (
    <form onSubmit={submit} className="mt-6 flex max-w-3xl flex-col gap-6">
      <section className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Lbl label="Supplier *" className="sm:col-span-2">
          <select className={inputCls} value={supplier} onChange={(e) => setSupplier(e.target.value)} required>
            <option value="">Choose…</option>
            {suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.name}</option>)}
          </select>
        </Lbl>
        <Lbl label="Paid on *"><input className={inputCls} type="date" max={today()} value={date} onChange={(e) => setDate(e.target.value)} required /></Lbl>
        <Lbl label="Amount paid *"><input className={inputCls} type="number" step="0.01" min="0.01" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} required /></Lbl>
        <Lbl label="Paid by *">
          <select className={inputCls} value={mode} onChange={(e) => setMode(e.target.value as "bank" | "upi" | "cash")}>
            <option value="bank">Bank transfer (NEFT / RTGS / IMPS / cheque)</option><option value="upi">UPI</option><option value="cash">Cash</option>
          </select>
        </Lbl>
        {mode !== "cash" ? (<>
          <Lbl label="From bank account *"><select className={inputCls} value={bank} onChange={(e) => setBank(e.target.value)} required>{banks.map((b) => <option key={b.bank_account_id} value={b.bank_account_id}>{b.label}</option>)}</select></Lbl>
          <Lbl label="UTR / reference no. *" hint="Each reference can be used once."><input className={inputCls} value={utr} onChange={(e) => setUtr(e.target.value)} required /></Lbl>
        </>) : <p className="self-end text-xs text-warning">Cash paid to one supplier on one day above ₹10,000 is not allowed as a business expense for income tax. Prefer a bank transfer.</p>}
        <Lbl label="Notes" className="sm:col-span-2"><input className={inputCls} value={notes} onChange={(e) => setNotes(e.target.value)} /></Lbl>
      </section>

      <section>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <p className="text-sm font-semibold text-ink">Which bills does this pay?</p>
          <button type="button" className={smallBtn} onClick={autoAllocate} disabled={!amt || !open.length}>Fill oldest first</button>
        </div>
        <div className="mt-2 border border-line bg-surface">
          {open.map((o) => (
            <div key={o.bill_id} className="grid grid-cols-2 items-center gap-2 border-b border-line px-4 py-3 text-sm last:border-0 sm:grid-cols-4">
              <div><p className="text-ink">{o.bill_no}</p><p className="text-xs text-ink-muted">inv {o.supplier_invoice_no}</p></div>
              <div className="text-xs text-ink-muted">due {new Date(o.due_date).toLocaleDateString("en-IN")}{o.msme_breach ? <span className="ml-1 text-danger">MSME limit passed</span> : null}</div>
              <div className="font-data text-ink">{inr(o.outstanding)} left</div>
              <input className={inputCls} type="number" step="0.01" min="0" max={o.outstanding} placeholder="Pay now" value={alloc[o.bill_id] ?? ""} onChange={(e) => setAlloc((a) => ({ ...a, [o.bill_id]: e.target.value }))} />
            </div>
          ))}
          {supplier && !open.length ? <p className="px-4 py-4 text-sm text-ink-muted">No approved bills are outstanding for this supplier. The payment will be recorded as an advance.</p> : null}
          {!supplier ? <p className="px-4 py-4 text-sm text-ink-muted">Choose a supplier to see their open bills.</p> : null}
        </div>
        {amt > 0 ? <p className="mt-2 text-sm text-ink-muted">Against bills {inr(allocated) === "—" ? "₹0.00" : inr(allocated)} · advance / on account {inr(Math.max(amt - allocated, 0)) === "—" ? "₹0.00" : inr(Math.max(amt - allocated, 0))}</p> : null}
      </section>

      <Proofs entityType="supplier_payment" pending={proofs} onPending={setProofs} kind="receipt" label="Payment proof (screenshot or receipt)" hint="Use the phone camera, or pick the bank app screenshot from the gallery." />
      {err ? <p className="text-sm text-danger">{err}</p> : null}
      <div><button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : "Submit for approval"}</button></div>
    </form>
  );
}
