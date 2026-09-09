import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { CreateWarehouseForm } from "./create-warehouse-form";

export default async function WarehousesPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const { data: warehouses } = await supabase
    .from("warehouses")
    .select("warehouse_id, name, type, address, status")
    .order("name");

  const canCreate = ["Super Admin", "Operations Manager"].includes(currentUser.roleName);

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Warehouses
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Physical stock locations — every Return, RTO, and inventory balance
        is tied to one of these.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Name</th>
                <th className="px-4 py-3 font-medium">Type</th>
                <th className="px-4 py-3 font-medium">Address</th>
                <th className="px-4 py-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {warehouses?.map((w, i) => (
                <tr
                  key={w.warehouse_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3 text-ink">{w.name}</td>
                  <td className="px-4 py-3 font-data text-ink-muted">{w.type}</td>
                  <td className="px-4 py-3 text-ink-muted">{w.address ?? "—"}</td>
                  <td className="px-4 py-3">
                    <StatusPill status={w.status === "active" ? "success" : "neutral"}>
                      {w.status}
                    </StatusPill>
                  </td>
                </tr>
              ))}
              {!warehouses?.length ? (
                <tr>
                  <td colSpan={4} className="px-4 py-8 text-center text-sm text-ink-muted">
                    No warehouses yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateWarehouseForm />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Only Super Admin and Operations Manager can add warehouses.
          </div>
        )}
      </div>
    </div>
  );
}
