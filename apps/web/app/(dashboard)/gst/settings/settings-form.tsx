"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { gstinValid } from "@/lib/purchase-calc";
import { Lbl, inputCls, primaryBtn } from "@/components/purchases/bits";

export function B2clForm({ value, canEdit }: { value: number; canEdit: boolean }) {
  const router = useRouter();
  const [v, setV] = useState(String(value));
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  async function save(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setMsg(null);
    const { error } = await createClient().rpc("save_gst_settings", { p_b2cl: Number(v) });
    setBusy(false);
    setMsg(error ? friendlyError(error.message) : "Saved.");
    if (!error) router.refresh();
  }
  return (
    <form onSubmit={save} className="flex max-w-sm flex-col gap-3">
      <Lbl label="Large-invoice limit (₹)" hint="Inter-state sales to unregistered buyers above this per invoice are reported invoice by invoice (B2C large). Confirm the current limit with your CA.">
        <input className={inputCls} type="number" min="0" step="1" value={v} onChange={(e) => setV(e.target.value)} disabled={!canEdit} />
      </Lbl>
      {canEdit ? <div><button className={primaryBtn} disabled={busy}>Save</button></div> : null}
      {msg ? <p className="text-sm text-ink-muted">{msg}</p> : null}
    </form>
  );
}

export function ChannelGstin({ channelId, name, value, canEdit }: { channelId: string; name: string; value: string; canEdit: boolean }) {
  const router = useRouter();
  const [v, setV] = useState(value);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  async function save() {
    const g = v.trim().toUpperCase();
    if (g && !gstinValid(g)) { setMsg("Not a valid GSTIN."); return; }
    setBusy(true); setMsg(null);
    const { error } = await createClient().from("channels").update({ eco_gstin: g || null }).eq("channel_id", channelId);
    setBusy(false);
    setMsg(error ? friendlyError(error.message) : "Saved.");
    if (!error) router.refresh();
  }
  return (
    <div className="flex flex-wrap items-end gap-3">
      <Lbl label={name} className="min-w-64 flex-1"><input className={inputCls} value={v} maxLength={15} onChange={(e) => setV(e.target.value.toUpperCase())} disabled={!canEdit} placeholder="Marketplace GSTIN (if any)" /></Lbl>
      {canEdit ? <button type="button" className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50" disabled={busy} onClick={save}>Save</button> : null}
      {msg ? <span className="pb-2 text-xs text-ink-muted">{msg}</span> : null}
    </div>
  );
}
