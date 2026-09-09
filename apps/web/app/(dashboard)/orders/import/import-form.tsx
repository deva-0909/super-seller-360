"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Papa from "papaparse";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";

type Channel = { channel_id: string; name: string };

type CsvRow = {
  external_order_id?: string;
  order_date?: string;
  customer_ref?: string;
  payment_type?: string;
  fulfilment_status?: string;
  payment_status?: string;
  sku?: string;
  quantity?: string;
  unit_price?: string;
  discount?: string;
  tax?: string;
};

type GroupedOrder = {
  external_order_id: string;
  order_date: string;
  customer_ref: string | null;
  payment_type: string | null;
  fulfilment_status: string;
  payment_status: string;
  lines: { sku: string; quantity: number; unit_price: number; discount: number; tax: number }[];
};

function groupRows(rows: CsvRow[]): GroupedOrder[] {
  const map = new Map<string, GroupedOrder>();
  for (const r of rows) {
    if (!r.external_order_id) continue;
    const id = r.external_order_id.trim();
    if (!map.has(id)) {
      map.set(id, {
        external_order_id: id,
        order_date: r.order_date || new Date().toISOString(),
        customer_ref: r.customer_ref || null,
        payment_type: r.payment_type || null,
        fulfilment_status: r.fulfilment_status || "pending",
        payment_status: r.payment_status || "pending",
        lines: [],
      });
    }
    if (r.sku) {
      const order = map.get(id)!;
      const sku = r.sku.trim();
      const quantity = Number(r.quantity) || 1;
      const unit_price = Number(r.unit_price) || 0;
      const discount = Number(r.discount) || 0;
      const tax = Number(r.tax) || 0;

      // Same order + same SKU appearing twice within one file (e.g. an
      // export with an overlapping date range) merges into one line by
      // summing quantities/amounts, rather than silently doubling the
      // order — this was a real gap found after shipping the first version.
      const existing = order.lines.find((l) => l.sku === sku);
      if (existing) {
        existing.quantity += quantity;
        existing.discount += discount;
        existing.tax += tax;
        // Unit price for a merged line is the most recent occurrence's
        // price — mixing two different prices for the same SKU in one
        // order is an edge case rare enough not to warrant averaging logic.
        existing.unit_price = unit_price;
      } else {
        order.lines.push({ sku, quantity, unit_price, discount, tax });
      }
    }
  }
  return Array.from(map.values());
}

export function ImportForm({ channels }: { channels: Channel[] }) {
  const router = useRouter();
  const supabase = createClient();

  const [channelId, setChannelId] = useState(channels[0]?.channel_id ?? "");
  const [orders, setOrders] = useState<GroupedOrder[]>([]);
  const [fileName, setFileName] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ imported: number } | null>(null);
  const [loading, setLoading] = useState(false);

  function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;

    setError(null);
    setResult(null);
    setFileName(file.name);

    Papa.parse<CsvRow>(file, {
      header: true,
      skipEmptyLines: true,
      complete: (results) => {
        if (!results.data.length) {
          setError("That file has no rows.");
          return;
        }
        setOrders(groupRows(results.data));
      },
      error: () => setError("Couldn't read that file as CSV."),
    });
  }

  async function handleImport() {
    if (!orders.length || !channelId) return;
    setError(null);
    setLoading(true);

    // Resolve SKUs to product_ids once, up front.
    const { data: products } = await supabase.from("products").select("product_id, sku");
    const skuMap = new Map((products ?? []).map((p) => [p.sku, p.product_id]));

    let imported = 0;

    for (const o of orders) {
      const gross = o.lines.reduce((s, l) => s + l.quantity * l.unit_price, 0);
      const discount = o.lines.reduce((s, l) => s + l.discount, 0);
      const tax = o.lines.reduce((s, l) => s + l.tax, 0);
      const net = gross - discount + tax;

      const { data: inserted, error: orderError } = await supabase
        .from("orders")
        .upsert(
          {
            channel_id: channelId,
            external_order_id: o.external_order_id,
            order_date: o.order_date,
            customer_ref: o.customer_ref,
            payment_type: o.payment_type,
            gross_amount: gross,
            discount,
            tax_amount: tax,
            net_amount: net,
            fulfilment_status: o.fulfilment_status,
            payment_status: o.payment_status,
          },
          { onConflict: "channel_id,external_order_id", ignoreDuplicates: true },
        )
        .select("order_id")
        .maybeSingle();

      if (orderError) {
        setError(`${o.external_order_id}: ${orderError.message}`);
        continue;
      }
      // ignoreDuplicates means an existing order returns no row — skip its lines too.
      if (!inserted) continue;

      if (o.lines.length) {
        await supabase.from("order_lines").insert(
          o.lines.map((l) => ({
            order_id: inserted.order_id,
            product_id: skuMap.get(l.sku) ?? null,
            quantity: l.quantity,
            unit_price: l.unit_price,
            discount: l.discount,
            tax: l.tax,
          })),
        );
      }
      imported += 1;
    }

    setLoading(false);
    setResult({ imported });
    setOrders([]);
    setFileName(null);
    router.refresh();
  }

  return (
    <div className="mt-6 border border-line bg-surface p-5">
      <div className="flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="channel" className="text-sm font-medium text-ink">
            Channel these orders belong to
          </label>
          <select
            id="channel"
            value={channelId}
            onChange={(e) => setChannelId(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            {channels.map((c) => (
              <option key={c.channel_id} value={c.channel_id}>
                {c.name}
              </option>
            ))}
          </select>
        </div>

        <div className="flex flex-col gap-1.5">
          <label htmlFor="file" className="text-sm font-medium text-ink">
            CSV file
          </label>
          <input
            id="file"
            type="file"
            accept=".csv"
            onChange={handleFile}
            className="text-sm text-ink file:mr-3 file:border file:border-line file:bg-surface file:px-3 file:py-1.5 file:text-sm"
          />
        </div>

        {fileName && orders.length ? (
          <p className="text-sm text-ink-muted">
            <span className="font-data">{fileName}</span> —{" "}
            {orders.length} order{orders.length === 1 ? "" : "s"},{" "}
            {orders.reduce((s, o) => s + o.lines.length, 0)} line items ready
            to import.
          </p>
        ) : null}

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}
        {result ? (
          <p className="text-sm text-success">
            Imported {result.imported} new order
            {result.imported === 1 ? "" : "s"} with line items. Orders that
            already existed were skipped.
          </p>
        ) : null}

        <Button
          onClick={handleImport}
          disabled={!orders.length || loading}
          className="w-auto px-4"
        >
          {loading ? "Importing…" : "Import orders"}
        </Button>
      </div>
    </div>
  );
}
