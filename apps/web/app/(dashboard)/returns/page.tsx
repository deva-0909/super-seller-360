import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import Link from "next/link";
import { CreateReturnForm } from "./create-return-form";

const STATUS_MAP: Record<string, "success" | "warning" | "danger" | "neutral"> = {
  restocked: "success",
  received: "neutral",
  inspected: "neutral",
  quarantined: "warning",
  claimed: "warning",
  rejected: "danger",
  requested: "warning",
  approved: "neutral",
  pickup: "neutral",
  in_transit: "neutral",
};

export default async function ReturnsPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const [{ data: returns }, { data: orders }, { data: warehouses }] =
    await Promise.all([
      supabase
        .from("returns")
        .select("return_id, status, return_reason, received_date, source, orders(external_order_id)")
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
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Returns
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Every stage is tracked separately — saleable stock only increases
        after a return is received, inspected, and dispositioned as good.
        Returns come in automatically once a marketplace/courier
        integration is connected — the form on the right is the manual
        fallback for anything the automated feed hasn&apos;t captured yet, not
        the primary way returns should get logged.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Order</th>
                <th className="px-4 py-3 font-medium">Reason</th>
                <th className="px-4 py-3 font-medium">Status</th>
                <th className="px-4 py-3 font-medium">Received</th>
                <th className="px-4 py-3 font-medium">Source</th>
              </tr>
            </thead>
            <tbody>
              {returns?.map((r, i) => (
                <tr
                  key={r.return_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3">
                    <Link
                      href={`/returns/${r.return_id}`}
                      className="font-data text-accent hover:underline"
                    >
                      {(r.orders as unknown as { external_order_id: string } | null)
                        ?.external_order_id ?? "—"}
                    </Link>
                  </td>
                  <td className="px-4 py-3 text-ink-muted">
                    {r.return_reason ?? "—"}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill status={STATUS_MAP[r.status] ?? "neutral"}>
                      {r.status}
                    </StatusPill>
                  </td>
                  <td className="px-4 py-3 font-data text-ink-muted">
                    {r.received_date
                      ? new Date(r.received_date).toLocaleDateString()
                      : "—"}
                  </td>
                  <td className="px-4 py-3">
                    <span
                      className={`text-xs ${r.source === "webhook" ? "text-success" : "text-ink-faint"}`}
                    >
                      {r.source === "webhook" ? "Auto (API)" : "Manual"}
                    </span>
                  </td>
                </tr>
              ))}
              {!returns?.length ? (
                <tr>
                  <td
                    colSpan={5}
                    className="px-4 py-8 text-center text-sm text-ink-muted"
                  >
                    No returns yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateReturnForm
            orders={orders ?? []}
            warehouses={warehouses ?? []}
          />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Your role can view returns but not create them.
          </div>
        )}
      </div>
    </div>
  );
}
