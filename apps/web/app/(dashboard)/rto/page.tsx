import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import Link from "next/link";
import { CreateRtoForm } from "./create-rto-form";

const STATUS_MAP: Record<string, "success" | "warning" | "danger" | "neutral"> = {
  restocked: "success",
  received: "neutral",
  inspected: "neutral",
  quarantined: "warning",
  claimed: "warning",
  initiated: "warning",
  in_transit: "neutral",
};

export default async function RtoPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const [{ data: rtos }, { data: orders }, { data: warehouses }] =
    await Promise.all([
      supabase
        .from("rtos")
        .select("rto_id, status, reason, awb, received_date, orders(external_order_id)")
        .order("created_at", { ascending: false }),
      supabase
        .from("orders")
        .select("order_id, external_order_id")
        .order("order_date", { ascending: false })
        .limit(50),
      supabase.from("warehouses").select("warehouse_id, name").order("name"),
    ]);

  const canCreate =
    currentUser.roleName === "Super Admin" ||
    currentUser.roleName === "Operations Manager" ||
    currentUser.roleName === "Warehouse Manager" ||
    currentUser.roleName === "Marketplace Manager";

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">RTO</h1>
      <p className="mt-1 text-sm text-ink-muted">
        Delivery failures returning to origin — tracked completely separately
        from customer returns.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Order</th>
                <th className="px-4 py-3 font-medium">AWB</th>
                <th className="px-4 py-3 font-medium">Reason</th>
                <th className="px-4 py-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {rtos?.map((r, i) => (
                <tr
                  key={r.rto_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3">
                    <Link
                      href={`/rto/${r.rto_id}`}
                      className="font-data text-accent hover:underline"
                    >
                      {(r.orders as unknown as { external_order_id: string } | null)
                        ?.external_order_id ?? "—"}
                    </Link>
                  </td>
                  <td className="px-4 py-3 font-data text-ink-muted">
                    {r.awb ?? "—"}
                  </td>
                  <td className="px-4 py-3 text-ink-muted">
                    {r.reason ?? "—"}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill status={STATUS_MAP[r.status] ?? "neutral"}>
                      {r.status}
                    </StatusPill>
                  </td>
                </tr>
              ))}
              {!rtos?.length ? (
                <tr>
                  <td
                    colSpan={4}
                    className="px-4 py-8 text-center text-sm text-ink-muted"
                  >
                    No RTOs yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateRtoForm orders={orders ?? []} warehouses={warehouses ?? []} />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Your role can view RTOs but not create them.
          </div>
        )}
      </div>
    </div>
  );
}
