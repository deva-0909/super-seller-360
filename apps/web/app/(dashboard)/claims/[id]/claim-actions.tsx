"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

export function ClaimActions({
  claimId,
  status,
  potentialAmount,
  claimedAmount,
  approvedAmount,
  recoveredAmount,
}: {
  claimId: string;
  status: string;
  potentialAmount: number;
  claimedAmount: number | null;
  approvedAmount: number | null;
  recoveredAmount: number;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [amount, setAmount] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function advance(newStatus: string, defaultAmount?: number) {
    setLoading(true);
    setError(null);
    const { error } = await supabase.rpc("advance_claim", {
      p_claim_id: claimId,
      p_status: newStatus,
      p_amount: amount ? Number(amount) : defaultAmount ?? null,
    });
    setLoading(false);
    if (error) {
      setError(friendlyError(error.message));
      return;
    }
    setAmount("");
    router.refresh();
  }

  if (status === "potential") {
    return (
      <div className="flex flex-col gap-3">
        <Field
          id="claim-file-amount"
          label={`Amount to file (defaults to ₹${potentialAmount.toLocaleString("en-IN")})`}
          type="number"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        {error ? <p className="text-sm text-danger">{error}</p> : null}
        <Button
          onClick={() => advance("claimed", potentialAmount)}
          disabled={loading}
          className="w-auto px-4"
        >
          {loading ? "Filing…" : "File claim"}
        </Button>
      </div>
    );
  }

  if (status === "claimed") {
    return (
      <div className="flex flex-col gap-3">
        <Field
          id="claim-approve-amount"
          label={`Approved amount (defaults to ₹${claimedAmount?.toLocaleString("en-IN")})`}
          type="number"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        {error ? <p className="text-sm text-danger">{error}</p> : null}
        <div className="flex gap-2">
          <Button
            onClick={() => advance("approved", claimedAmount ?? undefined)}
            disabled={loading}
            className="w-auto px-4"
          >
            Approve
          </Button>
          <Button
            variant="secondary"
            onClick={() => advance("rejected")}
            disabled={loading}
            className="w-auto px-4"
          >
            Reject
          </Button>
        </div>
      </div>
    );
  }

  if (status === "approved") {
    const outstanding = (approvedAmount ?? 0) - recoveredAmount;
    return (
      <div className="flex flex-col gap-3">
        <p className="text-sm text-ink-muted">
          ₹{outstanding.toLocaleString("en-IN")} still outstanding.
        </p>
        <Field
          id="claim-recover-amount"
          label="Amount recovered"
          type="number"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        {error ? <p className="text-sm text-danger">{error}</p> : null}
        <Button
          onClick={() => advance("recovered")}
          disabled={loading || !amount}
          className="w-auto px-4"
        >
          {loading ? "Recording…" : "Record recovery"}
        </Button>
      </div>
    );
  }

  return <p className="text-sm text-ink-muted">This claim is closed.</p>;
}
