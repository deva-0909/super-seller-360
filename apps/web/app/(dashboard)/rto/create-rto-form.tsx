"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";

type Order = { order_id: string; external_order_id: string };
type Warehouse = { warehouse_id: string; name: string };

export function CreateRtoForm({
  orders,
  warehouses,
}: {
  orders: Order[];
  warehouses: Warehouse[];
}) {
  const router = useRouter();
  const supabase = createClient();

  const [orderId, setOrderId] = useState(orders[0]?.order_id ?? "");
  const [awb, setAwb] = useState("");
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

    const {
      data: { user },
    } = await supabase.auth.getUser();

    const { error } = await supabase.from("rtos").insert({
      order_id: orderId,
      awb: awb || null,
      reason: reason || null,
      warehouse_id: warehouseId || null,
      created_by: user?.id ?? null,
    });

    setLoading(false);

    if (error) {
      setError(error.message);
      return;
    }

    setAwb("");
    setReason("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Log an RTO</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="rto-order" className="text-sm font-medium text-ink">
            Order
          </label>
          <select
            id="rto-order"
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
          id="rto-awb"
          label="AWB"
          value={awb}
          onChange={(e) => setAwb(e.target.value)}
          placeholder="Courier tracking number"
        />
        <Field
          id="rto-reason"
          label="Reason"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Customer unreachable"
        />

        <div className="flex flex-col gap-1.5">
          <label htmlFor="rto-warehouse" className="text-sm font-medium text-ink">
            Destination warehouse
          </label>
          <select
            id="rto-warehouse"
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
          {loading ? "Logging…" : "Log RTO"}
        </Button>
      </form>
    </div>
  );
}
