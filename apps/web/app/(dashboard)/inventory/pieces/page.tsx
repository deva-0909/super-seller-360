import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { fetchAll } from "@/lib/fetch-all";
import { PieceLabels, type UnitToPrint } from "./piece-labels";
import { PieceLookup } from "./piece-lookup";

type U = { unit_id: string; serial: string; product_id: string; received_ref_id: string | null; created_at: string; warehouse_id: string | null };

export default async function PiecesPage() {
  const supabase = await createClient();
  const [units, { data: canPrint }, { data: check }, { data: issues }] = await Promise.all([
    fetchAll<U>(() => supabase.from("item_units").select("unit_id, serial, product_id, received_ref_id, created_at, warehouse_id").is("label_printed_at", null).eq("state", "in_stock").order("created_at").order("serial")),
    supabase.rpc("has_grn_write"),
    supabase.from("unit_stock_check").select("product_id, warehouse_id, counted, labelled, unlabelled").lt("unlabelled", 0),
    supabase.from("automation_issues").select("entity_id, message").eq("kind", "serial_unscanned").eq("status", "open").limit(50),
  ]);
  const ids = [...new Set([...units.data.map((u) => u.product_id), ...(check ?? []).map((c) => c.product_id)])];
  const { data: prods } = ids.length ? await supabase.from("products").select("product_id, sku, name, size, colour").in("product_id", ids) : { data: [] };
  const pm = new Map((prods ?? []).map((p) => [p.product_id, p]));
  const { data: whs } = await supabase.from("warehouses").select("warehouse_id, name");
  const wn = new Map((whs ?? []).map((w) => [w.warehouse_id, w.name]));
  const toPrint: UnitToPrint[] = units.data.map((u) => {
    const p = pm.get(u.product_id);
    return { unit_id: u.unit_id, serial: u.serial, product_id: u.product_id, sku: p?.sku ?? "", name: p?.name ?? "", size: p?.size ?? null, colour: p?.colour ?? null, group: `${u.product_id}|${u.received_ref_id ?? u.created_at.slice(0, 10)}`, received: u.created_at.slice(0, 10) };
  });
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/inventory" className="text-xs text-accent hover:underline">← Inventory</Link>
      <h1 className="mt-1 text-lg font-semibold tracking-tight text-ink">Piece labels and tracking</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">
        Every piece that comes in gets its own serial. Print the labels as the goods are received and stick one on each piece. From then on every scan names that exact piece: where it is, where it has been, and whether it was sold.
      </p>

      <h2 className="mt-6 text-sm font-semibold text-ink">Find a piece</h2>
      <div className="mt-2"><PieceLookup /></div>

      {(check ?? []).length || (issues ?? []).length ? (
        <div className="mt-6 border border-warning bg-warning-tint p-4 text-sm text-ink">
          <p className="font-semibold">Needs attention</p>
          {(issues ?? []).length ? <p className="mt-1">{(issues ?? []).length} shipped order{(issues ?? []).length === 1 ? "" : "s"} had pieces that were not scanned. <Link className="text-accent hover:underline" href="/inventory/pack">Scan the pieces that left</Link>.</p> : null}
          {(check ?? []).map((c) => <p key={`${c.product_id}${c.warehouse_id}`} className="mt-1">{pm.get(c.product_id)?.sku} at {wn.get(c.warehouse_id)}: {c.labelled} labelled pieces in stock but only {Number(c.counted)} counted. Find the missing pieces or write them off.</p>)}
        </div>
      ) : null}

      <h2 className="mt-6 text-sm font-semibold text-ink">Serial labels waiting to be printed</h2>
      <div className="mt-2"><PieceLabels units={toPrint} canPrint={canPrint === true} /></div>
    </div>
  );
}
