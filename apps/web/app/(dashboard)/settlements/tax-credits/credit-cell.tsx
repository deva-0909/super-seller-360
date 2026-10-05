"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inr } from "@/lib/report-utils";
import { inputCls, smallBtn } from "@/components/purchases/bits";

const SRC: Record<string, [string, string][]> = {
  gst_tcs: [["gstr2b", "GSTR-2B"], ["gstr2a", "GSTR-2A"], ["cash_ledger", "Cash ledger"], ["other", "Other"]],
  tds_194o: [["form26as", "Form 26AS"], ["ais", "AIS"], ["form16a", "Form 16A"], ["other", "Other"]],
};

export function CreditCell({ kind, channelId, month, amount, source, claimed, canWrite }: { kind: string; channelId: string; month: string; amount: number | null; source: string | null; claimed: boolean; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [open, setOpen] = useState(false);
  const [v, setV] = useState(amount == null ? "" : String(amount));
  const [src, setSrc] = useState(source ?? SRC[kind][0][0]);
  const [cl, setCl] = useState(claimed);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("mtax_credit_set", { p_kind: kind, p_channel: channelId, p_month: month, p_amount: v.trim() === "" ? null : Number(v), p_taxable: null, p_source: src, p_claimed: cl, p_note: null });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setOpen(false); router.refresh();
  }
  if (!open) return (
    <div className="text-sm">
      {amount == null ? <span className="text-ink-muted">Not entered</span> : <span className="font-data">{inr(amount)} <span className="text-xs text-ink-muted">{SRC[kind].find(([k]) => k === source)?.[1] ?? ""}{claimed ? ", claimed" : ""}</span></span>}
      {canWrite ? <button className="ml-2 text-xs text-accent hover:underline" onClick={() => setOpen(true)}>{amount == null ? "Enter" : "Edit"}</button> : null}
    </div>
  );
  return (
    <div className="space-y-1">
      <div className="flex items-center gap-1">
        <input className={`${inputCls} !h-8 !w-28`} inputMode="decimal" placeholder="Amount" value={v} onChange={(e) => setV(e.target.value)} />
        <select className={`${inputCls} !h-8 !w-28`} value={src} onChange={(e) => setSrc(e.target.value)}>{SRC[kind].map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
      </div>
      <label className="flex items-center gap-1 text-xs text-ink-muted"><input type="checkbox" checked={cl} onChange={(e) => setCl(e.target.checked)} />{kind === "gst_tcs" ? "Claimed in the cash ledger" : "Claimed in my income tax return"}</label>
      <div className="flex items-center gap-2"><button className={`${smallBtn} !h-8`} disabled={busy} onClick={save}>Save</button><button className="text-xs text-ink-muted hover:underline" onClick={() => setOpen(false)}>Cancel</button>{err ? <span className="text-xs text-danger">{err}</span> : null}</div>
      <p className="text-[11px] text-ink-muted">Leave the amount empty and save to remove it.</p>
    </div>
  );
}
