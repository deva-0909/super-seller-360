"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { StatusPill } from "@/components/ui/status-pill";
import { friendlyError } from "@/lib/friendly-error";

type Product = {
  product_id: string;
  sku: string;
  name: string;
  category: string | null;
  hsn: string | null;
  gst_rate: number | null;
  cost_price: number | null;
  status: string;
};

export function ProductRow({
  product,
  striped,
  canEdit,
}: {
  product: Product;
  striped: boolean;
  canEdit: boolean;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [editing, setEditing] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [name, setName] = useState(product.name);
  const [category, setCategory] = useState(product.category ?? "");
  const [hsn, setHsn] = useState(product.hsn ?? "");
  const [gstRate, setGstRate] = useState(product.gst_rate?.toString() ?? "");
  const [costPrice, setCostPrice] = useState(product.cost_price?.toString() ?? "");

  async function handleSave() {
    setLoading(true);
    setError(null);
    const { error } = await supabase
      .from("products")
      .update({
        name,
        category: category || null,
        hsn: hsn || null,
        gst_rate: gstRate ? Number(gstRate) : null,
        cost_price: costPrice ? Number(costPrice) : null,
      })
      .eq("product_id", product.product_id);
    setLoading(false);
    if (error) {
      setError(friendlyError(error.message));
      return;
    }
    setEditing(false);
    router.refresh();
  }

  async function toggleStatus() {
    setLoading(true);
    const nextStatus = product.status === "active" ? "inactive" : "active";
    const { error } = await supabase
      .from("products")
      .update({ status: nextStatus })
      .eq("product_id", product.product_id);
    setLoading(false);
    if (!error) {
      router.refresh();
    }
  }

  const rowClass = striped ? "bg-surface-sunken/50" : undefined;

  if (editing) {
    return (
      <tr className={rowClass}>
        <td className="px-4 py-2">
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="h-8 w-full border border-line bg-surface px-2 text-sm outline-none focus:border-accent"
          />
        </td>
        <td className="px-4 py-2 font-data text-ink-muted">{product.sku}</td>
        <td className="px-4 py-2">
          <input
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            className="h-8 w-full border border-line bg-surface px-2 text-sm outline-none focus:border-accent"
          />
        </td>
        <td className="px-4 py-2">
          <input
            value={hsn}
            onChange={(e) => setHsn(e.target.value)}
            className="h-8 w-full border border-line bg-surface px-2 text-sm outline-none focus:border-accent"
          />
        </td>
        <td className="px-4 py-2">
          <input
            type="number"
            value={gstRate}
            onChange={(e) => setGstRate(e.target.value)}
            className="h-8 w-20 border border-line bg-surface px-2 text-sm outline-none focus:border-accent"
          />
        </td>
        <td className="px-4 py-2">
          <input
            type="number"
            value={costPrice}
            onChange={(e) => setCostPrice(e.target.value)}
            className="h-8 w-24 border border-line bg-surface px-2 text-sm outline-none focus:border-accent"
          />
        </td>
        <td className="px-4 py-2" colSpan={2}>
          <div className="flex items-center gap-2">
            <button
              onClick={handleSave}
              disabled={loading}
              className="bg-accent px-2 py-1 text-xs font-medium text-white hover:bg-accent-hover disabled:opacity-50"
            >
              {loading ? "Saving…" : "Save"}
            </button>
            <button
              onClick={() => setEditing(false)}
              disabled={loading}
              className="border border-line px-2 py-1 text-xs text-ink hover:bg-surface-sunken"
            >
              Cancel
            </button>
            {error ? <span className="text-xs text-danger">{error}</span> : null}
          </div>
        </td>
      </tr>
    );
  }

  return (
    <tr className={rowClass}>
      <td className="px-4 py-3 text-ink">{product.name}</td>
      <td className="px-4 py-3 font-data text-ink-muted">{product.sku}</td>
      <td className="px-4 py-3 text-ink-muted">{product.category ?? "—"}</td>
      <td className="px-4 py-3 font-data text-ink-muted">{product.hsn ?? "—"}</td>
      <td className="px-4 py-3 text-right font-data text-ink-muted">
        {product.gst_rate != null ? `${product.gst_rate}%` : "—"}
      </td>
      <td className="px-4 py-3 text-right font-data text-ink-muted">
        {product.cost_price != null
          ? `₹${Number(product.cost_price).toLocaleString("en-IN")}`
          : "—"}
      </td>
      <td className="px-4 py-3">
        <button
          onClick={canEdit ? toggleStatus : undefined}
          disabled={!canEdit || loading}
          className={canEdit ? "cursor-pointer" : "cursor-default"}
          title={canEdit ? "Click to toggle active/inactive" : undefined}
        >
          <StatusPill status={product.status === "active" ? "success" : "neutral"}>
            {product.status}
          </StatusPill>
        </button>
      </td>
      {canEdit ? (
        <td className="px-4 py-3">
          <button
            onClick={() => setEditing(true)}
            className="text-xs text-accent hover:underline"
          >
            Edit
          </button>
        </td>
      ) : null}
    </tr>
  );
}
