import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { B2clForm, ChannelGstin } from "./settings-form";

export default async function GstSettingsPage() {
  const user = await getCurrentUser();
  const canEdit = ["Super Admin", "Finance Manager", "Tax Manager"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data: set }, { data: channels }, { data: company }, { count: unmapped }, { count: b2b }] = await Promise.all([
    supabase.from("gst_settings").select("b2cl_limit").eq("id", 1).maybeSingle(),
    supabase.from("channels").select("channel_id, name, type, eco_gstin").order("name"),
    supabase.from("companies").select("name, state, gstin").limit(1).maybeSingle(),
    supabase.from("orders").select("order_id", { count: "exact", head: true }).is("ship_to_state_code", null).not("ship_to_state", "is", null),
    supabase.from("orders").select("order_id", { count: "exact", head: true }).not("customer_gstin", "is", null),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">GST settings</h1>
      <div className="mt-4 border border-line bg-surface p-4 text-sm">
        <p className="font-medium text-ink">{company?.name}</p>
        <p className="mt-1 text-ink-muted">Registered state: {company?.state ?? "not set"} · GSTIN: {company?.gstin ?? "not set"}</p>
        <p className="mt-1 text-xs text-ink-muted">Place of supply is compared with the registered state to choose between CGST and SGST, or IGST.</p>
      </div>

      <div className="mt-8"><B2clForm value={Number(set?.b2cl_limit ?? 250000)} canEdit={canEdit} /></div>

      <h2 className="mt-10 text-sm font-semibold text-ink">Marketplace GSTIN, by channel</h2>
      <p className="mt-1 text-xs text-ink-muted">Used to show supplies made through an e-commerce operator separately in the GSTR-1 workings.</p>
      <div className="mt-3 flex flex-col gap-3">
        {(channels ?? []).map((c) => <ChannelGstin key={c.channel_id} channelId={c.channel_id} name={`${c.name} (${c.type})`} value={c.eco_gstin ?? ""} canEdit={canEdit} />)}
      </div>

      <h2 className="mt-10 text-sm font-semibold text-ink">Data health</h2>
      <ul className="mt-2 list-disc pl-5 text-sm text-ink-muted">
        <li>{b2b ?? 0} order{b2b === 1 ? "" : "s"} carry a customer GSTIN (reported as B2B).</li>
        <li>{unmapped ?? 0} order{unmapped === 1 ? "" : "s"} have a ship-to state that could not be matched to an Indian state.</li>
      </ul>
    </div>
  );
}
