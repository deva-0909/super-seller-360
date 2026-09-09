import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { PostInvoiceButton } from "./post-invoice-button";

export default async function OrderDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const { data: order } = await supabase
    .from("orders")
    .select(
      "order_id, external_order_id, order_date, customer_ref, payment_type, gross_amount, discount, tax_amount, net_amount, fulfilment_status, payment_status, channels(name), order_lines(order_line_id, quantity, unit_price, discount, tax, products(name, sku)), invoices(invoice_id, invoice_number, total, taxable_value, gst_amount)",
    )
    .eq("order_id", id)
    .single();

  if (!order) {
    notFound();
  }

  const canPost =
    currentUser.roleName === "Super Admin" ||
    currentUser.roleName === "Operations Manager" ||
    currentUser.roleName === "Marketplace Manager" ||
    currentUser.roleName === "Finance Manager" ||
    currentUser.roleName === "Accountant";

  const invoice = (
    order.invoices as unknown as
      | { invoice_id: string; invoice_number: string; total: number }[]
      | null
  )?.[0];

  const { data: statusHistory } = await supabase
    .from("order_status_history")
    .select("history_id, fulfilment_status, payment_status, changed_at")
    .eq("order_id", id)
    .order("changed_at", { ascending: true });

  const [{ data: orderReturns }, { data: orderRtos }, { data: orderClaims }] =
    await Promise.all([
      supabase
        .from("returns")
        .select("return_id, status, created_at")
        .eq("order_id", id),
      supabase
        .from("rtos")
        .select("rto_id, status, created_at")
        .eq("order_id", id),
      supabase
        .from("claims")
        .select("claim_id, status, created_at")
        .eq("order_id", id),
    ]);

  type TimelineEvent = { at: string; label: string; href?: string };
  const timeline: TimelineEvent[] = [
    ...(statusHistory ?? []).map((h) => ({
      at: h.changed_at,
      label: `Status: ${h.fulfilment_status} / ${h.payment_status}`,
    })),
    ...(invoice
      ? [{ at: order.order_date, label: `Invoiced — ${invoice.invoice_number}` }]
      : []),
    ...(orderReturns ?? []).map((r) => ({
      at: r.created_at,
      label: `Return logged (${r.status})`,
      href: `/returns/${r.return_id}`,
    })),
    ...(orderRtos ?? []).map((r) => ({
      at: r.created_at,
      label: `RTO logged (${r.status})`,
      href: `/rto/${r.rto_id}`,
    })),
    ...(orderClaims ?? []).map((c) => ({
      at: c.created_at,
      label: `Claim logged (${c.status})`,
      href: `/claims/${c.claim_id}`,
    })),
  ].sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime());

  return (
    <div className="mx-auto max-w-3xl px-8 py-8">
      <div className="flex items-baseline justify-between">
        <div>
          <h1 className="font-data text-lg font-semibold tracking-tight text-ink">
            {order.external_order_id}
          </h1>
          <p className="mt-1 text-sm text-ink-muted">
            {(order.channels as unknown as { name: string } | null)?.name} ·{" "}
            {new Date(order.order_date).toLocaleString()}
          </p>
        </div>
        <div className="flex gap-2">
          <StatusPill status="neutral">{order.fulfilment_status}</StatusPill>
          <StatusPill
            status={order.payment_status === "paid" ? "success" : "warning"}
          >
            {order.payment_status}
          </StatusPill>
        </div>
      </div>

      <div className="mt-6 border border-line bg-surface p-5">
        <dl className="grid grid-cols-2 gap-x-6 gap-y-3 text-sm">
          <dt className="text-ink-muted">Customer reference</dt>
          <dd className="font-data text-ink">{order.customer_ref ?? "—"}</dd>
          <dt className="text-ink-muted">Payment type</dt>
          <dd className="text-ink">{order.payment_type ?? "—"}</dd>
          <dt className="text-ink-muted">Gross amount</dt>
          <dd className="font-data text-ink">
            ₹{Number(order.gross_amount).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Discount</dt>
          <dd className="font-data text-ink">
            ₹{Number(order.discount).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Tax</dt>
          <dd className="font-data text-ink">
            ₹{Number(order.tax_amount).toLocaleString("en-IN")}
          </dd>
          <dt className="text-ink-muted">Net amount</dt>
          <dd className="font-data font-semibold text-ink">
            ₹{Number(order.net_amount).toLocaleString("en-IN")}
          </dd>
        </dl>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Line items</h2>
      <div className="mt-3 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-2.5 font-medium">Product</th>
              <th className="px-4 py-2.5 font-medium">Qty</th>
              <th className="px-4 py-2.5 font-medium">Unit price</th>
              <th className="px-4 py-2.5 font-medium">Tax</th>
            </tr>
          </thead>
          <tbody>
            {(
              order.order_lines as unknown as {
                order_line_id: string;
                quantity: number;
                unit_price: number;
                tax: number;
                products: { name: string; sku: string } | null;
              }[]
            )?.map((line) => (
              <tr key={line.order_line_id}>
                <td className="px-4 py-2.5 text-ink">
                  {line.products?.name ?? (
                    <span className="text-ink-faint">Unmapped SKU</span>
                  )}
                </td>
                <td className="px-4 py-2.5 font-data text-ink-muted">
                  {line.quantity}
                </td>
                <td className="px-4 py-2.5 font-data text-ink-muted">
                  ₹{Number(line.unit_price).toLocaleString("en-IN")}
                </td>
                <td className="px-4 py-2.5 font-data text-ink-muted">
                  ₹{Number(line.tax).toLocaleString("en-IN")}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Accounting</h2>
      <div className="mt-3 border border-line bg-surface p-5">
        {invoice ? (
          <div className="flex items-center justify-between">
            <div>
              <p className="font-data text-sm text-ink">
                {invoice.invoice_number}
              </p>
              <p className="mt-1 text-sm text-ink-muted">
                Posted — ₹{Number(invoice.total).toLocaleString("en-IN")}
              </p>
            </div>
            <StatusPill status="success">Posted</StatusPill>
          </div>
        ) : canPost ? (
          <PostInvoiceButton orderId={order.order_id} />
        ) : (
          <p className="text-sm text-ink-muted">
            Not yet invoiced. Only Operations, Marketplace, Finance, or
            Accounting roles can post this.
          </p>
        )}
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">Timeline</h2>
      <div className="mt-3 border border-line bg-surface p-5">
        <ol className="flex flex-col gap-3">
          {timeline.map((event, i) => (
            <li key={i} className="flex items-start gap-3 text-sm">
              <span className="mt-1 h-1.5 w-1.5 shrink-0 rounded-full bg-accent" />
              <div>
                <p className="font-data text-xs text-ink-muted">
                  {new Date(event.at).toLocaleString()}
                </p>
                {event.href ? (
                  <Link href={event.href} className="text-accent hover:underline">
                    {event.label}
                  </Link>
                ) : (
                  <p className="text-ink">{event.label}</p>
                )}
              </div>
            </li>
          ))}
        </ol>
      </div>
    </div>
  );
}
