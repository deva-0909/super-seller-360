"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

const LABEL: Record<string, string> = { shipped: "Order is shipped", delivered: "Order is delivered", manual: "A person creates it" };

export function InvoiceModeSelect({ channelId, value, canEdit }: { channelId: string; value: string; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [v, setV] = useState(value);
  const [busy, setBusy] = useState(false);
  if (!canEdit) return <span className="text-ink-muted">{LABEL[value] ?? value}</span>;
  async function change(next: string) {
    const prev = v; setV(next); setBusy(true);
    const { error } = await supabase.from("channels").update({ auto_invoice_on: next }).eq("channel_id", channelId);
    setBusy(false);
    if (error) setV(prev); else router.refresh();
  }
  return (
    <select className="h-9 rounded-lg border border-line bg-surface px-2 text-sm text-ink disabled:opacity-60" value={v} disabled={busy} onChange={(e) => void change(e.target.value)}>
      {Object.entries(LABEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
    </select>
  );
}
