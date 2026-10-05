import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";

export default async function IntegrationsPage() {
  const supabase = await createClient();

  const { data: channels } = await supabase
    .from("channels")
    .select("channel_id, name, type, api_status, seller_account")
    .order("name");

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const webhookUrl = `${supabaseUrl}/functions/v1/shopify-order-webhook`;

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Integrations
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Channel connections and the webhook endpoints that bring orders,
        returns, and RTOs in automatically — manual entry is the fallback
        for what these haven&apos;t captured, not the primary path.
      </p>

      <h2 className="mt-6 text-sm font-semibold text-ink">
        Channel connections
      </h2>
      <div className="mt-3 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Channel</th>
              <th className="px-4 py-3 font-medium">Type</th>
              <th className="px-4 py-3 font-medium">Seller account</th>
              <th className="px-4 py-3 font-medium">API status</th>
            </tr>
          </thead>
          <tbody>
            {channels?.map((c, i) => (
              <tr key={c.channel_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3 text-ink">{c.name}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{c.type}</td>
                <td className="px-4 py-3 font-data text-ink-muted">
                  {c.seller_account ?? "—"}
                </td>
                <td className="px-4 py-3">
                  <StatusPill
                    status={
                      c.api_status === "connected"
                        ? "success"
                        : c.api_status === "error"
                          ? "danger"
                          : "neutral"
                    }
                  >
                    {c.api_status}
                  </StatusPill>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2 className="mt-8 text-sm font-semibold text-ink">
        Webhook endpoints
      </h2>
      <div className="mt-3 border border-line bg-surface p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-sm font-medium text-ink">
              Shopify order webhook
            </p>
            <p className="mt-1 font-data text-xs text-ink-muted break-all">
              {webhookUrl}?channel_id=&lt;your Shopify channel&apos;s ID&gt;
            </p>
          </div>
          <StatusPill status="success">Deployed</StatusPill>
        </div>
        <p className="mt-3 text-xs text-ink-muted">
          Deployed and reachable, but <strong>not yet verified against a real
          store</strong> — no Shopify account is connected to this project
          yet. It fails closed (returns an error, accepts nothing) until a
          store is registered and its signing secret is configured. To
          connect: register this URL in Shopify for the{" "}
          <code className="font-data">orders/create</code> and{" "}
          <code className="font-data">orders/updated</code> topics, then set
          the <code className="font-data">SHOPIFY_WEBHOOK_SECRET</code> for
          this function to the signing secret Shopify gives you.
        </p>
      </div>

      <div className="mt-3 border border-line bg-surface p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-sm font-medium text-ink">
              Returns/RTO ingestion webhook
            </p>
            <p className="mt-1 font-data text-xs text-ink-muted break-all">
              {`${supabaseUrl}/functions/v1/returns-rto-webhook`}
            </p>
          </div>
          <StatusPill status="warning">Deployment unconfirmed</StatusPill>
        </div>
        <p className="mt-3 text-xs text-ink-muted">
          Built so Returns and RTOs stop being manual-entry-only, the same
          way orders already can be — the deployment tool didn&apos;t
          confirm success this session, so treat this as not-yet-verified
          live rather than assume it is. Not yet connected to a real
          marketplace or courier API either way. Each marketplace/courier
          has its own payload shape, so connecting one means a small
          adapter that maps their format into this endpoint&apos;s
          normalized shape (documented in the function source), the same
          way the Shopify webhook is Shopify&apos;s own adapter for orders.
          Until connected, the &quot;Log a return&quot;/&quot;Log an
          RTO&quot; forms are the fallback, not the primary path.
        </p>
      </div>

      <div className="mt-3 border border-line bg-surface p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-sm font-medium text-ink">
              User invite function
            </p>
            <p className="mt-1 text-xs text-ink-muted">
              Internal — powers the &quot;Invite user&quot; action on the Users
              screen. Not a channel integration.
            </p>
          </div>
          <StatusPill status="success">Deployed</StatusPill>
        </div>
      </div>
    </div>
  );
}
