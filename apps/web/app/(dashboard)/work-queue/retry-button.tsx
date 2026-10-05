"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function RetryButton({ issueId }: { issueId: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("retry_automation_issue", { p_issue: issueId });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (
    <span className="inline-flex flex-col items-end gap-1">
      <button onClick={go} disabled={busy} className="border border-line bg-surface px-2.5 py-1 text-xs font-medium text-ink hover:bg-surface-sunken disabled:opacity-50">
        {busy ? "Trying…" : "Try again"}
      </button>
      {err ? <span role="alert" className="max-w-xs text-right text-xs text-danger">{err}</span> : null}
    </span>
  );
}
