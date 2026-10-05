import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";
import { RunActions } from "./run-actions";

export default async function RunPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: run } = await supabase.from("payment_runs").select("run_id, run_no, run_date, status, total, note, bank_accounts(bank_name, account_name)").eq("run_id", id).maybeSingle();
  if (!run) notFound();
  const [{ data: items }, { data: canWrite }, { data: canApprove }] = await Promise.all([
    supabase.from("payment_run_items").select("item_id, supplier_id, amount, status, payment_id, suppliers(name), purchase_bills(bill_no)").eq("run_id", id).order("supplier_id"),
    supabase.rpc("has_accounting_write"), supabase.rpc("has_purchase_approve"),
  ]);
  const payIds = (items ?? []).map((i) => i.payment_id).filter(Boolean) as string[];
  const { data: pays } = payIds.length ? await supabase.from("supplier_payments").select("payment_id, payment_no, status, utr").in("payment_id", payIds) : { data: [] };
  const pm = new Map((pays ?? []).map((p) => [p.payment_id, p]));
  const suppliers = [...new Map((items ?? []).map((i) => [i.supplier_id, (i.suppliers as unknown as { name: string } | null)?.name ?? ""])).entries()].map(([supplier_id, name]) => ({ supplier_id, name }));
  const pendingPayments = (pays ?? []).filter((p) => p.status === "pending").length;
  const bank = run.bank_accounts as unknown as { bank_name: string; account_name: string } | null;

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/payment-runs" className="text-sm text-ink-muted hover:text-ink">← Payment runs</Link>
      <h1 className="mt-2 text-lg font-semibold tracking-tight text-ink">{run.run_no} <StatusTag status={run.status} /></h1>
      <p className="mt-1 text-sm text-ink-muted">From {bank?.bank_name} · {bank?.account_name} · pay date {run.run_date} · total ₹{inr(Number(run.total))}{run.note ? ` · ${run.note}` : ""}</p>

      <RunActions runId={run.run_id} runNo={run.run_no} status={run.status} suppliers={suppliers} canWrite={canWrite === true} canApprove={canApprove === true} pendingPayments={pendingPayments} />

      <div className="mt-6 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Supplier</th><th className="px-4 py-3 font-medium">Bill</th><th className="px-4 py-3 text-right font-medium">Amount</th><th className="px-4 py-3 font-medium">Status</th><th className="px-4 py-3 font-medium">Payment</th></tr></thead>
          <tbody>
            {(items ?? []).map((i) => {
              const p = i.payment_id ? pm.get(i.payment_id) : null;
              return (
                <tr key={i.item_id} className="border-b border-line last:border-0">
                  <td className="px-4 py-3 text-ink">{(i.suppliers as unknown as { name: string } | null)?.name}</td>
                  <td className="px-4 py-3 font-data text-xs">{(i.purchase_bills as unknown as { bill_no: string } | null)?.bill_no}</td>
                  <td className="px-4 py-3 text-right font-data">{inr(Number(i.amount))}</td>
                  <td className="px-4 py-3"><StatusTag status={i.status} /></td>
                  <td className="px-4 py-3 text-xs">{p ? <span>{p.payment_no} · UTR {p.utr} · <StatusTag status={p.status} /></span> : ""}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
