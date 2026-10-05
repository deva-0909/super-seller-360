import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { Proofs } from "@/components/ui/proofs";
import { inr } from "@/lib/report-utils";
import { PaymentActions } from "./payment-actions";

export default async function PaymentPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ attach?: string }> }) {
  const { id } = await params;
  const { attach } = await searchParams;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const canApprove = ["Super Admin", "Finance Manager"].includes(user.roleName);
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  const { data: p } = await supabase.from("supplier_payments").select("*, suppliers(name), bank_accounts(bank_name, account_name)").eq("payment_id", id).maybeSingle();
  if (!p) notFound();
  const { data: allocs } = await supabase.from("payment_allocations").select("amount, purchase_bills(bill_id, bill_no, supplier_invoice_no)").eq("payment_id", id);
  const allocated = (allocs ?? []).reduce((t, a) => t + Number(a.amount), 0);
  const bank = p.bank_accounts as unknown as { bank_name: string; account_name: string } | null;

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/payments" className="text-sm text-ink-muted hover:text-ink">← Payments</Link>
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">{p.payment_no} <StatusTag status={p.status} /></h1>
          <p className="mt-1 text-sm text-ink-muted">
            {inr(Number(p.amount))} to <Link href={`/purchases/suppliers/${p.supplier_id}`} className="text-accent hover:underline">{(p.suppliers as unknown as { name: string }).name}</Link> on {new Date(p.payment_date).toLocaleDateString("en-IN")}
            {" "}· {p.mode === "cash" ? "cash" : `${p.mode} from ${bank?.bank_name ?? ""} ${bank?.account_name ?? ""}, ref ${p.utr}`}
          </p>
          {p.decision_note ? <p className="mt-1 text-sm text-ink-muted">Note: {p.decision_note}</p> : null}
          {attach === "failed" ? <p className="mt-2 text-sm text-warning">The payment was saved, but the photo could not be attached. Add it below.</p> : null}
        </div>
        <PaymentActions id={id} status={p.status} canApprove={canApprove} isMaker={p.created_by === auth.user?.id} />
      </div>

      <div className="mt-6 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Bill paid</th><th className="px-4 py-3 font-medium text-right">Amount</th></tr></thead>
          <tbody>
            {(allocs ?? []).map((a) => {
              const b = a.purchase_bills as unknown as { bill_id: string; bill_no: string; supplier_invoice_no: string };
              return <tr key={b.bill_id}><td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/bills/${b.bill_id}`}>{b.bill_no}</Link> <span className="text-xs text-ink-muted">inv {b.supplier_invoice_no}</span></td><td className="px-4 py-3 text-right font-data text-ink">{inr(Number(a.amount))}</td></tr>;
            })}
            {Number(p.amount) - allocated > 0.004 ? <tr><td className="px-4 py-3 text-ink-muted">Advance / on account</td><td className="px-4 py-3 text-right font-data text-ink">{inr(Number(p.amount) - allocated)}</td></tr> : null}
          </tbody>
        </table>
      </div>
      {p.voucher_id ? <p className="mt-3 text-sm"><Link className="text-accent hover:underline" href={`/accounting/vouchers/${p.voucher_id}`}>View the posted voucher</Link></p> : null}
      <div className="mt-4 border border-line bg-surface p-5">
        <Proofs entityType="supplier_payment" entityId={id} readOnly={!canWrite} kind="receipt" label="Payment proof" hint="Take a photo or pick one from the gallery." />
      </div>
    </div>
  );
}
