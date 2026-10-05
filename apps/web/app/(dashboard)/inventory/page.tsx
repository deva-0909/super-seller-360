import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fetchAll } from "@/lib/fetch-all";
import { TimeoutPill, type TimeoutState } from "@/components/ui/timeout-pill";

export default async function InventoryPage() {
  const supabase = await createClient();
  const { data: canUpload } = await supabase.rpc("import_can", { p_kind: "stock_count" }).then((r) => ({ data: r.data === true }));

  const { data: balances } = await fetchAll<{ quantity: number; updated_at: string; product_id: string; products: unknown; warehouses: unknown }>(() => supabase
    .from("inventory_balances")
    .select("quantity, updated_at, product_id, products(name, sku), warehouses(name)")
    .order("updated_at", { ascending: false }).order("product_id").order("warehouse_id"));

  const { data: resRows } = await fetchAll<{ product_id: string; reserved: number }>(() => supabase.from("inventory_reserved").select("product_id, reserved").order("product_id"));
  const reserved = new Map((resRows ?? []).map((r) => [r.product_id as string, Number(r.reserved)]));

  const { data: agingRows } = await fetchAll<{ sku: string; timeout_state: string; days_left: number | null; timeout_date: string | null }>(() => supabase
    .from("sku_stock_aging")
    .select("sku, timeout_state, days_left, timeout_date")
    .order("sku"));
  const aging = new Map((agingRows ?? []).map((a) => [a.sku, a]));
  const overdueCount = (agingRows ?? []).filter((a) => a.timeout_state === "overdue").length;
  const nearingCount = (agingRows ?? []).filter((a) => a.timeout_state === "nearing").length;

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Inventory
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Current saleable stock per warehouse — only updated by a confirmed
        receipt and inspection, never by a return or RTO being logged.
      </p>

      {canUpload ? (
        <p className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-sm">
          <Link href="/imports/opening_stock" className="font-medium text-accent hover:underline">Upload opening stock</Link>
          <Link href="/imports/stock_count" className="font-medium text-accent hover:underline">Upload a stock count</Link>
          <a href="/api/import-template/stock_count" className="text-accent hover:underline" download>Download the count sheet</a>
        </p>
      ) : null}

      {overdueCount + nearingCount > 0 ? (
        <div className="mt-4 flex flex-wrap items-center justify-between gap-2 border border-warning/40 bg-warning-tint px-4 py-3 text-sm text-ink">
          <span>
            <strong>{overdueCount}</strong> SKU{overdueCount === 1 ? "" : "s"} past stock time-out and{" "}
            <strong>{nearingCount}</strong> nearing it (within 15 days).
          </span>
          <Link href="/insights" className="text-xs font-medium text-accent hover:underline">
            See the time-out watch →
          </Link>
        </div>
      ) : null}

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Product</th>
              <th className="px-4 py-3 font-medium">SKU</th>
              <th className="px-4 py-3 font-medium">Warehouse</th>
              <th className="px-4 py-3 font-medium text-right">Quantity</th>
              <th className="px-4 py-3 font-medium text-right" title="Total across warehouses, on orders not yet shipped">Promised to orders</th>
              <th className="px-4 py-3 font-medium">Stock time-out</th>
              <th className="px-4 py-3 font-medium">Last movement</th>
            </tr>
          </thead>
          <tbody>
            {balances?.map((b, i) => (
              <tr
                key={`${(b.products as unknown as { sku: string } | null)?.sku}-${(b.warehouses as unknown as { name: string } | null)?.name}`}
                className={
                  aging.get((b.products as unknown as { sku: string } | null)?.sku ?? "")?.timeout_state === "overdue" && Number(b.quantity) > 0
                    ? "bg-danger-tint/40"
                    : aging.get((b.products as unknown as { sku: string } | null)?.sku ?? "")?.timeout_state === "nearing" && Number(b.quantity) > 0
                      ? "bg-warning-tint/40"
                      : i % 2 === 1
                        ? "bg-surface-sunken/50"
                        : undefined
                }
              >
                <td className="px-4 py-3 text-ink">
                  {(b.products as unknown as { name: string } | null)?.name}
                </td>
                <td className="px-4 py-3 font-data text-ink-muted">
                  {(b.products as unknown as { sku: string } | null)?.sku}
                </td>
                <td className="px-4 py-3 text-ink-muted">
                  {(b.warehouses as unknown as { name: string } | null)?.name}
                </td>
                <td className="px-4 py-3 text-right font-data font-medium text-ink">
                  {b.quantity}
                </td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{reserved.get(b.product_id as string) ?? 0}</td>
                <td className="px-4 py-3">
                  {(() => {
                    const a = aging.get((b.products as unknown as { sku: string } | null)?.sku ?? "");
                    return a ? (
                      <span title={a.timeout_date ? `Times out on ${a.timeout_date}` : undefined}>
                        <TimeoutPill state={(Number(b.quantity) > 0 ? a.timeout_state : "no_stock") as TimeoutState} daysLeft={a.days_left} />
                      </span>
                    ) : null;
                  })()}
                </td>
                <td className="px-4 py-3 font-data text-ink-muted">
                  {new Date(b.updated_at).toLocaleString()}
                </td>
              </tr>
            ))}
            {!balances?.length ? (
              <tr>
                <td
                  colSpan={6}
                  className="px-4 py-8 text-center text-sm text-ink-muted"
                >
                  No stock movements yet — restocking a return or RTO is what
                  creates the first entry here.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
