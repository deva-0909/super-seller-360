import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { CreateProductForm } from "./create-product-form";

export default async function ProductsPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const { data: products } = await supabase
    .from("products")
    .select("product_id, sku, name, category, hsn, gst_rate, cost_price, status")
    .order("name");

  const canCreate = ["Super Admin", "Operations Manager"].includes(currentUser.roleName);

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Products
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        The one canonical product per SKU that every channel maps into (see
        Channels → SKU mapping).
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Name</th>
                <th className="px-4 py-3 font-medium">SKU</th>
                <th className="px-4 py-3 font-medium">Category</th>
                <th className="px-4 py-3 font-medium">HSN</th>
                <th className="px-4 py-3 font-medium text-right">GST %</th>
                <th className="px-4 py-3 font-medium text-right">Cost</th>
                <th className="px-4 py-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {products?.map((p, i) => (
                <tr
                  key={p.product_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3 text-ink">{p.name}</td>
                  <td className="px-4 py-3 font-data text-ink-muted">{p.sku}</td>
                  <td className="px-4 py-3 text-ink-muted">{p.category ?? "—"}</td>
                  <td className="px-4 py-3 font-data text-ink-muted">{p.hsn ?? "—"}</td>
                  <td className="px-4 py-3 text-right font-data text-ink-muted">
                    {p.gst_rate != null ? `${p.gst_rate}%` : "—"}
                  </td>
                  <td className="px-4 py-3 text-right font-data text-ink-muted">
                    {p.cost_price != null ? `₹${Number(p.cost_price).toLocaleString("en-IN")}` : "—"}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill status={p.status === "active" ? "success" : "neutral"}>
                      {p.status}
                    </StatusPill>
                  </td>
                </tr>
              ))}
              {!products?.length ? (
                <tr>
                  <td colSpan={7} className="px-4 py-8 text-center text-sm text-ink-muted">
                    No products yet.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateProductForm />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Only Super Admin and Operations Manager can add products.
          </div>
        )}
      </div>
    </div>
  );
}
