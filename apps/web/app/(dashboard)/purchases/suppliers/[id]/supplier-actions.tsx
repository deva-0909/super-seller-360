"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { smallBtn } from "@/components/purchases/bits";

export function SupplierActions({ id, status, canApprove }: { id: string; status: string; canApprove: boolean }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (!canApprove) return null;
  async function go(action: "approve" | "block" | "unblock") {
    if (action === "block" && !window.confirm("Block this supplier? No new bills or payments can be entered for them.")) return;
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("supplier_decide", { p_id: id, p_action: action });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (
    <div className="flex flex-col items-end gap-1">
      <div className="flex gap-2">
        {status === "pending" ? <button className={smallBtn} disabled={busy} onClick={() => go("approve")}>Approve supplier</button> : null}
        {status === "active" ? <button className={smallBtn} disabled={busy} onClick={() => go("block")}>Block</button> : null}
        {status === "blocked" ? <button className={smallBtn} disabled={busy} onClick={() => go("unblock")}>Unblock</button> : null}
      </div>
      {err ? <span className="max-w-64 text-right text-xs text-danger">{err}</span> : null}
    </div>
  );
}
