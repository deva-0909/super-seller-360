"use client";

import { useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { ScanBox } from "@/components/scan/scan-box";
import { stateText } from "@/lib/scan/serial";

type Ev = { event_id: string; event: string; from_state: string | null; to_state: string | null; ref_type: string | null; note: string | null; at: string; warehouse_id: string | null };
type Found = { serial: string; state: string; sku: string; name: string; where: string; events: Ev[]; wn: Record<string, string> };

export function PieceLookup() {
  const supabase = useMemo(() => createClient(), []);
  const [found, setFound] = useState<Found | null>(null);
  const [err, setErr] = useState<string | null>(null);
  async function find(code: string) {
    setErr(null); setFound(null);
    const serial = code.trim().toLowerCase();
    const { data: u } = await supabase.from("item_units").select("unit_id, serial, state, product_id, warehouse_id").eq("serial", serial).maybeSingle();
    if (!u) { setErr(`No piece has the serial ${code.trim()}.`); return; }
    const [{ data: p }, { data: ev }, { data: whs }] = await Promise.all([
      supabase.from("products").select("sku, name").eq("product_id", u.product_id).maybeSingle(),
      supabase.from("unit_events").select("event_id, event, from_state, to_state, ref_type, note, at, warehouse_id").eq("unit_id", u.unit_id).order("at"),
      supabase.from("warehouses").select("warehouse_id, name"),
    ]);
    const wn = Object.fromEntries((whs ?? []).map((w) => [w.warehouse_id, w.name]));
    setFound({ serial: u.serial, state: u.state, sku: p?.sku ?? "", name: p?.name ?? "", where: u.warehouse_id ? wn[u.warehouse_id] ?? "" : "", events: (ev ?? []) as Ev[], wn });
  }
  return (
    <div className="space-y-3 border border-line bg-surface p-4">
      <ScanBox onScan={(c) => void find(c)} />
      {err ? <p role="alert" className="text-sm text-danger">{err}</p> : null}
      {found ? (
        <div className="text-sm">
          <p className="font-semibold text-ink">{found.sku} · {found.name} <span className="font-data text-ink-muted">{found.serial}</span></p>
          <p className="mt-1 text-ink">Now: <b>{stateText(found.state)}</b>{found.where ? ` · ${found.where}` : ""}</p>
          <ul className="mt-2 divide-y divide-line border border-line">
            {found.events.map((e) => (
              <li key={e.event_id} className="px-3 py-2"><span className="font-data text-xs text-ink-muted">{e.at.slice(0, 16).replace("T", " ")}</span> · {stateText(e.event)}{e.warehouse_id ? ` · ${found.wn[e.warehouse_id] ?? ""}` : ""}{e.note ? <span className="text-ink-muted"> · {e.note}</span> : null}</li>
            ))}
          </ul>
        </div>
      ) : null}
    </div>
  );
}
