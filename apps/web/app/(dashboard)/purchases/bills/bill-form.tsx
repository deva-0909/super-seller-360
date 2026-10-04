"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { GST_RATES } from "@/lib/purchase-calc";
import { inr } from "@/lib/report-utils";
import { linkProofs, type Proof } from "@/lib/attachments";
import { Proofs } from "@/components/ui/proofs";
import { Lbl, inputCls, primaryBtn, smallBtn } from "@/components/purchases/bits";

type Line = { description: string; hsn_code: string; quantity: string; unit_price: string; gst_rate: string; ledger_id: string };
type Preview = { taxable: number; cgst: number; sgst: number; igst: number; total: number; intra: boolean };
type Tds = { section: string | null; base: number; rate: number; amount: number };

const today = () => new Date().toISOString().slice(0, 10);

export function BillForm({ suppliers, ledgers, defaultLedger }: {
  suppliers: { supplier_id: string; name: string; gstin: string | null }[];
  ledgers: { ledger_id: string; name: string }[];
  defaultLedger: string;
}) {
  const router = useRouter();
  const [supplier, setSupplier] = useState("");
  const [invNo, setInvNo] = useState("");
  const [invDate, setInvDate] = useState(today());
  const [billDate, setBillDate] = useState(today());
  const [itc, setItc] = useState(true);
  const [itcReason, setItcReason] = useState("");
  const [notes, setNotes] = useState("");
  const blank = (): Line => ({ description: "", hsn_code: "", quantity: "1", unit_price: "", gst_rate: "5", ledger_id: defaultLedger });
  const [lines, setLines] = useState<Line[]>([blank()]);
  const [proofs, setProofs] = useState<Proof[]>([]);
  const [prev, setPrev] = useState<Preview | null>(null);
  const [tds, setTds] = useState<Tds | null>(null);
  const [prevErr, setPrevErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const sup = suppliers.find((s) => s.supplier_id === supplier);
  const payload = useMemo(
    () => lines.filter((l) => l.description.trim() && Number(l.quantity) > 0 && l.unit_price !== "").map((l) => ({
      description: l.description, hsn_code: l.hsn_code, quantity: Number(l.quantity), unit_price: Number(l.unit_price), gst_rate: Number(l.gst_rate), ledger_id: l.ledger_id,
    })),
    [lines],
  );

  // the database does the arithmetic, so what is previewed is exactly what will be saved
  useEffect(() => {
    if (!supplier || !payload.length) return;
    const t = setTimeout(async () => {
      const supabase = createClient();
      const { data, error } = await supabase.rpc("pb_calc", { p_supplier: supplier, p_lines: payload });
      if (error) { setPrev(null); setTds(null); setPrevErr(friendlyError(error.message)); return; }
      setPrevErr(null);
      const c = data as Preview;
      setPrev(c);
      const r = await supabase.rpc("pb_tds", { p_supplier: supplier, p_bill_date: billDate, p_taxable: c.taxable, p_exclude: null });
      setTds(r.error ? null : (r.data as Tds));
    }, 400);
    return () => clearTimeout(t);
  }, [supplier, payload, billDate]);

  const ready = Boolean(supplier) && payload.length > 0;
  const shown = ready ? prev : null;
  const shownErr = ready ? prevErr : null;
  const shownTds = ready ? tds : null;
  const setLine = (i: number, k: keyof Line, v: string) => setLines((ls) => ls.map((l, j) => (j === i ? { ...l, [k]: v } : l)));

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    if (!payload.length) { setErr("Add at least one line with a description and price."); return; }
    setBusy(true);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("create_purchase_bill", {
      p_supplier: supplier, p_invoice_no: invNo, p_invoice_date: invDate, p_bill_date: billDate, p_lines: payload,
      p_itc: itc, p_itc_reason: itc ? null : itcReason, p_notes: notes || null,
    });
    if (error) { setBusy(false); setErr(friendlyError(error.message)); return; }
    const id = data as string;
    let attach = "";
    if (proofs.length) {
      try { await linkProofs(proofs.map((p) => p.attachment_id), "supplier_bill", id); } catch { attach = "?attach=failed"; }
    }
    router.push(`/purchases/bills/${id}${attach}`);
    router.refresh();
  }

  return (
    <form onSubmit={submit} className="mt-6 flex max-w-4xl flex-col gap-6">
      <section className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <Lbl label="Supplier *" className="sm:col-span-2">
          <select className={inputCls} value={supplier} onChange={(e) => setSupplier(e.target.value)} required>
            <option value="">Choose…</option>
            {suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.name} {s.gstin ? `· ${s.gstin}` : "· unregistered"}</option>)}
          </select>
        </Lbl>
        <Lbl label="Supplier's invoice number *"><input className={inputCls} value={invNo} onChange={(e) => setInvNo(e.target.value)} required /></Lbl>
        <Lbl label="Invoice date *"><input className={inputCls} type="date" max={today()} value={invDate} onChange={(e) => { setInvDate(e.target.value); if (billDate < e.target.value) setBillDate(e.target.value); }} required /></Lbl>
        <Lbl label="Book it on *" hint="The voucher is posted on this date. It must fall in an open period."><input className={inputCls} type="date" min={invDate} value={billDate} onChange={(e) => setBillDate(e.target.value)} required /></Lbl>
      </section>

      <section className="flex flex-col gap-3">
        <p className="text-sm font-semibold text-ink">What was bought</p>
        {lines.map((l, i) => (
          <div key={i} className="grid grid-cols-2 gap-3 border border-line bg-surface p-3 md:grid-cols-12">
            <input className={`${inputCls} col-span-2 md:col-span-4`} placeholder="Description" value={l.description} onChange={(e) => setLine(i, "description", e.target.value)} />
            <input className={`${inputCls} md:col-span-2`} placeholder="HSN" value={l.hsn_code} onChange={(e) => setLine(i, "hsn_code", e.target.value)} />
            <input className={`${inputCls} md:col-span-1`} type="number" step="0.001" min="0" placeholder="Qty" value={l.quantity} onChange={(e) => setLine(i, "quantity", e.target.value)} />
            <input className={`${inputCls} md:col-span-2`} type="number" step="0.01" min="0" placeholder="Price each" value={l.unit_price} onChange={(e) => setLine(i, "unit_price", e.target.value)} />
            <select className={`${inputCls} md:col-span-1`} value={l.gst_rate} onChange={(e) => setLine(i, "gst_rate", e.target.value)} aria-label="GST rate">
              {GST_RATES.map((r) => <option key={r} value={r}>{r}%</option>)}
            </select>
            <select className={`${inputCls} col-span-2 md:col-span-10`} value={l.ledger_id} onChange={(e) => setLine(i, "ledger_id", e.target.value)} aria-label="Book to">
              {ledgers.map((x) => <option key={x.ledger_id} value={x.ledger_id}>{x.name}</option>)}
            </select>
            {lines.length > 1 ? <button type="button" className={`${smallBtn} col-span-2 md:col-span-2`} onClick={() => setLines((ls) => ls.filter((_, j) => j !== i))}>Remove</button> : null}
          </div>
        ))}
        <div><button type="button" className={smallBtn} onClick={() => setLines((ls) => [...ls, blank()])}>Add another line</button></div>
      </section>

      <section className="flex flex-col gap-3">
        <label className="flex items-center gap-2 text-sm font-medium text-ink">
          <input type="checkbox" className="h-5 w-5" checked={itc} onChange={(e) => setItc(e.target.checked)} disabled={!sup?.gstin} />
          Claim the GST on this bill as input credit {sup && !sup.gstin ? "(not possible: supplier is unregistered)" : ""}
        </label>
        {!itc && sup?.gstin ? <Lbl label="Why is the credit not claimed? *"><input className={inputCls} value={itcReason} onChange={(e) => setItcReason(e.target.value)} placeholder="e.g. blocked credit, personal use" required /></Lbl> : null}
        <Lbl label="Notes"><input className={inputCls} value={notes} onChange={(e) => setNotes(e.target.value)} /></Lbl>
      </section>

      <div className="border border-line bg-surface p-4 text-sm">
        {shownErr ? <p className="text-danger">{shownErr}</p> : null}
        {shown ? (
          <dl className="flex flex-col gap-1.5">
            <div className="flex justify-between"><dt className="text-ink-muted">Taxable value</dt><dd className="font-data">{inr(shown.taxable)}</dd></div>
            {shown.intra ? (<>
              <div className="flex justify-between"><dt className="text-ink-muted">CGST</dt><dd className="font-data">{inr(shown.cgst)}</dd></div>
              <div className="flex justify-between"><dt className="text-ink-muted">SGST</dt><dd className="font-data">{inr(shown.sgst)}</dd></div>
            </>) : <div className="flex justify-between"><dt className="text-ink-muted">IGST</dt><dd className="font-data">{inr(shown.igst)}</dd></div>}
            <div className="flex justify-between border-t border-line pt-1.5 font-medium"><dt>Invoice total</dt><dd className="font-data">{inr(shown.total)}</dd></div>
            {shownTds && shownTds.amount > 0 ? (<>
              <div className="flex justify-between text-warning"><dt>TDS to deduct ({shownTds.section}, {shownTds.rate}% on {inr(shownTds.base)})</dt><dd className="font-data">− {inr(shownTds.amount)}</dd></div>
              <div className="flex justify-between font-medium"><dt>To pay the supplier</dt><dd className="font-data">{inr(shown.total - shownTds.amount)}</dd></div>
            </>) : null}
            <p className="pt-1 text-xs text-ink-muted">Checked again when you save. TDS is final only when the bill is approved.</p>
          </dl>
        ) : !shownErr ? <p className="text-ink-muted">Choose a supplier and fill in a line to see the tax.</p> : null}
      </div>

      <Proofs entityType="supplier_bill" pending={proofs} onPending={setProofs} kind="bill" label="Supplier's bill (proof)" hint="Photograph the bill with the phone camera or pick it from the gallery." />

      {err ? <p className="text-sm text-danger">{err}</p> : null}
      <div><button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : "Submit for approval"}</button></div>
    </form>
  );
}
