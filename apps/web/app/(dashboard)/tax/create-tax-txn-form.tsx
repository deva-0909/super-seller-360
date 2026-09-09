"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

export function CreateTaxTxnForm() {
  const router = useRouter();
  const supabase = createClient();

  const [taxType, setTaxType] = useState("GST");
  const [period, setPeriod] = useState("");
  const [source, setSource] = useState("");
  const [taxableValue, setTaxableValue] = useState("");
  const [taxAmount, setTaxAmount] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { error } = await supabase.from("tax_transactions").insert({
      tax_type: taxType,
      period,
      source: source || null,
      taxable_value: Number(taxableValue) || 0,
      tax_amount: Number(taxAmount) || 0,
    });

    setLoading(false);

    if (error) {
      setError(friendlyError(error.message));
      return;
    }

    setSource("");
    setTaxableValue("");
    setTaxAmount("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Log a tax record</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Tax type</label>
          <select
            value={taxType}
            onChange={(e) => setTaxType(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            <option value="GST">GST</option>
            <option value="TDS">TDS</option>
            <option value="TCS">TCS</option>
          </select>
        </div>

        <Field
          id="tax-period"
          label="Period"
          required
          value={period}
          onChange={(e) => setPeriod(e.target.value)}
          placeholder="Sep 2026"
        />
        <Field
          id="tax-source"
          label="Source"
          value={source}
          onChange={(e) => setSource(e.target.value)}
          placeholder="Amazon settlement statement"
        />
        <Field
          id="tax-taxable-value"
          label="Taxable value (₹)"
          type="number"
          value={taxableValue}
          onChange={(e) => setTaxableValue(e.target.value)}
        />
        <Field
          id="tax-amount"
          label="Tax amount (₹)"
          type="number"
          required
          value={taxAmount}
          onChange={(e) => setTaxAmount(e.target.value)}
        />

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Logging…" : "Log record"}
        </Button>
      </form>
    </div>
  );
}
