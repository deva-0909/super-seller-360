"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";

export function ClosePeriodButton({
  periodId,
  periodName,
}: {
  periodId: string;
  periodName: string;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleClose() {
    setLoading(true);
    setError(null);
    const { error } = await supabase.rpc("close_accounting_period", {
      p_period_id: periodId,
    });
    setLoading(false);
    if (error) {
      setError(error.message);
      return;
    }
    router.refresh();
  }

  if (confirming) {
    return (
      <div className="flex flex-col gap-2">
        <p className="text-xs text-danger">
          This locks {periodName} permanently. Confirm?
        </p>
        {error ? <p className="text-xs text-danger">{error}</p> : null}
        <div className="flex gap-2">
          <Button onClick={handleClose} disabled={loading} className="w-auto px-3 py-1 text-xs">
            {loading ? "Closing…" : "Yes, close it"}
          </Button>
          <Button
            variant="secondary"
            onClick={() => setConfirming(false)}
            className="w-auto px-3 py-1 text-xs"
          >
            Cancel
          </Button>
        </div>
      </div>
    );
  }

  return (
    <button
      onClick={() => setConfirming(true)}
      className="border border-line px-2 py-1 text-xs text-ink hover:bg-surface-sunken"
    >
      Close period
    </button>
  );
}
