import { createClient } from "@/lib/supabase/server";

export default async function InventoryPage() {
  const supabase = await createClient();

  const { data: balances } = await supabase
    .from("inventory_balances")
    .select("quantity, updated_at, products(name, sku), warehouses(name)")
    .order("updated_at", { ascending: false });

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Inventory
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Current saleable stock per warehouse — only updated by a confirmed
        receipt and inspection, never by a return or RTO being logged.
      </p>

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Product</th>
              <th className="px-4 py-3 font-medium">SKU</th>
              <th className="px-4 py-3 font-medium">Warehouse</th>
              <th className="px-4 py-3 font-medium text-right">Quantity</th>
              <th className="px-4 py-3 font-medium">Last movement</th>
            </tr>
          </thead>
          <tbody>
            {balances?.map((b, i) => (
              <tr
                key={`${(b.products as unknown as { sku: string } | null)?.sku}-${(b.warehouses as unknown as { name: string } | null)?.name}`}
                className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
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
                <td className="px-4 py-3 font-data text-ink-muted">
                  {new Date(b.updated_at).toLocaleString()}
                </td>
              </tr>
            ))}
            {!balances?.length ? (
              <tr>
                <td
                  colSpan={5}
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
