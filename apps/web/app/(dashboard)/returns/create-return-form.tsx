"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";

type Order = { order_id: string; external_order_id: string };
type Warehouse = { warehouse_id: string; name: string };

export function CreateReturnForm({
  orders,
  warehouses,
}: {
  orders: Order[];
  warehouses: Warehouse[];
}) {
  const router = useRouter();
  const supabase = createClient();

  const [orderId, setOrderId] = useState(orders[0]?.order_id ?? "");
  const [reason, setReason] = useState("");
  const [warehouseId, setWarehouseId] = useState(
    warehouses[0]?.warehouse_id ?? "",
  );
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { error } = await supabase.from("returns").insert({
      order_id: orderId,
      return_reason: reason || null,
      warehouse_id: warehouseId || null,
    });

    setLoading(false);

    if (error) {
      setError(error.message);
      return;
    }

    setReason("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Log a return</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="return-order" className="text-sm font-medium text-ink">
            Order
          </label>
          <select
            id="return-order"
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

        <Field
          id="return-reason"
          label="Reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Customer changed mind"
        />

        <div className="flex flex-col gap-1.5">
          <label
            htmlFor="return-warehouse"
            className="text-sm font-medium text-ink"
          >
            Destination warehouse
          </label>
          <select
            id="return-warehouse"
            value={warehouseId}
            onChange={(e) => setWarehouseId(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            {warehouses.map((w) => (
              <option key={w.warehouse_id} value={w.warehouse_id}>
                {w.name}
              </option>
            ))}
          </select>
        </div>

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Logging…" : "Log return"}
        </Button>
      </form>
    </div>
  );
}
