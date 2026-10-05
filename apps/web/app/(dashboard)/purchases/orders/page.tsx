import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";

const FILTERS = ["open", "pending", "all"] as const;

export default async function OrdersPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const sp = await searchParams;
  const f = (FILTERS as readonly string[]).includes(sp.status ?? "") ? sp.status! : "open";
  const supabase = await createClient();
  const [{ data: canWrite }, { data: orders }] = await Promise.all([
    supabase.rpc("has_po_write"),
    (() => {
      let q = supabase.from("purchase_orders").select("po_id, po_no, order_date, expected_date, status, total, suppliers(name), warehouses(name)").order("created_at", { ascending: false }).limit(300);
      if (f === "open") q = q.in("status", ["pending", "approved", "part_received"]);
      if (f === "pending") q = q.eq("status", "pending");
      return q;
    })(),
  ]);
  const today = new Date().toISOString().slice(0, 10);
  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Purchase orders</h1>
          <p className="mt-1 text-sm text-ink-muted">Order → receive at the warehouse → bill from what was received. Large orders wait for a second person to approve.</p>
        </div>
        {canWrite === true ? <Link href="/purchases/orders/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">New order</Link> : null}
      </div>
      <div className="mt-4 flex gap-4 text-sm">
        {FILTERS.map((x) => <Link key={x} href={`?status=${x}`} className={x === f ? "font-medium text-ink" : "text-accent hover:underline"}>{x[0].toUpperCase() + x.slice(1)}</Link>)}
      </div>
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Order</th><th className="px-4 py-3 font-medium">Supplier</th><th className="px-4 py-3 font-medium">Warehouse</th><th className="px-4 py-3 font-medium">Expected</th><th className="px-4 py-3 text-right font-medium">Total</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(orders ?? []).map((o, i) => {
              const late = o.expected_date && o.expected_date < today && ["approved", "part_received"].includes(o.status);
              return (
                <tr key={o.po_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                  <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/orders/${o.po_id}`}>{o.po_no}</Link></td>
                  <td className="px-4 py-3 text-ink">{(o.suppliers as unknown as { name: string } | null)?.name}</td>
                  <td className="px-4 py-3 text-ink-muted">{(o.warehouses as unknown as { name: string } | null)?.name}</td>
                  <td className={`px-4 py-3 ${late ? "text-danger" : "text-ink-muted"}`}>{o.expected_date ?? "—"}{late ? " (late)" : ""}</td>
                  <td className="px-4 py-3 text-right font-data">{inr(Number(o.total))}</td>
                  <td className="px-4 py-3"><StatusTag status={o.status} /></td>
                </tr>
              );
            })}
            {(orders ?? []).length === 0 ? <tr><td colSpan={6} className="px-4 py-6 text-ink-muted">No orders here.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
