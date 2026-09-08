import { createClient } from "@/lib/supabase/server";
import { ImportForm } from "./import-form";

export default async function ImportOrdersPage() {
  const supabase = await createClient();
  const { data: channels } = await supabase
    .from("channels")
    .select("channel_id, name")
    .order("name");

  return (
    <div className="mx-auto max-w-2xl px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Import orders from CSV
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Every portal integration in the BRD lists CSV/XLS as the fallback
        method when the live API isn&apos;t connected yet — this is that
        fallback, so you can bring in real orders before Shopify/Amazon/etc.
        API access is set up.
      </p>

      {!channels?.length ? (
        <p className="mt-6 border border-line bg-surface p-4 text-sm text-ink-muted">
          No channels yet.{" "}
          <a href="/admin/channels" className="text-accent hover:underline">
            Add one first
          </a>
          .
        </p>
      ) : (
        <ImportForm channels={channels} />
      )}

      <div className="mt-8 border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Expected columns</h2>
        <p className="mt-2 text-xs text-ink-muted">
          One row per order (line items aren&apos;t imported this way yet).
          Header row required, columns in any order:
        </p>
        <code className="font-data mt-3 block text-xs text-ink-muted">
          external_order_id, order_date, customer_ref, payment_type,
          gross_amount, discount, tax_amount, net_amount, fulfilment_status,
          payment_status
        </code>
      </div>
    </div>
  );
}
