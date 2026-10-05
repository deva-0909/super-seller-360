import { createClient } from "@/lib/supabase/server";
import { NewRun } from "./new-run";

export default async function NewRunPage({ searchParams }: { searchParams: Promise<{ due?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const due = /^\d{4}-\d{2}-\d{2}$/.test(sp.due ?? "") ? sp.due! : new Date().toISOString().slice(0, 10);
  const [{ data: canWrite }, { data: banks }, { data: cands }] = await Promise.all([
    supabase.rpc("has_accounting_write"),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_name, account_number_last4").eq("status", "active"),
    supabase.rpc("payment_run_candidates", { p_due_by: due }),
  ]);
  const rows = ((cands ?? []) as { bill_id: string; bill_no: string; supplier_id: string; supplier_name: string; due_date: string; outstanding: number; is_msme: boolean; msme_days_left: number | null; has_bank: boolean }[]).map((c) => ({ ...c, outstanding: Number(c.outstanding) }));
  return (
    <div className="px-4 md:px-8 py-8">
      <h1 className="text-lg font-semibold tracking-tight text-ink">New payment run</h1>
      {canWrite === true ? <NewRun due={due} banks={(banks ?? []).map((b) => ({ id: b.bank_account_id, label: `${b.bank_name} · ${b.account_name} ····${b.account_number_last4}` }))} rows={rows} />
        : <p className="mt-4 text-sm text-ink-muted">Your role cannot make payment runs.</p>}
    </div>
  );
}
