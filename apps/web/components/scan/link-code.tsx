"use client";

import { useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { friendlyError } from "@/lib/friendly-error";
import type { CatRow } from "@/lib/scan/catalog";

/** An unknown code was scanned (a supplier's own label, a carton code): choose the product it belongs to, once, and it is remembered for good. */
export function LinkCode({ code, products, onLinked, onCancel }: {
  code: string; products: { product_id: string; label: string }[];
  onLinked: (row: CatRow) => void; onCancel: () => void;
}) {
  const supabase = createClient();
  const [q, setQ] = useState("");
  const [pid, setPid] = useState("");
  const [kind, setKind] = useState("supplier");
  const [pack, setPack] = useState("1");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const shown = useMemo(() => {
    const t = q.trim().toLowerCase();
    return (t ? products.filter((p) => p.label.toLowerCase().includes(t)) : products).slice(0, 60);
  }, [q, products]);

  async function save() {
    if (!pid) { setErr("Choose the product"); return; }
    setBusy(true); setErr(null);
    const n = kind === "carton" ? Math.max(1, Math.floor(Number(pack) || 1)) : 1;
    const { error } = await supabase.rpc("product_code_link", { p_code: code, p_product: pid, p_kind: kind, p_pack_qty: n });
    setBusy(false);
    if (error) { setErr(friendlyError(error.message)); return; }
    const p = products.find((x) => x.product_id === pid)!;
    const [sku, ...rest] = p.label.split(" · ");
    onLinked({ code: code.trim().toLowerCase(), product_id: pid, sku, product_name: rest.join(" · "), size: null, colour: null, lot_tracked: false, status: "active", pack_qty: n, kind });
  }

  const cls = "h-10 border border-line bg-surface px-2 text-sm text-ink";
  return (
    <div className="space-y-2 border-2 border-warning bg-warning-tint p-3 text-sm">
      <p className="font-medium text-ink">Unknown code <span className="font-data">{code}</span>. Which product is it?</p>
      <input className={`${cls} w-full`} placeholder="Search product or SKU" value={q} onChange={(e) => setQ(e.target.value)} />
      <select className={`${cls} w-full`} size={6} value={pid} onChange={(e) => setPid(e.target.value)}>
        {shown.map((p) => <option key={p.product_id} value={p.product_id}>{p.label}</option>)}
      </select>
      <div className="flex flex-wrap items-center gap-2">
        <select className={cls} value={kind} onChange={(e) => setKind(e.target.value)}>
          <option value="supplier">Supplier&apos;s label</option>
          <option value="carton">Carton / pack code</option>
          <option value="marketplace">Marketplace code</option>
          <option value="own">Our own label</option>
        </select>
        {kind === "carton" ? <label className="flex items-center gap-1 text-ink">pieces in the pack <input className={`${cls} w-20`} inputMode="numeric" value={pack} onChange={(e) => setPack(e.target.value)} /></label> : null}
        <button type="button" disabled={busy} onClick={save} className="h-10 bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover disabled:opacity-60">{busy ? "Saving…" : "Link and count it"}</button>
        <button type="button" onClick={onCancel} className="h-10 px-3 text-sm text-ink-muted hover:underline">Skip this code</button>
      </div>
      {err ? <p role="alert" className="text-danger">{err}</p> : null}
    </div>
  );
}
