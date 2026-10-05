"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn, primaryBtn } from "@/components/purchases/bits";

/** One button that calls a database function and refreshes the page. */
export function RpcButton({ rpc, args, label, primary, confirmText }: { rpc: string; args: Record<string, unknown>; label: string; primary?: boolean; confirmText?: string }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    if (confirmText && !window.confirm(confirmText)) return;
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc(rpc, args);
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (<span className="inline-flex flex-wrap items-center gap-2"><button className={primary ? primaryBtn : smallBtn} disabled={busy} onClick={go}>{label}</button>{err ? <span className="text-xs text-danger">{err}</span> : null}</span>);
}

/** Pick bank and date, then call a database function that records the payment. */
export function PayForm({ rpc, idKey, id, banks, label }: { rpc: string; idKey: string; id: string; banks: { id: string; label: string }[]; label: string }) {
  const router = useRouter();
  const supabase = createClient();
  const [bank, setBank] = useState(banks[0]?.id ?? "");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc(rpc, { [idKey]: id, p_bank: bank, p_date: date });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (
    <span className="inline-flex flex-wrap items-center gap-2">
      <select className={`${inputCls} !h-9 !w-44`} value={bank} onChange={(e) => setBank(e.target.value)}>{banks.map((b) => <option key={b.id} value={b.id}>{b.label}</option>)}</select>
      <input type="date" className={`${inputCls} !h-9 !w-36`} value={date} onChange={(e) => setDate(e.target.value)} />
      <button className={smallBtn} disabled={busy || !bank} onClick={go}>{label}</button>
      {err ? <span className="text-xs text-danger">{err}</span> : null}
    </span>
  );
}
