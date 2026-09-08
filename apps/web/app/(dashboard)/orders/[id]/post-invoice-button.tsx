"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";

export function PostInvoiceButton({ orderId }: { orderId: string }) {
  const router = useRouter();
  const supabase = createClient();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handlePost() {
    setLoading(true);
    setError(null);

    const { error } = await supabase.rpc("post_sales_voucher", {
      p_order_id: orderId,
    });

    setLoading(false);

    if (error) {
      setError(error.message);
      return;
    }

    router.refresh();
  }

  return (
    <div className="flex items-center justify-between">
      <div>
        <p className="text-sm text-ink">Not yet invoiced.</p>
        <p className="mt-1 text-xs text-ink-muted">
          Posts a balanced sales voucher — Trade Receivables debited, Sales
          Revenue and GST Payable credited.
        </p>
        {error ? <p className="mt-2 text-sm text-danger">{error}</p> : null}
      </div>
      <Button
        onClick={handlePost}
        disabled={loading}
        className="w-auto px-4"
      >
        {loading ? "Posting…" : "Generate invoice & post"}
      </Button>
    </div>
  );
}
