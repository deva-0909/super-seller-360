import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { getAccess } from "@/lib/access";
import { CreateProductForm } from "./create-product-form";
import { ProductRow } from "./product-row";

export default async function ProductsPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const showCost = (await getAccess()).cost_view !== false;
  const { data: rawProducts } = await supabase
    .from("products")
    .select("product_id, sku, name, category, hsn, gst_rate, cost_price, stock_timeout_days, status, size, colour, barcode, brand, packaging_cost")
    .order("name");

  // people who may not see cost prices never receive them
  const products = (rawProducts ?? []).map((p) => (showCost ? p : { ...p, cost_price: null, packaging_cost: null }));
  const canCreate = ["Super Admin", "Operations Manager"].includes(currentUser.roleName);

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Products
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        The one canonical product per SKU that every channel maps into (see
        Channels → SKU mapping). Click a status pill to toggle active/inactive,
        or Edit to change details.
      </p>

      {canCreate ? (
        <p className="mt-3 flex gap-4 text-sm">
          <Link href="/imports/products" className="font-medium text-accent hover:underline">Upload the SKU master from Excel</Link>
                    <a href={`/api/import-template/${"products"}`} className="text-accent hover:underline">Download the template</a>
        </p>
      ) : null}

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
                {showCost ? <th className="px-4 py-3 font-medium text-right">Cost</th> : null}
                <th className="px-4 py-3 font-medium text-right">Time-out</th>
                <th className="px-4 py-3 font-medium">Status</th>
                {canCreate ? <th className="px-4 py-3 font-medium"></th> : null}
              </tr>
            </thead>
            <tbody>
              {products?.map((p, i) => (
                <ProductRow
                  key={p.product_id}
                  product={p}
                  striped={i % 2 === 1}
                  canEdit={canCreate}
                  showCost={showCost}
                />
              ))}
              {!products?.length ? (
                <tr>
                  <td colSpan={9} className="px-4 py-8 text-center text-sm text-ink-muted">
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
