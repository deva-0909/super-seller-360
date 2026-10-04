"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { linkProofs, type Proof } from "@/lib/attachments";
import { Proofs } from "@/components/ui/proofs";
import { Lbl, inputCls, primaryBtn } from "@/components/purchases/bits";

const today = () => new Date().toISOString().slice(0, 10);

export function ChallanForm({ sections, banks, initial }: {
  sections: { section: string; description: string }[];
  banks: { bank_account_id: string; label: string }[];
  initial: { period: string; section: string; amount: string };
}) {
  const router = useRouter();
  const [period, setPeriod] = useState(initial.period);
  const [section, setSection] = useState(initial.section || sections[0]?.section || "");
  const [tax, setTax] = useState(initial.amount);
  const [interest, setInterest] = useState("");
  const [fee, setFee] = useState("");
  const [date, setDate] = useState(today());
  const [bank, setBank] = useState(banks[0]?.bank_account_id ?? "");
  const [bsr, setBsr] = useState("");
  const [serial, setSerial] = useState("");
  const [notes, setNotes] = useState("");
  const [proofs, setProofs] = useState<Proof[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault(); setErr(null); setBusy(true);
    const { data, error } = await createClient().rpc("create_tds_challan", {
      p_period: period, p_section: section, p_tax: Number(tax) || 0, p_interest: Number(interest) || 0, p_late_fee: Number(fee) || 0,
      p_date: date, p_bank: bank, p_bsr: bsr.trim(), p_serial: serial.trim(), p_notes: notes,
    });
    if (error || !data) { setBusy(false); setErr(friendlyError(error?.message ?? "Could not save")); return; }
    const id = data as unknown as string;
    let attach = "";
    if (proofs.length) { try { await linkProofs(proofs.map((p) => p.attachment_id), "tds_challan", id); } catch { attach = "?attach=failed"; } }
    router.push(`/purchases/tds/${id}${attach}`);
  }

  return (
    <form onSubmit={submit} className="mt-6 flex max-w-3xl flex-col gap-4">
      <div className="grid grid-cols-2 gap-4 sm:grid-cols-3">
        <Lbl label="Month the tax was deducted"><input className={inputCls} type="month" value={period} onChange={(e) => setPeriod(e.target.value)} required /></Lbl>
        <Lbl label="Section" className="col-span-2 sm:col-span-2">
          <select className={inputCls} value={section} onChange={(e) => setSection(e.target.value)}>
            {sections.map((s) => <option key={s.section} value={s.section}>{s.section} · {s.description}</option>)}
          </select>
        </Lbl>
        <Lbl label="Tax deposited"><input className={inputCls} type="number" step="0.01" min="0" inputMode="decimal" value={tax} onChange={(e) => setTax(e.target.value)} required /></Lbl>
        <Lbl label="Interest (if any)"><input className={inputCls} type="number" step="0.01" min="0" inputMode="decimal" value={interest} onChange={(e) => setInterest(e.target.value)} /></Lbl>
        <Lbl label="Late fee (if any)"><input className={inputCls} type="number" step="0.01" min="0" inputMode="decimal" value={fee} onChange={(e) => setFee(e.target.value)} /></Lbl>
        <Lbl label="Date deposited"><input className={inputCls} type="date" max={today()} value={date} onChange={(e) => setDate(e.target.value)} required /></Lbl>
        <Lbl label="Paid from" className="col-span-2 sm:col-span-2">
          <select className={inputCls} value={bank} onChange={(e) => setBank(e.target.value)} required>{banks.map((b) => <option key={b.bank_account_id} value={b.bank_account_id}>{b.label}</option>)}</select>
        </Lbl>
        <Lbl label="BSR code (7 digits)"><input className={inputCls} inputMode="numeric" maxLength={7} value={bsr} onChange={(e) => setBsr(e.target.value.replace(/\D/g, ""))} required /></Lbl>
        <Lbl label="Challan serial (5 digits)"><input className={inputCls} inputMode="numeric" maxLength={5} value={serial} onChange={(e) => setSerial(e.target.value.replace(/\D/g, ""))} required /></Lbl>
        <Lbl label="Note (optional)"><input className={inputCls} value={notes} onChange={(e) => setNotes(e.target.value)} /></Lbl>
      </div>
      <p className="text-xs text-ink-muted">Interest is charged on tax deposited late (1.5% per month or part of a month from the date of deduction is the usual rule; confirm the amount with your CA or the portal). A second person approves this challan, and only then is it posted to the books.</p>
      <Proofs entityType="tds_challan" pending={proofs} onPending={setProofs} kind="receipt" label="Challan receipt (CIN counterfoil or screenshot)" hint="Use the phone camera, or pick the downloaded PDF." />
      {err ? <p className="text-sm text-danger">{err}</p> : null}
      <div><button className={primaryBtn} disabled={busy}>{busy ? "Saving…" : "Save for approval"}</button></div>
    </form>
  );
}
