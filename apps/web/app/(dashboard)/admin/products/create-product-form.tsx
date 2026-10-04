"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

export function CreateProductForm() {
  const router = useRouter();
  const supabase = createClient();

  const [sku, setSku] = useState("");
  const [name, setName] = useState("");
  const [category, setCategory] = useState("");
  const [hsn, setHsn] = useState("");
  const [gstRate, setGstRate] = useState("");
  const [costPrice, setCostPrice] = useState("");
  const [timeoutDays, setTimeoutDays] = useState("");
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

    const { error } = await supabase.from("products").insert({
      company_id: company?.company_id,
      sku,
      name,
      category: category || null,
      hsn: hsn || null,
      gst_rate: gstRate ? Number(gstRate) : null,
      cost_price: costPrice ? Number(costPrice) : null,
      stock_timeout_days: Number(timeoutDays),
    });

    setLoading(false);

    if (error) {
      setError(friendlyError(error.message));
      return;
    }

    setSku("");
    setName("");
    setCategory("");
    setHsn("");
    setGstRate("");
    setCostPrice("");
    setTimeoutDays("");
    router.refresh();
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Add a product</h2>
      <form onSubmit={handleSubmit} className="mt-4 flex flex-col gap-4">
        <Field
          id="product-sku"
          label="SKU"
          required
          value={sku}
          onChange={(e) => setSku(e.target.value)}
          placeholder="TS-BLK-M"
        />
        <Field
          id="product-name"
          label="Name"
          required
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Classic Crew T-Shirt - Black"
        />
        <Field
          id="product-category"
          label="Category"
          value={category}
          onChange={(e) => setCategory(e.target.value)}
          placeholder="Apparel"
        />
        <Field
          id="product-hsn"
          label="HSN code"
          value={hsn}
          onChange={(e) => setHsn(e.target.value)}
          placeholder="610910"
        />
        <div className="grid grid-cols-2 gap-3">
          <Field
            id="product-gst"
            label="GST rate %"
            type="number"
            value={gstRate}
            onChange={(e) => setGstRate(e.target.value)}
          />
          <Field
            id="product-cost"
            label="Cost price (₹)"
            type="number"
            value={costPrice}
            onChange={(e) => setCostPrice(e.target.value)}
          />
        </div>

        <Field
          id="product-timeout"
          label="Stock time-out (days)"
          type="number"
          min={1}
          max={1095}
          required
          value={timeoutDays}
          onChange={(e) => setTimeoutDays(e.target.value)}
          placeholder="90"
          hint="Max days this SKU's stock should sit unsold, counted from the last stock receipt. You'll be alerted 15 days before. Seasonal/occasion wear: 30–60; basics: 180."
        />

        {error ? (
          <p role="alert" className="text-sm text-danger">
            {error}
          </p>
        ) : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Adding…" : "Add product"}
        </Button>
      </form>
    </div>
  );
}
