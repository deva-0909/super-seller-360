"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function BookLineActions({ lineId, excluded, canWrite }: { lineId: string; excluded: boolean; canWrite: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (!canWrite) return null;

  async function go() {
    let reason = "";
    if (!excluded) {
      reason = window.prompt("Why is this entry set aside (e.g. recorded twice, cheque not yet presented)?") ?? "";
      if (!reason.trim()) return;
    }
    setBusy(true); setErr(null);
    const { error } = excluded ? await supabase.rpc("br_include_book_line", { p_voucher_line_id: lineId }) : await supabase.rpc("br_exclude_book_line", { p_voucher_line_id: lineId, p_reason: reason });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (
    <span>
      <button disabled={busy} onClick={go} className="text-xs font-semibold text-accent hover:underline disabled:opacity-50">{excluded ? "Include again" : "Set aside"}</button>
      {err ? <span className="ml-2 text-xs text-danger">{err}</span> : null}
    </span>
  );
}
