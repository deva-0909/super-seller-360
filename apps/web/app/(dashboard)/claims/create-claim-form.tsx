"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";

type Order = { order_id: string; external_order_id: string };

export function CreateClaimForm({ orders }: { orders: Order[] }) {
  const router = useRouter();
  const supabase = createClient();

  const [orderId, setOrderId] = useState(orders[0]?.order_id ?? "");
  const [claimType, setClaimType] = useState("lost_shipment");
  const [amount, setAmount] = useState("");
  const [deadline, setDeadline] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { error } = await supabase.from("claims").insert({
      order_id: orderId,
      claim_type: claimType,
      potential_amount: Number(amount) || 0,
      deadline: deadline || null,
    });

    setLoading(false);

    if (error) {
      setError(error.message);
      return;
    }

    setAmount("");
    setDeadline("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Log a claim</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Order</label>
          <select
            value={orderId}
            onChange={(e) => setOrderId(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            {orders.map((o) => (
              <option key={o.order_id} value={o.order_id}>
                {o.external_order_id}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Claim type</label>
          <select
            value={claimType}
            onChange={(e) => setClaimType(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            <option value="lost_shipment">Lost shipment</option>
            <option value="damaged_return">Damaged return</option>
            <option value="incorrect_deduction">Incorrect deduction</option>
            <option value="excess_deduction">Excess deduction</option>
            <option value="other">Other</option>
          </select>
        </div>

        <Field
          id="claim-amount"
          label="Potential amount (₹)"
          type="number"
          required
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />
        <Field
          id="claim-deadline"
          label="Deadline"
          type="date"
          value={deadline}
          onChange={(e) => setDeadline(e.target.value)}
        />

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Logging…" : "Log claim"}
        </Button>
      </form>
    </div>
  );
}
