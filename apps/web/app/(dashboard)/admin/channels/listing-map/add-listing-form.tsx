"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

export function AddListingForm({ channels, products }: { channels: { channel_id: string; name: string }[]; products: { product_id: string; sku: string; name: string }[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [channelId, setChannelId] = useState(channels[0]?.channel_id ?? "");
  const [sku, setSku] = useState("");
  const [listingId, setListingId] = useState("");
  const [channelSku, setChannelSku] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const product = products.find((p) => p.sku.toLowerCase() === sku.trim().toLowerCase());
    if (!product) { setError(`SKU ${sku} not found among active products.`); return; }
    setLoading(true);
    const { error: err } = await supabase.from("channel_sku_map").insert({
      product_id: product.product_id, channel_id: channelId, listing_id: listingId.trim(), channel_sku: channelSku.trim() || null,
    });
    setLoading(false);
    if (err) { setError(friendlyError(err.message)); return; }
    setSku(""); setListingId(""); setChannelSku("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Add one listing</h2>
      <form onSubmit={submit} className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="al-ch" className="text-sm font-medium text-ink">Channel</label>
          <select id="al-ch" value={channelId} onChange={(e) => setChannelId(e.target.value)} className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent">
            {channels.map((c) => <option key={c.channel_id} value={c.channel_id}>{c.name}</option>)}
          </select>
        </div>
        <Field id="al-sku" label="Our SKU" required value={sku} onChange={(e) => setSku(e.target.value)} list="al-skus" />
        <datalist id="al-skus">{products.slice(0, 2000).map((p) => <option key={p.product_id} value={p.sku}>{p.name}</option>)}</datalist>
        <Field id="al-lid" label="Listing id (ASIN / FSN / style id)" required value={listingId} onChange={(e) => setListingId(e.target.value)} />
        <Field id="al-csku" label="Channel SKU" value={channelSku} onChange={(e) => setChannelSku(e.target.value)} />
        {error ? <p role="alert" className="text-sm text-danger">{error}</p> : null}
        <Button type="submit" disabled={loading || !channelId}>{loading ? "Adding…" : "Add listing"}</Button>
      </form>
    </div>
  );
}
