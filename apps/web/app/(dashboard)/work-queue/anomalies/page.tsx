import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { inr } from "@/lib/report-utils";

const daysAgo = (n: number) => new Date(Date.now() - n * 86400_000).toISOString();

export default async function AnomaliesPage() {
  const supabase = await createClient();
  const since = daysAgo(30);
  const [{ data: lines }, { data: disc }, { data: pays }] = await Promise.all([
    supabase.from("order_lines").select("order_id, quantity, unit_price, products(sku, name, cost_price), orders!inner(external_order_id, order_date, fulfilment_status)").gte("orders.order_date", since).neq("orders.fulfilment_status", "cancelled").limit(2000),
    supabase.from("orders").select("order_id, external_order_id, order_date, gross_amount, discount").gte("order_date", since).neq("fulfilment_status", "cancelled").gt("gross_amount", 0).limit(2000),
    supabase.from("supplier_payments").select("payment_id, payment_no, supplier_id, amount, payment_date, status, suppliers(name)").in("status", ["pending", "approved"]).gte("payment_date", daysAgo(60).slice(0, 10)).limit(1000),
  ]);
  type L = { order_id: string; quantity: number; unit_price: number; products: { sku: string; name: string; cost_price: number | null } | null; orders: { external_order_id: string } | null };
  const below = ((lines ?? []) as unknown as L[]).filter((l) => l.products?.cost_price && Number(l.unit_price) > 0 && Number(l.unit_price) < Number(l.products.cost_price));
  const bigDisc = (disc ?? []).filter((o) => Number(o.discount) > Number(o.gross_amount) * 0.4);
  const seen = new Map<string, typeof pays>();
  for (const p of pays ?? []) { const k = `${p.supplier_id}|${p.amount}`; seen.set(k, [...(seen.get(k) ?? []), p]); }
  const dups = [...seen.values()].filter((g) => (g?.length ?? 0) > 1);

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/work-queue" className="text-sm text-ink-muted hover:text-ink">← Work queue</Link>
      <h1 className="mt-2 text-lg font-semibold tracking-tight text-ink">Worth a second look</h1>
      <p className="mt-1 text-sm text-ink-muted">Not errors, just things that are unusual enough to check. The last 30 days of orders and 60 days of supplier payments.</p>

      <h2 className="mt-6 text-sm font-semibold text-ink">Sold below cost ({below.length})</h2>
      <ul className="mt-2 divide-y divide-line border border-line bg-surface text-sm">
        {below.slice(0, 100).map((l, i) => <li key={i} className="flex justify-between px-3 py-2"><span><Link className="text-accent hover:underline" href={`/orders/${l.order_id}`}>{l.orders?.external_order_id}</Link> · {l.products?.sku}</span><span className="font-data">sold {inr(Number(l.unit_price))} · cost {inr(Number(l.products?.cost_price))}</span></li>)}
        {below.length === 0 ? <li className="px-3 py-2 text-ink-muted">None.</li> : null}
      </ul>

      <h2 className="mt-6 text-sm font-semibold text-ink">Discount above 40% ({bigDisc.length})</h2>
      <ul className="mt-2 divide-y divide-line border border-line bg-surface text-sm">
        {bigDisc.slice(0, 100).map((o) => <li key={o.order_id} className="flex justify-between px-3 py-2"><Link className="text-accent hover:underline" href={`/orders/${o.order_id}`}>{o.external_order_id}</Link><span className="font-data">{inr(Number(o.discount))} off {inr(Number(o.gross_amount))}</span></li>)}
        {bigDisc.length === 0 ? <li className="px-3 py-2 text-ink-muted">None.</li> : null}
      </ul>

      <h2 className="mt-6 text-sm font-semibold text-ink">Possible duplicate supplier payments ({dups.length})</h2>
      <ul className="mt-2 divide-y divide-line border border-line bg-surface text-sm">
        {dups.map((g, i) => <li key={i} className="px-3 py-2">{(g![0].suppliers as unknown as { name: string } | null)?.name}: {g!.map((p) => `${p.payment_no} (${p.payment_date})`).join(", ")} · ₹{inr(Number(g![0].amount))} each</li>)}
        {dups.length === 0 ? <li className="px-3 py-2 text-ink-muted">None.</li> : null}
      </ul>
    </div>
  );
}
