"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";

type BankTxn = { bank_txn_id: string; txn_date: string; reference: string | null; amount: number };

export function ReconcileForm({
  settlementId,
  unmatchedTxns,
}: {
  settlementId: string;
  unmatchedTxns: BankTxn[];
}) {
  const router = useRouter();
  const supabase = createClient();

  const [actualAmount, setActualAmount] = useState("");
  const [bankTxnId, setBankTxnId] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { error } = await supabase.rpc("reconcile_settlement", {
      p_settlement_id: settlementId,
      p_actual_amount: Number(actualAmount),
      p_bank_txn_id: bankTxnId || null,
    });

    setLoading(false);

    if (error) {
      setError(error.message);
      return;
    }

    router.refresh();
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <Field
        id="actual-amount"
        label="Amount actually received (₹)"
        type="number"
        required
        value={actualAmount}
        onChange={(e) => setActualAmount(e.target.value)}
      />

      <div className="flex flex-col gap-1.5">
        <label className="text-sm font-medium text-ink">
          Match to a bank transaction (optional)
        </label>
        <select
          value={bankTxnId}
          onChange={(e) => setBankTxnId(e.target.value)}
          className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
        >
          <option value="">Don&apos;t link one</option>
          {unmatchedTxns.map((t) => (
            <option key={t.bank_txn_id} value={t.bank_txn_id}>
              {new Date(t.txn_date).toLocaleDateString()} — ₹
              {Number(t.amount).toLocaleString("en-IN")} ({t.reference ?? "no ref"})
            </option>
          ))}
        </select>
      </div>

      {error ? <p className="text-sm text-danger">{error}</p> : null}

      <Button type="submit" disabled={loading} className="w-auto px-4">
        {loading ? "Reconciling…" : "Reconcile"}
      </Button>
    </form>
  );
}
