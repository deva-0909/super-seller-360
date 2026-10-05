import { createClient } from "@/lib/supabase/server";
import { ConnectorCard, type CardProps } from "./connector-card";
import { AddConnection } from "./add-connection";
import { ClearDummy } from "./clear-dummy";

const GROUPS: [string, string][] = [["marketplace", "Marketplaces"], ["courier", "Courier"], ["gst", "GST and e-invoice"], ["whatsapp", "WhatsApp"], ["bank", "Bank feed"]];

export default async function ConnectorsPage() {
  const supabase = await createClient();
  const [{ data: catalog }, { data: instances }, { data: channels }, { data: logs }] = await Promise.all([
    supabase.from("connector_catalog").select("code, category, label, description, fields, sort").order("sort"),
    supabase.from("connector_instances").select("instance_id, connector_code, label, channel_id, mode, enabled, status, last_sync_at, last_message").order("created_at"),
    supabase.from("channels").select("channel_id, name").order("name"),
    supabase.from("connector_log").select("at, kind, ok, message, instance_id").order("at", { ascending: false }).limit(12),
  ]);
  const cat = new Map((catalog ?? []).map((c) => [c.code, c]));
  const cards = await Promise.all((instances ?? []).map(async (i) => {
    const c = cat.get(i.connector_code)!;
    const { data: ks } = await supabase.rpc("connector_key_status", { p_id: i.instance_id });
    return { c, props: {
      instanceId: i.instance_id, code: i.connector_code, category: c.category, providerLabel: c.label, label: i.label, mode: i.mode, enabled: i.enabled, status: i.status,
      channelId: i.channel_id, channels: channels ?? [], fields: c.fields, keyStatus: (ks ?? {}) as CardProps["keyStatus"], lastMessage: i.last_message, lastSync: i.last_sync_at,
    } as CardProps };
  }));

  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">Connection centre</h1>
      <p className="mt-1 max-w-3xl text-sm text-ink-muted">
        Where each client&apos;s own accounts and keys are plugged in: marketplaces, courier, GST e-invoice, WhatsApp and bank. Everything starts in
        <strong> Dummy</strong> mode with sample data so the whole flow can be tried first. When the client has their keys, enter them here and switch to
        <strong> Live</strong>. Only a Super Admin can see or change this screen.
      </p>

      <AddConnection providers={(catalog ?? []).map((c) => ({ code: c.code, label: c.label, category: c.category }))} />

      {GROUPS.map(([k, title]) => {
        const list = cards.filter((x) => x.c.category === k);
        return (
          <section key={k} className="mt-8">
            <h2 className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-muted">{title}</h2>
            {list.length === 0 ? <p className="border border-line bg-surface p-4 text-sm text-ink-muted">No {title.toLowerCase()} connection yet.</p> : <div className="space-y-3">{list.map((x) => <ConnectorCard key={x.props.instanceId} {...x.props} />)}</div>}
          </section>
        );
      })}

      <ClearDummy />

      <h2 className="mt-8 text-sm font-semibold text-ink">Recent activity</h2>
      <ul className="mt-2 divide-y divide-line border border-line bg-surface text-xs">
        {(logs ?? []).map((l, i) => <li key={i} className="flex justify-between gap-3 px-3 py-2"><span>{new Date(l.at).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" })} · {l.kind}</span><span className={l.ok ? "text-ink-muted" : "text-danger"}>{l.message}</span></li>)}
        {(logs ?? []).length === 0 ? <li className="px-3 py-2 text-ink-muted">Nothing yet.</li> : null}
      </ul>
    </div>
  );
}
