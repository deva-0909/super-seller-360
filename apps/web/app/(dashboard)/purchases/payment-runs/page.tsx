import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { StatusTag } from "@/components/purchases/bits";
import { inr } from "@/lib/report-utils";

export default async function PaymentRunsPage() {
  const supabase = await createClient();
  const [{ data: runs }, { data: canWrite }] = await Promise.all([
    supabase.from("payment_runs").select("run_id, run_no, run_date, status, total, note").order("created_at", { ascending: false }).limit(100),
    supabase.rpc("has_accounting_write"),
  ]);
  return (
    <div className="px-4 md:px-8 py-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-semibold tracking-tight text-ink">Payment runs</h1>
          <p className="mt-1 max-w-2xl text-sm text-ink-muted">Pay every bill that is due in one go: pick the bills, send the bank file, enter the UTRs, and a Finance Manager approves all the payments with one click.</p>
        </div>
        {canWrite === true ? <Link href="/purchases/payment-runs/new" className="inline-flex h-10 items-center rounded-lg bg-accent px-4 text-sm font-semibold text-white hover:bg-accent-hover">New payment run</Link> : null}
      </div>
      <div className="mt-4 overflow-x-auto border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead><tr className="border-b border-line-strong text-xs text-ink-muted"><th className="px-4 py-3 font-medium">Run</th><th className="px-4 py-3 font-medium">Pay date</th><th className="px-4 py-3 text-right font-medium">Total</th><th className="px-4 py-3 font-medium">Status</th><th className="px-4 py-3 font-medium">Note</th></tr></thead>
          <tbody>
            {(runs ?? []).map((r, i) => (
              <tr key={r.run_id} className={i % 2 === 1 ? "bg-surface-sunken/50" : undefined}>
                <td className="px-4 py-3"><Link className="text-accent hover:underline" href={`/purchases/payment-runs/${r.run_id}`}>{r.run_no}</Link></td>
                <td className="px-4 py-3 text-ink-muted">{r.run_date}</td><td className="px-4 py-3 text-right font-data">{inr(Number(r.total))}</td><td className="px-4 py-3"><StatusTag status={r.status} /></td><td className="px-4 py-3 text-ink-muted">{r.note ?? ""}</td>
              </tr>
            ))}
            {(runs ?? []).length === 0 ? <tr><td colSpan={5} className="px-4 py-6 text-ink-muted">No payment runs yet.</td></tr> : null}
          </tbody>
        </table>
      </div>
    </div>
  );
}
