"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function ReviewActions({ voucherId }: { voucherId: string }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function go(fn: "approve_rule_voucher" | "discard_rule_voucher") {
    if (fn === "discard_rule_voucher" && !window.confirm("Discard this draft entry?")) return;
    setBusy(true); setError(null);
    const { error } = await supabase.rpc(fn, { p_voucher_id: voucherId });
    setBusy(false);
    if (error) { setError(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (
    <div className="flex flex-col items-end gap-1">
      <div className="flex gap-2">
        <button disabled={busy} onClick={() => go("approve_rule_voucher")} className="h-9 rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-50">Approve &amp; post</button>
        <button disabled={busy} onClick={() => go("discard_rule_voucher")} className="h-9 rounded-lg border border-line bg-surface px-3 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50">Discard</button>
      </div>
      {error ? <span className="max-w-64 text-right text-xs text-danger">{error}</span> : null}
    </div>
  );
}
