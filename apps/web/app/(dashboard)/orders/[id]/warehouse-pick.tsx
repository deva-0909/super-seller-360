"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";

export function WarehousePick({ orderId, current, warehouses, canEdit }: { orderId: string; current: string | null; warehouses: { warehouse_id: string; name: string }[]; canEdit: boolean }) {
  const router = useRouter();
  const supabase = createClient();
  const [v, setV] = useState(current ?? "");
  const [err, setErr] = useState<string | null>(null);
  const name = warehouses.find((w) => w.warehouse_id === v)?.name;
  async function change(next: string) {
    setErr(null); const prev = v; setV(next);
    const { error } = await supabase.from("orders").update({ warehouse_id: next || null }).eq("order_id", orderId);
    if (error) { setV(prev); setErr(friendlyError(error.message)); } else router.refresh();
  }
  return (
    <div className="mt-6 flex flex-wrap items-center gap-3 text-sm">
      <span className="font-semibold text-ink">Ships from</span>
      {canEdit ? (
        <select className="h-9 rounded-lg border border-line bg-surface px-2 text-sm text-ink" value={v} onChange={(e) => void change(e.target.value)}>
          <option value="">Automatic (warehouse with stock)</option>
          {warehouses.map((w) => <option key={w.warehouse_id} value={w.warehouse_id}>{w.name}</option>)}
        </select>
      ) : <span className="text-ink-muted">{name ?? "Automatic"}</span>}
      {err ? <span className="text-danger">{err}</span> : null}
    </div>
  );
}
