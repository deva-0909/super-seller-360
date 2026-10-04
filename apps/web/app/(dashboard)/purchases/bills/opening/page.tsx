import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { inr } from "@/lib/report-utils";
import { OpeningForm } from "./opening-form";

export default async function OpeningBalancesPage() {
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const [{ data: suppliers }, { data: done }] = await Promise.all([
    supabase.from("suppliers").select("supplier_id, name, gstin, status, payment_terms_days").neq("status", "blocked").order("name"),
    supabase.from("purchase_bills").select("bill_id, bill_no, supplier_invoice_no, supplier_invoice_date, due_date, total, status, suppliers(name)").eq("is_opening", true).in("status", ["pending", "approved"]).order("created_at", { ascending: false }).limit(200),
  ]);
  const approved = (done ?? []).filter((b) => b.status === "approved").reduce((t, b) => t + Number(b.total), 0);
  const pending = (done ?? []).filter((b) => b.status === "pending").reduce((t, b) => t + Number(b.total), 0);

  return (
    <div className="px-4 md:px-8 py-8">
      <Link href="/purchases/bills" className="text-sm text-ink-muted hover:text-ink">← Bills</Link>
      <h1 className="mt-3 text-lg font-semibold tracking-tight text-ink">Supplier opening balances</h1>
      <p className="mt-1 max-w-2xl text-sm text-ink-muted">
        Enter each unpaid supplier invoice as it stood on the day you started using this app. They then show in creditors ageing and can be paid like any bill. No GST or TDS is booked on them (that was done when the invoice was first booked). A second person approves them, and approval posts Dr Opening Balance Equity, Cr Sundry Creditors.
      </p>
      <p className="mt-2 text-sm text-ink-muted">
        Entered so far: approved {inr(approved) === "—" ? "₹0.00" : inr(approved)}, waiting for approval {inr(pending) === "—" ? "₹0.00" : inr(pending)}. The total should match what your old books showed as owed to suppliers.
      </p>
      {canWrite ? (
        <OpeningForm suppliers={(suppliers ?? []).map((s) => ({ supplier_id: s.supplier_id, name: s.name, gstin: s.gstin, status: s.status }))} />
      ) : <p className="mt-4 text-sm text-ink-muted">Your role can view opening balances but not enter them.</p>}

      <h2 className="mt-10 text-sm font-semibold text-ink">Already entered</h2>
      <div className="mt-2 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Bill</th><th className="px-4 py-3 font-medium">Supplier</th><th className="px-4 py-3 font-medium">Invoice</th><th className="px-4 py-3 font-medium">Due</th><th className="px-4 py-3 text-right font-medium">Amount</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(done ?? []).map((b) => (
              <tr key={b.bill_id} className="border-b border-line last:border-0">
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/bills/${b.bill_id}`}>{b.bill_no}</Link></td>
                <td className="px-4 py-3 text-ink">{(b.suppliers as unknown as { name: string } | null)?.name}</td>
                <td className="px-4 py-3 text-ink-muted">{b.supplier_invoice_no} · {new Date(b.supplier_invoice_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(b.due_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(b.total))}</td>
                <td className="px-4 py-3 text-ink-muted">{b.status}</td>
              </tr>
            ))}
            {!done?.length ? <tr><td colSpan={6} className="px-4 py-8 text-center text-ink-muted">None yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
