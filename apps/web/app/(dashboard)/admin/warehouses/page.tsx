import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { CreateWarehouseForm } from "./create-warehouse-form";
import { WarehouseRow } from "./warehouse-row";

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
                {canCreate ? <th className="px-4 py-3 font-medium"></th> : null}
              </tr>
            </thead>
            <tbody>
              {warehouses?.map((w, i) => (
                <WarehouseRow
                  key={w.warehouse_id}
                  warehouse={w}
                  striped={i % 2 === 1}
                  canEdit={canCreate}
                />
              ))}
              {!warehouses?.length ? (
                <tr>
                  <td colSpan={5} className="px-4 py-8 text-center text-sm text-ink-muted">
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
