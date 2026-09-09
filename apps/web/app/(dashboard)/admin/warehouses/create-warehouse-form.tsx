"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

const TYPES = [
  { value: "own", label: "Own warehouse" },
  { value: "marketplace_fulfilled", label: "Marketplace-fulfilled" },
  { value: "3pl", label: "3PL" },
];

export function CreateWarehouseForm() {
  const router = useRouter();
  const supabase = createClient();

  const [name, setName] = useState("");
  const [type, setType] = useState(TYPES[0].value);
  const [address, setAddress] = useState("");
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

    const { error } = await supabase.from("warehouses").insert({
      company_id: company?.company_id,
      name,
      type,
      address: address || null,
    });

    setLoading(false);

    if (error) {
      setError(friendlyError(error.message));
      return;
    }

    setName("");
    setAddress("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Add a warehouse</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <Field
          id="warehouse-name"
          label="Name"
          required
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Surat Main Warehouse"
        />

        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Type</label>
          <select
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

        <Field
          id="warehouse-address"
          label="Address"
          value={address}
          onChange={(e) => setAddress(e.target.value)}
          placeholder="Plot 14, GIDC Sachin, Surat"
        />

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Adding…" : "Add warehouse"}
        </Button>
      </form>
    </div>
  );
}
