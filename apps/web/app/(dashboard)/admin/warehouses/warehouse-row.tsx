"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { StatusPill } from "@/components/ui/status-pill";
import { friendlyError } from "@/lib/friendly-error";

type Warehouse = {
  warehouse_id: string;
  name: string;
  type: string;
  address: string | null;
  status: string;
};

export function WarehouseRow({
  warehouse,
  striped,
  canEdit,
}: {
  warehouse: Warehouse;
  striped: boolean;
  canEdit: boolean;
}) {
  const router = useRouter();
  const supabase = createClient();
  const [editing, setEditing] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [name, setName] = useState(warehouse.name);
  const [address, setAddress] = useState(warehouse.address ?? "");

  async function handleSave() {
    setLoading(true);
    setError(null);
    const { error } = await supabase
      .from("warehouses")
      .update({ name, address: address || null })
      .eq("warehouse_id", warehouse.warehouse_id);
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
    const nextStatus = warehouse.status === "active" ? "inactive" : "active";
    const { error } = await supabase
      .from("warehouses")
      .update({ status: nextStatus })
      .eq("warehouse_id", warehouse.warehouse_id);
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
        <td className="px-4 py-2 font-data text-ink-muted">{warehouse.type}</td>
        <td className="px-4 py-2">
          <input
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            className="h-8 w-full border border-line bg-surface px-2 text-sm outline-none focus:border-accent"
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
      <td className="px-4 py-3 text-ink">{warehouse.name}</td>
      <td className="px-4 py-3 font-data text-ink-muted">{warehouse.type}</td>
      <td className="px-4 py-3 text-ink-muted">{warehouse.address ?? "—"}</td>
      <td className="px-4 py-3">
        <button
          onClick={canEdit ? toggleStatus : undefined}
          disabled={!canEdit || loading}
          className={canEdit ? "cursor-pointer" : "cursor-default"}
          title={canEdit ? "Click to toggle active/inactive" : undefined}
        >
          <StatusPill status={warehouse.status === "active" ? "success" : "neutral"}>
            {warehouse.status}
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
