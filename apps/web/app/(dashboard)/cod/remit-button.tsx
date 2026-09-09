"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export function RemitButton({ codId, pending }: { codId: string; pending: number }) {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState(false);

  async function handleRemit() {
    setLoading(true);
    const { error } = await supabase.rpc("record_cod_remittance", {
      p_cod_id: codId,
      p_remitted_amount: pending,
      p_bank_txn_id: null,
    });
    setLoading(false);
    if (!error) {
      router.refresh();
    }
  }

  return (
    <button
      onClick={handleRemit}
      disabled={loading}
      className="border border-line px-2 py-1 text-xs text-ink hover:bg-surface-sunken disabled:opacity-50"
    >
      {loading ? "…" : "Mark remitted"}
    </button>
  );
}
