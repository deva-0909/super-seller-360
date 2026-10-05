import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";

const FULFILMENT_STATUS_MAP: Record<
  string,
  "success" | "warning" | "danger" | "neutral"
> = {
  delivered: "success",
  shipped: "neutral",
  processing: "neutral",
  pending: "warning",
  cancelled: "danger",
  rto: "danger",
};

const PAGE = 50;
type SP = { q?: string; status?: string; page?: string };

export default async function OrdersPage({ searchParams }: { searchParams: Promise<SP> }) {
  const sp = await searchParams;
  const page = Math.max(1, Number(sp.page) || 1);
  const q = (sp.q ?? "").trim().replace(/[%,()]/g, " ").slice(0, 60);
  const status = Object.keys(FULFILMENT_STATUS_MAP).includes(sp.status ?? "") ? sp.status! : "";
  const supabase = await createClient();

  let query = supabase
    .from("orders")
    .select(
      "order_id, external_order_id, order_date, net_amount, fulfilment_status, payment_status, channels(name), invoices(invoice_id)",
      { count: "exact" },
    )
    .order("order_date", { ascending: false })
    .order("order_id")
    .range((page - 1) * PAGE, page * PAGE - 1);
  if (q) query = query.ilike("external_order_id", `%${q}%`);
  if (status) query = query.eq("fulfilment_status", status);
  const { data: orders, count } = await query;
  const pages = Math.max(1, Math.ceil((count ?? 0) / PAGE));
  const link = (p: number) => `/orders?${new URLSearchParams({ ...(q ? { q } : {}), ...(status ? { status } : {}), page: String(p) }).toString()}`;

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">
            Orders
          </h1>
          <p className="mt-1 text-sm text-ink-muted">
            Every order ingested from a connected channel.
          </p>
        </div>
        <Link
          href="/orders/import"
          className="border border-line px-3 py-1.5 text-sm text-ink hover:bg-surface-sunken"
        >
          Import CSV
        </Link>
      </div>

      <form className="mt-4 flex flex-wrap items-center gap-2 text-sm" method="get">
        <label htmlFor="o-q" className="sr-only">Search by order number</label>
        <input id="o-q" name="q" defaultValue={q} placeholder="Order number" className="h-9 border border-line bg-surface px-3" />
        <label htmlFor="o-s" className="sr-only">Fulfilment status</label>
        <select id="o-s" name="status" defaultValue={status} className="h-9 border border-line bg-surface px-2">
          <option value="">All statuses</option>
          {Object.keys(FULFILMENT_STATUS_MAP).map((k) => <option key={k} value={k}>{k}</option>)}
        </select>
        <button className="h-9 border border-line px-3 hover:bg-surface-sunken">Search</button>
        <span className="text-ink-muted">{count ?? 0} order(s)</span>
      </form>

      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Order</th>
              <th className="px-4 py-3 font-medium">Channel</th>
              <th className="px-4 py-3 font-medium">Date</th>
              <th className="px-4 py-3 font-medium">Net amount</th>
              <th className="px-4 py-3 font-medium">Fulfilment</th>
              <th className="px-4 py-3 font-medium">Invoiced</th>
            </tr>
          </thead>
          <tbody>
            {orders?.map((o, i) => (
              <tr
                key={o.order_id}
                className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
              >
                <td className="px-4 py-3">
                  <Link
                    href={`/orders/${o.order_id}`}
                    className="font-data text-accent hover:underline"
                  >
                    {o.external_order_id}
                  </Link>
                </td>
                <td className="px-4 py-3 text-ink-muted">
                  {(o.channels as unknown as { name: string } | null)?.name ??
                    "—"}
                </td>
                <td className="px-4 py-3 font-data text-ink-muted">
                  {new Date(o.order_date).toLocaleDateString()}
                </td>
                <td className="px-4 py-3 font-data text-ink">
                  ₹{Number(o.net_amount).toLocaleString("en-IN")}
                </td>
                <td className="px-4 py-3">
                  <StatusPill
                    status={
                      FULFILMENT_STATUS_MAP[o.fulfilment_status] ?? "neutral"
                    }
                  >
                    {o.fulfilment_status}
                  </StatusPill>
                </td>
                <td className="px-4 py-3">
                  <StatusPill
                    status={
                      (o.invoices as unknown as unknown[])?.length
                        ? "success"
                        : "neutral"
                    }
                  >
                    {(o.invoices as unknown as unknown[])?.length
                      ? "Invoiced"
                      : "Not invoiced"}
                  </StatusPill>
                </td>
              </tr>
            ))}
            {!orders?.length ? (
              <tr>
                <td
                  colSpan={6}
                  className="px-4 py-8 text-center text-sm text-ink-muted"
                >
                  No orders yet.{" "}
                  <Link
                    href="/orders/import"
                    className="text-accent hover:underline"
                  >
                    Import a CSV
                  </Link>{" "}
                  to bring some in.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
      {pages > 1 ? (
        <p className="mt-3 flex items-center gap-4 text-sm">
          {page > 1 ? <Link href={link(page - 1)} className="text-accent hover:underline">Previous</Link> : null}
          <span className="text-ink-muted">Page {page} of {pages}</span>
          {page < pages ? <Link href={link(page + 1)} className="text-accent hover:underline">Next</Link> : null}
        </p>
      ) : null}
    </div>
  );
}
