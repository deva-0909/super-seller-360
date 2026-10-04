import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";

export default async function PaymentsPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const sp = await searchParams;
  const status = ["pending", "approved", "all"].includes(sp.status ?? "") ? sp.status! : "pending";
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  let q = supabase.from("supplier_payments").select("payment_id, payment_no, payment_date, mode, amount, utr, status, suppliers(name)").order("created_at", { ascending: false }).limit(300);
  if (status !== "all") q = q.eq("status", status);
  const { data: pays } = await q;
  const { count: waiting } = await supabase.from("supplier_payments").select("payment_id", { count: "exact", head: true }).eq("status", "pending");
  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Supplier payments</h1>
          <p className="mt-1 text-sm text-ink-muted">{waiting ? `${waiting} payment${waiting === 1 ? "" : "s"} waiting for approval.` : "Nothing waiting for approval."}</p>
        </div>
        {canWrite ? <Link href="/purchases/payments/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">Record a payment</Link> : null}
      </div>
      <div className="mt-4 flex gap-4 text-sm">
        {["pending", "approved", "all"].map((f) => <Link key={f} href={`?status=${f}`} className={f === status ? "font-medium text-ink" : "text-accent hover:underline"}>{f === "all" ? "All" : f[0].toUpperCase() + f.slice(1)}</Link>)}
      </div>
      <div className="mt-4 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Payment</th><th className="px-4 py-3 font-medium">Supplier</th><th className="px-4 py-3 font-medium">Date</th>
            <th className="px-4 py-3 font-medium">Mode</th><th className="px-4 py-3 font-medium text-right">Amount</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(pays ?? []).map((p, i) => (
              <tr key={p.payment_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/payments/${p.payment_id}`}>{p.payment_no}</Link></td>
                <td className="px-4 py-3 text-ink">{(p.suppliers as unknown as { name: string } | null)?.name}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(p.payment_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-ink-muted">{p.mode}{p.utr ? ` · ${p.utr}` : ""}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(p.amount))}</td>
                <td className="px-4 py-3"><StatusTag status={p.status} /></td>
              </tr>
            ))}
            {!pays?.length ? <tr><td colSpan={6} className="px-4 py-8 text-center text-sm text-ink-muted">No payments here.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
