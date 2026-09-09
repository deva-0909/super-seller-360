import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { RtoActions } from "./rto-actions";

export default async function RtoDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const { data: rto } = await supabase
    .from("rtos")
    .select(
      "rto_id, status, reason, awb, received_date, inspection_result, warehouse_id, orders(external_order_id, net_amount), warehouses(name)",
    )
    .eq("rto_id", id)
    .single();

  if (!rto) {
    notFound();
  }

  const { data: movements } = await supabase
    .from("inventory_transactions")
    .select("inventory_txn_id, quantity, before_qty, after_qty, products(name, sku)")
    .eq("reference_id", id)
    .eq("reference_type", "rto");

  const canAct =
    currentUser.roleName === "Super Admin" ||
    currentUser.roleName === "Operations Manager" ||
    currentUser.roleName === "Warehouse Manager" ||
    currentUser.roleName === "Marketplace Manager";

  const order = rto.orders as unknown as {
    external_order_id: string;
    net_amount: number;
  } | null;
  const warehouse = rto.warehouses as unknown as { name: string } | null;

  return (
    <div className="mx-auto max-w-2xl px-8 py-8">
      <div className="flex items-baseline justify-between">
        <div>
          <h1 className="font-data text-lg font-semibold tracking-tight text-ink">
            RTO — {order?.external_order_id}
          </h1>
          <p className="mt-1 text-sm text-ink-muted">
            {rto.reason ?? "No reason given"}
            {rto.awb ? ` · AWB ${rto.awb}` : ""}
          </p>
        </div>
        <StatusPill
          status={
            rto.status === "restocked"
              ? "success"
              : rto.status === "quarantined" || rto.status === "claimed"
                ? "warning"
                : "neutral"
          }
        >
          {rto.status}
        </StatusPill>
      </div>

      <div className="mt-6 border border-line bg-surface p-5">
        <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
          <dt className="text-ink-muted">Order value</dt>
          <dd className="font-data text-ink">
            ₹{Number(order?.net_amount ?? 0).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Destination warehouse</dt>
          <dd className="text-ink">{warehouse?.name ?? "Not set"}</dd>
          <dt className="text-ink-muted">Received date</dt>
          <dd className="font-data text-ink">
            {rto.received_date
              ? new Date(rto.received_date).toLocaleDateString()
              : "—"}
          </dd>
          <dt className="text-ink-muted">Inspection result</dt>
          <dd className="text-ink">{rto.inspection_result ?? "—"}</dd>
        </dl>
      </div>

      {movements?.length ? (
        <>
          <h2 className="mt-8 text-sm font-semibold text-ink">
            Stock credited
          </h2>
          <div className="mt-3 border border-line bg-surface">
            <table className="w-full text-left text-sm">
              <thead>
                <tr className="border-b border-line-strong text-xs text-ink-muted">
                  <th className="px-4 py-2.5 font-medium">Product</th>
                  <th className="px-4 py-2.5 font-medium">Qty</th>
                  <th className="px-4 py-2.5 font-medium">Before → After</th>
                </tr>
              </thead>
              <tbody>
                {movements.map((m) => (
                  <tr key={m.inventory_txn_id}>
                    <td className="px-4 py-2.5 text-ink">
                      {(m.products as unknown as { name: string } | null)
                        ?.name ?? "—"}
                    </td>
                    <td className="px-4 py-2.5 font-data text-success">
                      +{m.quantity}
                    </td>
                    <td className="px-4 py-2.5 font-data text-ink-muted">
                      {m.before_qty} → {m.after_qty}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      ) : null}

      <h2 className="mt-8 text-sm font-semibold text-ink">Actions</h2>
      <div className="mt-3 border border-line bg-surface p-5">
        {canAct ? (
          <RtoActions
            rtoId={rto.rto_id}
            status={rto.status}
            hasWarehouse={!!rto.warehouse_id}
          />
        ) : (
          <p className="text-sm text-ink-muted">
            Your role can view this RTO but not update it.
          </p>
        )}
      </div>
    </div>
  );
}
