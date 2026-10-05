"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn } from "@/components/purchases/bits";

export function RemitForm({ head, month, balance, banks }: { head: string; month: string; balance: number; banks: { id: string; label: string }[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState(String(balance));
  const [bank, setBank] = useState(banks[0]?.id ?? "");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [ref, setRef] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function go() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("payroll_remit", { p_head: head, p_month: month, p_amount: Number(amount), p_bank: bank, p_date: date, p_reference: ref || null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setOpen(false); router.refresh();
  }
  if (!open) return <button className="text-xs text-accent hover:underline" onClick={() => setOpen(true)}>Record payment</button>;
  return (
    <div className="flex flex-wrap items-center justify-end gap-2">
      <input className={`${inputCls} !h-9 !w-28`} inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
      <select className={`${inputCls} !h-9 !w-44`} value={bank} onChange={(e) => setBank(e.target.value)}>{banks.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}</select>
      <input type="date" className={`${inputCls} !h-9 !w-36`} value={date} onChange={(e) => setDate(e.target.value)} />
      <input className={`${inputCls} !h-9 !w-32`} placeholder="Challan / ref" value={ref} onChange={(e) => setRef(e.target.value)} />
      <button className={smallBtn} disabled={busy || !bank} onClick={go}>Save</button>
      {err ? <span className="w-full text-right text-xs text-danger">{err}</span> : null}
    </div>
  );
}
