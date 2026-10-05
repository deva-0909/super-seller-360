import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";
import { SupplierForm } from "../supplier-form";
import { SupplierActions } from "./supplier-actions";

export default async function SupplierPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const canApprove = ["Super Admin", "Finance Manager"].includes(user.roleName);
  const supabase = await createClient();
  const { data: s } = await supabase.from("suppliers").select("*").eq("supplier_id", id).maybeSingle();
  if (!s) notFound();
  const [{ data: bank }, { data: states }, { data: sections }, { data: bills }, { data: pays }] = await Promise.all([
    supabase.from("supplier_bank").select("bank_name, ifsc, account_holder, account_last4").eq("supplier_id", id).maybeSingle(),
    supabase.from("gst_states").select("code, name").order("code"),
    supabase.from("tds_sections").select("section, description").eq("active", true).order("section"),
    supabase.from("purchase_bills").select("bill_id, bill_no, supplier_invoice_no, bill_date, total, tds_amount, net_payable, status").eq("supplier_id", id).order("bill_date", { ascending: false }).limit(50),
    supabase.from("supplier_payments").select("payment_id, payment_no, payment_date, amount, status").eq("supplier_id", id).order("payment_date", { ascending: false }).limit(50),
  ]);
  const billed = (bills ?? []).filter((b) => b.status === "approved").reduce((t, b) => t + Number(b.net_payable), 0);
  const paid = (pays ?? []).filter((p) => p.status === "approved").reduce((t, p) => t + Number(p.amount), 0);

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/suppliers" className="text-sm text-ink-muted hover:text-ink">← Suppliers</Link>
      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">{s.name} <StatusTag status={s.status} /></h1>
          <p className="mt-1 text-sm text-ink-muted">{s.gstin ?? "Unregistered"} · we owe {inr(billed - paid)} (approved bills less approved payments)</p>
          {s.status === "pending" ? <p className="mt-2 text-sm text-warning">Waiting for approval by a second person. Bills cannot be entered yet.</p> : null}
        </div>
        <SupplierActions id={id} status={s.status} canApprove={canApprove} />
      </div>

      {canWrite ? (
        <details className="mt-6 border border-line bg-surface p-4">
          <summary className="cursor-pointer text-sm font-semibold text-ink">Edit supplier details</summary>
          <SupplierForm init={{ ...s, ...(bank ?? {}) }} states={states ?? []} sections={sections ?? []} showBank />
        </details>
      ) : null}

      <h2 className="mt-8 text-sm font-semibold text-ink">Bills</h2>
      <div className="mt-2 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Bill</th><th className="px-4 py-3 font-medium">Invoice</th><th className="px-4 py-3 font-medium">Date</th>
            <th className="px-4 py-3 font-medium text-right">Net payable</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(bills ?? []).map((b) => (
              <tr key={b.bill_id}><td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/bills/${b.bill_id}`}>{b.bill_no}</Link></td>
                <td className="px-4 py-3 text-ink-muted">{b.supplier_invoice_no}</td><td className="px-4 py-3 font-data text-ink-muted">{new Date(b.bill_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(b.net_payable))}</td><td className="px-4 py-3"><StatusTag status={b.status} /></td></tr>
            ))}
            {!bills?.length ? <tr><td colSpan={5} className="px-4 py-6 text-center text-ink-muted">No bills.</td></tr> : null}
          </tbody>
        </table>
      </div>
      <h2 className="mt-8 text-sm font-semibold text-ink">Payments</h2>
      <div className="mt-2 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Payment</th><th className="px-4 py-3 font-medium">Date</th>
            <th className="px-4 py-3 font-medium text-right">Amount</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(pays ?? []).map((p) => (
              <tr key={p.payment_id}><td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/payments/${p.payment_id}`}>{p.payment_no}</Link></td>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(p.payment_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(p.amount))}</td><td className="px-4 py-3"><StatusTag status={p.status} /></td></tr>
            ))}
            {!pays?.length ? <tr><td colSpan={4} className="px-4 py-6 text-center text-ink-muted">No payments.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
