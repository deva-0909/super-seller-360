import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { CreateCodForm } from "./create-cod-form";
import { RemitButton } from "./remit-button";

const STATUS_MAP: Record<string, "success" | "warning" | "danger" | "neutral"> = {
  remitted: "success",
  short_remit: "danger",
  collected: "warning",
  pending: "neutral",
};

export default async function CodPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const [{ data: collections }, { data: codOrders }] = await Promise.all([
    supabase
      .from("cod_collections")
      .select("cod_id, courier_name, cod_amount, collected_amount, remitted_amount, status, collected_date, orders(external_order_id)")
      .order("created_at", { ascending: false }),
    supabase
      .from("orders")
      .select("order_id, external_order_id, net_amount")
      .eq("payment_type", "cod")
      .order("order_date", { ascending: false })
      .limit(50),
  ]);

  const canAct =
    currentUser.roleName === "Super Admin" ||
    currentUser.roleName === "Finance Manager" ||
    currentUser.roleName === "Accountant";

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        COD collections
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Cash the courier collected on delivery, and how much of it has
        actually been remitted back to you — with ageing on what&apos;s still
        outstanding.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Order</th>
                <th className="px-4 py-3 font-medium">Courier</th>
                <th className="px-4 py-3 font-medium text-right">COD amt</th>
                <th className="px-4 py-3 font-medium text-right">Remitted</th>
                <th className="px-4 py-3 font-medium text-right">Pending</th>
                <th className="px-4 py-3 font-medium">Ageing</th>
                <th className="px-4 py-3 font-medium">Status</th>
                {canAct ? <th className="px-4 py-3 font-medium">Action</th> : null}
              </tr>
            </thead>
            <tbody>
              {collections?.map((c, i) => {
                const pending = Number(c.cod_amount) - Number(c.remitted_amount);
                const ageing = c.collected_date
                  ? Math.floor(
                      (Date.now() - new Date(c.collected_date).getTime()) /
                        (1000 * 60 * 60 * 24),
                    )
                  : null;
                return (
                  <tr
                    key={c.cod_id}
                    className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                  >
                    <td className="px-4 py-3 font-data text-ink">
                      {(c.orders as unknown as { external_order_id: string } | null)
                        ?.external_order_id}
                    </td>
                    <td className="px-4 py-3 text-ink-muted">
                      {c.courier_name ?? "—"}
                    </td>
                    <td className="px-4 py-3 text-right font-data text-ink">
                      ₹{Number(c.cod_amount).toLocaleString("en-IN")}
                    </td>
                    <td className="px-4 py-3 text-right font-data text-ink">
                      ₹{Number(c.remitted_amount).toLocaleString("en-IN")}
                    </td>
                    <td className="px-4 py-3 text-right font-data text-ink-muted">
                      {pending > 0 ? `₹${pending.toLocaleString("en-IN")}` : "—"}
                    </td>
                    <td className="px-4 py-3 font-data text-ink-muted">
                      {pending > 0 && ageing !== null ? `${ageing}d` : "—"}
                    </td>
                    <td className="px-4 py-3">
                      <StatusPill status={STATUS_MAP[c.status] ?? "neutral"}>
                        {c.status.replace("_", " ")}
                      </StatusPill>
                    </td>
                    {canAct ? (
                      <td className="px-4 py-3">
                        {pending > 0 ? (
                          <RemitButton codId={c.cod_id} pending={pending} />
                        ) : null}
                      </td>
                    ) : null}
                  </tr>
                );
              })}
              {!collections?.length ? (
                <tr>
                  <td
                    colSpan={canAct ? 8 : 7}
                    className="px-4 py-8 text-center text-sm text-ink-muted"
                  >
                    No COD collections logged yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canAct ? (
          <CreateCodForm orders={codOrders ?? []} />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Your role can view COD collections but not log new ones.
          </div>
        )}
      </div>
    </div>
  );
}
