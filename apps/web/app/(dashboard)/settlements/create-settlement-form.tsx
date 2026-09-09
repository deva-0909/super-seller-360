"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

type Channel = { channel_id: string; name: string };

export function CreateSettlementForm({ channels }: { channels: Channel[] }) {
  const router = useRouter();
  const supabase = createClient();

  const [channelId, setChannelId] = useState(channels[0]?.channel_id ?? "");
  const [externalId, setExternalId] = useState("");
  const [periodStart, setPeriodStart] = useState("");
  const [periodEnd, setPeriodEnd] = useState("");
  const [gross, setGross] = useState("");
  const [deductions, setDeductions] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const g = Number(gross) || 0;
    const d = Number(deductions) || 0;

    if (g < 0 || d < 0) {
      setError("Amounts can't be negative.");
      setLoading(false);
      return;
    }
    if (periodStart && periodEnd && periodEnd < periodStart) {
      setError("Period end can't be before period start.");
      setLoading(false);
      return;
    }

    const { error } = await supabase.from("settlements").insert({
      channel_id: channelId,
      external_settlement_id: externalId,
      period_start: periodStart || null,
      period_end: periodEnd || null,
      gross: g,
      deductions: d,
      expected_amount: g - d,
    });

    setLoading(false);

    if (error) {
      setError(friendlyError(error.message));
      return;
    }

    setExternalId("");
    setGross("");
    setDeductions("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Log a settlement</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Channel</label>
          <select
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

        <Field
          id="settlement-external-id"
          label="Settlement reference"
          required
          value={externalId}
          onChange={(e) => setExternalId(e.target.value)}
          placeholder="Portal's settlement ID"
        />

        <div className="grid grid-cols-2 gap-3">
          <Field
            id="settlement-period-start"
            label="Period start"
            type="date"
            value={periodStart}
            onChange={(e) => setPeriodStart(e.target.value)}
          />
          <Field
            id="settlement-period-end"
            label="Period end"
            type="date"
            value={periodEnd}
            onChange={(e) => setPeriodEnd(e.target.value)}
          />
        </div>

        <div className="grid grid-cols-2 gap-3">
          <Field
            id="settlement-gross"
            label="Gross (₹)"
            type="number"
            value={gross}
            onChange={(e) => setGross(e.target.value)}
          />
          <Field
            id="settlement-deductions"
            label="Deductions (₹)"
            type="number"
            value={deductions}
            onChange={(e) => setDeductions(e.target.value)}
          />
        </div>

        {gross && (
          <p className="text-xs text-ink-muted">
            Expected: ₹{(Number(gross) - Number(deductions || 0)).toLocaleString("en-IN")}
          </p>
        )}

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Logging…" : "Log settlement"}
        </Button>
      </form>
    </div>
  );
}
