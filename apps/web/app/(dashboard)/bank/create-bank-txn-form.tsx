"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Field } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { friendlyError } from "@/lib/friendly-error";

type Account = { bank_account_id: string; bank_name: string; account_number_last4: string | null };

export function CreateBankTxnForm({ accounts }: { accounts: Account[] }) {
  const router = useRouter();
  const supabase = createClient();
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  // Account fields
  const [bankName, setBankName] = useState("");
  const [accountName, setAccountName] = useState("");
  const [last4, setLast4] = useState("");

  // Transaction fields
  const [accountId, setAccountId] = useState(accounts[0]?.bank_account_id ?? "");
  const [txnDate, setTxnDate] = useState("");
  const [reference, setReference] = useState("");
  const [amount, setAmount] = useState("");
  const [type, setType] = useState("credit");

  async function handleCreateAccount(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);

    const { data: company } = await supabase
      .from("companies")
      .select("company_id")
      .limit(1)
      .single();

    const { error } = await supabase.from("bank_accounts").insert({
      company_id: company?.company_id,
      bank_name: bankName,
      account_name: accountName,
      account_number_last4: last4,
    });

    setLoading(false);
    if (error) {
      setError(friendlyError(error.message));
      return;
    }
    router.refresh();
  }

  async function handleCreateTxn(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (Number(amount) <= 0) {
      setError("Amount must be greater than zero.");
      return;
    }
    setLoading(true);

    const { error } = await supabase.from("bank_transactions").insert({
      bank_account_id: accountId,
      txn_date: txnDate,
      reference: reference || null,
      amount: Number(amount),
      type,
    });

    setLoading(false);
    if (error) {
      setError(friendlyError(error.message));
      return;
    }
    setReference("");
    setAmount("");
    router.refresh();
  }

  if (!accounts.length) {
    return (
      <div className="h-fit border border-line bg-surface p-5">
        <h2 className="text-sm font-semibold text-ink">Add a bank account</h2>
        <p className="mt-1 text-xs text-ink-muted">
          Needed before you can log transactions against it.
        </p>
        <form onSubmit={handleCreateAccount} className="mt-4 flex flex-col gap-4">
          <Field
            id="bank-name"
            label="Bank name"
            required
            value={bankName}
            onChange={(e) => setBankName(e.target.value)}
            placeholder="HDFC Bank"
          />
          <Field
            id="account-name"
            label="Account name"
            required
            value={accountName}
            onChange={(e) => setAccountName(e.target.value)}
            placeholder="Super Seller 360 Current Account"
          />
          <Field
            id="last4"
            label="Last 4 digits"
            maxLength={4}
            value={last4}
            onChange={(e) => setLast4(e.target.value)}
            placeholder="4821"
          />
          {error ? <p className="text-sm text-danger">{error}</p> : null}
          <Button type="submit" disabled={loading}>
            {loading ? "Adding…" : "Add account"}
          </Button>
        </form>
      </div>
    );
  }

  return (
    <div className="h-fit border border-line bg-surface p-5">
      <h2 className="text-sm font-semibold text-ink">Log a transaction</h2>
      <form onSubmit={handleCreateTxn} className="mt-4 flex flex-col gap-4">
        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Account</label>
          <select
            value={accountId}
            onChange={(e) => setAccountId(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            {accounts.map((a) => (
              <option key={a.bank_account_id} value={a.bank_account_id}>
                {a.bank_name} •• {a.account_number_last4}
              </option>
            ))}
          </select>
        </div>

        <Field
          id="txn-date"
          label="Date"
          type="date"
          required
          value={txnDate}
          onChange={(e) => setTxnDate(e.target.value)}
        />
        <Field
          id="txn-reference"
          label="Reference"
          value={reference}
          onChange={(e) => setReference(e.target.value)}
          placeholder="NEFT-AMZ-8821"
        />
        <Field
          id="txn-amount"
          label="Amount (₹)"
          type="number"
          required
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
        />

        <div className="flex flex-col gap-1.5">
          <label className="text-sm font-medium text-ink">Type</label>
          <select
            value={type}
            onChange={(e) => setType(e.target.value)}
            className="h-10 border border-line bg-surface px-3 text-sm text-ink outline-none focus:border-accent"
          >
            <option value="credit">Credit</option>
            <option value="debit">Debit</option>
          </select>
        </div>

        {error ? <p className="text-sm text-danger">{error}</p> : null}

        <Button type="submit" disabled={loading}>
          {loading ? "Logging…" : "Log transaction"}
        </Button>
      </form>
    </div>
  );
}
