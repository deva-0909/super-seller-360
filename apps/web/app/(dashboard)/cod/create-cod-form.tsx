"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";

type Order = { order_id: string; external_order_id: string; net_amount: number };

export function CreateCodForm({ orders }: { orders: Order[] }) {
  const router = useRouter();
  const supabase = createClient();

  const [orderId, setOrderId] = useState(orders[0]?.order_id ?? "");
  const [courier, setCourier] = useState("");
  const [codAmount, setCodAmount] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { error } = await supabase.from("cod_collections").insert({
      order_id: orderId,
      courier_name: courier || null,
      cod_amount: Number(codAmount),
      collected_amount: Number(codAmount),
      status: "collected",
      collected_date: new Date().toISOString().slice(0, 10),
    });

    setLoading(false);

    if (error) {
      setError(error.message);
      return;
    }

    setCourier("");
    setCodAmount("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Log a COD collection</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Order</label>
          <select
            value={orderId}
            onChange={(e) => {
              setOrderId(e.target.value);
              const o = orders.find((o) => o.order_id === e.target.value);
              if (o) setCodAmount(String(o.net_amount));
            }}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            {orders.map((o) => (
              <option key={o.order_id} value={o.order_id}>
                {o.external_order_id}
              </option>
            ))}
          </select>
        </div>

        <Field
          id="cod-courier"
          label="Courier"
          value={courier}
          onChange={(e) => setCourier(e.target.value)}
          placeholder="Delhivery"
        />
        <Field
          id="cod-amount"
          label="COD amount (₹)"
          type="number"
          required
          value={codAmount}
          onChange={(e) => setCodAmount(e.target.value)}
        />

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Logging…" : "Log collection"}
        </Button>
      </form>
    </div>
  );
}
