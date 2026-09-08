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
  gross_amount?: string;
  discount?: string;
  tax_amount?: string;
  net_amount?: string;
  fulfilment_status?: string;
  payment_status?: string;
};

export function ImportForm({ channels }: { channels: Channel[] }) {
  const router = useRouter();
  const supabase = createClient();

  const [channelId, setChannelId] = useState(channels[0]?.channel_id ?? "");
  const [rows, setRows] = useState<CsvRow[]>([]);
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
        setRows(results.data);
      },
      error: () => setError("Couldn't read that file as CSV."),
    });
  }

  async function handleImport() {
    if (!rows.length || !channelId) return;
    setError(null);
    setLoading(true);

    const payload = rows
      .filter((r) => r.external_order_id)
      .map((r) => ({
        channel_id: channelId,
        external_order_id: r.external_order_id!.trim(),
        order_date: r.order_date || new Date().toISOString(),
        customer_ref: r.customer_ref || null,
        payment_type: r.payment_type || null,
        gross_amount: Number(r.gross_amount) || 0,
        discount: Number(r.discount) || 0,
        tax_amount: Number(r.tax_amount) || 0,
        net_amount: Number(r.net_amount) || 0,
        fulfilment_status: r.fulfilment_status || "pending",
        payment_status: r.payment_status || "pending",
      }));

    // Upsert with ignoreDuplicates: BR-001 requires a unique source-transaction
    // key, so re-importing the same file (or an overlapping export window)
    // skips rows that already exist instead of erroring the whole batch.
    const { error, count } = await supabase
      .from("orders")
      .upsert(payload, {
        onConflict: "channel_id,external_order_id",
        ignoreDuplicates: true,
        count: "exact",
      });

    setLoading(false);

    if (error) {
      setError(error.message);
      return;
    }

    setResult({ imported: count ?? payload.length });
    setRows([]);
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

        {fileName && rows.length ? (
          <p className="text-sm text-ink-muted">
            <span className="font-data">{fileName}</span> — {rows.length} row
            {rows.length === 1 ? "" : "s"} ready to import.
          </p>
        ) : null}

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}
        {result ? (
          <p className="text-sm text-success">
            Imported {result.imported} order
            {result.imported === 1 ? "" : "s"}. Duplicates (matching channel +
            order ID) were skipped automatically.
          </p>
        ) : null}

        <Button
          onClick={handleImport}
          disabled={!rows.length || loading}
          className="w-auto px-4"
        >
          {loading ? "Importing…" : "Import orders"}
        </Button>
      </div>
    </div>
  );
}
