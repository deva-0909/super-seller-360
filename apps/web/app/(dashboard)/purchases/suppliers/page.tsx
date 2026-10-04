import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";

export default async function SuppliersPage() {
  const user = await getCurrentUser();
  const canWrite = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const supabase = await createClient();
  const { data: suppliers } = await supabase
    .from("suppliers")
    .select("supplier_id, name, gstin, state_code, is_msme, tds_section, payment_terms_days, status")
    .order("name");

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Suppliers</h1>
          <p className="mt-1 text-sm text-ink-muted">A new supplier, or a change to its GSTIN, TDS or bank account, must be approved by a second person before bills can be entered.</p>
        </div>
        {canWrite ? <Link href="/purchases/suppliers/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">Add supplier</Link> : null}
      </div>
      <div className="mt-6 border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead>
            <tr className="border-b border-line-strong text-xs text-ink-muted">
              <th className="px-4 py-3 font-medium">Supplier</th>
              <th className="px-4 py-3 font-medium">GSTIN</th>
              <th className="px-4 py-3 font-medium">TDS</th>
              <th className="px-4 py-3 font-medium">Terms</th>
              <th className="px-4 py-3 font-medium">Status</th>
            </tr>
          </thead>
          <tbody>
            {(suppliers ?? []).map((s, i) => (
              <tr key={s.supplier_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3"><Link href={`/purchases/suppliers/${s.supplier_id}`} className="text-accent hover:underline">{s.name}</Link>{s.is_msme ? <span className="ml-2 text-xs text-ink-muted">MSME</span> : null}</td>
                <td className="px-4 py-3 font-data text-ink-muted">{s.gstin ?? "Unregistered"}</td>
                <td className="px-4 py-3 text-ink-muted">{s.tds_section ?? "—"}</td>
                <td className="px-4 py-3 text-ink-muted">{s.payment_terms_days} days</td>
                <td className="px-4 py-3"><StatusTag status={s.status} /></td>
              </tr>
            ))}
            {!suppliers?.length ? <tr><td colSpan={5} className="px-4 py-8 text-center text-sm text-ink-muted">No suppliers yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
