"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

const TYPES = [
  { value: "marketplace", label: "Marketplace" },
  { value: "d2c", label: "D2C storefront" },
  { value: "payment_gateway", label: "Payment gateway" },
];

export function CreateChannelForm() {
  const router = useRouter();
  const supabase = createClient();

  const [name, setName] = useState("");
  const [type, setType] = useState(TYPES[0].value);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { data: company } = await supabase
      .from("companies")
      .select("company_id")
      .limit(1)
      .single();

    const { error } = await supabase.from("channels").insert({
      company_id: company?.company_id,
      name,
      type,
    });

    setLoading(false);

    if (error) {
      setError(friendlyError(error.message));
      return;
    }

    setName("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Add a channel</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <Field
          id="channel-name"
          label="Name"
          required
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Shopify - Main Store"
        />

        <div className="flex flex-col gap-1.5">
          <label
            htmlFor="channel-type"
            className="text-sm font-medium text-ink"
          >
            Type
          </label>
          <select
            id="channel-type"
            value={type}
            onChange={(e) => setType(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            {TYPES.map((t) => (
              <option key={t.value} value={t.value}>
                {t.label}
              </option>
            ))}
          </select>
        </div>

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Adding…" : "Add channel"}
        </Button>
      </form>
    </div>
  );
}
