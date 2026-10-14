import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { fetchAll } from "@/lib/fetch-all";
import type { CatRow } from "@/lib/scan/catalog";
import { TransferActions } from "./transfer-actions";

const STATUS: Record<string, string> = { in_transit: "On its way", received: "Received", received_short: "Received short", resolved: "Settled", cancelled: "Cancelled" };

export default async function TransferPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: t } = await supabase.from("stock_transfers").select("*").eq("transfer_id", id).maybeSingle();
  if (!t) notFound();
  const [{ data: lines }, { data: whs }, { data: me }, { data: canGrn }, { data: canDecide }] = await Promise.all([
    supabase.from("stock_transfer_lines").select("line_id, product_id, lot_no, qty_sent, qty_received").eq("transfer_id", id),
    supabase.from("warehouses").select("warehouse_id, name"),
    supabase.auth.getUser(), supabase.rpc("has_grn_write"), supabase.rpc("has_req_decide"),
  ]);
  const wn = new Map((whs ?? []).map((w) => [w.warehouse_id, w.name]));
  const ids = (lines ?? []).map((l) => l.product_id);
  const { data: prods } = ids.length ? await supabase.from("products").select("product_id, sku, name").in("product_id", ids) : { data: [] };
  const pm = new Map((prods ?? []).map((p) => [p.product_id, `${p.sku} · ${p.name}`]));
  const cat = t.status === "in_transit" && canGrn === true ? (await fetchAll<CatRow>(() => supabase.rpc("scan_catalog"))).data : [];
  const rows = (lines ?? []).map((l) => ({ line_id: l.line_id, label: pm.get(l.product_id) ?? "", product_id: l.product_id, lot: l.lot_no, sent: Number(l.qty_sent), got: l.qty_received == null ? null : Number(l.qty_received) }));
  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/inventory/transfers" className="text-sm text-ink-muted hover:text-ink">← Transfers</Link>
      <h1 className="mt-3 text-lg font-semibold tracking-tight text-ink">{t.transfer_no} <span className="text-sm font-normal text-ink-muted">{STATUS[t.status] ?? t.status}</span></h1>
      <p className="mt-1 text-sm text-ink-muted">{wn.get(t.from_wh)} → {wn.get(t.to_wh)} · dispatched {String(t.dispatched_at).slice(0, 10)}{t.ref_no ? ` · gate pass ${t.ref_no}` : ""}</p>
      {t.receive_note ? <p className="mt-1 text-sm text-ink-muted">Receiver&apos;s note: {t.receive_note}</p> : null}
      {t.resolution ? <p className="mt-1 text-sm text-ink-muted">Settled: shortfall {t.resolution === "returned" ? "sent back to the sending store" : "written off"}. {t.resolve_note}</p> : null}
      {t.status === "cancelled" ? <p className="mt-1 text-sm text-ink-muted">Cancelled: {t.resolve_note}</p> : null}
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-2 font-medium">Item</th><th className="px-3 py-2 font-medium">Lot</th><th className="px-3 py-2 text-right font-medium">Sent</th><th className="px-3 py-2 text-right font-medium">Received</th></tr></thead>
          <tbody>{rows.map((r) => (
            <tr key={r.line_id} className="border-b border-line/60">
              <td className="px-3 py-2">{r.label}</td><td className="px-3 py-2 text-ink-muted">{r.lot ?? "—"}</td><td className="px-3 py-2 text-right font-data">{r.sent}</td>
              <td className={`px-3 py-2 text-right font-data ${r.got != null && r.got < r.sent ? "text-danger" : ""}`}>{r.got ?? "—"}</td>
            </tr>))}</tbody>
        </table>
      </div>
      <TransferActions id={id} status={t.status} lines={rows} catalog={cat} canGrn={canGrn === true} canDecide={canDecide === true} isSender={t.dispatched_by === me.user?.id} />
    </div>
  );
}
