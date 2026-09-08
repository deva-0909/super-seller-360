import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";

const FULFILMENT_STATUS_MAP: Record<
  string,
  "success" | "warning" | "danger" | "neutral"
> = {
  delivered: "success",
  shipped: "neutral",
  processing: "neutral",
  pending: "warning",
  cancelled: "danger",
  rto: "danger",
};

export default async function OrdersPage() {
  const supabase = await createClient();

  const { data: orders } = await supabase
    .from("orders")
    .select(
      "order_id, external_order_id, order_date, net_amount, fulfilment_status, payment_status, channels(name), invoices(invoice_id)",
    )
    .order("order_date", { ascending: false })
    .limit(100);

  return (
    <div className="px-8 py-8">
      <div className="flex items-baseline justify-between">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">
            Orders
          </h1>
          <p className="mt-1 text-sm text-ink-muted">
            Every order ingested from a connected channel.
          </p>
        </div>
        <Link
          href="/orders/import"
          className="border border-line px-3 py-1.5 text-sm text-ink hover:bg-surface-sunken"
        >
          Import CSV
        </Link>
      </div>

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Order</th>
              <th className="px-4 py-3 font-medium">Channel</th>
              <th className="px-4 py-3 font-medium">Date</th>
              <th className="px-4 py-3 font-medium">Net amount</th>
              <th className="px-4 py-3 font-medium">Fulfilment</th>
              <th className="px-4 py-3 font-medium">Invoiced</th>
            </tr>
          </thead>
          <tbody>
            {orders?.map((o, i) => (
              <tr
                key={o.order_id}
                className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
              >
                <td className="px-4 py-3">
                  <Link
                    href={`/orders/${o.order_id}`}
                    className="font-data text-accent hover:underline"
                  >
                    {o.external_order_id}
                  </Link>
                </td>
                <td className="px-4 py-3 text-ink-muted">
                  {(o.channels as unknown as { name: string } | null)?.name ??
                    "—"}
                </td>
                <td className="px-4 py-3 font-data text-ink-muted">
                  {new Date(o.order_date).toLocaleDateString()}
                </td>
                <td className="px-4 py-3 font-data text-ink">
                  ₹{Number(o.net_amount).toLocaleString("en-IN")}
                </td>
                <td className="px-4 py-3">
                  <StatusPill
                    status={
                      FULFILMENT_STATUS_MAP[o.fulfilment_status] ?? "neutral"
                    }
                  >
                    {o.fulfilment_status}
                  </StatusPill>
                </td>
                <td className="px-4 py-3">
                  <StatusPill
                    status={
                      (o.invoices as unknown as unknown[])?.length
                        ? "success"
                        : "neutral"
                    }
                  >
                    {(o.invoices as unknown as unknown[])?.length
                      ? "Invoiced"
                      : "Not invoiced"}
                  </StatusPill>
                </td>
              </tr>
            ))}
            {!orders?.length ? (
              <tr>
                <td
                  colSpan={6}
                  className="px-4 py-8 text-center text-sm text-ink-muted"
                >
                  No orders yet.{" "}
                  <Link
                    href="/orders/import"
                    className="text-accent hover:underline"
                  >
                    Import a CSV
                  </Link>{" "}
                  to bring some in.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
