import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

const STATUS: Record<string, string> = { in_transit: "On its way", received: "Received", received_short: "Received short: needs a manager", resolved: "Settled", cancelled: "Cancelled" };

export default async function TransfersPage() {
  const supabase = await createClient();
  const [{ data: canWrite }, { data: rows }, { data: whs }] = await Promise.all([
    supabase.rpc("has_grn_write"),
    supabase.from("stock_transfers").select("transfer_id, transfer_no, from_wh, to_wh, status, dispatched_at, stock_transfer_lines(qty_sent)").order("dispatched_at", { ascending: false }).limit(200),
    supabase.from("warehouses").select("warehouse_id, name"),
  ]);
  const wn = new Map((whs ?? []).map((w) => [w.warehouse_id, w.name]));
  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link href="/inventory" className="text-xs text-accent hover:underline">← Inventory</Link>
          <h1 className="mt-1 text-lg font-semibold tracking-tight text-ink">Store-to-store transfers</h1>
          <p className="mt-1 max-w-3xl text-sm text-ink-muted">Stock leaves the sending store when it is dispatched and is added to the other store only for what actually arrives. A shortfall must be explained and settled by a manager.</p>
        </div>
        {canWrite === true ? <Link href="/inventory/transfers/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">New transfer</Link> : null}
      </div>
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-3 py-2 font-medium">No.</th><th className="px-3 py-2 font-medium">Sent</th><th className="px-3 py-2 font-medium">From</th><th className="px-3 py-2 font-medium">To</th><th className="px-3 py-2 text-right font-medium">Units</th><th className="px-3 py-2 font-medium">Status</th></tr></thead>
          <tbody>
            {(rows ?? []).map((r) => (
              <tr key={r.transfer_id} className="border-b border-line/60">
                <td className="px-3 py-2"><Link className="text-accent hover:underline" href={`/inventory/transfers/${r.transfer_id}`}>{r.transfer_no}</Link></td>
                <td className="px-3 py-2">{String(r.dispatched_at).slice(0, 10)}</td>
                <td className="px-3 py-2">{wn.get(r.from_wh)}</td><td className="px-3 py-2">{wn.get(r.to_wh)}</td>
                <td className="px-3 py-2 text-right font-data">{((r.stock_transfer_lines as unknown as { qty_sent: number }[]) ?? []).reduce((s, l) => s + Number(l.qty_sent), 0)}</td>
                <td className={`px-3 py-2 ${r.status === "received_short" ? "text-danger" : "text-ink"}`}>{STATUS[r.status] ?? r.status}</td>
              </tr>
            ))}
            {!(rows ?? []).length ? <tr><td colSpan={6} className="px-3 py-6 text-center text-ink-muted">No transfers yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
