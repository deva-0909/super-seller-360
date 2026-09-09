import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusPill } from "@/components/ui/status-pill";
import { CreateChannelForm } from "./create-channel-form";
import { ChannelStatusToggle } from "./channel-status-toggle";

export default async function ChannelsPage() {
  const currentUser = await getCurrentUser();
  const supabase = await createClient();

  const { data: channels } = await supabase
    .from("channels")
    .select("channel_id, name, type, api_status, settlement_cycle, status")
    .order("name");

  const canCreate = currentUser.roleName === "Super Admin";

  return (
    <div className="px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">
        Channels
      </h1>
      <p className="mt-1 text-sm text-ink-muted">
        Marketplaces, D2C storefronts, and payment gateways orders can be
        ingested from. Each order and ledger is scoped to one of these.
      </p>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Name</th>
                <th className="px-4 py-3 font-medium">Type</th>
                <th className="px-4 py-3 font-medium">API status</th>
                <th className="px-4 py-3 font-medium">Settlement cycle</th>
                <th className="px-4 py-3 font-medium">Active</th>
                {canCreate ? <th className="px-4 py-3 font-medium"></th> : null}
              </tr>
            </thead>
            <tbody>
              {channels?.map((c, i) => (
                <tr
                  key={c.channel_id}
                  className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}
                >
                  <td className="px-4 py-3 text-ink">{c.name}</td>
                  <td className="px-4 py-3 font-data text-ink-muted">
                    {c.type}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill
                      status={
                        c.api_status === "connected" ? "success" : "neutral"
                      }
                    >
                      {c.api_status}
                    </StatusPill>
                  </td>
                  <td className="px-4 py-3 text-ink-muted">
                    {c.settlement_cycle ?? "—"}
                  </td>
                  <td className="px-4 py-3">
                    <StatusPill status={c.status === "active" ? "success" : "neutral"}>
                      {c.status}
                    </StatusPill>
                  </td>
                  {canCreate ? (
                    <td className="px-4 py-3">
                      <ChannelStatusToggle channelId={c.channel_id} status={c.status} />
                    </td>
                  ) : null}
                </tr>
              ))}
              {!channels?.length ? (
                <tr>
                  <td
                    colSpan={6}
                    className="px-4 py-8 text-center text-sm text-ink-muted"
                  >
                    No channels yet — add one to start bringing in orders.
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>

        {canCreate ? (
          <CreateChannelForm />
        ) : (
          <div className="border border-line bg-surface p-4 text-sm text-ink-muted">
            Only Super Admin can add channels.
          </div>
        )}
      </div>
    </div>
  );
}
