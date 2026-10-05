"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function AutoMatch({ count }: { count: number }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  async function go() {
    setBusy(true); setMsg(null);
    const { data, error } = await createClient().rpc("settlement_auto_match", {});
    setBusy(false);
    if (error) { setMsg(friendlyError(error.message)); return; }
    const r = data as { reconciled: number; failed: { settlement: string; reason: string }[] };
    setMsg(`${r.reconciled} settlement(s) reconciled.${r.failed.length ? ` ${r.failed.length} could not be: ${r.failed.map((f) => `${f.settlement} (${f.reason})`).join("; ")}` : ""}`);
    router.refresh();
  }
  return (
    <div className="mt-4 flex flex-wrap items-center gap-3 border border-line bg-surface p-4">
      <p className="text-sm text-ink">{count} pending settlement{count === 1 ? " has" : "s have"} exactly one bank credit for the expected amount.</p>
      <button onClick={go} disabled={busy} className="h-9 bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50">{busy ? "Reconciling…" : "Reconcile them"}</button>
      {msg ? <p className="basis-full text-sm text-ink-muted">{msg}</p> : null}
    </div>
  );
}
