"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import { inputCls, smallBtn } from "@/components/purchases/bits";

export function StockInReview({ id, canReview }: { id: string; canReview: boolean }) {
  const router = useRouter();
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (!canReview) return <span className="text-xs text-ink-muted">A manager reviews this</span>;
  async function go() {
    setBusy(true); setErr(null);
    const { error } = await createClient().rpc("stock_in_review", { p_id: id, p_note: note });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    router.refresh();
  }
  return (
    <div className="flex flex-col gap-1">
      <div className="flex gap-2"><input className={`${inputCls} h-9 min-w-48`} placeholder="What did you check?" value={note} onChange={(e) => setNote(e.target.value)} />
        <button className={smallBtn} disabled={busy || !note.trim()} onClick={go}>Mark reviewed</button></div>
      {err ? <span className="text-xs text-danger">{err}</span> : null}
    </div>
  );
}
