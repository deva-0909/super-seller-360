"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function RunButton({ fn, label, doneText }: { fn: "apply_bank_rules" | "run_journal_backfill"; label: string; doneText: (r: Record<string, number>) => string }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function go() {
    setBusy(true); setMsg(null); setErr(null);
    const { data, error } = fn === "apply_bank_rules" ? await supabase.rpc("apply_bank_rules", {}) : await supabase.rpc("run_journal_backfill");
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    setMsg(doneText((data ?? {}) as Record<string, number>));
    router.refresh();
  }
  return (
    <div className="flex flex-col items-start gap-1">
      <button disabled={busy} onClick={go} className="h-10 rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50">{busy ? "Working…" : label}</button>
      {msg ? <span className="text-xs text-success">{msg}</span> : null}
      {err ? <span className="text-xs text-danger">{err}</span> : null}
    </div>
  );
}
