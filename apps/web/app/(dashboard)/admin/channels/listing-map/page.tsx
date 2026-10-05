import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusPill } from "@/components/ui/status-pill";
import { AddListingForm } from "./add-listing-form";

export default async function ListingMapPage({ searchParams }: { searchParams: Promise<{ channel?: string }> }) {
  const { channel } = await searchParams;
  const supabase = await createClient();
  const [{ data: channels }, { data: products }, { data: canUpload }] = await Promise.all([
    supabase.from("channels").select("channel_id, name").order("name"),
    supabase.from("products").select("product_id, sku, name").eq("status", "active").order("sku").limit(5000),
    supabase.rpc("import_can", { p_kind: "listing_map" }),
  ]);
  let q = supabase.from("channel_sku_map").select("mapping_id, channel_id, channel_sku, listing_id, status, products(sku, name), channels(name)").order("listing_id").limit(1000);
  if (channel) q = q.eq("channel_id", channel);
  const [{ data: rows }, { data: mappedIds }] = await Promise.all([q, supabase.from("channel_sku_map").select("product_id").eq("status", "active").limit(20000)]);
  const mapped = new Set((mappedIds ?? []).map((m) => m.product_id));
  const unmapped = (products ?? []).filter((p) => !mapped.has(p.product_id)).length;

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/admin/channels" className="text-sm text-ink-muted hover:text-ink">← Channels</Link>
      <h1 className="mt-4 text-lg font-semibold tracking-tight text-ink">Marketplace listing map</h1>
      <p className="mt-1 text-sm text-ink-muted">
        Links each of our SKUs to the marketplace&apos;s own SKU and listing id (ASIN, FSN, style id), so orders tie back to our products.
        {unmapped > 0 ? <> <strong>{unmapped}</strong> active SKU{unmapped === 1 ? " is" : "s are"} not mapped to any listing yet.</> : null}
      </p>
      {canUpload === true ? (
        <p className="mt-3 flex gap-4 text-sm">
          <Link href="/imports/listing_map" className="font-medium text-accent hover:underline">Upload the map from Excel</Link>
                    <a href={`/api/import-template/${"listing_map"}`} className="text-accent hover:underline">Download the template</a>
        </p>
      ) : null}

      <form className="mt-4 flex items-center gap-2 text-sm" method="get">
        <label htmlFor="lm-ch" className="text-ink-muted">Channel</label>
        <select id="lm-ch" name="channel" defaultValue={channel ?? ""} className="h-9 border border-line bg-surface px-2 text-sm text-ink">
          <option value="">All channels</option>
          {channels?.map((c) => <option key={c.channel_id} value={c.channel_id}>{c.name}</option>)}
        </select>
        <button className="h-9 border border-line bg-surface px-3 text-sm hover:bg-surface-sunken">Show</button>
      </form>

      <div className="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <div className="overflow-x-auto border border-line bg-surface">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-line-strong text-xs text-ink-muted">
                <th className="px-4 py-3 font-medium">Channel</th>
                <th className="px-4 py-3 font-medium">Listing id</th>
                <th className="px-4 py-3 font-medium">Channel SKU</th>
                <th className="px-4 py-3 font-medium">Our SKU</th>
                <th className="px-4 py-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {(rows ?? []).map((m, i) => {
                const p = m.products as unknown as { sku: string; name: string } | null;
                return (
                  <tr key={m.mapping_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                    <td className="px-4 py-2 text-ink-muted">{(m.channels as unknown as { name: string } | null)?.name}</td>
                    <td className="px-4 py-2 font-data text-ink">{m.listing_id}</td>
                    <td className="px-4 py-2 font-data text-ink-muted">{m.channel_sku ?? "—"}</td>
                    <td className="px-4 py-2 text-ink">{p?.sku} <span className="text-xs text-ink-faint">{p?.name}</span></td>
                    <td className="px-4 py-2"><StatusPill status={m.status === "active" ? "success" : "neutral"}>{m.status}</StatusPill></td>
                  </tr>
                );
              })}
              {!rows?.length ? <tr><td colSpan={5} className="px-4 py-8 text-center text-sm text-ink-muted">No listings mapped yet.</td></tr> : null}
            </tbody>
          </table>
        </div>
        <AddListingForm channels={channels ?? []} products={products ?? []} />
      </div>
    </div>
  );
}
