import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";

export default async function CreditNotesPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const sp = await searchParams;
  const status = ["pending", "approved", "all"].includes(sp.status ?? "") ? sp.status! : "pending";
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  let q = supabase.from("supplier_credit_notes").select("note_id, note_no, supplier_note_no, note_date, reason, total, status, suppliers(name), purchase_bills(bill_no)").order("created_at", { ascending: false }).limit(300);
  if (status !== "all") q = q.eq("status", status);
  const { data: notes } = await q;
  const { count: waiting } = await supabase.from("supplier_credit_notes").select("note_id", { count: "exact", head: true }).eq("status", "pending");
  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Supplier credit notes</h1>
          <p className="mt-1 text-sm text-ink-muted">{waiting ? `${waiting} credit note${waiting === 1 ? "" : "s"} waiting for approval.` : "Nothing waiting for approval."} A credit note from a supplier reduces what you owe on a bill, and reverses the GST credit you claimed on it.</p>
        </div>
        {canWrite ? <Link href="/purchases/credit-notes/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">Record a credit note</Link> : null}
      </div>
      <div className="mt-4 flex gap-4 text-sm">
        {["pending", "approved", "all"].map((f) => <Link key={f} href={`?status=${f}`} className={f === status ? "font-medium text-ink" : "text-accent hover:underline"}>{f === "all" ? "All" : f[0].toUpperCase() + f.slice(1)}</Link>)}
      </div>
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Note</th><th className="px-4 py-3 font-medium">Supplier</th><th className="px-4 py-3 font-medium">Supplier’s number</th><th className="px-4 py-3 font-medium">Against</th>
            <th className="px-4 py-3 font-medium">Date</th><th className="px-4 py-3 text-right font-medium">Total</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(notes ?? []).map((n, i) => (
              <tr key={n.note_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/credit-notes/${n.note_id}`}>{n.note_no}</Link></td>
                <td className="px-4 py-3 text-ink">{(n.suppliers as unknown as { name: string } | null)?.name}</td>
                <td className="px-4 py-3 text-ink-muted">{n.supplier_note_no}</td>
                <td className="px-4 py-3 text-ink-muted">{(n.purchase_bills as unknown as { bill_no: string } | null)?.bill_no}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{new Date(n.note_date).toLocaleDateString("en-IN")}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(n.total))}</td>
                <td className="px-4 py-3"><StatusTag status={n.status} /></td>
              </tr>
            ))}
            {!notes?.length ? <tr><td colSpan={7} className="px-4 py-8 text-center text-ink-muted">No credit notes here.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
