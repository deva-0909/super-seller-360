import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";

const FILTERS = ["pending", "approved", "all"] as const;

export default async function BillsPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const sp = await searchParams;
  const status = (FILTERS as readonly string[]).includes(sp.status ?? "") ? (sp.status as (typeof FILTERS)[number]) : "pending";
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  let q = supabase
    .from("purchase_bills")
    .select("bill_id, bill_no, supplier_invoice_no, bill_date, due_date, total, tds_amount, net_payable, status, is_opening, suppliers(name)")
    .order("created_at", { ascending: false })
    .limit(300);
  if (status !== "all") q = q.eq("status", status);
  const { data: bills } = await q;
  const { count: waiting } = await supabase.from("purchase_bills").select("bill_id", { count: "exact", head: true }).eq("status", "pending");

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Purchase bills</h1>
          <p className="mt-1 text-sm text-ink-muted">{waiting ? `${waiting} bill${waiting === 1 ? "" : "s"} waiting for approval.` : "Nothing waiting for approval."}</p>
        </div>
        {canWrite ? (
          <div className="flex gap-2">
            <Link href="/purchases/bills/opening" className="inline-flex h-10 items-center rounded-lg border border-line bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-sunken">Opening balances</Link>
            <Link href="/purchases/bills/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">Enter a bill</Link>
          </div>
        ) : null}
      </div>
      <div className="mt-4 flex gap-4 text-sm">
        {FILTERS.map((f) => (
          <Link key={f} href={`?status=${f}`} className={f === status ? "font-medium text-ink" : "text-accent hover:underline"}>{f === "all" ? "All" : f[0].toUpperCase() + f.slice(1)}</Link>
        ))}
      </div>
      <div className="mt-4 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Bill</th>
              <th className="px-4 py-3 font-medium">Supplier</th>
              <th className="px-4 py-3 font-medium">Invoice</th>
              <th className="px-4 py-3 font-medium">Due</th>
              <th className="px-4 py-3 font-medium text-right">Total</th>
              <th className="px-4 py-3 font-medium text-right">TDS</th>
              <th className="px-4 py-3 font-medium">Status</th>
            </tr>
          </thead>
          <tbody>
            {(bills ?? []).map((b, i) => (
              <tr key={b.bill_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/bills/${b.bill_id}`}>{b.bill_no}</Link>{b.is_opening ? <span className="ml-2 text-xs text-ink-muted">opening</span> : null}</td>
                <td className="px-4 py-3 text-ink">{(b.suppliers as unknown as { name: string } | null)?.name}</td>
                <td className="px-4 py-3 text-ink-muted">{b.supplier_invoice_no}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(b.due_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(b.total))}</td>
                <td className="px-4 py-3 text-right font-data text-ink-muted">{inr(Number(b.tds_amount))}</td>
                <td className="px-4 py-3"><StatusTag status={b.status} /></td>
              </tr>
            ))}
            {!bills?.length ? <tr><td colSpan={7} className="px-4 py-8 text-center text-sm text-ink-muted">No bills here.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
