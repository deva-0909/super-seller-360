"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function ClearDummy() {
  const router = useRouter();
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function go() {
    if (!confirm("Remove all sample (dummy) orders, shipments, messages and e-invoices? Real data is not touched.")) return;
    setBusy(true);
    const { data, error } = await createClient().rpc("connector_clear_dummy");
    setBusy(false);
    if (error) { setMsg(friendlyError(error.message)); return; }
    const r = data as { orders: number; shipments: number; messages: number; einvoices: number; kept_orders: number };
    setMsg(`Removed ${r.orders} sample orders, ${r.shipments} shipments, ${r.messages} messages, ${r.einvoices} e-invoices.${r.kept_orders ? ` ${r.kept_orders} sample orders already invoiced or shipped were kept.` : ""}`);
    router.refresh();
  }
  return (
    <div className="mt-8 border border-line bg-surface p-4">
      <p className="text-sm font-medium text-ink">Going live?</p>
      <p className="mt-1 text-xs text-ink-muted">Clear everything created in dummy mode before you switch connections to Live.</p>
      <button onClick={go} disabled={busy} className="mt-3 border border-danger px-3 py-1.5 text-xs font-medium text-danger hover:bg-danger-tint/40 disabled:opacity-50">{busy ? "Clearing…" : "Clear sample data"}</button>
      {msg ? <p className="mt-2 text-sm text-ink-muted">{msg}</p> : null}
    </div>
  );
}
