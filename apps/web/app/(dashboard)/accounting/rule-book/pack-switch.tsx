"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function PackSwitch({ pack, activeCount, total, canEdit }: { pack: string; activeCount: number; total: number; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const allOn = activeCount === total;

  async function flip() {
    if (!allOn && !window.confirm("Turn on perpetual inventory & COGS entries?\n\nOnly do this after an opening-stock valuation journal has been posted, otherwise the Inventory ledger will start negative. Existing entries are not touched.")) return;
    setBusy(true);
    setError(null);
    const { error } = await supabase.rpc("set_journal_pack_status", { p_pack: pack, p_status: allOn ? "inactive" : "active" });
    setBusy(false);
    if (error) { setError(friendlyError(error.message)); return; }
    router.refresh();
  }

  if (!canEdit) return null;
  return (
    <div className="flex items-center gap-3">
      <button
        type="button"
        onClick={flip}
        disabled={busy}
        className="rounded-lg border border-line bg-surface px-3 py-1.5 text-sm font-semibold text-ink hover:bg-surface-sunken disabled:opacity-50"
      >
        {busy ? "Working…" : allOn ? "Turn the pack off" : "Turn the whole pack on"}
      </button>
      {error ? <span className="text-xs text-danger">{error}</span> : null}
    </div>
  );
}
