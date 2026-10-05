import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentUser } from "@/lib/current-user";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";

export default async function ExpensesPage({ searchParams }: { searchParams: Promise<{ view?: string }> }) {
  const sp = await searchParams;
  const user = await getCurrentUser();
  const reviewer = ["Super Admin", "Finance Manager", "Operations Manager"].includes(user.roleName);
  const finance = ["Super Admin", "Finance Manager"].includes(user.roleName);
  const payer = ["Super Admin", "Finance Manager", "Accountant"].includes(user.roleName);
  const views = [{ key: "mine", label: "My claims" }, ...(reviewer ? [{ key: "review", label: "To review" }] : []), ...(payer ? [{ key: "pay", label: "To pay" }] : []), ...((reviewer || payer) ? [{ key: "all", label: "All claims" }] : [])];
  const view = views.some((v) => v.key === sp.view) ? sp.view! : "mine";

  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  let q = supabase.from("expense_claims").select("claim_id, claim_no, claimant_name, title, total, status, submitted_at, created_at").order("created_at", { ascending: false }).limit(300);
  if (view === "mine") q = q.eq("claimant_id", auth.user?.id ?? "");
  if (view === "review") q = q.in("status", finance ? ["submitted", "manager_approved"] : ["submitted"]);
  if (view === "pay") q = q.eq("status", "approved");
  const { data: claims } = await q;

  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Expense claims</h1>
          <p className="mt-1 text-sm text-ink-muted">Staff reimbursements. Courier and marketplace claims are under Claims.</p>
        </div>
        <Link href="/expenses/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">New claim</Link>
      </div>
      <div className="mt-4 flex gap-4 overflow-x-auto text-sm">
        {views.map((v) => <Link key={v.key} href={`?view=${v.key}`} className={`whitespace-nowrap ${v.key === view ? "font-medium text-ink" : "text-accent hover:underline"}`}>{v.label}</Link>)}
      </div>
      <div className="mt-4 border border-line bg-surface overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted">
            <th className="px-4 py-3 font-medium">Claim</th><th className="px-4 py-3 font-medium">By</th><th className="px-4 py-3 font-medium">Title</th>
            <th className="px-4 py-3 font-medium text-right">Amount</th><th className="px-4 py-3 font-medium">Status</th></tr></thead>
          <tbody>
            {(claims ?? []).map((c, i) => (
              <tr key={c.claim_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/expenses/${c.claim_id}`}>{c.claim_no}</Link></td>
                <td className="px-4 py-3 text-ink">{c.claimant_name}</td>
                <td className="px-4 py-3 text-ink-muted">{c.title}</td>
                <td className="px-4 py-3 text-right font-data text-ink">{inr(Number(c.total))}</td>
                <td className="px-4 py-3"><StatusTag status={c.status === "manager_approved" ? "reviewed" : c.status === "approved" ? "to be paid" : c.status} /></td>
              </tr>
            ))}
            {!claims?.length ? <tr><td colSpan={5} className="px-4 py-8 text-center text-sm text-ink-muted">Nothing here.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
