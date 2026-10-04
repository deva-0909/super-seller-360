import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { Proofs } from "@/components/ui/proofs";
import { inr } from "@/lib/report-utils";
import { ExpenseActions } from "./expense-actions";

export default async function ExpensePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ issue?: string }> }) {
  const { id } = await params;
  const { issue } = await searchParams;
  const user = await getCurrentUser();
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  const { data: c } = await supabase.from("expense_claims").select("*").eq("claim_id", id).maybeSingle();
  if (!c) notFound();
  const [{ data: lines }, { data: set }, { data: banks }] = await Promise.all([
    supabase.from("expense_claim_lines").select("*, expense_categories(name)").eq("claim_id", id).order("line_no"),
    supabase.from("expense_settings").select("require_manager_step").eq("id", 1).maybeSingle(),
    supabase.from("bank_accounts").select("bank_account_id, bank_name, account_name, account_number_last4").eq("status", "active"),
  ]);
  const isOwner = c.claimant_id === auth.user?.id;
  const canReview = ["Super Admin", "Finance Manager", "Operations Manager"].includes(user.roleName);
  const canFinal = ["Super Admin", "Finance Manager"].includes(user.roleName);
  const canPay = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const label = c.status === "manager_approved" ? "reviewed" : c.status === "approved" ? "to be paid" : c.status;

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/expenses" className="text-sm text-ink-muted hover:text-ink">← Expense claims</Link>
      <h1 className="mt-3 text-lg font-semibold tracking-tight text-ink">{c.claim_no} <StatusTag status={label} /></h1>
      <p className="mt-1 text-sm text-ink-muted">{c.title} · {c.claimant_name} · {inr(Number(c.total))}</p>
      {c.decision_note ? <p className="mt-1 text-sm text-ink-muted">Note: {c.decision_note}</p> : null}
      {issue === "attach" ? <p className="mt-2 text-sm text-warning">The claim was saved, but the receipt could not be attached. Add it below, then submit.</p> : null}
      {issue === "submit" ? <p className="mt-2 text-sm text-warning">The claim was saved as a draft. Attach a receipt below, then submit it.</p> : null}
      {c.status === "paid" ? <p className="mt-1 text-sm text-ink-muted">Paid on {new Date(c.paid_on).toLocaleDateString("en-IN")} by {c.payment_mode}{c.payment_utr ? `, ref ${c.payment_utr}` : ""}.</p> : null}

      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Date</th><th className="px-4 py-3 font-medium">Category</th><th className="px-4 py-3 font-medium">For</th><th className="px-4 py-3 font-medium text-right">Amount</th></tr></thead>
          <tbody>
            {(lines ?? []).map((l) => (
              <tr key={l.line_id}>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(l.expense_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-ink-muted">{(l.expense_categories as unknown as { name: string } | null)?.name}</td>
                <td className="px-4 py-3 text-ink">{l.description}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(l.amount))}</td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr className="border-t border-line-strong text-sm font-medium"><td className="px-4 py-3" colSpan={3}>Total</td><td className="px-4 py-3 text-right font-data">{inr(Number(c.total))}</td></tr></tfoot>
        </table>
      </div>

      <div className="mt-4 border border-line bg-surface p-5">
        <Proofs entityType="expense_claim" entityId={id} readOnly={!((isOwner && c.status === "draft") || canPay)} kind="receipt" label="Receipts" hint="Take a photo of each bill, or pick it from the gallery." />
      </div>

      <ExpenseActions id={id} status={c.status} isOwner={isOwner} canReview={canReview} canFinal={canFinal} canPay={canPay} managerStep={set?.require_manager_step ?? true}
        banks={(banks ?? []).map((b) => ({ bank_account_id: b.bank_account_id, label: `${b.bank_name} · ${b.account_name}${b.account_number_last4 ? ` ····${b.account_number_last4}` : ""}` }))} />
      {c.voucher_id && canPay ? <p className="mt-3 text-sm"><Link className="text-accent hover:underline" href={`/accounting/vouchers/${c.voucher_id}`}>View the posted voucher</Link></p> : null}
    </div>
  );
}
