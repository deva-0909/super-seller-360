"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

const RECEIVABLE_STATUSES = ["initiated", "in_transit"];
const DISPOSITIONABLE_STATUSES = ["received", "inspected"];

export function RtoActions({
  rtoId,
  status,
  hasWarehouse,
}: {
  rtoId: string;
  status: string;
  hasWarehouse: boolean;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [inspectionResult, setInspectionResult] = useState("good");
  const [disposition, setDisposition] = useState("restocked");

  async function markReceived() {
    setLoading(true);
    setError(null);
    const { error } = await supabase
      .from("rtos")
      .update({ status: "received", received_date: new Date().toISOString().slice(0, 10) })
      .eq("rto_id", rtoId);
    setLoading(false);
    if (error) {
      setError(friendlyError(error.message));
      return;
    }
    router.refresh();
  }

  async function submitDisposition(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    const { error } = await supabase.rpc("disposition_rto", {
      p_rto_id: rtoId,
      p_inspection_result: inspectionResult,
      p_disposition: disposition,
    });
    setLoading(false);
    if (error) {
      setError(friendlyError(error.message));
      return;
    }
    router.refresh();
  }

  if (RECEIVABLE_STATUSES.includes(status)) {
    return (
      <div>
        <p className="text-sm text-ink-muted">
          Waiting for the item to physically arrive back.
        </p>
        <div className="mt-3">
          <Button onClick={markReceived} disabled={loading} className="w-auto px-4">
            {loading ? "Marking…" : "Mark received"}
          </Button>
        </div>
        {error ? <p className="mt-2 text-sm text-danger">{error}</p> : null}
      </div>
    );
  }

  if (DISPOSITIONABLE_STATUSES.includes(status)) {
    return (
      <form onSubmit={submitDisposition} className="flex flex-col gap-4">
        <p className="text-xs text-ink-muted">
          Stock is only credited if disposition is &quot;Restock&quot; and
          inspection result is &quot;Good&quot;.
        </p>
        {!hasWarehouse ? (
          <p className="text-sm text-warning">
            No destination warehouse set — restocking will be blocked until
            one is assigned.
          </p>
        ) : null}

        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">
            Inspection result
          </label>
          <select
            value={inspectionResult}
            onChange={(e) => setInspectionResult(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            <option value="good">Good</option>
            <option value="damaged">Damaged</option>
            <option value="wrong_item">Wrong item</option>
            <option value="missing">Missing</option>
          </select>
        </div>

        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Disposition</label>
          <select
            value={disposition}
            onChange={(e) => setDisposition(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            <option value="restocked">Restock</option>
            <option value="quarantined">Quarantine</option>
            <option value="claimed">File claim</option>
          </select>
        </div>

        {error ? <p className="text-sm text-danger">{error}</p> : null}

        <Button type="submit" disabled={loading} className="w-auto px-4">
          {loading ? "Recording…" : "Record disposition"}
        </Button>
      </form>
    );
  }

  return <p className="text-sm text-ink-muted">This RTO is closed.</p>;
}
